# storage/minio_client.py
# Brique de connexion MinIO

import os
import logging
from datetime import datetime, timezone
from io import BytesIO

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

    client = Minio(
        endpoint=f"{endpoint}:{port}",
        access_key=access_key,
        secret_key=secret_key,
        secure=use_ssl,
    )

    logger.info(f"Client MinIO créé → {endpoint}:{port}")
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
    Utilisé pour les exports SURGE.
    
    Chemin généré :
    bronze/surge/transactions/2025/06/15/transactions.csv
    """
    now = datetime.now(timezone.utc)
    date_path = now.strftime("%Y/%m/%d")
    object_key = f"bronze/{source}/{entity}/{date_path}/{entity}.csv"

    # fput_object lit directement le fichier local
    # Plus efficace que de le charger en mémoire d'abord
    client.fput_object(
        bucket_name=bucket_name,
        object_name=object_key,
        file_path=file_path,
        content_type="text/csv",
    )

    logger.info(f"CSV uploadé → {object_key}")
    return object_key


def list_bronze_files(client, bucket_name, source, entity, date=None):
    """
    Liste les fichiers Bronze disponibles.
    
    Utilisé par les transformateurs Silver pour savoir
    quels fichiers lire depuis MinIO.
    """
    prefix = f"bronze/{source}/{entity}/"
    if date:
        prefix = f"bronze/{source}/{entity}/{date}/"

    objects = client.list_objects(bucket_name, prefix=prefix, recursive=True)
    keys = [obj.object_name for obj in objects]
    logger.info(f"Fichiers trouvés ({source}/{entity}) : {len(keys)}")
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