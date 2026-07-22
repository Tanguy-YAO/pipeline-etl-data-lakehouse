-- gold/portfolio_summary.sql
-- KPIs clés du portefeuille TEVIA — vue quotidienne
CREATE OR REPLACE VIEW gold.portfolio_summary AS
SELECT
    CURRENT_DATE AS report_date,
    COUNT(*) FILTER (WHERE uc.contract_status = 'ENABLED' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia') AND COALESCE(uc.consecutive_locked_days, 0) <= 120) AS nb_contrats_actifs,
    COUNT(*) FILTER (WHERE uc.contract_status = 'LOCKED' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_contrats_locked,
    COUNT(*) FILTER (WHERE uc.contract_status = 'REPOSSESSED' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_repossedes,
    COUNT(*) FILTER (WHERE uc.paid_off = 'true' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_paidoff,
    ROUND(SUM(uc.total_contract_value) FILTER (WHERE uc.contract_status = 'ENABLED' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia') AND COALESCE(uc.consecutive_locked_days, 0) <= 120) / 655.957, 0) AS valeur_portefeuille_eur,
    ROUND(SUM(uc.remaining_debt) FILTER (WHERE uc.contract_status = 'ENABLED' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia') AND COALESCE(uc.consecutive_locked_days, 0) <= 120) / 655.957, 0) AS receivables_eur,
    ROUND(SUM(uc.total_paid) FILTER (WHERE (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) / 655.957, 0) AS total_collected_eur,
    ROUND(AVG(pvp.pvp_linearized) FILTER (WHERE pvp.pvp_linearized < 2 AND pvp.days_on_books > 0 AND pvp.categorie IN ('upya_tevia', 'surge_tevia')), 4) AS pvp_moyen,
    COUNT(*) FILTER (WHERE uc.consecutive_locked_days = 0 AND uc.contract_status = 'ENABLED' AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_cld_0,
    COUNT(*) FILTER (WHERE uc.consecutive_locked_days BETWEEN 1 AND 30 AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_par_1_30j,
    COUNT(*) FILTER (WHERE uc.consecutive_locked_days BETWEEN 31 AND 60 AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_par_31_60j,
    COUNT(*) FILTER (WHERE uc.consecutive_locked_days BETWEEN 61 AND 90 AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_par_61_90j,
    COUNT(*) FILTER (WHERE uc.consecutive_locked_days BETWEEN 91 AND 120 AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_par_91_120j,
    COUNT(*) FILTER (WHERE uc.consecutive_locked_days > 120 AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')) AS nb_writeoff
FROM gold.unified_contracts uc
LEFT JOIN gold.pvp_linearized pvp ON pvp.contract_number = uc.contract_number;