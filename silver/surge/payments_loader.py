# silver/surge/payments_loader.py
#
# RÔLE : Lire le CSV Bronze SURGE payments → nettoyer →
# charger dans PostgreSQL silver.surge_payments
#
# SOURCE : Export CRM SURGE payments (9 colonnes)
# VOLUME : ~658k lignes (fichier de 372 MB)
#
# COLONNES SOURCE :
#   ID, Sender Name, Source Name, Payment Kind,
#   Paid Time, External Reference, Payment Status,
#   Account, Amount

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


# Colonnes source → noms Silver
COLUMN_MAPPING = {
    "ID":                 "transaction_id",
    "Sender Name":        "sender_name",
    "Source Name":        "source_name",
    "Payment Kind":       "payment_kind",
    "Paid Time":          "paid_time",
    "External Reference": "external_reference",
    "Payment Status":     "payment_status",
    "Account":            "account",
    "Amount":             "amount",
}

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.surge_payments (
    -- Identifiant unique de la transaction
    transaction_id      TEXT PRIMARY KEY,

    -- Expéditeur et source
    sender_name         TEXT,
    source_name         TEXT,
    payment_kind        TEXT,

    -- Date et référence
    paid_time           TIMESTAMPTZ,
    external_reference  TEXT,

    -- Statut
    payment_status      TEXT,

    -- Lien avec le contrat SURGE
    -- Account = installation_id dans surge_contracts
    account             TEXT,

    -- Montant (stocké en string "20,000" → converti en float)
    amount              NUMERIC(18,2),

    -- Méta pipeline
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_surge_payments_account
    ON silver.surge_payments(account);

CREATE INDEX IF NOT EXISTS idx_surge_payments_paid_time
    ON silver.surge_payments(paid_time);

CREATE INDEX IF NOT EXISTS idx_surge_payments_status
    ON silver.surge_payments(payment_status);
"""

UPSERT_SQL = """
INSERT INTO silver.surge_payments (
    transaction_id, sender_name, source_name, payment_kind,
    paid_time, external_reference, payment_status,
    account, amount
) VALUES %s
ON CONFLICT (transaction_id) DO UPDATE SET
    payment_status     = EXCLUDED.payment_status,
    paid_time          = EXCLUDED.paid_time,
    amount             = EXCLUDED.amount,
    updated_at         = NOW();
"""


def clean_value(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
            return None
        return str(v).strip()
    except Exception:
        return None


def clean_datetime(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
            return None
        result = pd.to_datetime(v, errors="coerce")
        return result.to_pydatetime() if not pd.isna(result) else None
    except Exception:
        return None


def clean_amount(v):
    """
    Convertit le montant SURGE en float.
    Le CSV SURGE stocke les montants avec virgule :
    "20,000" → 20000.0
    """
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none", "null"):
            return None
        s = str(v).replace(",", "").replace(" ", "").strip()
        return float(s) if s else None
    except Exception:
        return None


def make_row(r):
    return (
        clean_value(r.get("transaction_id")),
        clean_value(r.get("sender_name")),
        clean_value(r.get("source_name")),
        clean_value(r.get("payment_kind")),
        clean_datetime(r.get("paid_time")),
        clean_value(r.get("external_reference")),
        clean_value(r.get("payment_status")),
        clean_value(r.get("account")),
        clean_amount(r.get("amount")),
    )


def load_surge_payments(date=None):
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — SURGE PAYMENTS")
    logger.info("=" * 50)

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.surge_payments prête")

    files = list_bronze_files(minio_client, bucket, "surge", "payments", date)
    if not files:
        logger.warning("Aucun fichier Bronze SURGE payments trouvé")
        return

    latest_file = files[-1]
    logger.info(f"Fichier : {latest_file}")

    total_rows   = 0
    total_errors = 0
    tmp_path     = None

    try:
        # Étape 1 — Téléchargement MinIO → fichier temporaire
        logger.info("Téléchargement depuis MinIO...")
        response = minio_client.get_object(bucket, latest_file)
        tmp = tempfile.NamedTemporaryFile(
            delete=False, suffix=".csv", prefix="surge_payments_"
        )

        # Téléchargement par morceaux pour les gros fichiers
        DOWNLOAD_CHUNK = 8 * 1024 * 1024  # 8 MB par morceau
        downloaded = 0
        for chunk in response.stream(DOWNLOAD_CHUNK):
            tmp.write(chunk)
            downloaded += len(chunk)
            if downloaded % (50 * 1024 * 1024) == 0:
                logger.info(f"  Téléchargé : {downloaded / 1024 / 1024:.0f} MB")

        tmp.close()
        response.close()
        response.release_conn()
        tmp_path = tmp.name
        logger.info(f"Téléchargement terminé : {downloaded / 1024 / 1024:.1f} MB")

        # Étape 2 — Lecture complète en mémoire
        logger.info("Lecture CSV en mémoire...")
        df = pd.read_csv(tmp_path, dtype=str, low_memory=False)
        logger.info(f"Lignes brutes : {len(df):,} | Colonnes : {list(df.columns)}")

        # Étape 3 — Suppression fichier temporaire
        os.unlink(tmp_path)
        tmp_path = None
        logger.info("Fichier temporaire supprimé")

        # Étape 4 — Renommage des colonnes
        df = df.rename(columns=COLUMN_MAPPING)

        # Étape 5 — Nettoyage clé primaire
        df["transaction_id"] = df["transaction_id"].apply(clean_value)
        df = df[df["transaction_id"].notna()]
        df = df.drop_duplicates(subset=["transaction_id"], keep="last")
        logger.info(f"Lignes uniques : {len(df):,}")

        # Étape 6 — Filtre métier : on garde uniquement
        # les paiements avec un account (lié à un contrat)
        before = len(df)
        df["account"] = df["account"].apply(clean_value)
        df = df[df["account"].notna()]
        logger.info(
            f"Filtre account IS NOT NULL : "
            f"{before:,} → {len(df):,} "
            f"({before - len(df):,} exclus)"
        )

        # Étape 7 — Upsert par chunks de 50 000 lignes
        # Plus grand que contracts car les lignes sont plus simples
        CHUNK_SIZE   = 50_000
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
            execute_values(cur, UPSERT_SQL, rows, page_size=1000)
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
    logger.info(f"✅ SILVER SURGE PAYMENTS TERMINÉ")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Erreurs  : {total_errors}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_surge_payments(date)