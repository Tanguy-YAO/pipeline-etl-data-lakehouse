import os
import psycopg2
from dotenv import load_dotenv

load_dotenv()

GREENO_DB_HOST = os.getenv("GREENO_DB_HOST")
GREENO_DB_PORT = int(os.getenv("GREENO_DB_PORT") or 5432)
GREENO_DB_NAME = os.getenv("GREENO_DB_NAME")
GREENO_DB_USERNAME = os.getenv("GREENO_DB_USERNAME")
GREENO_DB_PASSWORD = os.getenv("GREENO_DB_PASSWORD")

try:
    conn = psycopg2.connect(
        host=GREENO_DB_HOST,
        port=GREENO_DB_PORT,
        dbname=GREENO_DB_NAME,
        user=GREENO_DB_USERNAME,
        password=GREENO_DB_PASSWORD,
        sslmode="require",
        connect_timeout=15
    )
    print("Connexion reussie !")

    cur = conn.cursor()
    cur.execute("""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public'
        ORDER BY table_name;
    """)
    tables = cur.fetchall()
    print(f"\n{len(tables)} table(s) trouvee(s) :")
    for t in tables:
        print(f"  - {t[0]}")

    # -- NOUVEAU BLOC : exploration des vues vlk_ --
    vlk_views = [
        "vlk_cds2_tlc", "vlk_commerciaux_vendeur_tlc", "vlk_credit_scoring_avec_date_deposit",
        "vlk_deposit_agent_tlc", "vlk_eligibilite_cds2_tlc", "vlk_installation_annee_en_cours",
        "vlk_installation_tlc", "vlk_installation_v2_tlc", "vlk_kyc_tlc",
        "vlk_ponderation_commerciaux", "vlk_preparation_installation", "vlk_prospect_tlc",
        "vlk_sav_req_fermees", "vlk_sav_req_ouvertes", "vlk_sites_evalues_tlc",
        "vlk_spatial_client_installe", "vlk_suivi_client_tlc", "vlk_sup_vente"
    ]

    for view in vlk_views:
        print(f"\n--- {view} ---")
        cur.execute(f'SELECT COUNT(*) FROM "{view}";')
        print(f"Lignes : {cur.fetchone()[0]}")

        cur.execute("""
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE table_name = %s
            ORDER BY ordinal_position;
        """, (view,))
        cols = cur.fetchall()
        print("Colonnes :", ", ".join([f"{c[0]} ({c[1]})" for c in cols]))
    # -- FIN DU NOUVEAU BLOC --

    cur.close()
    conn.close()

except Exception as e:
    print(f"Erreur de connexion : {e}")