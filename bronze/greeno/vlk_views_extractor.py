# bronze/greeno/vlk_views_extractor.py
#
# Extraction Bronze des 18 vues vlk_ de la base GREENO (Cloud SQL).
# Rechargement complet a chaque execution (TRUNCATE + reload) : ces vues
# n'exposent aucune colonne de date de modification fiable, un chargement
# incremental par watermark n'est donc pas possible ici (contrairement a
# UPYA/SURGE). Les volumes mesures (max ~25 000 lignes/vue) rendent ce
# rechargement complet tout a fait tenable a chaque cycle.
#
# CONNEXION : psycopg2 classique par IP statique Railway (validee le
# 27/08/2026, cf. service greeno_db_runner) -- destine a terme a basculer
# sur cloud-sql-python-connector (IAM) une fois le compte de service
# finalise avec Herve, pour ne plus dependre d'aucune IP.

import os
import sys
import logging
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from database.db_client import get_db_connection, init_schemas

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


def get_greeno_conn():
    return psycopg2.connect(
        host=os.getenv("GREENO_DB_HOST"),
        port=int(os.getenv("GREENO_DB_PORT") or 5432),
        dbname=os.getenv("GREENO_DB_NAME"),
        user=os.getenv("GREENO_DB_USERNAME"),
        password=os.getenv("GREENO_DB_PASSWORD"),
        sslmode="require", connect_timeout=30
    )


def sync_view(src_conn, tgt_conn, view_name):
    src_cur = src_conn.cursor()
    tgt_cur = tgt_conn.cursor()
    target_table = f"bronze.greeno_{view_name}"

    # Colonnes + types, pour recréer une table Bronze fidèle à la vue source.
    # Tout en TEXT par prudence : c'est une source externe non maitrisée,
    # un futur changement de type côté GREENO ne doit pas casser l'insertion.
    src_cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = %s ORDER BY ordinal_position;
    """, (view_name,))
    columns = [r[0] for r in src_cur.fetchall()]

    if not columns:
        logger.warning(f"{view_name}: aucune colonne trouvee, vue introuvable ou vide -- ignoree")
        src_cur.close()
        tgt_cur.close()
        return 0

    col_defs = ", ".join([f'"{c}" TEXT' for c in columns])
    tgt_cur.execute(f"""
        CREATE SCHEMA IF NOT EXISTS bronze;
        DROP TABLE IF EXISTS {target_table};
        CREATE TABLE {target_table} (
            {col_defs},
            extracted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
    """)
    tgt_conn.commit()

    cols_sql = ", ".join([f'"{c}"' for c in columns])
    src_cur.execute(f'SELECT {cols_sql} FROM "{view_name}";')
    rows = src_cur.fetchall()

    if rows:
        insert_sql = f"INSERT INTO {target_table} ({cols_sql}) VALUES %s"
        # Cast explicite en texte pour eviter les erreurs de type sur les
        # colonnes ARRAY (vu : id_prospect_appsheet) ou autres types
        # non-standards rencontrés lors de l'exploration.
        safe_rows = [tuple(str(v) if v is not None else None for v in row) for row in rows]
        execute_values(tgt_cur, insert_sql, safe_rows, page_size=500)
        tgt_conn.commit()

    logger.info(f"{view_name}: {len(rows):,} lignes chargees dans {target_table}")
    src_cur.close()
    tgt_cur.close()
    return len(rows)


def main():
    src_conn = get_greeno_conn()
    tgt_conn = get_db_connection()
    init_schemas(tgt_conn)

    total_lignes = 0
    total_erreurs = 0

    logger.info("=" * 50)
    logger.info(f"BRONZE GREENO — extraction des {len(VLK_VIEWS)} vues vlk_")
    logger.info("=" * 50)

    for view in VLK_VIEWS:
        try:
            n = sync_view(src_conn, tgt_conn, view)
            total_lignes += n
        except Exception as e:
            total_erreurs += 1
            logger.error(f"Erreur sur {view}: {e}")
            tgt_conn.rollback()

    src_conn.close()
    tgt_conn.close()

    logger.info("=" * 50)
    logger.info(f"TERMINE — {total_lignes:,} lignes au total, {total_erreurs} erreur(s)")
    logger.info("=" * 50)


if __name__ == "__main__":
    main()