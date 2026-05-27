# silver/upya/contracts_loader.py
#
# RÔLE : Lire les JSON Bronze contracts → nettoyer → charger
# dans PostgreSQL silver.upya_contracts

import os
import sys
import json
import logging
import time
from datetime import datetime, timezone

from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, list_bronze_files, download_json
from database.db_client import get_db_connection, init_schemas

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.upya_contracts (
    -- Identifiant unique
    contract_number     TEXT PRIMARY KEY,

    -- Statut du contrat
    status              TEXT,
    onboarding_status   TEXT,
    flag                TEXT,

    -- Dates clés
    registration_date   TIMESTAMPTZ,
    last_status_update  TIMESTAMPTZ,
    next_status_update  TIMESTAMPTZ,
    paid_off_date       TIMESTAMPTZ,

    -- Financier
    total_cost          NUMERIC(18,2),
    total_paid          NUMERIC(18,2),
    remaining_debt      NUMERIC(18,2),
    upfront_payment     NUMERIC(18,2),
    monthly_payment     NUMERIC(18,2),

    -- Produit
    product_name        TEXT,
    asset_number        TEXT,
    deal_type           TEXT,

    -- Client
    client_number       TEXT,

    -- Localisation
    region              TEXT,
    district            TEXT,
    village             TEXT,

    -- Agent
    agent_number        TEXT,

    -- Méta pipeline
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_upya_contracts_status
    ON silver.upya_contracts(status);

CREATE INDEX IF NOT EXISTS idx_upya_contracts_client
    ON silver.upya_contracts(client_number);

CREATE INDEX IF NOT EXISTS idx_upya_contracts_agent
    ON silver.upya_contracts(agent_number);
"""

UPSERT_SQL = """
INSERT INTO silver.upya_contracts (
    contract_number, status, onboarding_status, flag,
    registration_date, last_status_update, next_status_update, paid_off_date,
    total_cost, total_paid, remaining_debt, upfront_payment, monthly_payment,
    product_name, asset_number, deal_type,
    client_number, region, district, village, agent_number
) VALUES %s
ON CONFLICT (contract_number) DO UPDATE SET
    status              = EXCLUDED.status,
    onboarding_status   = EXCLUDED.onboarding_status,
    flag                = EXCLUDED.flag,
    last_status_update  = EXCLUDED.last_status_update,
    next_status_update  = EXCLUDED.next_status_update,
    paid_off_date       = EXCLUDED.paid_off_date,
    total_cost          = EXCLUDED.total_cost,
    total_paid          = EXCLUDED.total_paid,
    remaining_debt      = EXCLUDED.remaining_debt,
    upfront_payment     = EXCLUDED.upfront_payment,
    monthly_payment     = EXCLUDED.monthly_payment,
    updated_at          = NOW();
"""


def parse_date(date_str):
    if not date_str:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def parse_amount(value):
    if value is None:
        return None
    try:
        if isinstance(value, str):
            value = value.replace(",", "").replace(" ", "")
        return float(value)
    except (ValueError, TypeError):
        return None


def transform_contract(item):
    """
    Transforme un contrat JSON brut en tuple SQL.

    Les contrats UPYA ont une structure imbriquée :
    - item["product"]["name"] → nom du produit
    - item["client"]["clientNumber"] → numéro client
    - item["location"]["region"] → région

    On "aplatit" cette structure en colonnes plates
    pour PostgreSQL.
    """
    contract_number = item.get("contractNumber")
    if not contract_number:
        return None

    # Extraction des objets imbriqués
    # .get() retourne None si la clé n'existe pas
    # "or {}" évite le crash si la valeur est None
    product  = item.get("product")  or {}
    client   = item.get("client")   or {}
    location = item.get("location") or {}
    agent    = item.get("agent")    or {}
    deal     = item.get("deal")     or {}

    return (
        str(contract_number),
        item.get("status"),
        item.get("onboardingStatus"),
        item.get("flag"),
        # Dates
        parse_date(item.get("registrationDate")),
        parse_date(item.get("lastStatusUpdate")),
        parse_date(item.get("nextStatusUpdate")),
        parse_date(item.get("paidOffDate")),
        # Financier
        parse_amount(item.get("totalCost")),
        parse_amount(item.get("totalPaid")),
        parse_amount(item.get("remainingDebt")),
        parse_amount(item.get("upfrontPayment")),
        parse_amount(item.get("monthlyPayment")),
        # Produit
        product.get("name"),
        item.get("assetNumber"),
        deal.get("type"),
        # Client
        client.get("clientNumber"),
        # Localisation
        location.get("region"),
        location.get("district"),
        location.get("village"),
        # Agent
        agent.get("agentNumber"),
    )


def load_contracts(date=None):
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — UPYA CONTRACTS")
    logger.info("=" * 50)

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.upya_contracts prête")

    files = list_bronze_files(minio_client, bucket, "upya", "contracts", date)

    if not files:
        logger.warning("Aucun fichier Bronze trouvé pour contracts")
        return

    logger.info(f"Fichiers à traiter : {len(files)}")

    total_rows   = 0
    total_errors = 0

    for file_key in files:
        logger.info(f"Traitement : {file_key}")
        try:
            content = download_json(minio_client, bucket, file_key)
            items   = json.loads(content)

            rows = []
            for item in items:
                row = transform_contract(item)
                if row:
                    rows.append(row)
                else:
                    total_errors += 1

            if not rows:
                continue

            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, rows, page_size=200)
            conn.commit()
            cur.close()

            total_rows += len(rows)
            logger.info(f"  → {len(rows)} contrats chargés")

        except Exception as e:
            conn.rollback()
            logger.error(f"Erreur sur {file_key} : {e}")
            total_errors += 1

    duration = time.time() - start_time

    logger.info("=" * 50)
    logger.info(f"✅ SILVER CONTRACTS TERMINÉ")
    logger.info(f"   Fichiers : {len(files)}")
    logger.info(f"   Lignes   : {total_rows}")
    logger.info(f"   Erreurs  : {total_errors}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_contracts(date)