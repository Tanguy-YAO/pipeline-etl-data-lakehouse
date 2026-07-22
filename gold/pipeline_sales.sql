-- ============================================================
-- gold/pipeline_sales.sql
-- Ventes en attente d'installation (signed mais pas déployé)
-- ============================================================
CREATE OR REPLACE VIEW gold.pipeline_sales AS
SELECT
    uc.contract_number,
    uc.customer_name,
    uc.entite,
    uc.categorie,
    uc.agent_name,
    uc.region,
    uc.sub_prefecture,
    uc.product_name,
    uc.paid_date::date                          AS date_vente,
    uc.registration_date::date                  AS date_installation,
    CURRENT_DATE - uc.paid_date::date           AS jours_attente,
    uc.total_contract_value,
    uc.upfront_payment,
    uc.contract_status
FROM gold.unified_contracts uc
WHERE uc.categorie IN ('upya_tevia', 'surge_tevia')
  AND uc.paid_date IS NOT NULL
  AND uc.registration_date IS NULL
  AND uc.contract_status != 'CANCELLED'
ORDER BY uc.paid_date DESC;
