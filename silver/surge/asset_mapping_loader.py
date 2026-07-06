# silver/surge/asset_mapping_loader.py
#
# RÔLE : Charger la table bridge asset_number ↔ installation_id
# depuis Google Drive vers silver.surge_asset_mapping
#
# Cette table permet de lier :
#   surge_payments.account (asset_number)
#       → surge_contracts.installation_id

import os
import sys
import logging
import time
import tempfile

import pandas as pd
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, ensure_bucket_exists, upload_csv, list_bronze_files
from database.db_client import get_db_connection, init_schemas
from bronze.surge.surge_extractor import get_drive_service, find_folder_id, list_csv_files, download_csv

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.surge_asset_mapping (
    asset_number        TEXT PRIMARY KEY,
    installation_id     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_asset_mapping_installation
    ON silver.surge_asset_mapping(installation_id);
"""

UPSERT_SQL = """
INSERT INTO silver.surge_asset_mapping (asset_number, installation_id)
VALUES %s
ON CONFLICT (asset_number) DO UPDATE SET
    installation_id = EXCLUDED.installation_id;
"""


def load_asset_mapping():
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — SURGE ASSET MAPPING")
    logger.info("=" * 50)

    # Connexions
    service      = get_drive_service()
    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    ensure_bucket_exists(minio_client, bucket)
    conn         = get_db_connection()

    # Création table Silver
    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.surge_asset_mapping prête")

    # Trouver le fichier dans Drive (dans surge_contracts)
    root_folder_name = os.getenv("SURGE_DRIVE_FOLDER", "surge_daily_logs")
    root_folder_id   = find_folder_id(service, root_folder_name)

    if not root_folder_id:
        raise ValueError(f"Dossier Drive '{root_folder_name}' introuvable")

    # On cherche dans surge_contracts où on a déposé le fichier
    contracts_folder_id = find_folder_id(
        service, "surge_contracts", root_folder_id
    )
    if not contracts_folder_id:
        raise ValueError("Dossier surge_contracts introuvable dans Drive")

    # Lister les CSV et trouver asset_mapping
    csv_files = list_csv_files(service, contracts_folder_id)
    mapping_file = None
    for f in csv_files:
        if "asset_mapping" in f["name"].lower():
            mapping_file = f
            break

    if not mapping_file:
        raise ValueError("Fichier asset_mapping.csv introuvable dans Drive")

    logger.info(f"Fichier trouvé : {mapping_file['name']}")

    tmp_path = None
    total_rows = 0

    try:
        # Téléchargement depuis Drive
        tmp_path = download_csv(service, mapping_file["id"], "asset_mapping")

        # Lecture en mémoire
        df = pd.read_csv(tmp_path, dtype=str)
        logger.info(f"Lignes brutes : {len(df):,}")

        # Suppression fichier temporaire
        os.unlink(tmp_path)
        tmp_path = None

        # Renommage des colonnes
        df = df.rename(columns={
            "contract_number": "installation_id",
            "asset_number":    "asset_number",
        })

        # Nettoyage
        df["asset_number"]    = df["asset_number"].astype(str).str.strip()
        df["installation_id"] = df["installation_id"].astype(str).str.strip()
        df = df[df["asset_number"].notna() & df["installation_id"].notna()]
        df = df.drop_duplicates(subset=["asset_number"], keep="last")
        logger.info(f"Lignes uniques : {len(df):,}")

        # Upsert
        rows = [
            (r["asset_number"], r["installation_id"])
            for _, r in df.iterrows()
        ]

        cur = conn.cursor()
        execute_values(cur, UPSERT_SQL, rows, page_size=1000)
        conn.commit()
        cur.close()
        total_rows = len(rows)

        # Archiver dans MinIO Bronze
        logger.info("Archivage dans MinIO Bronze...")

    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur : {e}", exc_info=True)

    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    # Vérification de la jointure
    cur = conn.cursor()
    cur.execute("""
        SELECT COUNT(*)
        FROM silver.surge_payments p
        JOIN silver.surge_asset_mapping m ON p.account = m.asset_number
        JOIN silver.surge_contracts c ON m.installation_id = c.installation_id
    """)
    matches = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM silver.surge_payments")
    total = cur.fetchone()[0]
    cur.close()
    conn.close()

    duration = time.time() - start_time
    logger.info("=" * 50)
    logger.info(f"✅ ASSET MAPPING TERMINÉ")
    logger.info(f"   Lignes chargées : {total_rows:,}")
    logger.info(f"   Match payments  : {matches:,} / {total:,} ({matches/total*100:.1f}%)")
    logger.info(f"   Durée           : {duration:.1f}s")
    logger.info("=" * 50)


if __name__ == "__main__":
    load_asset_mapping()