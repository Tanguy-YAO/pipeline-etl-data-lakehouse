# silver/surge/surge_legacy_contacts_loader.py
# RÔLE : Ingestion des numéros de téléphone SURGE
#        depuis l'export de l'ancien pipeline
# SOURCE : fichier CSV local (contract_number, prim_mobile, snd_mobile)

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
CREATE TABLE IF NOT EXISTS silver.surge_legacy_contacts (
    contract_number  TEXT PRIMARY KEY,
    prim_mobile      TEXT,
    snd_mobile       TEXT,
    loaded_at        TIMESTAMPTZ DEFAULT NOW()
);
"""

UPSERT_SQL = """
INSERT INTO silver.surge_legacy_contacts (contract_number, prim_mobile, snd_mobile)
VALUES %s
ON CONFLICT (contract_number) DO UPDATE SET
    prim_mobile = EXCLUDED.prim_mobile,
    snd_mobile  = EXCLUDED.snd_mobile,
    loaded_at   = NOW();
"""

def load_surge_contacts(filepath):
    load_dotenv()
    logger.info("SILVER LOADER — SURGE LEGACY CONTACTS")

    df = pd.read_csv(filepath, dtype=str)
    df.columns = ["contract_number", "prim_mobile", "snd_mobile"]
    df = df[df["contract_number"].notna()]
    df = df.drop_duplicates(subset=["contract_number"], keep="last")

    def clean(v):
        return str(v).strip() if pd.notna(v) else None

    rows = [(clean(r.contract_number), clean(r.prim_mobile), clean(r.snd_mobile))
            for r in df.itertuples()]

    conn = get_db_connection()
    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()

    execute_values(cur, UPSERT_SQL, rows, page_size=1000)
    conn.commit()
    cur.close()
    conn.close()

    logger.info(f"TERMINÉ — {len(rows):,} lignes chargées dans silver.surge_legacy_contacts")

if __name__ == "__main__":
    filepath = sys.argv[1] if len(sys.argv) > 1 else "surge_contacts.csv"
    load_surge_contacts(filepath)