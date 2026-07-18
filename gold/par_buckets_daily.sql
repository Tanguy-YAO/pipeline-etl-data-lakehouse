-- ============================================================
-- gold/par_buckets_daily.sql
-- Aging PAR par bucket, entite, source, categorie
-- ============================================================
CREATE OR REPLACE VIEW gold.par_buckets_daily AS
SELECT
    CURRENT_DATE AS report_date,
    uc.entite, uc.source, uc.categorie,
    CASE
        WHEN uc.contract_status = 'REPOSSESSED' THEN 'repossessed'
        WHEN uc.paid_off = 'true' THEN 'paidoff'
        WHEN COALESCE(uc.consecutive_locked_days,0) > 120 THEN 'writeoff'
        WHEN COALESCE(uc.consecutive_locked_days,0) = 0 THEN '0. pas_retard'
        WHEN uc.consecutive_locked_days BETWEEN 1 AND 30 THEN '1. PAR_1_30j'
        WHEN uc.consecutive_locked_days BETWEEN 31 AND 60 THEN '2. PAR_31_60j'
        WHEN uc.consecutive_locked_days BETWEEN 61 AND 90 THEN '3. PAR_61_90j'
        WHEN uc.consecutive_locked_days BETWEEN 91 AND 120 THEN '4. PAR_91_120j'
        ELSE 'autre'
    END AS par_bucket,
    COUNT(*) AS nb_contrats,
    ROUND(SUM(uc.total_contract_value) / 655.957, 0) AS valeur_eur,
    ROUND(SUM(uc.remaining_debt) / 655.957, 0) AS receivables_eur,
    ROUND(AVG(uc.consecutive_locked_days), 1) AS cld_moyen
FROM gold.unified_contracts uc
WHERE uc.contract_status NOT IN ('CANCELLED')
GROUP BY 1, 2, 3, 4, 5
ORDER BY 2, 3, 5;
