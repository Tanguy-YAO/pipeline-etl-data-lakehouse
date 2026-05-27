# silver/upya/payments_loader.py
#
# RÔLE : Lire les JSON Bronze (MinIO) → nettoyer → charger
# dans PostgreSQL silver.upya_payments
#
# FLUX :
#   MinIO Bronze (bronze/upya/payments/2026/05/27/*.json)
#       → [ce fichier]
#       → PostgreSQL silver.upya_payments

import os
import sys
import json
import logging
import time
from datetime import datetime, timezone

import psycopg2
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

# SCHÉMA SILVER — fixe et documenté
# On choisit exactement les colonnes qu'on veut.

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.upya_payments (
    -- Identifiant unique de la transaction
    transaction_id    TEXT PRIMARY KEY,

    -- Lien avec le contrat (clé de jointure)
    contract_number   TEXT,

    -- Informations de paiement
    payment_date      TIMESTAMPTZ,
    amount            NUMERIC(18,2),
    currency          TEXT,
    status            TEXT,

    -- Opérateur mobile money (MTN, Orange, etc.)
    operator          TEXT,
    payment_type      TEXT,
    payment_reference TEXT,
    mobile            TEXT,

    -- Entité (agence, point de vente)
    entity_name       TEXT,
    entity_number     TEXT,

    -- Métadonnées pipeline
    loaded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_upya_payments_contract
    ON silver.upya_payments(contract_number);

CREATE INDEX IF NOT EXISTS idx_upya_payments_date
    ON silver.upya_payments(payment_date);

CREATE INDEX IF NOT EXISTS idx_upya_payments_status
    ON silver.upya_payments(status);
"""

UPSERT_SQL = """
INSERT INTO silver.upya_payments (
    transaction_id, contract_number, payment_date,
    amount, currency, status, operator, payment_type,
    payment_reference, mobile, entity_name, entity_number
) VALUES %s
ON CONFLICT (transaction_id) DO UPDATE SET
    contract_number   = EXCLUDED.contract_number,
    payment_date      = EXCLUDED.payment_date,
    amount            = EXCLUDED.amount,
    currency          = EXCLUDED.currency,
    status            = EXCLUDED.status,
    operator          = EXCLUDED.operator,
    payment_type      = EXCLUDED.payment_type,
    payment_reference = EXCLUDED.payment_reference,
    mobile            = EXCLUDED.mobile,
    entity_name       = EXCLUDED.entity_name,
    entity_number     = EXCLUDED.entity_number,
    updated_at        = NOW();
"""


def parse_date(date_str):
    """
    Convertit une date ISO en datetime Python.
    Retourne None si la date est invalide ou absente.

    Pourquoi gérer None ?
    → Les APIs retournent parfois des champs vides.
      PostgreSQL accepte NULL mais pas une string vide
      dans une colonne TIMESTAMPTZ.
    """
    if not date_str:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def parse_amount(value):
    """
    Convertit un montant en float.
    Retourne None si invalide.

    Pourquoi ?
    → L'API peut retourner "20,000" (string avec virgule)
      ou 20000 (int) ou 20000.0 (float).
      On normalise tout en float propre.
    """
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
    Transforme un dict JSON brut en tuple SQL.

    C'est le coeur de la transformation Silver :
    on mappe explicitement chaque champ JSON vers
    sa colonne PostgreSQL avec le bon type.

    Args:
        item: dict JSON brut de l'API UPYA

    Returns:
        tuple: prêt pour l'insertion PostgreSQL
        None : si l'item est invalide (pas de transaction_id)
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
        item.get("paymentReference"),
        item.get("mobile"),
        entity.get("name") if isinstance(entity, dict) else None,
        entity.get("entityNumber") if isinstance(entity, dict) else None,
    )


def load_payments(date=None):
    """
    Charge les paiements Bronze → Silver.

    Séquence :
    1. Liste les fichiers JSON dans MinIO Bronze
    2. Pour chaque fichier → télécharge → transforme → upsert
    3. Commit par batch de fichiers

    Args:
        date: "2026/05/27" pour charger un jour précis
              None = dernier jour disponible
    """
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — UPYA PAYMENTS")
    logger.info("=" * 50)

    # Connexions
    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    # Création de la table Silver si elle n'existe pas
    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.upya_payments prête")

    # Liste les fichiers Bronze disponibles
    files = list_bronze_files(minio_client, bucket, "upya", "payments", date)

    if not files:
        logger.warning("Aucun fichier Bronze trouvé pour payments")
        return

    logger.info(f"Fichiers à traiter : {len(files)}")

    total_rows    = 0
    total_errors  = 0

    for file_key in files:
        logger.info(f"Traitement : {file_key}")

        try:
            # Télécharge le JSON depuis MinIO
            content = download_json(minio_client, bucket, file_key)

            # Parse le JSON — c'est une liste de paiements
            items = json.loads(content)

            # Transforme chaque paiement en tuple SQL
            rows = []
            for item in items:
                row = transform_payment(item)
                if row:
                    rows.append(row)
                else:
                    total_errors += 1

            if not rows:
                logger.warning(f"Aucune ligne valide dans {file_key}")
                continue

            # Upsert en batch
            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, rows, page_size=500)
            conn.commit()
            cur.close()

            total_rows += len(rows)
            logger.info(f"  → {len(rows)} paiements chargés")

        except Exception as e:
            conn.rollback()
            logger.error(f"Erreur sur {file_key} : {e}")
            total_errors += 1

    duration = time.time() - start_time

    logger.info("=" * 50)
    logger.info(f"✅ SILVER PAYMENTS TERMINÉ")
    logger.info(f"   Fichiers  : {len(files)}")
    logger.info(f"   Lignes    : {total_rows}")
    logger.info(f"   Erreurs   : {total_errors}")
    logger.info(f"   Durée     : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    import sys
    # Optionnel : passer une date en argument
    # python payments_loader.py 2026/05/27
    date = sys.argv[1] if len(sys.argv) > 1 else None
    load_payments(date)