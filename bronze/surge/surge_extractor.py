# bronze/surge/surge_extractor.py
#
# RÔLE : Surveille un dossier Google Drive, télécharge les
# CSV SURGE et les archive dans MinIO Bronze.
#
# FLUX :
#   Google Drive (surge_daily_logs)
#       → [ce fichier]
#       → MinIO Bronze (bronze/surge/contracts/2026/05/27/)
#       → bronze_meta.run_log
#
# STRUCTURE DRIVE ATTENDUE :
#   surge_daily_logs/
#   ├── surge_contracts/    ← CSV des contrats
#   ├── surge_payments/     ← CSV des transactions
#   └── surge_tasks/        ← CSV des tasks

import os
import sys
import time
import logging
import tempfile
from datetime import datetime, timezone

from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload
from dotenv import load_dotenv
import io

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, ensure_bucket_exists, upload_csv
from database.db_client import get_db_connection, init_schemas, init_run_log, log_run

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Mapping dossier Drive → nom entité dans notre pipeline
SURGE_FOLDERS = {
    "surge_contracts": "contracts",
    "surge_payments":  "payments",
    "surge_tasks":     "tasks",
}

SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]


def get_drive_service():
    """
    Crée et retourne un client Google Drive authentifié.

    Analogie : c'est comme présenter ta carte d'identité
    (google_credentials.json) à Google pour qu'il te laisse
    lire les fichiers du dossier partagé.
    """
    load_dotenv()
    creds_path = os.getenv("GOOGLE_CREDENTIALS_PATH", "config/google_credentials.json")

    if not os.path.exists(creds_path):
        raise FileNotFoundError(f"Fichier credentials introuvable : {creds_path}")

    creds = Credentials.from_service_account_file(creds_path, scopes=SCOPES)
    service = build("drive", "v3", credentials=creds)
    logger.info("Client Google Drive authentifié")
    return service


def find_folder_id(service, folder_name, parent_id=None):
    """
    Trouve l'ID d'un dossier Google Drive par son nom.

    Google Drive identifie chaque fichier/dossier par un ID
    unique (pas par son nom). Cette fonction fait la traduction
    nom → ID pour qu'on puisse lister son contenu.

    Args:
        service     : client Drive
        folder_name : nom du dossier à trouver
        parent_id   : ID du dossier parent (optionnel)

    Returns:
        str: l'ID du dossier, ou None si non trouvé
    """
    query = (
        f"name='{folder_name}' "
        f"and mimeType='application/vnd.google-apps.folder' "
        f"and trashed=false"
    )
    if parent_id:
        query += f" and '{parent_id}' in parents"

    results = service.files().list(
        q=query,
        fields="files(id, name)",
        spaces="drive"
    ).execute()

    files = results.get("files", [])
    if not files:
        logger.warning(f"Dossier introuvable : {folder_name}")
        return None

    folder_id = files[0]["id"]
    logger.info(f"Dossier trouvé : {folder_name} → {folder_id}")
    return folder_id


def list_csv_files(service, folder_id):
    """
    Liste tous les fichiers CSV dans un dossier Drive.

    Returns:
        list of dict: [{"id": ..., "name": ..., "modifiedTime": ...}]
    """
    query = (
        f"'{folder_id}' in parents "
        f"and mimeType='text/csv' "
        f"and trashed=false"
    )

    results = service.files().list(
        q=query,
        fields="files(id, name, modifiedTime, size)",
        orderBy="modifiedTime desc"
    ).execute()

    files = results.get("files", [])
    logger.info(f"Fichiers CSV trouvés : {len(files)}")
    return files


def download_csv(service, file_id, file_name):
    """
    Télécharge un fichier CSV depuis Drive vers un fichier
    temporaire local.

    On utilise un fichier temporaire car MinIO attend
    un chemin de fichier local (fput_object).
    Le fichier temporaire est supprimé après l'upload.

    Args:
        service : client Drive
        file_id : ID du fichier Drive
        file_name: nom du fichier (pour le log)

    Returns:
        str: chemin du fichier temporaire téléchargé
    """
    request = service.files().get_media(fileId=file_id)

    # Crée un fichier temporaire sur le disque
    tmp = tempfile.NamedTemporaryFile(
        delete=False,
        suffix=".csv",
        prefix=f"surge_{file_name}_"
    )

    downloader = MediaIoBaseDownload(tmp, request)

    done = False
    while not done:
        status, done = downloader.next_chunk()
        if status:
            logger.info(f"Téléchargement {file_name}: {int(status.progress() * 100)}%")

    tmp.close()
    logger.info(f"Fichier téléchargé → {tmp.name}")
    return tmp.name


def process_surge_folder(
    service, drive_folder_name, entity_name,
    parent_folder_id, minio_client, bucket, conn
):
    """
    Traite un dossier SURGE complet :
    1. Trouve le dossier dans Drive
    2. Liste les CSV dedans
    3. Télécharge le plus récent
    4. L'uploade dans MinIO Bronze
    5. Logue le run

    On prend uniquement le fichier le plus récent —
    c'est l'export du jour.

    Args:
        drive_folder_name: "surge_contracts", "surge_payments"...
        entity_name      : "contracts", "payments"...
        parent_folder_id : ID du dossier surge_daily_logs
    """
    start_time = time.time()

    # 1. Trouver le sous-dossier
    folder_id = find_folder_id(service, drive_folder_name, parent_folder_id)
    if not folder_id:
        logger.warning(f"Dossier {drive_folder_name} non trouvé — ignoré")
        return

    # 2. Lister les CSV
    csv_files = list_csv_files(service, folder_id)
    if not csv_files:
        logger.warning(f"Aucun CSV dans {drive_folder_name} — ignoré")
        return

    # 3. Prendre le plus récent (déjà trié par modifiedTime desc)
    # 3. Sélection du fichier
    # Pour surge_contracts : filtrer sur surge_crm_contracts (source CRM officielle)
    # Pour les autres dossiers : prendre le plus récent
    if drive_folder_name == "surge_contracts":
        crm_files = [f for f in csv_files if "surge_crm_contracts" in f["name"]]
        latest = crm_files[0] if crm_files else csv_files[0]
    else:
        latest = csv_files[0]
    logger.info(
        f"Fichier sélectionné : {latest['name']} "
        f"(modifié : {latest['modifiedTime']})"
    )

    tmp_path = None
    try:
        # 4. Télécharger
        tmp_path = download_csv(service, latest["id"], entity_name)

        # 5. Uploader dans MinIO Bronze
        object_key = upload_csv(
            client=minio_client,
            bucket_name=bucket,
            file_path=tmp_path,
            source="surge",
            entity=entity_name,
        )

        duration = time.time() - start_time

        # 6. Logger le run
        log_run(
            conn=conn,
            source="surge",
            entity=entity_name,
            status="success",
            rows_count=0,      # On comptera les lignes en Silver
            minio_prefix=object_key,
            duration_sec=duration,
        )

        logger.info(f"✅ {entity_name} → {object_key} ({duration:.1f}s)")

    except Exception as e:
        duration = time.time() - start_time
        log_run(
            conn=conn,
            source="surge",
            entity=entity_name,
            status="error",
            error_message=str(e),
            duration_sec=duration,
        )
        logger.error(f"❌ Erreur {entity_name} : {e}", exc_info=True)

    finally:
        # Toujours supprimer le fichier temporaire
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)
            logger.info(f"Fichier temporaire supprimé : {tmp_path}")


def main():
    """
    Point d'entrée principal.

    Séquence :
    1. Authentification Google Drive
    2. Trouver le dossier surge_daily_logs
    3. Pour chaque sous-dossier SURGE → télécharger + Bronze
    4. Logger tous les runs
    """
    load_dotenv()

    logger.info("=" * 50)
    logger.info("EXTRACTEUR SURGE — GOOGLE DRIVE → BRONZE")
    logger.info("=" * 50)

    # Connexions
    service      = get_drive_service()
    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    ensure_bucket_exists(minio_client, bucket)

    conn = get_db_connection()
    init_schemas(conn)
    init_run_log(conn)

    # Trouver le dossier racine surge_daily_logs
    root_folder_name = os.getenv("SURGE_DRIVE_FOLDER", "surge_daily_logs")
    root_folder_id   = find_folder_id(service, root_folder_name)

    if not root_folder_id:
        raise ValueError(
            f"Dossier Drive '{root_folder_name}' introuvable. "
            f"Vérifie qu'il est partagé avec le service account."
        )

    # Traiter chaque sous-dossier SURGE
    for drive_folder, entity in SURGE_FOLDERS.items():
        logger.info(f"\n--- Traitement : {drive_folder} ---")
        process_surge_folder(
            service=service,
            drive_folder_name=drive_folder,
            entity_name=entity,
            parent_folder_id=root_folder_id,
            minio_client=minio_client,
            bucket=bucket,
            conn=conn,
        )

    conn.close()

    logger.info("\n" + "=" * 50)
    logger.info("EXTRACTION SURGE TERMINÉE")
    logger.info("=" * 50)


if __name__ == "__main__":
    import sys

    # Si des arguments sont passés, on filtre les dossiers
    # python surge_extractor.py surge_payments surge_tasks
    if len(sys.argv) > 1:
        requested = sys.argv[1:]
        # Filtre SURGE_FOLDERS selon les arguments
        filtered = {k: v for k, v in SURGE_FOLDERS.items() if k in requested}
        if not filtered:
            logger.error(f"Dossiers inconnus : {requested}")
            logger.error(f"Dossiers valides : {list(SURGE_FOLDERS.keys())}")
            sys.exit(1)
        # Override temporaire
        original = SURGE_FOLDERS.copy()
        SURGE_FOLDERS.clear()
        SURGE_FOLDERS.update(filtered)

    main()