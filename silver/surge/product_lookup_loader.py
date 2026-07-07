# silver/surge/product_lookup_loader.py
#
# RÔLE : Charger la table de référence produits SURGE
# depuis Google Drive (surge_product_lookup.xlsx)
# vers silver.surge_product_lookup
#
# Cette table statique contient les infos financières
# des contrats SURGE qui ne sont plus dans le CSV CRM :
#   total_contract_value, upfront_payment, monthly_payment

import os
import sys
import logging
import time
import tempfile

import pandas as pd
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from database.db_client import get_db_connection, init_schemas
from bronze.surge.surge_extractor import get_drive_service, find_folder_id, list_csv_files

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.surge_product_lookup (
    installation_id       TEXT PRIMARY KEY,
    asset_number          TEXT,
    product_name          TEXT,
    deal_type             TEXT,
    total_contract_value  NUMERIC(18,2),
    upfront_payment       NUMERIC(18,2),
    monthly_payment       NUMERIC(18,2),
    loaded_at             TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_surge_lookup_asset
    ON silver.surge_product_lookup(asset_number);
"""

UPSERT_SQL = """
INSERT INTO silver.surge_product_lookup (
    installation_id, asset_number, product_name, deal_type,
    total_contract_value, upfront_payment, monthly_payment
) VALUES %s
ON CONFLICT (installation_id) DO UPDATE SET
    asset_number         = EXCLUDED.asset_number,
    product_name         = EXCLUDED.product_name,
    deal_type            = EXCLUDED.deal_type,
    total_contract_value = EXCLUDED.total_contract_value,
    upfront_payment      = EXCLUDED.upfront_payment,
    monthly_payment      = EXCLUDED.monthly_payment;
"""


def download_xlsx_from_drive(service, folder_id, filename_contains):
    """Télécharge un fichier Excel depuis Drive vers un fichier temporaire."""
    # Chercher le fichier (Excel ou CSV)
    query = (
        f"'{folder_id}' in parents "
        f"and trashed=false "
        f"and name contains '{filename_contains}'"
    )
    results = service.files().list(
        q=query,
        fields="files(id, name, modifiedTime)",
        orderBy="modifiedTime desc"
    ).execute()

    files = results.get("files", [])
    if not files:
        raise ValueError(f"Fichier '{filename_contains}' introuvable dans Drive")

    file_info = files[0]
    logger.info(f"Fichier trouvé : {file_info['name']}")

    request  = service.files().get_media(fileId=file_info["id"])
    tmp      = tempfile.NamedTemporaryFile(
        delete=False, suffix=".xlsx", prefix="surge_lookup_"
    )
    tmp.write(request.execute())
    tmp.close()
    logger.info(f"Téléchargé : {tmp.name}")
    return tmp.name


def clean_number(v):
    if pd.isna(v):
        return None
    try:
        return float(str(v).replace(",", "").replace(" ", "").strip())
    except Exception:
        return None


def clean_value(v):
    if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
        return None
    return str(v).strip()


def load_product_lookup():
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — SURGE PRODUCT LOOKUP")
    logger.info("=" * 50)

    service = get_drive_service()
    conn    = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.surge_product_lookup prête")

    # Trouver le dossier surge_contracts dans Drive
    root_name = os.getenv("SURGE_DRIVE_FOLDER", "surge_daily_logs")
    root_id   = find_folder_id(service, root_name)
    if not root_id:
        raise ValueError(f"Dossier '{root_name}' introuvable dans Drive")

    contracts_folder_id = find_folder_id(service, "surge_contracts", root_id)
    if not contracts_folder_id:
        raise ValueError("Dossier 'surge_contracts' introuvable")

    tmp_path = None
    total_rows = 0

    try:
        # Téléchargement depuis Drive
        tmp_path = download_xlsx_from_drive(
            service, contracts_folder_id, "surge_product_lookup"
        )

        # Lecture Excel en mémoire
        logger.info("Lecture Excel en mémoire...")
        df = pd.read_excel(tmp_path, dtype=str)
        logger.info(f"Lignes brutes : {len(df):,} | Colonnes : {list(df.columns)}")

        # Suppression fichier temporaire
        os.unlink(tmp_path)
        tmp_path = None

        # Renommage colonnes
        df = df.rename(columns={
            "contract_number":       "installation_id",
            "asset_number":          "asset_number",
            "product_name":          "product_name",
            "deal_type":             "deal_type",
            "total_contract_value":  "total_contract_value",
            "upfront_payment":       "upfront_payment",
            "monthly_payment":       "monthly_payment",
        })

        # Nettoyage clé primaire
        df["installation_id"] = df["installation_id"].apply(clean_value)
        df = df[df["installation_id"].notna()]
        df = df.drop_duplicates(subset=["installation_id"], keep="last")
        logger.info(f"Lignes uniques : {len(df):,}")

        # Normalisation deal_type
        df["deal_type"] = df["deal_type"].apply(
            lambda v: "FULL" if str(v).upper() in ("FULL", "YES")
            else "PAYG" if str(v).upper() in ("PAYG", "NO")
            else clean_value(v)
        )

        # Construction des tuples SQL
        rows = []
        for _, r in df.iterrows():
            rows.append((
                clean_value(r.get("installation_id")),
                clean_value(r.get("asset_number")),
                clean_value(r.get("product_name")),
                clean_value(r.get("deal_type")),
                clean_number(r.get("total_contract_value")),
                clean_number(r.get("upfront_payment")),
                clean_number(r.get("monthly_payment")),
            ))

        rows = [r for r in rows if r[0] is not None]

        # Upsert par chunks
        CHUNK_SIZE   = 10_000
        total_chunks = (len(rows) // CHUNK_SIZE) + 1

        for i in range(total_chunks):
            chunk = rows[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]
            if not chunk:
                continue
            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, chunk, page_size=500)
            conn.commit()
            cur.close()
            total_rows += len(chunk)
            logger.info(f"Chunk {i+1}/{total_chunks} : {len(chunk):,} lignes")

        # Stats
        cur = conn.cursor()
        cur.execute("""
            SELECT deal_type, COUNT(*), 
                   ROUND(AVG(total_contract_value)) as avg_value
            FROM silver.surge_product_lookup
            GROUP BY deal_type ORDER BY COUNT(*) DESC
        """)
        logger.info("Répartition par deal_type :")
        for row in cur.fetchall():
            logger.info(f"  {row[0]:6} : {row[1]:,} contrats | valeur moy: {row[2]:,} XOF")
        cur.close()

    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur : {e}", exc_info=True)

    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    duration = time.time() - start_time
    logger.info("=" * 50)
    logger.info(f"✅ SURGE PRODUCT LOOKUP TERMINÉ")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    load_product_lookup()