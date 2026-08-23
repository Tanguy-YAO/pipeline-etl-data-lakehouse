# storage/minio_client.py
# Brique de connexion MinIO
#
# CORRECTIF (06/08/2026) : l'upload de surge_payments (376 MB) a échoué
# de façon répétée -- chaque bloc de 50 MB expirait systématiquement au
# bout de 300s (timeout par défaut du client HTTP), signe d'une connexion
# trop lente/instable pour ce débit sur ce lien réseau précis.
# Deux ajustements :
#   1. PART_SIZE réduit de 50 MB à 16 MB -- chaque bloc individuel a
#      beaucoup plus de chances de passer dans le temps imparti, même
#      sur une connexion lente (au prix d'un peu plus de blocs, donc
#      un peu plus d'overhead HTTP -- négligeable face au gain de fiabilité).
#   2. Le client MinIO est maintenant construit avec un pool HTTP explicite
#      dont le timeout de lecture est monté à 600s (contre ~300s implicite
#      avant), pour absorber les pics de lenteur sans épuiser les 4 tentatives
#      de retry en quelques minutes.

import os
import logging
from datetime import datetime, timezone
from io import BytesIO

import urllib3
from minio import Minio
from minio.error import S3Error
from dotenv import load_dotenv

logger = logging.getLogger(__name__)


def get_minio_client():
    """
    Crée et retourne un client MinIO.

    Analogie : c'est comme composer le numéro de téléphone
    de MinIO. On lit les credentials dans .env et on établit
    la connexion.

    Le pool HTTP est configuré avec un timeout de lecture généreux
    (600s) pour tolérer les connexions lentes/instables sur de gros
    fichiers en upload multipart -- voir le correctif du 06/08/2026
    en tête de ce fichier.
    """
    load_dotenv()  # Lit le fichier .env

    endpoint   = os.getenv("MINIO_ENDPOINT")
    port       = int(os.getenv("MINIO_PORT", "443"))
    use_ssl    = os.getenv("MINIO_USE_SSL", "true").lower() == "true"
    access_key = os.getenv("MINIO_ACCESS_KEY")
    secret_key = os.getenv("MINIO_SECRET_KEY")

    # Vérifie que les variables obligatoires sont présentes
    missing = [k for k, v in {
        "MINIO_ENDPOINT": endpoint,
        "MINIO_ACCESS_KEY": access_key,
        "MINIO_SECRET_KEY": secret_key,
    }.items() if not v]

    if missing:
        raise ValueError(f"Variables manquantes dans .env : {missing}")

    # Pool HTTP avec timeout de lecture allongé (600s au lieu du défaut
    # implicite ~300s) et quelques retries internes supplémentaires côté
    # urllib3 -- vient s'ajouter aux retries déjà gérés par minio-py.
    timeout = urllib3.Timeout(connect=30, read=600)
    http_client = urllib3.PoolManager(
        timeout=timeout,
        maxsize=10,
        retries=urllib3.Retry(
            total=5,
            backoff_factor=1,
            status_forcelist=[500, 502, 503, 504],
        ),
    )

    client = Minio(
        endpoint=f"{endpoint}:{port}",
        access_key=access_key,
        secret_key=secret_key,
        secure=use_ssl,
        http_client=http_client,
    )

    logger.info(f"Client MinIO créé → {endpoint}:{port} (timeout lecture : 600s)")
    return client


def ensure_bucket_exists(client, bucket_name):
    """
    Crée le bucket s'il n'existe pas.

    Analogie : un bucket c'est comme un disque dur virtuel
    dans MinIO. On en a un seul : 'paygo-lakehouse'.
    """
    if not client.bucket_exists(bucket_name):
        client.make_bucket(bucket_name)
        logger.info(f"Bucket créé : {bucket_name}")
    else:
        logger.info(f"Bucket existant : {bucket_name}")


def upload_json(client, bucket_name, data, source, entity, page=None):
    """
    Sauvegarde du JSON dans MinIO Bronze.

    Le chemin est construit automatiquement avec la date :
    bronze/upya/payments/2025/06/15/page_001.json

    Pourquoi partitionner par date ?
    → Pour retrouver facilement les fichiers d'un jour précis
      et rejouer uniquement ce jour si besoin.
    """
    now = datetime.now(timezone.utc)
    date_path = now.strftime("%Y/%m/%d")  # ex: 2025/06/15

    if page is not None:
        # Zéro padding : page 3 → "page_003"
        # Pourquoi ? Pour que le tri alphabétique = tri numérique
        filename = f"page_{page:03d}.json"
    else:
        filename = f"{entity}.json"

    object_key = f"bronze/{source}/{entity}/{date_path}/{filename}"

    # BytesIO transforme la string en flux d'octets
    # MinIO travaille avec des flux, pas des strings directement
    data_bytes = data.encode("utf-8")
    data_stream = BytesIO(data_bytes)

    client.put_object(
        bucket_name=bucket_name,
        object_name=object_key,
        data=data_stream,
        length=len(data_bytes),
        content_type="application/json",
    )

    logger.info(f"Fichier uploadé → {object_key}")
    return object_key


def upload_csv(client, bucket_name, file_path, source, entity):
    """
    Sauvegarde un fichier CSV local dans MinIO Bronze.
    Utilise le multipart upload pour les gros fichiers.
    Chemin généré :
    bronze/surge/payments/2026/05/27/payments.csv

    Seuils ajustés le 06/08/2026 (voir en-tête du fichier) : blocs de
    16 MB au lieu de 50 MB, pour fiabiliser l'upload sur connexion lente.
    """
    now = datetime.now(timezone.utc)
    date_path = now.strftime("%Y/%m/%d")
    object_key = f"bronze/{source}/{entity}/{date_path}/{entity}.csv"

    file_size = os.path.getsize(file_path)
    logger.info(f"Upload CSV : {file_path} ({file_size / 1024 / 1024:.1f} MB)")

    # Seuil multipart : 100 MB
    # En dessous → upload simple
    # Au dessus  → multipart par morceaux de 16 MB (réduit depuis 50 MB
    # le 06/08/2026 pour fiabiliser l'upload sur connexion lente/instable)
    MULTIPART_THRESHOLD = 100 * 1024 * 1024   # 100 MB
    PART_SIZE           = 16 * 1024 * 1024    # 16 MB

    if file_size > MULTIPART_THRESHOLD:
        logger.info(
            f"Fichier > 100MB → multipart upload "
            f"({file_size / 1024 / 1024:.0f} MB, blocs de "
            f"{PART_SIZE / 1024 / 1024:.0f} MB)"
        )

        # fput_object gère automatiquement le multipart
        # si part_size est spécifié
        client.fput_object(
            bucket_name=bucket_name,
            object_name=object_key,
            file_path=file_path,
            content_type="text/csv",
            part_size=PART_SIZE,
        )
    else:
        client.fput_object(
            bucket_name=bucket_name,
            object_name=object_key,
            file_path=file_path,
            content_type="text/csv",
        )

    logger.info(f"CSV uploadé → {object_key}")
    return object_key


def list_bronze_files(client, bucket_name, source, entity, since_date=None):
    """
    Liste les fichiers Bronze disponibles.

    CORRECTIF (21/08/2026) : l'ancien parametre `date` ne listait qu'un
    seul jour exact -- avec date=None (l'appel par defaut de tous les
    loaders Silver), ca listait TOUT l'historique depuis le debut du
    pipeline a chaque run, causant une degradation progressive jusqu'a
    un timeout de 90 minutes sur contracts/assets. Remplace par
    `since_date` : ne retourne que les fichiers strictement posterieurs
    a cette date, pour ne jamais tout recharger mais aussi ne jamais
    sauter un jour reste en echec.

    since_date : format 'YYYY/MM/DD' ou None (= tout charger, utilise
    uniquement lors du tout premier run avant qu'un watermark existe).
    La comparaison de chaines fonctionne car le format zero-padded
    trie alphabetiquement = trie chronologiquement.
    """
    prefix = f"bronze/{source}/{entity}/"
    objects = client.list_objects(bucket_name, prefix=prefix, recursive=True)

    keys = []
    for obj in objects:
        if since_date is None:
            keys.append(obj.object_name)
            continue
        # object_name : bronze/upya/contracts/2026/08/21/page_001.json
        parts = obj.object_name.replace(prefix, "").split("/")
        file_date = "/".join(parts[:3])  # "2026/08/21"
        if file_date > since_date:
            keys.append(obj.object_name)

    logger.info(f"Fichiers trouvés ({source}/{entity}), depuis {since_date or 'le début'} : {len(keys)}")
    return keys


def download_json(client, bucket_name, object_key):
    """
    Télécharge et retourne le contenu d'un fichier JSON.
    Utilisé par les transformateurs Silver.
    """
    response = client.get_object(bucket_name, object_key)
    content = response.read().decode("utf-8")
    response.close()
    response.release_conn()
    return content


# TEST — lance ce fichier directement pour tester la connexion
# python storage/minio_client.py

if __name__ == "__main__":
    import json

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s"
    )

    print("\n=== TEST CONNEXION MINIO ===\n")

    # Étape 1 : connexion
    client = get_minio_client()
    bucket = os.getenv("MINIO_BUCKET", "paygo-lakehouse")

    # Étape 2 : créer le bucket
    ensure_bucket_exists(client, bucket)

    # Étape 3 : uploader un fichier de test
    test_data = json.dumps({
        "test": True,
        "message": "Connexion MinIO OK",
        "timestamp": datetime.now(timezone.utc).isoformat()
    }, indent=2)

    key = upload_json(
        client, bucket, test_data,
        source="test", entity="ping", page=1
    )

    # Étape 4 : re-télécharger pour vérifier
    content = download_json(client, bucket, key)
    print(f" Upload + Download réussis !")
    print(f"   Fichier : {key}")
    print(f"   Contenu : {content[:80]}...")

    # Étape 5 : lister
    files = list_bronze_files(client, bucket, "test", "ping")
    print(f" Listing : {len(files)} fichier(s) trouvé(s)")
    print("\n=== TEST TERMINÉ ===\n")