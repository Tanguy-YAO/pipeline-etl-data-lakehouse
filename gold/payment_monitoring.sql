-- gold/payment_monitoring.sql
-- Vue de monitoring mensuel des paiements UPYA + SURGE
-- Source : gold.unified_transactions
CREATE OR REPLACE VIEW gold.payment_monitoring AS
SELECT
    DATE_TRUNC('month', payment_date)::date     AS mois,
    source,
    normalized_reason                           AS payment_type,
    COUNT(*)                                    AS nb_transactions,
    COUNT(DISTINCT contract_number)             AS nb_contrats,
    SUM(amount)                                 AS total_xof,
    ROUND(SUM(amount) / 655.957, 0)             AS total_eur,
    MIN(payment_date)::date                     AS premiere_transaction,
    MAX(payment_date)::date                     AS derniere_transaction
FROM gold.unified_transactions
WHERE ignore_payment = false
GROUP BY
    DATE_TRUNC('month', payment_date)::date,
    source,
    normalized_reason
ORDER BY mois DESC, source, payment_type;