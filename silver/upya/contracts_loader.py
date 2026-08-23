# silver/upya/contracts_loader.py v3.4
#
# NOUVEAUTÉS v3 :
# - Ajout repossession_date (depuis repossessionDate API)
# - Indispensable pour le rapport EFA (nb_repossessions,
#   nb_new_repossessions, repossession_rate)
# CORRECTION v3.1 :
# - Normalisation statuts en MAJUSCULES à l'insertion
# CORRECTION v3.2 :
# - Ajout sub_prefecture depuis profile.commune (UPYA API)
# - district conservé séparément
# CORRECTION v3.3 :
# - Ajout latitude et longitude depuis profile.gps (UPYA API)
# CORRECTION v3.4 (21/08/2026) :
# - Watermark Silver : ne relit plus TOUT l'historique Bronze a chaque
#   run (cause du timeout de 90min du 21/08/2026), seulement les
#   fichiers non encore traites avec succes. Voir silver_meta.load_watermark.

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
from database.db_client import (
    get_db_connection, init_schemas,
    get_load_watermark, set_load_watermark
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
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
    repossession_date   TIMESTAMPTZ,
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
    sub_prefecture      TEXT,
    district            TEXT,
    village             TEXT,
    latitude            DOUBLE PRECISION,
    longitude           DOUBLE PRECISION,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_upya_contracts_status
    ON silver.upya_contracts(status);
CREATE INDEX IF NOT EXISTS idx_upya_contracts_entity
    ON silver.upya_contracts(entity_name);
CREATE INDEX IF NOT EXISTS idx_upya_contracts_client
    ON silver.upya_contracts(client_number);
"""

UPSERT_SQL = """
INSERT INTO silver.upya_contracts (
    contract_number, entity_name, status, onboarding_status,
    flag, paid_off_status, deal_type,
    signing_date, registration_date, last_status_update,
    next_status_update, paid_off_date, repossession_date,
    total_cost, total_paid, remaining_debt,
    upfront_payment, monthly_payment,
    product_name, asset_number,
    client_number, customer_name,
    agent_number, agent_name,
    region, sub_prefecture, district, village,
    latitude, longitude
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
    repossession_date  = EXCLUDED.repossession_date,
    total_cost         = EXCLUDED.total_cost,
    total_paid         = EXCLUDED.total_paid,
    remaining_debt     = EXCLUDED.remaining_debt,
    upfront_payment    = EXCLUDED.upfront_payment,
    monthly_payment    = EXCLUDED.monthly_payment,
    sub_prefecture     = EXCLUDED.sub_prefecture,
    district           = EXCLUDED.district,
    village            = EXCLUDED.village,
    latitude           = EXCLUDED.latitude,
    longitude          = EXCLUDED.longitude,
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


def parse_float(v):
    """Convertit une valeur GPS en float — retourne None si invalide."""
    if v is None:
        return None
    try:
        return float(v)
    except Exception:
        return None


def concat_name(first, last):
    parts = [p for p in [first, last] if p and str(p).strip()]
    return " ".join(parts) if parts else None


def transform_contract(item):
    contract_number = item.get("contractNumber")
    if not contract_number:
        return None

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

    paidoff_obj    = item.get("paidOff") or {}
    paidoff_status = (
        paidoff_obj.get("status")
        or item.get("paidoffStatus")
        or item.get("paidOffStatus")
        or ""
    )

    raw_status = item.get("status")
    status = raw_status.upper() if raw_status else None

    gps       = profile.get("gps") or {}
    latitude  = parse_float(gps.get("latitude"))
    longitude = parse_float(gps.get("longitude"))

    return (
        str(contract_number),
        entity.get("name"),
        status,
        item.get("onboardingStatus"),
        item.get("flag"),
        str(paidoff_status),
        item.get("type"),
        parse_date(item.get("signingDate")),
        parse_date(item.get("signingDate")),
        parse_date(item.get("lastStatusUpdate")),
        parse_date(item.get("nextStatusUpdate")),
        parse_date(item.get("paidOffDate") or item.get("paidoffDate")),
        parse_date(item.get("repossessionDate")),
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
        profile.get("commune"),
        profile.get("district"),
        profile.get("village"),
        latitude,
        longitude,
    )


def load_contracts(date=None):
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — UPYA CONTRACTS v3.4")
    logger.info("=" * 50)

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()

    cur.execute("""
        ALTER TABLE IF EXISTS silver.upya_contracts
        ADD COLUMN IF NOT EXISTS sub_prefecture TEXT,
        ADD COLUMN IF NOT EXISTS district       TEXT,
        ADD COLUMN IF NOT EXISTS latitude       DOUBLE PRECISION,
        ADD COLUMN IF NOT EXISTS longitude      DOUBLE PRECISION
    """)
    conn.commit()

    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.upya_contracts prête")

    # Watermark : ne relit que les fichiers non encore traites avec succes,
    # sauf appel explicite avec une date precise (rejeu manuel d'un jour donne)
    since = date if date else get_load_watermark(conn, "upya", "contracts")
    files = list_bronze_files(minio_client, bucket, "upya", "contracts", since_date=since)

    if not files:
        logger.warning("Aucun nouveau fichier Bronze pour contracts depuis le dernier chargement")
        conn.close()
        return 0

    logger.info(f"Fichiers à traiter : {len(files)} (depuis {since or 'le début'})")
    total_rows   = 0
    total_errors = 0
    max_date_seen = since

    for file_key in files:
        try:
            content = download_json(minio_client, bucket, file_key)
            items   = json.loads(content)
            rows    = [r for r in (transform_contract(i) for i in items) if r]

            if rows:
                cur = conn.cursor()
                execute_values(cur, UPSERT_SQL, rows, page_size=200)
                conn.commit()
                cur.close()
                total_rows += len(rows)
                logger.info(f"  {file_key.split('/')[-1]} → {len(rows)} contrats")

            # Extrait la date du chemin bronze/upya/contracts/YYYY/MM/DD/xxx.json
            path_parts = file_key.split("/")
            file_date = "/".join(path_parts[3:6])
            if max_date_seen is None or file_date > max_date_seen:
                max_date_seen = file_date

        except Exception as e:
            conn.rollback()
            logger.error(f"Erreur {file_key} : {e}")
            total_errors += 1

    # N'avance le watermark que si tout s'est bien passe -- en cas d'erreur,
    # on prefere retraiter ces fichiers au prochain run plutot que de risquer
    # de perdre silencieusement un changement de statut.
    if total_errors == 0 and max_date_seen and not date:
        set_load_watermark(conn, "upya", "contracts", max_date_seen)
        logger.info(f"Watermark Silver mis à jour : {max_date_seen}")
    elif total_errors > 0:
        logger.warning(f"{total_errors} erreur(s) rencontrée(s) — watermark non avancé, ces fichiers seront retraités au prochain run")

    cur = conn.cursor()
    cur.execute("""
        SELECT entity_name, COUNT(*),
               COUNT(repossession_date) AS avec_repossession_date,
               COUNT(sub_prefecture)   AS avec_sub_prefecture,
               COUNT(latitude)         AS avec_gps
        FROM silver.upya_contracts
        GROUP BY entity_name ORDER BY COUNT(*) DESC
    """)
    logger.info("Répartition par entité :")
    for row in cur.fetchall():
        logger.info(
            f"  {row[0] or 'NULL':10} : {row[1]:,} contrats "
            f"| {row[2]:,} repossessions "
            f"| {row[3]:,} avec sub_prefecture "
            f"| {row[4]:,} avec GPS"
        )
    cur.close()

    duration = time.time() - start_time
    logger.info("=" * 50)
    logger.info(f"SILVER CONTRACTS v3.4 TERMINÉ")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Erreurs  : {total_errors}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_contracts(date)