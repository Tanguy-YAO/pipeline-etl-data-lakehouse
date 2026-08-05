# silver/surge/lease_engine_loader.py
#
# RÔLE : Charger le LBL complet (NetSuite + reconstruction 2026)
# depuis Google Drive vers silver.surge_lease_engine
#
# SOURCE : surge_lease_engine.csv dans Drive (surge_payments/)
#          = lbl_conso_complet (historique nov 2017 → juillet 2026)
#
# NOTE (05/08/2026) : la table silver.surge_lease_engine existe déjà en
# production avec les noms de colonnes contract_ref / ending_balance_principal /
# ending_balance_interest (et non contract_ogc / ending_principal / ending_interest
# comme dans une version antérieure de ce script). De nombreuses vues gold
# (gold.unified_contracts et 10 vues qui en dépendent) reposent sur cette
# structure existante -> ce script a été aligné sur la table réelle plutôt que
# l'inverse, pour ne rien casser en aval.
#
# UTILISATION (depuis la racine du projet) :
#   python -m silver.surge.lease_engine_loader

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
from bronze.surge.surge_extractor import get_drive_service, find_folder_id

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS silver.surge_lease_engine (
    -- Identifiants
    contract_ref             TEXT,           -- Numéro NetSuite (OGCxxxxxxx)
    installation_id          TEXT,           -- Surge Installation Id

    -- Période
    posting_date              DATE,           -- Date de la période (mensuelle)
    billing_date               DATE,           -- Date de facturation
    period                      INTEGER,        -- Numéro de période

    -- Cash collecté
    total_cash_collected      NUMERIC(18,2),  -- Total encaissé cumulé

    -- Soldes de clôture
    ending_balance_principal  NUMERIC(18,2),  -- Principal restant
    ending_balance_interest   NUMERIC(18,2),  -- Intérêts restants
    total_ending_balance      NUMERIC(18,2),  -- Solde total restant

    -- Infos contrat
    status                       TEXT,
    subsidiary                  TEXT,           -- OGE : NEOT ou JV
    contract_type               TEXT,

    -- Méta
    loaded_at                   TIMESTAMPTZ DEFAULT NOW(),

    -- Clé primaire composite RÉELLE, confirmée en base le 05/08/2026 via
    -- information_schema.table_constraints (PAS contract_ref/posting_date,
    -- qui n'était qu'une hypothèse initiale erronée)
    PRIMARY KEY (installation_id, period)
);

CREATE INDEX IF NOT EXISTS idx_lease_engine_installation
    ON silver.surge_lease_engine(installation_id);
CREATE INDEX IF NOT EXISTS idx_lease_engine_date
    ON silver.surge_lease_engine(posting_date);
CREATE INDEX IF NOT EXISTS idx_lease_engine_subsidiary
    ON silver.surge_lease_engine(subsidiary);
"""

UPSERT_SQL = """
INSERT INTO silver.surge_lease_engine (
    contract_ref, installation_id,
    posting_date, billing_date, period,
    total_cash_collected,
    ending_balance_principal, ending_balance_interest, total_ending_balance,
    status, subsidiary, contract_type
) VALUES %s
ON CONFLICT (installation_id, period) DO UPDATE SET
    contract_ref              = EXCLUDED.contract_ref,
    total_cash_collected     = EXCLUDED.total_cash_collected,
    ending_balance_principal = EXCLUDED.ending_balance_principal,
    ending_balance_interest  = EXCLUDED.ending_balance_interest,
    total_ending_balance     = EXCLUDED.total_ending_balance;
"""


def clean_number(v):
    try:
        if pd.isna(v):
            return None
        s = str(v).replace(",", "").replace(" ", "").strip()
        return float(s) if s else None
    except Exception:
        return None


def clean_date(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan"):
            return None
        result = pd.to_datetime(v, errors="coerce")
        return result.date() if not pd.isna(result) else None
    except Exception:
        return None


def clean_int(v):
    n = clean_number(v)
    return int(n) if n is not None else None


def clean_value(v):
    try:
        if pd.isna(v) or str(v).strip().lower() in ("", "nan", "none"):
            return None
        return str(v).strip()
    except Exception:
        return None


def load_lease_engine():
    load_dotenv()
    start_time = time.time()

    logger.info("=" * 50)
    logger.info("SILVER LOADER — SURGE LEASE ENGINE")
    logger.info("=" * 50)

    # Trouver le fichier dans Drive
    service   = get_drive_service()
    root_id   = find_folder_id(service, "surge_daily_logs")
    folder_id = find_folder_id(service, "surge_payments", root_id)

    query   = f"'{folder_id}' in parents and name contains 'lease_engine' and trashed=false"
    results = service.files().list(
        q=query,
        fields="files(id, name, size)",
        orderBy="modifiedTime desc"
    ).execute()
    files = results.get("files", [])
    if not files:
        raise ValueError("Fichier surge_lease_engine introuvable dans Drive")

    f       = files[0]
    size_mb = int(f.get("size", 0)) / 1024 / 1024
    logger.info(f"Fichier : {f['name']} ({size_mb:.1f} MB)")

    # Connexion DB
    conn = get_db_connection()
    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    conn.commit()
    cur.close()
    logger.info("Table silver.surge_lease_engine prête")

    # Téléchargement
    logger.info("Téléchargement depuis Drive...")
    request = service.files().get_media(fileId=f["id"])
    tmp     = tempfile.NamedTemporaryFile(
        delete=False, suffix=".csv", prefix="lease_engine_"
    )

    downloaded = 0
    CHUNK = 8 * 1024 * 1024
    data  = request.execute()
    tmp.write(data)
    tmp.close()
    logger.info(f"Téléchargé : {len(data)/1024/1024:.1f} MB")

    tmp_path   = tmp.name
    total_rows = 0

    try:
        # Lecture en mémoire
        logger.info("Lecture CSV en mémoire...")
        df = pd.read_csv(tmp_path, dtype=str, low_memory=False)
        logger.info(f"Lignes : {len(df):,} | Colonnes : {len(df.columns)}")

        # Suppression fichier temporaire
        os.unlink(tmp_path)
        tmp_path = None

        # Renommage colonnes
        df = df.rename(columns={
            "Contract":                          "contract_ref",
            "Surge Installation Id":             "installation_id",
            "Posting Date":                      "posting_date",
            "Billing Date":                      "billing_date",
            "Period":                            "period",
            "Total Cash Collected from Customer":"total_cash_collected",
            "Ending Balance Principal":          "ending_balance_principal",
            "Ending Balance Interest":           "ending_balance_interest",
            "Total Ending Balance":              "total_ending_balance",
            "Status":                            "status",
            "Subsidiary":                        "subsidiary",
            "Contract Type":                     "contract_type",
        })

        # Nettoyage colonnes clés
        df["contract_ref"]    = df["contract_ref"].apply(clean_value)
        df["installation_id"] = df["installation_id"].apply(clean_value)
        df["posting_date"]    = df["posting_date"].apply(clean_date)

        # Filtre sur la VRAIE clé primaire (installation_id, period) confirmée
        # en base -- contract_ref/posting_date restent des colonnes normales,
        # plus la clé de déduplication.
        df = df[df["installation_id"].notna() & df["period"].notna()]

        # Filtrer les lignes parasites (ex: "Overall Total", qui n'a pas de
        # contract_ref commençant par "OGC")
        df = df[df["contract_ref"].str.startswith("OGC", na=False)]
        df = df.drop_duplicates(subset=["installation_id", "period"], keep="last")
        logger.info(f"Lignes valides : {len(df):,}")

        # Upsert par chunks
        CHUNK_SIZE   = 50_000
        total_chunks = (len(df) // CHUNK_SIZE) + 1

        for i in range(total_chunks):
            i0    = i * CHUNK_SIZE
            i1    = min(i0 + CHUNK_SIZE, len(df))
            chunk = df.iloc[i0:i1]
            if chunk.empty:
                continue

            rows = []
            for r in chunk.itertuples(index=False):
                r = r._asdict()
                rows.append((
                    clean_value(r.get("contract_ref")),
                    clean_value(r.get("installation_id")),
                    clean_date(r.get("posting_date")),
                    clean_date(r.get("billing_date")),
                    clean_int(r.get("period")),
                    clean_number(r.get("total_cash_collected")),
                    clean_number(r.get("ending_balance_principal")),
                    clean_number(r.get("ending_balance_interest")),
                    clean_number(r.get("total_ending_balance")),
                    clean_value(r.get("status")),
                    clean_value(r.get("subsidiary")),
                    clean_value(r.get("contract_type")),
                ))

            # index 1 = installation_id, index 4 = period -- la vraie clé primaire
            # (test "is not None", pas juste "truthy" : period=0 est une valeur
            # légitime qu'un simple `if r[4]` aurait éliminée par erreur)
            rows = [r for r in rows if r[1] is not None and r[4] is not None]

            cur = conn.cursor()
            execute_values(cur, UPSERT_SQL, rows, page_size=1000)
            conn.commit()
            cur.close()

            total_rows += len(rows)
            logger.info(f"Chunk {i+1}/{total_chunks} : {len(rows):,} lignes (total : {total_rows:,})")

        # Stats
        cur = conn.cursor()
        cur.execute("""
            SELECT
                MIN(posting_date) as debut,
                MAX(posting_date) as fin,
                COUNT(DISTINCT contract_ref) as contrats,
                COUNT(DISTINCT installation_id) as installations
            FROM silver.surge_lease_engine
        """)
        row = cur.fetchone()
        logger.info(f"Période     : {row[0]} → {row[1]}")
        logger.info(f"Contrats    : {row[2]:,}")
        logger.info(f"Installations : {row[3]:,}")
        cur.close()

    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur : {e}", exc_info=True)

    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    duration = time.time() - start_time
    logger.info("=" * 50)
    logger.info(f"✅ LEASE ENGINE TERMINÉ")
    logger.info(f"   Lignes   : {total_rows:,}")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    conn.close()
    return total_rows


if __name__ == "__main__":
    load_lease_engine()