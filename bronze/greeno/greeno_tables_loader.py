# bronze/greeno/greeno_tables_loader.py
#
# RÔLE : Loader générique pour les 130 tables BASE TABLE de la BD GREENO
#        (Google Cloud SQL) → Silver PostgreSQL Railway
#
# APPROCHE : Full load (DROP + recreate) — ces tables n'ont pas de
#            colonne de modification fiable pour un watermark incrémental.
#            Les volumes sont faibles (~190k lignes total) — full load
#            tenable à chaque cycle.
#
# CONNEXION : IP statique Railway → Cloud SQL GREENO (whitelistée)
#
# NETTOYAGE :
#   - Chaîne vide → NULL
#   - "Error" littéral → NULL
#   - TRIM sur toutes les valeurs
#   - Colonnes géométriques → ST_AsText (cast TEXT)
#
# LOGGING : chaque table loggée dans bronze_meta.run_log
#           source = "greeno", entity = nom_table

import os
import sys
import logging
import time
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from database.db_client import get_db_connection, init_schemas, init_run_log, log_run

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)
load_dotenv()

# Tables à exclure (système, tests, extensions PostGIS)
EXCLUDE = {
    'spatial_ref_sys',
    'test_prospect_actions',
    'test_prospects',
    '00_menu',
}


def get_greeno_conn():
    return psycopg2.connect(
        host=os.getenv("GREENO_DB_HOST"),
        port=int(os.getenv("GREENO_DB_PORT") or 5432),
        dbname=os.getenv("GREENO_DB_NAME"),
        user=os.getenv("GREENO_DB_USERNAME"),
        password=os.getenv("GREENO_DB_PASSWORD"),
        sslmode="require",
        connect_timeout=30
    )


def get_tables(src_conn):
    cur = src_conn.cursor()
    cur.execute("""
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_type = 'BASE TABLE'
          AND table_name != ALL(%s)
        ORDER BY table_name
    """, (list(EXCLUDE),))
    tables = [r[0] for r in cur.fetchall()]
    cur.close()
    return tables


def get_columns(src_conn, table_name):
    cur = src_conn.cursor()
    cur.execute("""
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = %s
        ORDER BY ordinal_position
    """, (table_name,))
    cols = cur.fetchall()
    cur.close()
    return cols


def sync_table(src_conn, dst_conn, dst_log, table_name):
    start = time.time()
    try:
        cols = get_columns(src_conn, table_name)
        if not cols:
            logger.warning(f"{table_name}: aucune colonne — ignorée")
            return 0

        # Colonnes géométriques → cast ST_AsText côté source
        select_exprs = []
        col_names    = []
        for col_name, data_type in cols:
            if 'geometry' in data_type or 'geography' in data_type:
                select_exprs.append(f'ST_AsText("{col_name}")')
            else:
                select_exprs.append(f'"{col_name}"::text')
            col_names.append(col_name)

        # Lecture depuis Cloud SQL GREENO
        src_cur = src_conn.cursor()
        src_cur.execute(
            f'SELECT {", ".join(select_exprs)} FROM public."{table_name}"'
        )
        rows = src_cur.fetchall()
        src_cur.close()

        # Nettoyage : vide → NULL, "Error" → NULL, TRIM
        def clean(v):
            if v is None:
                return None
            s = str(v).strip()
            return None if s in ('', 'Error') else s

        rows_clean = [tuple(clean(v) for v in row) for row in rows]

        # Écriture dans silver Railway
        silver_table = f"greeno_{table_name}"
        col_defs     = ", ".join([f'"{c}" TEXT' for c in col_names])
        col_insert   = ", ".join([f'"{c}"' for c in col_names])

        dst_cur = dst_conn.cursor()
        dst_cur.execute(f"""
            CREATE SCHEMA IF NOT EXISTS silver;
            DROP TABLE IF EXISTS silver.{silver_table};
            CREATE TABLE silver.{silver_table} (
                {col_defs},
                loaded_at TIMESTAMPTZ DEFAULT NOW()
            );
        """)

        if rows_clean:
            execute_values(
                dst_cur,
                f'INSERT INTO silver.{silver_table} ({col_insert}) VALUES %s',
                rows_clean,
                page_size=500
            )

        dst_conn.commit()
        dst_cur.close()

        count = len(rows_clean)
        log_run(
            conn=dst_log,
            source="greeno",
            entity=table_name,
            status="success",
            rows_count=count,
            minio_prefix=None,
            duration_sec=time.time() - start,
        )
        logger.info(f"✅ {table_name}: {count:,} lignes ({time.time()-start:.1f}s)")
        return count

    except Exception as e:
        dst_conn.rollback()
        log_run(
            conn=dst_log,
            source="greeno",
            entity=table_name,
            status="error",
            rows_count=0,
            error_message=str(e),
            duration_sec=time.time() - start,
        )
        logger.error(f"❌ {table_name}: {e}")
        return 0


def main():
    logger.info("=" * 50)
    logger.info("GREENO — chargement des tables BASE TABLE")
    logger.info("=" * 50)

    src_conn = get_greeno_conn()
    dst_conn = get_db_connection()
    dst_log  = get_db_connection()
    init_schemas(dst_log)
    init_run_log(dst_log)

    tables = get_tables(src_conn)
    logger.info(f"Tables à traiter : {len(tables)}")

    total = 0
    for table in tables:
        total += sync_table(src_conn, dst_conn, dst_log, table)

    src_conn.close()
    dst_conn.close()
    dst_log.close()

    logger.info("=" * 50)
    logger.info(f"TERMINÉ — {total:,} lignes au total")
    logger.info("=" * 50)


if __name__ == "__main__":
    main()