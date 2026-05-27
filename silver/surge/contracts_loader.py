
# silver/surge/contracts_loader.py
#
# RÔLE : Lire le CSV Bronze SURGE contracts → nettoyer →
# charger dans PostgreSQL silver.surge_contracts
#
# SOURCE : Export brut CRM SURGE (29 colonnes)
# CIBLE  : silver.surge_contracts (21 colonnes utiles)

import os
import sys
import logging
import time
import tempfile

import pandas as pd
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, list_bronze_files
from database.db_client import get_db_connection, init_schemas

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

COLUMNS_TO_KEEP = [
    "id", "customer_id", "customer_name", "status",
    "region", "district", "ward",
    "financial_type", "lease_term_in_months",
    "requested", "unlocked_until", "paid_at",
    "activated_at", "canceled_at", "removed_at",
    "order_created_by", "lead_created_by", "installed_by",
    "removal_reason", "latitude", "longitude"
]

COLUMN_MAPPING = {
    "id":                   "installation_id",
    "customer_id":          "customer_id",
    "customer_name":        "customer_name",
    "status":               "status",
    "region":               "region",
    "district":             "district",
    "ward":                 "ward",
    "financial_type":       "financial_type",
    "lease_term_in_months": "lease_term_in_months",
    "requested":            "requested_date",
    "unlocked_until":       "unlocked_until",
    "paid_at":              "paid_at",
    "activated_at":         "activated_at",
    "canceled_at":          "canceled_at",
    "removed_at":           "removed_at",
    "order_created_by":     "order_created_by",
    "lead_created_by":      "lead_created_by",
    "installed_by":         "installed_by",
    "removal_reason":       "removal_reason",
    "latitude":             "latitude",
    "longitude":            "longitude",
}

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.surge_contracts (
    installation_id      TEXT PRIMARY KEY,
    customer_id          TEXT,
    customer_name        TEXT,
    status               TEXT,
    region               TEXT,
    district             TEXT,
    ward                 TEXT,
    financial_type       TEXT,
    lease_term_in_months INTEGER,
    requested_date       DATE,
    unlocked_until       DATE,
    paid_at              DATE,
    activated_at         DATE,
    canceled_at          DATE,
    removed_at           DATE,
    order_created_by     TEXT,
    lead_created_by      TEXT,
    installed_by         TEXT,
    removal_reason       TEXT,
    latitude             NUMERIC(18,8),
    longitude            NUMERIC(18,8),
    loaded_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_surge_contracts_status
    ON silver.surge_contracts(status);
CREATE INDEX IF NOT EXISTS idx_surge_contracts_customer
    ON silver.surge_contracts(customer_id);
CREATE INDEX IF NOT EXISTS idx_surge_contracts_region
    ON silver.surge_contracts(region);
"""

UPSERT_SQL = """
INSERT INTO silver.surge_contracts (
    installation_id, customer_id, customer_name, status,
    region, district, ward, financial_type, lease_term_in_months,
    requested_date, unlocked_until, paid_at, activated_at,
    canceled_at, removed_at, order_created_by, lead_created_by,
    installed_by, removal_reason, latitude, longitude
) VALUES %s
ON CONFLICT (installation_id) DO UPDATE SET
    status         = EXCLUDED.status,
    unlocked_until = EXCLUDED.unlocked_until,
    paid_at        = EXCLUDED.paid_at,
    activated_at   = EXCLUDED.activated_at,
    canceled_at    = EXCLUDED.canceled_at,
    removed_at     = EXCLUDED.removed_at,
    removal_reason = EXCLUDED.removal_reason,
    updated_at     = NOW();
"""


def clean_value(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
            return None
        return str(v).strip()
    except Exception:
        return None


def clean_date(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
            return None
        result = pd.to_datetime(v, errors="coerce")
        return result.date() if not pd.isna(result) else None
    except Exception:
        return None


def clean_number(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
            return None
        s = str(v).replace(",", "").replace("$", "").strip()
        return float(s) if s else None
    except Exception:
        return None


def clean_int(v):
    n = clean_number(v)
    return int(n) if n is not None else None


def make_row(r):
    return (
        clean_value(r.get("installation_id")),
        clean_value(r.get("customer_id")),
        clean_value(r.get("customer_name")),
        clean_value(r.get("status")),
        clean_value(r.get("region")),
        clean_value(r.get("district")),
        clean_value(r.get("ward")),
        clean_value(r.get("financial_type")),
        clean_int(r.get("lease_term_in_months")),
        clean_date(r.get("requested_date")),
        clean_date(r.get("unlocked_until")),
        clean_date(r.get("paid_at")),
        clean_date(r.get("activated_at")),
        clean_date(r.get("canceled_at")),
        clean_date(r.get("removed_at")),
        clean_value(r.get("order_created_by")),
        clean_value(r.get("lead_created_by")),
        clean_value(r.get("installed_by")),
        clean_value(r.get("removal_reason")),
        clean_number(r.get("latitude")),
        clean_number(r.get("longitude")),
    )


def load_surge_contracts(date=None):
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — SURGE CONTRACTS")
    logger.info("=" * 50)

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.surge_contracts prête")

    files = list_bronze_files(minio_client, bucket, "surge", "contracts", date)
    if not files:
        logger.warning("Aucun fichier Bronze SURGE contracts trouvé")
        return

    latest_file = files[-1]
    logger.info(f"Fichier : {latest_file}")

    total_rows   = 0
    total_errors = 0
    tmp_path     = None

    try:
        # Étape 1 — Téléchargement MinIO → fichier temporaire
        response = minio_client.get_object(bucket, latest_file)
        tmp = tempfile.NamedTemporaryFile(
            delete=False, suffix=".csv", prefix="surge_contracts_"
        )
        tmp.write(response.read())
        tmp.close()
        response.close()
        response.release_conn()
        tmp_path = tmp.name
        logger.info(f"Téléchargé : {tmp_path}")

        # Étape 2 — Lecture complète en mémoire
        logger.info("Lecture CSV en mémoire...")
        df = pd.read_csv(tmp_path, dtype=str, low_memory=False)
        logger.info(f"Lignes brutes : {len(df):,} | Colonnes : {len(df.columns)}")

        # Étape 3 — Suppression fichier temporaire
        os.unlink(tmp_path)
        tmp_path = None
        logger.info("Fichier temporaire supprimé")

        # Étape 4 — Colonnes utiles uniquement
        available = [c for c in COLUMNS_TO_KEEP if c in df.columns]
        missing   = [c for c in COLUMNS_TO_KEEP if c not in df.columns]
        if missing:
            logger.warning(f"Colonnes absentes : {missing}")
        df = df[available]

        # Étape 5 — Renommage
        df = df.rename(columns=COLUMN_MAPPING)

        # Étape 6 — Nettoyage clé primaire
        df["installation_id"] = df["installation_id"].apply(clean_value)
        df = df[df["installation_id"].notna()]
        df = df.drop_duplicates(subset=["installation_id"], keep="last")
        logger.info(f"Lignes uniques : {len(df):,}")

        # Filtre métier — on ne garde que les contrats activés
        # Un contrat sans activated_at n'a jamais eu de vie
        before = len(df)
        df["activated_at"] = df["activated_at"].apply(clean_value)
        df = df[df["activated_at"].notna()]
        after = len(df)
        logger.info(
            f"Filtre activated_at IS NOT NULL : "
            f"{before:,} → {after:,} "
            f"({before - after:,} contrats non activés exclus)"
        )

        # Étape 7 — Upsert par chunks
        CHUNK_SIZE   = 10_000
        total_chunks = (len(df) // CHUNK_SIZE) + 1

        for i in range(total_chunks):
            i0    = i * CHUNK_SIZE
            i1    = min(i0 + CHUNK_SIZE, len(df))
            chunk = df.iloc[i0:i1]
            if chunk.empty:
                continue

            rows = [make_row(r) for _, r in chunk.iterrows()]
            rows = [r for r in rows if r[0] is not None]
            if not rows:
                continue

            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, rows, page_size=500)
            conn.commit()
            cur.close()

            total_rows += len(rows)
            logger.info(
                f"Chunk {i+1}/{total_chunks} : "
                f"{len(rows):,} lignes (total : {total_rows:,})"
            )

    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur : {e}", exc_info=True)
        total_errors += 1

    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    duration = time.time() - start_time
    logger.info("=" * 50)
    logger.info(f"✅ SILVER SURGE CONTRACTS TERMINÉ")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Erreurs  : {total_errors}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_surge_contracts(date)