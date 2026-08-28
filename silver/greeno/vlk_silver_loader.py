# silver/greeno/vlk_silver_loader.py
#
# Loader générique pour les 18 vues vlk_ GREENO : lit chaque table
# bronze.greeno_vlk_* (créée par bronze/greeno/vlk_views_extractor.py)

# APPROCHE : les colonnes sont découvertes dynamiquement via
# information_schema plutot car on ne connait pas encore
# le détail exact des 18 vues, et cette approche s'adapte automatiquement
# si GREENO modifie une vue cote source. Je verrai avec Lucien si des modifications fréquentes sont à prévoir, auquel cas on pourra passer à une approche plus statique (liste de colonnes codée en dur).
#
# NETTOYAGE APPLIQUE (toutes tables) :
#   - Chaine vide -> NULL
#   - Espaces en debut/fin retires (TRIM)
#   - Valeur littérale "Error" -> NULL (anomalie connue sur lib_localite,
#     potentiellement présente ailleurs)
#
# LIMITE CONNUE : id_prospect_appsheet (vlk_prospect_tlc) est stocke comme
# texte de representation Python d'une liste (ex: "['b1e1c8e4']"), pas
# comme un vrai tableau SQL -- laisse tel quel pour l'instant, a traiter
# specifiquement si besoin d'exploiter cette colonne.

import os
import logging
import psycopg2
from dotenv import load_dotenv

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


def get_conn():
    return psycopg2.connect(
        host=os.getenv("DB_HOST"), port=int(os.getenv("DB_PORT") or 5432),
        dbname=os.getenv("DB_NAME"), user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"), sslmode="require", connect_timeout=60
    )


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

    cols_sql = ", ".join([f'"{c}"' for c in columns])
    # Nettoyage universel : chaine vide -> NULL, "Error" litteral -> NULL,
    # espaces en trop retires
    clean_cols_sql = ", ".join([
        f"""NULLIF(NULLIF(TRIM("{c}"), ''), 'Error') AS "{c}\"""" for c in columns
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
    conn = get_conn()
    total = 0
    logger.info("=" * 50)
    logger.info(f"SILVER GREENO - chargement des {len(VLK_VIEWS)} vues vlk_")
    logger.info("=" * 50)

    for view in VLK_VIEWS:
        try:
            total += sync_vlk_view(conn, view)
        except Exception as e:
            logger.error(f"Erreur sur {view}: {e}")
            conn.rollback()

    conn.close()
    logger.info("=" * 50)
    logger.info(f"TERMINE — {total:,} lignes au total")
    logger.info("=" * 50)


if __name__ == "__main__":
    main()