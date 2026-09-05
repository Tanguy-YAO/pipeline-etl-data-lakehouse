# silver/greeno/vlk_silver_loader.py
import os
import sys
import logging
import time
import psycopg2
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from database.db_client import get_db_connection, init_schemas, init_run_log, log_run

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)
load_dotenv()

VLK_VIEWS = [
    "vlk_cds2_tlc", "vlk_commerciaux_vendeur_tlc", "vlk_credit_scoring_avec_date_deposit",
    "vlk_deposit_agent_tlc", "vlk_eligibilite_cds2_tlc", "vlk_installation_annee_en_cours",
    "vlk_installation_tlc", "vlk_installation_v2_tlc", "vlk_kyc_tlc",
    "vlk_ponderation_commerciaux", "vlk_preparation_installation", "vlk_prospect_tlc",
    "vlk_sav_req_fermees", "vlk_sav_req_ouvertes", "vlk_sites_evalues_tlc",
    "vlk_spatial_client_installe", "vlk_suivi_client_tlc", "vlk_sup_vente"
]


def get_columns(conn, table_name):
    cur = conn.cursor()
    cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'bronze' AND table_name = %s
          AND column_name != 'extracted_at'
        ORDER BY ordinal_position;
    """, (table_name,))
    cols = [r[0] for r in cur.fetchall()]
    cur.close()
    return cols


def sync_vlk_view(conn, view_name):
    bronze_table = f"greeno_{view_name}"
    silver_table = f"greeno_{view_name}"

    columns = get_columns(conn, bronze_table)
    if not columns:
        logger.warning(f"{view_name}: aucune colonne trouvee dans bronze.{bronze_table} -- ignoree")
        return 0

    clean_cols_sql = ", ".join([
        f"""NULLIF(NULLIF(TRIM("{c}"), ''), 'Error') AS "{c}" """ for c in columns
    ])

    cur = conn.cursor()
    cur.execute(f"""
        CREATE SCHEMA IF NOT EXISTS silver;
        DROP TABLE IF EXISTS silver.{silver_table};
        CREATE TABLE silver.{silver_table} AS
        SELECT {clean_cols_sql}, NOW() AS loaded_at
        FROM bronze.{bronze_table};
    """)
    conn.commit()

    cur.execute(f"SELECT COUNT(*) FROM silver.{silver_table};")
    count = cur.fetchone()[0]
    cur.close()

    logger.info(f"{view_name}: {count:,} lignes chargees dans silver.{silver_table}")
    return count


def main():
    conn     = get_db_connection()
    conn_log = get_db_connection()
    init_schemas(conn_log)
    init_run_log(conn_log)

    total = 0
    logger.info("=" * 50)
    logger.info(f"SILVER GREENO - chargement des {len(VLK_VIEWS)} vues vlk_")
    logger.info("=" * 50)

    for view in VLK_VIEWS:
        start = time.time()
        try:
            count = sync_vlk_view(conn, view)
            total += count
            log_run(
                conn=conn_log,
                source="greeno",
                entity=view,
                status="success",
                rows_count=count,
                minio_prefix=None,
                duration_sec=time.time() - start,
            )
        except Exception as e:
            logger.error(f"Erreur sur {view}: {e}")
            conn.rollback()
            log_run(
                conn=conn_log,
                source="greeno",
                entity=view,
                status="error",
                rows_count=0,
                error_message=str(e),
                duration_sec=time.time() - start,
            )

    conn.close()
    conn_log.close()

    logger.info("=" * 50)
    logger.info(f"TERMINE — {total:,} lignes au total")
    logger.info("=" * 50)


if __name__ == "__main__":
    main()