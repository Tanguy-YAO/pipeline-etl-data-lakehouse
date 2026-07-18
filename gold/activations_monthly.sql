-- ============================================================
-- gold/activations_monthly.sql
-- Activations par mois, entite, source, categorie, produit
-- registration_date = deploy_date (event DEPLOYED)
-- ============================================================
CREATE OR REPLACE VIEW gold.activations_monthly AS
SELECT
    DATE_TRUNC('month', uc.registration_date)::date AS mois,
    uc.entite, uc.source, uc.categorie, uc.product_name,
    COUNT(*) AS nb_activations,
    ROUND(SUM(uc.total_contract_value) / 655.957, 0) AS valeur_eur,
    ROUND(AVG(uc.monthly_payment), 0) AS mensualite_moyenne,
    ROUND(AVG(uc.upfront_payment), 0) AS upfront_moyen
FROM gold.unified_contracts uc
WHERE uc.registration_date IS NOT NULL
  AND uc.registration_date >= '2024-01-01'
  AND uc.contract_status != 'CANCELLED'
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC, 2, 4;
