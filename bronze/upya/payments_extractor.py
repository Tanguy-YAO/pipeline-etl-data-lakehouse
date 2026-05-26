# RÔLE : Extraire les paiements depuis l'API UPYA et les
# sauvegarder en JSON dans MinIO Bronze.

# FLUX :
#   API UPYA → [ce fichier] → MinIO Bronze
#                           → bronze_meta.run_log

# CHARGEMENT : Incrémental — on ne tire que les paiements
# depuis le dernier run réussi (watermark).

import os
import sys
import json
import time
import logging
from datetime import datetime, timezone, timedelta

import requests
from requests.auth import HTTPBasicAuth
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from dotenv import load_dotenv

# On importe nos deux briques de base (Modules 2)
sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, ensure_bucket_exists, upload_json
from database.db_client import get_db_connection, init_schemas, init_run_log, log_run, get_last_successful_run

# --- Logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Constantes ---
API_URL  = "https://data.upya.io/data/search/payments"
HEADERS  = {"Content-Type": "application/json", "Accept": "application/json"}
PER_PAGE = 500


def build_session():
    """
    Crée une session HTTP avec retry automatique.

    Analogie : c'est comme un livreur qui réessaie de
    sonner à la porte si personne ne répond, jusqu'à
    3 tentatives avec une pause entre chaque essai.

    Les codes 429, 500, 502, 503, 504 déclenchent un retry :
    - 429 = "trop de requêtes, ralentis"
    - 5xx = erreurs serveur temporaires
    """
    session = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=1.0,        # attend 1s, puis 2s, puis 4s
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("POST",),
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    return session


def get_watermark(conn):
    """
    Retourne la date de départ pour l'extraction.

    Logique :
    1. On cherche le dernier run réussi dans run_log
    2. Si trouvé → on repart de cette date - 1 jour (sécurité)
    3. Si jamais extrait → on repart du début (2023-08-01)

    Pourquoi -1 jour ?
    Certains paiements peuvent arriver avec un léger retard
    dans l'API. Le -1 jour évite de les manquer.
    """
    last_run = get_last_successful_run(conn, "upya", "payments")

    if last_run:
        # On recule d'un jour pour être sûr de ne rien manquer
        watermark = last_run["run_date"] - timedelta(days=1)
        logger.info(f"Watermark trouvé → reprise depuis {watermark}")
        return watermark.isoformat()
    else:
        # Premier run → on repart du début
        default = "2023-08-01"
        logger.info(f"Aucun run précédent → extraction depuis {default}")
        return default


def extract_payments(start_date, auth, session, minio_client, bucket):
    """
    Extrait tous les paiements depuis start_date et les
    sauvegarde page par page dans MinIO Bronze.

    Pourquoi page par page ?
    Si on a 50 000 paiements, on ne peut pas tout charger
    en mémoire d'un coup. On traite 500 à la fois, on
    sauvegarde, et on libère la mémoire.

    Args:
        start_date  : date ISO "YYYY-MM-DD" de départ
        auth        : credentials UPYA (HTTPBasicAuth)
        session     : session HTTP avec retry
        minio_client: client MinIO
        bucket      : nom du bucket MinIO

    Returns:
        dict avec pages_fetched, rows_count, minio_prefix
    """
    page        = 1
    total_rows  = 0
    now         = datetime.now(timezone.utc)
    date_path   = now.strftime("%Y/%m/%d")
    minio_prefix = f"bronze/upya/payments/{date_path}/"

    logger.info(f"Extraction payments depuis {start_date}...")

    while True:
        # Construction du payload de requête
        # $gte = "greater than or equal" (MongoDB style)
        # C'est le filtre incrémental par date
        payload = {
            "query": {"date": {"$gte": start_date}},
            "paginate": True,
            "pageNumber": page,
            "nPerPage": PER_PAGE,
        }

        try:
            resp = session.post(
                API_URL,
                json=payload,
                headers=HEADERS,
                auth=auth,
                timeout=60
            )
        except requests.RequestException as e:
            logger.error(f"Erreur réseau page {page}: {e}")
            break

        if resp.status_code != 200:
            logger.error(f"HTTP {resp.status_code} page {page}: {resp.text[:200]}")
            break

        # Extraction des données de la réponse JSON
        data = resp.json()
        items = data.get("data", [])

        # Si la page est vide → on a tout extrait
        if not items:
            logger.info(f"Fin de pagination à la page {page - 1}")
            break

        logger.info(f"Page {page} : {len(items)} paiements")

        # Sauvegarde de la page en Bronze MinIO
        # On sauvegarde le JSON brut EXACTEMENT comme reçu
        # Aucune modification — c'est la règle du Bronze
        page_json = json.dumps(items, ensure_ascii=False, default=str)
        upload_json(
            client=minio_client,
            bucket_name=bucket,
            data=page_json,
            source="upya",
            entity="payments",
            page=page,
        )

        total_rows += len(items)
        page += 1

        # Pause pour ne pas surcharger l'API
        time.sleep(0.5)

    return {
        "pages_fetched": page - 1,
        "rows_count":    total_rows,
        "minio_prefix":  minio_prefix,
    }


def main():
    """
    Point d'entrée principal de l'extracteur.

    Séquence :
    1. Charger les credentials (.env)
    2. Connexion MinIO + PostgreSQL
    3. Récupérer le watermark
    4. Extraire depuis l'API → MinIO Bronze
    5. Logger le run dans bronze_meta.run_log
    """
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("EXTRACTEUR UPYA — PAYMENTS")
    logger.info("=" * 50)

    # --- Credentials UPYA ---
    upya_user = os.getenv("UPYA_USERNAME")
    upya_pass = os.getenv("UPYA_PASSWORD")

    if not upya_user or not upya_pass:
        raise ValueError("UPYA_USERNAME et UPYA_PASSWORD requis dans .env")

    auth = HTTPBasicAuth(upya_user, upya_pass)

    # --- Connexions ---
    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    ensure_bucket_exists(minio_client, bucket)

    conn = get_db_connection()
    init_schemas(conn)
    init_run_log(conn)

    try:
        # --- Watermark ---
        start_date = get_watermark(conn)

        # --- Extraction ---
        session = build_session()
        result  = extract_payments(
            start_date   = start_date,
            auth         = auth,
            session      = session,
            minio_client = minio_client,
            bucket       = bucket,
        )

        # --- Log du run réussi ---
        duration = time.time() - start_time
        log_run(
            conn          = conn,
            source        = "upya",
            entity        = "payments",
            status        = "success",
            pages_fetched = result["pages_fetched"],
            rows_count    = result["rows_count"],
            minio_prefix  = result["minio_prefix"],
            duration_sec  = duration,
        )

        logger.info("=" * 50)
        logger.info(f"✅ EXTRACTION TERMINÉE")
        logger.info(f"   Pages     : {result['pages_fetched']}")
        logger.info(f"   Paiements : {result['rows_count']}")
        logger.info(f"   Durée     : {duration:.1f}s")
        logger.info(f"   MinIO     : {result['minio_prefix']}")
        logger.info("=" * 50)

    except Exception as e:
        # --- Log du run en erreur ---
        duration = time.time() - start_time
        log_run(
            conn          = conn,
            source        = "upya",
            entity        = "payments",
            status        = "error",
            error_message = str(e),
            duration_sec  = duration,
        )
        logger.error(f"Erreur fatale : {e}", exc_info=True)
        return 1

    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())