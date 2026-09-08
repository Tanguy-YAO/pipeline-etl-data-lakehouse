# silver/reference/encryption_codes_loader.py
# RÔLE : Ingestion du fichier encryption_codes.xlsx
#        vers silver.encryption_codes
# SOURCE : fichier Excel local (69 473 lignes)
# CLÉ : device_id (= asset_number dans unified_contracts)

import os
import sys
import logging
import pandas as pd
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from database.db_client import get_db_connection, init_schemas

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.encryption_codes (
    device_id       TEXT PRIMARY KEY,
    product_series  TEXT,
    enc_code        TEXT,
    loaded_at       TIMESTAMPTZ DEFAULT NOW()
);
"""

UPSERT_SQL = """
INSERT INTO silver.encryption_codes (device_id, product_series, enc_code)
VALUES %s
ON CONFLICT (device_id) DO UPDATE SET
    product_series = EXCLUDED.product_series,
    enc_code       = EXCLUDED.enc_code,
    loaded_at      = NOW();
"""

def load_encryption_codes(filepath="encryption_codes.xlsx"):
    load_dotenv()
    logger.info("=" * 50)
    logger.info("SILVER LOADER — ENCRYPTION CODES")
    logger.info("=" * 50)

    # Lecture Excel
    logger.info(f"Lecture de {filepath}...")
    df = pd.read_excel(filepath, dtype=str)
    df.columns = ["product_series", "device_id", "enc_code"]
    logger.info(f"Lignes brutes : {len(df):,}")

    # Nettoyage
    df["device_id"]      = df["device_id"].str.strip()
    df["product_series"] = df["product_series"].str.strip()
    df["enc_code"]       = df["enc_code"].str.strip()
    df = df[df["device_id"].notna() & (df["device_id"] != "")]
    df = df.drop_duplicates(subset=["device_id"], keep="last")
    logger.info(f"Lignes après nettoyage : {len(df):,}")

    # Chargement
    conn = get_db_connection()
    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()

    rows = list(df[["device_id", "product_series", "enc_code"]].itertuples(index=False, name=None))
    execute_values(cur, UPSERT_SQL, rows, page_size=1000)
    conn.commit()
    cur.close()
    conn.close()

    logger.info(f"✅ {len(rows):,} lignes chargées dans silver.encryption_codes")
    logger.info("=" * 50)

if __name__ == "__main__":
    filepath = sys.argv[1] if len(sys.argv) > 1 else "encryption_codes.xlsx"
    load_encryption_codes(filepath)