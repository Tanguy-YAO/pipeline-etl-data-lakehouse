# gold/tevia_sales_dashboard_base_builder.py
#
# Table dediee au dashboard "TEVIA Field Sales" -- reconstruite periodiquement
# pour eviter que les ~15 cartes Metabase interrogent directement
# gold.unified_contracts (vue couteuse, ~7-9s par appel). Centralise aussi
# la normalisation region (4 copies divergentes trouvees dans les cartes
# existantes) et la jointure RSS/DSM (migree de public.upya_locations vers
# silver.upya_locations, cf. correctif du 27/08/2026).
#
# PERIMETRE ROLE (RSS/DSM/FSA-FSR) : UPYA uniquement, de facon assumee --
# aucune donnee "surge_users" n'est integree au pipeline, donc la structure
# organisationnelle commerciale par role ne peut couvrir que UPYA. Le flag
# has_upya_role_data permet aux cartes de l'onglet role de le signaler
# explicitement plutot que de le cacher silencieusement.

import os
import logging
import psycopg2
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)
load_dotenv()

def get_conn():
    return psycopg2.connect(
        host=os.getenv("DB_HOST"), port=int(os.getenv("DB_PORT") or 5432),
        dbname=os.getenv("DB_NAME"), user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"), sslmode="require", connect_timeout=60
    )

# Normalisation region -- version consolidee, reprise a l'identique des
# cartes existantes (doc 28/29/30, qui etaient deja coherentes entre elles).
REGION_NORM_CASE = """
    CASE
        WHEN LOWER(TRIM(uc.region)) LIKE '%cavall%' OR LOWER(TRIM(uc.region)) LIKE '%cavaly%' THEN 'CAVALLY'
        WHEN LOWER(TRIM(uc.region)) LIKE '%nawa%' THEN 'NAWA'
        WHEN LOWER(TRIM(uc.region)) LIKE '%haut-sassandra%' THEN 'HAUT-SASSANDRA'
        WHEN LOWER(TRIM(uc.region)) LIKE '%san-pedro%' OR LOWER(TRIM(uc.region)) LIKE '%san pedro%' THEN 'SAN PEDRO'
        WHEN LOWER(TRIM(uc.region)) LIKE '%gôh%' OR LOWER(TRIM(uc.region)) LIKE '%goh%' THEN 'GOH'
        WHEN LOWER(TRIM(uc.region)) LIKE '%lôh-djiboua%' OR LOWER(TRIM(uc.region)) LIKE '%loh-djiboua%' THEN 'LOH-DJIBOUA'
        WHEN LOWER(TRIM(uc.region)) LIKE '%sud-comoe%' OR LOWER(TRIM(uc.region)) LIKE '%sud-comoé%' THEN 'SUD-COMOE'
        WHEN LOWER(TRIM(uc.region)) LIKE '%guemon%' THEN 'GUEMON'
        WHEN LOWER(TRIM(uc.region)) LIKE '%marahoue%' OR LOWER(TRIM(uc.region)) LIKE '%marahoué%' THEN 'MARAHOUE'
        WHEN LOWER(TRIM(uc.region)) LIKE '%agneby%' THEN 'AGNEBY-TIASSA'
        WHEN LOWER(TRIM(uc.region)) LIKE '%grands ponts%' THEN 'GRANDS PONTS'
        WHEN LOWER(TRIM(uc.region)) LIKE '%tonkpi%' THEN 'TONKPI'
        WHEN LOWER(TRIM(uc.region)) LIKE '%bere%' OR LOWER(TRIM(uc.region)) LIKE '%béré%' THEN 'BERE'
        WHEN LOWER(TRIM(uc.region)) LIKE '%gbokle%' OR LOWER(TRIM(uc.region)) LIKE '%gbôkle%' THEN 'GBOKLE'
        WHEN LOWER(TRIM(uc.region)) LIKE '%worodougou%' THEN 'WORODOUGOU'
        WHEN LOWER(TRIM(uc.region)) LIKE '%tchologo%' THEN 'TCHOLOGO'
        WHEN LOWER(TRIM(uc.region)) LIKE '%la me%' OR LOWER(TRIM(uc.region)) LIKE '%la mé%' OR LOWER(TRIM(uc.region)) = 'me' THEN 'LA ME'
        WHEN LOWER(TRIM(uc.region)) LIKE '%indenie%' OR LOWER(TRIM(uc.region)) LIKE '%indénie%' THEN 'INDENIE-DJUABLIN'
        WHEN LOWER(TRIM(uc.region)) LIKE '%bafing%' THEN 'BAFING'
        WHEN LOWER(TRIM(uc.region)) LIKE '%gontougo%' THEN 'GONTOUGO'
        WHEN LOWER(TRIM(uc.region)) LIKE '%poro%' THEN 'PORO'
        WHEN LOWER(TRIM(uc.region)) LIKE '%des lacs%' THEN 'LACS'
        WHEN LOWER(TRIM(uc.region)) LIKE '%belier%' OR LOWER(TRIM(uc.region)) LIKE '%bélier%' THEN 'BELIER'
        WHEN LOWER(TRIM(uc.region)) LIKE '%iffou%' THEN 'IFFOU'
        WHEN LOWER(TRIM(uc.region)) LIKE '%moronou%' THEN 'MORONOU'
        WHEN LOWER(TRIM(uc.region)) LIKE '%gbeke%' OR LOWER(TRIM(uc.region)) LIKE '%gbêkê%' THEN 'GBEKE'
        WHEN LOWER(TRIM(uc.region)) LIKE '%hambol%' THEN 'HAMBOL'
        WHEN LOWER(TRIM(uc.region)) LIKE '%des lagunes%' THEN 'LAGUNES'
        WHEN LOWER(TRIM(uc.region)) LIKE '%bounkani%' THEN 'BOUNKANI'
        WHEN LOWER(TRIM(uc.region)) LIKE '%n''zi%' OR LOWER(TRIM(uc.region)) LIKE '%nzi%' THEN 'N''ZI'
        WHEN LOWER(TRIM(uc.region)) LIKE '%kabadougou%' THEN 'KABADOUGOU'
        WHEN LOWER(TRIM(uc.region)) LIKE '%bagoue%' OR LOWER(TRIM(uc.region)) LIKE '%baghoué%' THEN 'BAGOUE'
        WHEN LOWER(TRIM(uc.region)) LIKE '%district%yamoussoukro%' THEN 'DISTRICT AUTONOME DE YAMOUSSOUKRO'
        WHEN LOWER(TRIM(uc.region)) LIKE '%district%abidjan%' THEN 'DISTRICT AUTONOME D''ABIDJAN'
        WHEN uc.region IS NOT NULL THEN UPPER(TRIM(uc.region))
        ELSE 'NON DEFINI'
    END
"""

DEAL_FAMILY_CASE = """
    CASE
        WHEN LOWER(uc.product_name) LIKE '%tevia smart%'       THEN 'TEVIA SMART'
        WHEN LOWER(uc.product_name) LIKE '%tevia prestige%'    THEN 'TEVIA PRESTIGE'
        WHEN LOWER(uc.product_name) LIKE '%tevia classic%'     THEN 'TEVIA CLASSIC'
        WHEN LOWER(uc.product_name) LIKE '%tevia eco confort%' THEN 'TEVIA ECO CONFORT'
        WHEN LOWER(uc.product_name) LIKE '%tevia eco%'         THEN 'TEVIA ECO'
        WHEN LOWER(uc.product_name) LIKE '%tevia deluxe%'      THEN 'TEVIA DELUXE'
        WHEN LOWER(uc.product_name) LIKE '%tevia home 32%'     THEN 'TEVIA HOME 32'
        WHEN LOWER(uc.product_name) LIKE '%tevia home 24%'     THEN 'TEVIA HOME 24'
        WHEN LOWER(uc.product_name) LIKE '%tevia extra%'       THEN 'TEVIA EXTRA'
        WHEN LOWER(uc.product_name) LIKE '%tevia aurea%'       THEN 'TEVIA AUREA'
        WHEN LOWER(uc.product_name) LIKE '%tevia optima%'      THEN 'TEVIA OPTIMA'
        WHEN LOWER(uc.product_name) LIKE '%tevia%'             THEN 'TEVIA AUTRES'
        WHEN LOWER(uc.product_name) LIKE '%flex plus 22%'      THEN 'ZOLA FLEX 22'
        WHEN LOWER(uc.product_name) LIKE '%flex 22%'           THEN 'ZOLA FLEX 22'
        WHEN LOWER(uc.product_name) LIKE '%flex plus 24%'      THEN 'ZOLA FLEX 24'
        WHEN LOWER(uc.product_name) LIKE '%flex plus 32%'      THEN 'ZOLA FLEX 32'
        WHEN LOWER(uc.product_name) LIKE '%flex 19%'           THEN 'ZOLA FLEX 19'
        WHEN LOWER(uc.product_name) LIKE '%flex light%'        THEN 'ZOLA FLEX LIGHTS'
        WHEN LOWER(uc.product_name) LIKE '%flex kit%'          THEN 'ZOLA FLEX KIT'
        WHEN LOWER(uc.product_name) LIKE '%zola%'              THEN 'ZOLA AUTRES'
        WHEN uc.product_name IS NOT NULL THEN
            TRIM(REGEXP_REPLACE(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(uc.product_name,
                        '\\s+(Lease|Buy Now)(\\s*\\(PROMO\\))?\\s*$', '', 'i'),
                    '\\s+[0-9]+$', '', 'i'),
                '\\s+(JUA|MUA|PROMO|promo)\\s*$', '', 'i'))
        ELSE 'NON DEFINI'
    END
"""

AGENT_ROLE_CASE = """
    CASE
        WHEN uc.agent_name ILIKE '%FSA%'        THEN 'FSA'
        WHEN uc.agent_name ILIKE '%FSR%'        THEN 'FSR'
        WHEN uc.agent_name ILIKE '%DSM%'        THEN 'DSM'
        WHEN uc.agent_name ILIKE '%RSS%'        THEN 'RSS'
        WHEN uc.agent_name ILIKE '%Shop point%' THEN 'Shop Point'
        ELSE 'Autres'
    END
"""

BUILD_SQL = f"""
CREATE SCHEMA IF NOT EXISTS gold;
DROP TABLE IF EXISTS gold.tevia_sales_dashboard_base;

CREATE TABLE gold.tevia_sales_dashboard_base AS

WITH locations_dedup AS (
    SELECT DISTINCT ON (
        UPPER(TRANSLATE(TRIM(sous_prefecture),
            'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇŸàâäéèêëîïôöùûüçÿ',
            'AAAEEEEIIOOUUUCYaaaeeeeiioouuucy'))
    )
        UPPER(TRANSLATE(TRIM(sous_prefecture),
            'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇŸàâäéèêëîïôöùûüçÿ',
            'AAAEEEEIIOOUUUCYaaaeeeeiioouuucy')) AS sp_norm,
        rss, dsm
    FROM silver.upya_locations
    WHERE rss IS NOT NULL
)

SELECT
    uc.contract_number,
    uc.entite,
    uc.categorie,
    uc.paid_date::date          AS paid_date,
    uc.registration_date::date  AS registration_date,
    {REGION_NORM_CASE} AS region_norm,
    COALESCE(
        spm.canonical_value,
        INITCAP(TRIM(REGEXP_REPLACE(uc.sub_prefecture, '^[Ss][Pp]\\s*', '', 'i')))
    ) AS sub_prefecture,
    uc.product_name,
    {DEAL_FAMILY_CASE} AS deal_family,
    uc.deal_type,
    TRIM(uc.agent_name)         AS agent_name,
    {AGENT_ROLE_CASE} AS agent_role,
    ld.rss,
    ld.dsm,
    (uc.categorie = 'upya_tevia') AS has_upya_role_data,
    sc.onboarding_status,
    (
        LOWER(uc.customer_name) LIKE '%test%'
        OR uc.contract_number IN ('374477057', '295943315', '251745061')
        OR uc.agent_name = 'Agent UPYA'
    ) AS is_test_or_excluded
FROM gold.unified_contracts uc
LEFT JOIN silver.upya_contracts sc ON sc.contract_number = uc.contract_number
LEFT JOIN silver.sub_prefecture_mapping spm
    ON spm.raw_value_normalized = LOWER(REPLACE(
        TRIM(REGEXP_REPLACE(uc.sub_prefecture, '^[Ss][Pp]\\s*', '', 'i')), '-', ' '
    ))
LEFT JOIN locations_dedup ld
    ON ld.sp_norm = UPPER(TRANSLATE(
        TRIM(REGEXP_REPLACE(uc.sub_prefecture, '^[Ss][Pp]\\s*', '', 'i')),
        'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇŸàâäéèêëîïôöùûüçÿ',
        'AAAEEEEIIOOUUUCYaaaeeeeiioouuucy'
    ))
WHERE uc.entite = 'TEVIA'
  AND uc.categorie IN ('upya_tevia', 'surge_tevia');

CREATE INDEX idx_tsdb_paid_date ON gold.tevia_sales_dashboard_base(paid_date);
CREATE INDEX idx_tsdb_reg_date ON gold.tevia_sales_dashboard_base(registration_date);
CREATE INDEX idx_tsdb_region ON gold.tevia_sales_dashboard_base(region_norm);
CREATE INDEX idx_tsdb_agent ON gold.tevia_sales_dashboard_base(agent_name);
CREATE INDEX idx_tsdb_categorie ON gold.tevia_sales_dashboard_base(categorie);
"""

def build():
    conn = get_conn()
    cur = conn.cursor()
    logger.info("Construction de gold.tevia_sales_dashboard_base...")
    cur.execute(BUILD_SQL)
    conn.commit()
    cur.execute("SELECT COUNT(*), COUNT(*) FILTER (WHERE NOT is_test_or_excluded) FROM gold.tevia_sales_dashboard_base;")
    total, valides = cur.fetchone()
    logger.info(f"Termine : {total:,} lignes ({valides:,} hors test/exclusions)")
    cur.close()
    conn.close()

if __name__ == "__main__":
    build()