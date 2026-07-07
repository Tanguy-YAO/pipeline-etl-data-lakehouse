# ============================================================
# silver/upya/contracts_loader.py v2
# Ajout : entity_name, signing_date, customer_name, agent_name
# ============================================================

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

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.upya_contracts (
    contract_number     TEXT PRIMARY KEY,
    entity_name         TEXT,
    status              TEXT,
    onboarding_status   TEXT,
    flag                TEXT,
    paid_off_status     TEXT,
    deal_type           TEXT,
    signing_date        TIMESTAMPTZ,
    registration_date   TIMESTAMPTZ,
    last_status_update  TIMESTAMPTZ,
    next_status_update  TIMESTAMPTZ,
    paid_off_date       TIMESTAMPTZ,
    total_cost          NUMERIC(18,2),
    total_paid          NUMERIC(18,2),
    remaining_debt      NUMERIC(18,2),
    upfront_payment     NUMERIC(18,2),
    monthly_payment     NUMERIC(18,2),
    product_name        TEXT,
    asset_number        TEXT,
    client_number       TEXT,
    customer_name       TEXT,
    agent_number        TEXT,
    agent_name          TEXT,
    region              TEXT,
    district            TEXT,
    village             TEXT,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_upya_contracts_status ON silver.upya_contracts(status);
CREATE INDEX IF NOT EXISTS idx_upya_contracts_entity ON silver.upya_contracts(entity_name);
CREATE INDEX IF NOT EXISTS idx_upya_contracts_client ON silver.upya_contracts(client_number);
"""

UPSERT_SQL = """
INSERT INTO silver.upya_contracts (
    contract_number, entity_name, status, onboarding_status,
    flag, paid_off_status, deal_type,
    signing_date, registration_date, last_status_update,
    next_status_update, paid_off_date,
    total_cost, total_paid, remaining_debt,
    upfront_payment, monthly_payment,
    product_name, asset_number,
    client_number, customer_name,
    agent_number, agent_name,
    region, district, village
) VALUES %s
ON CONFLICT (contract_number) DO UPDATE SET
    entity_name        = EXCLUDED.entity_name,
    status             = EXCLUDED.status,
    onboarding_status  = EXCLUDED.onboarding_status,
    flag               = EXCLUDED.flag,
    paid_off_status    = EXCLUDED.paid_off_status,
    deal_type          = EXCLUDED.deal_type,
    signing_date       = EXCLUDED.signing_date,
    last_status_update = EXCLUDED.last_status_update,
    next_status_update = EXCLUDED.next_status_update,
    paid_off_date      = EXCLUDED.paid_off_date,
    total_cost         = EXCLUDED.total_cost,
    total_paid         = EXCLUDED.total_paid,
    remaining_debt     = EXCLUDED.remaining_debt,
    upfront_payment    = EXCLUDED.upfront_payment,
    monthly_payment    = EXCLUDED.monthly_payment,
    updated_at         = NOW();
"""

def parse_date(v):
    if not v:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.strptime(v, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None

def parse_amount(v):
    if v is None:
        return None
    try:
        return float(str(v).replace(",", ""))
    except Exception:
        return None

def concat_name(first, last):
    parts = [p for p in [first, last] if p and str(p).strip()]
    return " ".join(parts) if parts else None

def transform_contract(item):
    contract_number = item.get("contractNumber")
    if not contract_number:
        return None

    # Filtrer contrats test
    client  = item.get("client")  or {}
    profile = client.get("profile") or {}
    first   = profile.get("firstName", "") or ""
    last    = profile.get("lastName", "")  or ""
    if "test" in first.lower() or "test" in last.lower():
        return None

    entity  = item.get("entity")  or {}
    agent   = item.get("agent")   or {}
    ag_prof = agent.get("profile") or {}
    product = item.get("product") or {}
    pricing = item.get("pricingSchedule") or {}
    asset   = item.get("asset")   or {}

    # paid_off_status peut être dans paidOff.status ou paidoff_status
    paidoff_obj    = item.get("paidOff") or {}
    paidoff_status = (
        paidoff_obj.get("status")
        or item.get("paidoffStatus")
        or item.get("paidOffStatus")
        or ""
    )

    return (
        str(contract_number),
        entity.get("name"),
        item.get("status"),
        item.get("onboardingStatus"),
        item.get("flag"),
        str(paidoff_status),
        item.get("type"),
        parse_date(item.get("signingDate")),
        parse_date(item.get("signingDate")),
        parse_date(item.get("lastStatusUpdate")),
        parse_date(item.get("nextStatusUpdate")),
        parse_date(item.get("paidOffDate") or item.get("paidoffDate")),
        parse_amount(item.get("totalCost")),
        parse_amount(item.get("totalPaid")),
        parse_amount(item.get("remainingDebt")),
        parse_amount(pricing.get("upfrontPayment")),
        parse_amount(pricing.get("recurrentPayment")),
        product.get("name") or item.get("dealName"),
        asset.get("paygNumber") or item.get("paygNumber"),
        client.get("clientNumber"),
        concat_name(first, last),
        agent.get("agentNumber"),
        concat_name(ag_prof.get("firstName"), ag_prof.get("lastName")),
        profile.get("region"),
        profile.get("district"),
        profile.get("village"),
    )

def load_contracts(date=None):
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — UPYA CONTRACTS v2")
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
        return 0

    logger.info(f"Fichiers à traiter : {len(files)}")
    total_rows   = 0
    total_errors = 0

    for file_key in files:
        try:
            content = download_json(minio_client, bucket, file_key)
            items   = json.loads(content)
            rows    = [r for r in (transform_contract(i) for i in items) if r]

            if not rows:
                continue

            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, rows, page_size=200)
            conn.commit()
            cur.close()
            total_rows += len(rows)
            logger.info(f"  {file_key.split('/')[-1]} → {len(rows)} contrats")

        except Exception as e:
            conn.rollback()
            logger.error(f"Erreur {file_key} : {e}")
            total_errors += 1

    # Stats par entité
    cur = conn.cursor()
    cur.execute("""
        SELECT entity_name, COUNT(*)
        FROM silver.upya_contracts
        GROUP BY entity_name ORDER BY COUNT(*) DESC
    """)
    logger.info("Répartition par entité :")
    for row in cur.fetchall():
        logger.info(f"  {row[0] or 'NULL'} : {row[1]:,}")
    cur.close()

    duration = time.time() - start_time
    logger.info("=" * 50)
    logger.info(f"✅ SILVER CONTRACTS v2 TERMINÉ")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Erreurs  : {total_errors}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows

if __name__ == "__main__":
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_contracts(date)