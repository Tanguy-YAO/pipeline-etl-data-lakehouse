# ============================================================
# silver/upya/payments_loader.py
#
# RÔLE : Lire les JSON Bronze UPYA payments → nettoyer →
# charger dans PostgreSQL silver.upya_payments
#
# v2 : Ajout colonne payment_code (DOWNPAYMENT_SUCCESS,
#      PAYMENT_SUCCESS, etc.) indispensable pour le
#      calcul du Collection Rate EFA
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

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.upya_payments (
    -- Identifiant unique
    transaction_id      TEXT PRIMARY KEY,

    -- Lien avec le contrat
    contract_number     TEXT,

    -- Date et montant
    payment_date        TIMESTAMPTZ,
    amount              NUMERIC(18,2),
    currency            TEXT,

    -- Statut et classification
    status              TEXT,
    operator            TEXT,
    payment_type        TEXT,

    -- Code de paiement — clé pour le Collection Rate EFA
    -- DOWNPAYMENT_SUCCESS / INCOMPLETE_DOWNPAYMENT / FINAL_PAYMENT → upfront
    -- PAYMENT_SUCCESS / INCOMPLETE_PAYMENT                          → recharge
    -- REVERSED                                                      → à exclure
    payment_code        TEXT,

    payment_reference   TEXT,
    mobile              TEXT,

    -- Entité (TEVIA / GREENO)
    entity_name         TEXT,
    entity_number       TEXT,

    -- Méta pipeline
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_upya_payments_contract
    ON silver.upya_payments(contract_number);
CREATE INDEX IF NOT EXISTS idx_upya_payments_date
    ON silver.upya_payments(payment_date);
CREATE INDEX IF NOT EXISTS idx_upya_payments_status
    ON silver.upya_payments(status);
CREATE INDEX IF NOT EXISTS idx_upya_payments_code
    ON silver.upya_payments(payment_code);
"""

UPSERT_SQL = """
INSERT INTO silver.upya_payments (
    transaction_id, contract_number, payment_date,
    amount, currency, status, operator, payment_type,
    payment_code, payment_reference, mobile,
    entity_name, entity_number
) VALUES %s
ON CONFLICT (transaction_id) DO UPDATE SET
    contract_number   = EXCLUDED.contract_number,
    payment_date      = EXCLUDED.payment_date,
    amount            = EXCLUDED.amount,
    currency          = EXCLUDED.currency,
    status            = EXCLUDED.status,
    operator          = EXCLUDED.operator,
    payment_type      = EXCLUDED.payment_type,
    payment_code      = EXCLUDED.payment_code,
    payment_reference = EXCLUDED.payment_reference,
    mobile            = EXCLUDED.mobile,
    entity_name       = EXCLUDED.entity_name,
    entity_number     = EXCLUDED.entity_number,
    updated_at        = NOW();
"""


def parse_date(date_str):
    """Convertit une date ISO en datetime UTC."""
    if not date_str:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def parse_amount(value):
    """Convertit un montant en float."""
    if value is None:
        return None
    try:
        if isinstance(value, str):
            value = value.replace(",", "").replace(" ", "")
        return float(value)
    except (ValueError, TypeError):
        return None


def transform_payment(item):
    """
    Transforme un paiement JSON UPYA en tuple SQL.

    Champs JSON UPYA disponibles :
    transactionId, date, amount, ccy, contractNumber,
    days, mobile, operator, paymentCode, paymentReference,
    status, type, entity
    """
    transaction_id = item.get("transactionId")
    if not transaction_id:
        return None

    entity = item.get("entity") or {}

    return (
        str(transaction_id),
        item.get("contractNumber"),
        parse_date(item.get("date")),
        parse_amount(item.get("amount")),
        item.get("ccy"),
        item.get("status"),
        item.get("operator"),
        item.get("type"),
        item.get("paymentCode"),          # upfront vs recharge
        item.get("paymentReference"),
        item.get("mobile"),
        entity.get("name") if isinstance(entity, dict) else None,
        entity.get("entityNumber") if isinstance(entity, dict) else None,
    )


def load_payments(date=None):
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — UPYA PAYMENTS v2")
    logger.info("=" * 50)

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.upya_payments prête")

    files = list_bronze_files(minio_client, bucket, "upya", "payments", date)

    if not files:
        logger.warning("Aucun fichier Bronze trouvé pour payments")
        return 0

    logger.info(f"Fichiers à traiter : {len(files)}")

    total_rows   = 0
    total_errors = 0

    for file_key in files:
        try:
            content = download_json(minio_client, bucket, file_key)
            items   = json.loads(content)

            rows = [r for r in (transform_payment(i) for i in items) if r]

            if not rows:
                logger.warning(f"Aucune ligne valide dans {file_key}")
                continue

            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, rows, page_size=500)
            conn.commit()
            cur.close()

            total_rows += len(rows)
            logger.info(f"  {file_key.split('/')[-1]} → {len(rows)} paiements")

        except Exception as e:
            conn.rollback()
            logger.error(f"Erreur sur {file_key} : {e}")
            total_errors += 1

    # Stats par payment_code
    cur = conn.cursor()
    cur.execute("""
        SELECT payment_code, COUNT(*), SUM(amount)
        FROM silver.upya_payments
        WHERE status = 'ACCEPTED'
        GROUP BY payment_code
        ORDER BY COUNT(*) DESC
    """)
    logger.info("Répartition par payment_code :")
    for row in cur.fetchall():
        logger.info(f"  {str(row[0] or 'NULL'):30} : {row[1]:>8,} tx | {row[2] or 0:>15,.0f} XOF")
    cur.close()

    duration = time.time() - start_time

    logger.info("=" * 50)
    logger.info(f"✅ SILVER PAYMENTS v2 TERMINÉ")
    logger.info(f"   Fichiers : {len(files)}")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Erreurs  : {total_errors}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_payments(date)