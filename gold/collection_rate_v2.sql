-- ============================================================
-- gold/collection_rate_v2.sql
-- Collection Rate v2 — Aligné définition EDF
-- Formule :
-- CR = (paid_upfront + paid_recharge + paid_cash_sales)
--      / (expected_upfront + expected_recharge + expected_cash_sales)
-- expected_recharge basé sur unlocked_until_history
-- ============================================================
CREATE OR REPLACE VIEW gold.collection_rate_v2 AS
WITH
monthly_dates AS (
    SELECT
        DATE_TRUNC('month', d)::date AS month_start,
        (DATE_TRUNC('month', d) + INTERVAL '1 month'
            - INTERVAL '1 day')::date AS month_end
    FROM generate_series('2025-09-01'::date, CURRENT_DATE, INTERVAL '1 month') d
),
-- ============================================================
-- CONTRATS ACTIFS PAR MOIS
-- ============================================================
monthly_contracts AS (
    SELECT DISTINCT ON (md.month_end, s.contract_number)
        md.month_start,
        md.month_end,
        s.contract_number,
        s.source,
        uc.registration_date::date                  AS start_date,
        uc.deal_type,
        uc.entite,
        uc.categorie,
        COALESCE(uc.monthly_payment, 0)             AS monthly_payment,
        COALESCE(uc.monthly_payment, 0) / 30.0      AS daily_rate,
        COALESCE(uc.upfront_payment, 0)             AS upfront_payment,
        COALESCE(s.consecutive_locked_days, 0)      AS cld
    FROM monthly_dates md
    JOIN gold.unified_snapshot s
        ON s.snapshot_date <= md.month_end
       AND s.snapshot_date >= md.month_start - INTERVAL '45 days'
       AND s.categorie IN ('upya_tevia', 'surge_tevia')
       AND (s.contract_status IS NULL
            OR s.contract_status NOT IN ('REPOSSESSED', 'CANCELLED'))
    JOIN gold.unified_contracts uc ON uc.contract_number = s.contract_number
    WHERE uc.registration_date IS NOT NULL
      AND uc.registration_date <= md.month_end
      AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')
      AND (uc.paid_off_date IS NULL OR uc.paid_off_date > md.month_end)
    ORDER BY md.month_end, s.contract_number, s.snapshot_date DESC
),
-- ============================================================
-- UNLOCKED_UNTIL PAR CONTRAT ET PAR MOIS
-- Dernier unlocked_until connu avant la fin du mois
-- ============================================================
unlocked_per_month AS (
    SELECT DISTINCT ON (md.month_end, h.contract_number)
        md.month_start,
        md.month_end,
        h.contract_number,
        h.unlocked_until
    FROM monthly_dates md
    JOIN gold.unlocked_until_history h
        ON h.transaction_date <= md.month_end
    ORDER BY md.month_end, h.contract_number, h.transaction_date DESC
),
-- ============================================================
-- EXPECTED PAR CONTRAT ET PAR MOIS
-- ============================================================
expected_per_contract AS (
    SELECT
        mc.month_start,
        mc.month_end,
        mc.contract_number,
        mc.deal_type,
        mc.start_date,
        mc.upfront_payment,
        mc.monthly_payment,
        mc.daily_rate,
        mc.cld,
        upm.unlocked_until,

        -- UPFRONT : attendu le mois du paiement (signing_date ≈ mois de la tx)
        -- On s'appuie sur le mois de registration_date comme proxy
        CASE
            WHEN mc.deal_type != 'FULL'
             AND DATE_TRUNC('month', mc.start_date) = mc.month_start
            THEN mc.upfront_payment
            ELSE 0
        END AS expected_upfront,

        -- CASH SALES : contrats FULL activés ce mois
        CASE
            WHEN mc.deal_type = 'FULL'
             AND DATE_TRUNC('month', mc.start_date) = mc.month_start
            THEN mc.monthly_payment
            ELSE 0
        END AS expected_cash_sales,

        -- RECHARGE : basée sur unlocked_until réel
        CASE
            -- Exclusions
            WHEN mc.cld > 60                                          THEN 0
            WHEN mc.deal_type = 'FULL'                                THEN 0
            -- Mois d'activation → pas de recharge attendue
            WHEN DATE_TRUNC('month', mc.start_date) = mc.month_start THEN 0
            -- Pas encore de paiement → recharge pleine attendue
            WHEN upm.unlocked_until IS NULL                           THEN mc.monthly_payment
            -- Kit couvert tout le mois → rien attendu
            WHEN upm.unlocked_until >= mc.month_end                   THEN 0
            -- Kit éteint avant le mois → recharge pleine
            WHEN upm.unlocked_until < mc.month_start
            THEN mc.monthly_payment
            -- Kit s'éteint dans le mois → prorata
            ELSE GREATEST(0, (mc.month_end - upm.unlocked_until)) * mc.daily_rate
        END AS expected_recharge

    FROM monthly_contracts mc
    LEFT JOIN unlocked_per_month upm
        ON upm.contract_number = mc.contract_number
       AND upm.month_end = mc.month_end
),
-- ============================================================
-- AGRÉGATION MENSUELLE EXPECTED
-- ============================================================
expected_monthly AS (
    SELECT
        month_start,
        SUM(expected_upfront)    AS expected_upfront,
        SUM(expected_recharge)   AS expected_recharge,
        SUM(expected_cash_sales) AS expected_cash_sales
    FROM expected_per_contract
    GROUP BY month_start
),
-- ============================================================
-- PAIEMENTS UPYA
-- ============================================================
upya_paid AS (
    SELECT
        DATE_TRUNC('month', p.payment_date)::date AS month_start,
        SUM(p.amount) FILTER (
            WHERE p.payment_code IN ('DOWNPAYMENT_SUCCESS','INCOMPLETE_DOWNPAYMENT')
        )              AS paid_upfront,
        SUM(p.amount) FILTER (
            WHERE p.payment_code IN ('PAYMENT_SUCCESS','INCOMPLETE_PAYMENT','FINAL_PAYMENT')
        )              AS paid_recharge,
        0::numeric     AS paid_cash_sales
    FROM silver.upya_payments p
    JOIN gold.unified_contracts uc ON uc.contract_number = p.contract_number
    WHERE p.status = 'ACCEPTED'
      AND p.payment_code IS NOT NULL
      AND p.payment_code NOT IN ('REVERSED','SURVEY_SUCCESS')
      AND uc.categorie IN ('upya_tevia','surge_tevia')
      AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')
    GROUP BY 1
),
-- ============================================================
-- PAIEMENTS SURGE
-- ============================================================
surge_paid AS (
    SELECT
        DATE_TRUNC('month', p.paid_time)::date AS month_start,
        0::numeric     AS paid_upfront,
        SUM(p.amount)  AS paid_recharge,
        0::numeric     AS paid_cash_sales
    FROM silver.surge_payments p
    JOIN silver.surge_asset_mapping m ON m.asset_number = p.account
    JOIN gold.unified_contracts uc ON uc.contract_number = m.installation_id::TEXT
    WHERE p.payment_status != 'REVERSED'
      AND uc.categorie = 'surge_tevia'
      AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')
    GROUP BY 1
),
-- ============================================================
-- PAIEMENTS CASH SALES
-- ============================================================
cash_paid AS (
    SELECT
        DATE_TRUNC('month', p.payment_date)::date AS month_start,
        0::numeric     AS paid_upfront,
        0::numeric     AS paid_recharge,
        SUM(p.amount)  AS paid_cash_sales
    FROM silver.upya_payments p
    JOIN gold.unified_contracts uc ON uc.contract_number = p.contract_number
    WHERE p.status = 'ACCEPTED'
      AND uc.deal_type = 'FULL'
      AND uc.categorie IN ('upya_tevia','surge_tevia')
      AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')
    GROUP BY 1
),
-- ============================================================
-- AGRÉGATION MENSUELLE PAIEMENTS
-- ============================================================
paid_monthly AS (
    SELECT
        month_start,
        SUM(paid_upfront)     AS paid_upfront,
        SUM(paid_recharge)    AS paid_recharge,
        SUM(paid_cash_sales)  AS paid_cash_sales
    FROM (
        SELECT * FROM upya_paid
        UNION ALL
        SELECT * FROM surge_paid
        UNION ALL
        SELECT * FROM cash_paid
    ) t
    GROUP BY month_start
)
-- ============================================================
-- SELECT FINAL
-- ============================================================
SELECT
    md.month_start,
    md.month_end,
    TO_CHAR(md.month_start, 'YYYY-MM')              AS month_year,
    ROUND(COALESCE(p.paid_upfront,      0), 0)      AS paid_upfront_fcfa,
    ROUND(COALESCE(p.paid_recharge,     0), 0)      AS paid_recharge_fcfa,
    ROUND(COALESCE(p.paid_cash_sales,   0), 0)      AS paid_cash_sales_fcfa,
    ROUND(
        COALESCE(p.paid_upfront,    0) +
        COALESCE(p.paid_recharge,   0) +
        COALESCE(p.paid_cash_sales, 0), 0
    )                                               AS paid_total_fcfa,
    ROUND(COALESCE(e.expected_upfront,     0), 0)   AS expected_upfront_fcfa,
    ROUND(COALESCE(e.expected_recharge,    0), 0)   AS expected_recharge_fcfa,
    ROUND(COALESCE(e.expected_cash_sales,  0), 0)   AS expected_cash_sales_fcfa,
    ROUND(
        COALESCE(e.expected_upfront,    0) +
        COALESCE(e.expected_recharge,   0) +
        COALESCE(e.expected_cash_sales, 0), 0
    )                                               AS expected_total_fcfa,
    ROUND(
        100.0 * (
            COALESCE(p.paid_upfront,    0) +
            COALESCE(p.paid_recharge,   0) +
            COALESCE(p.paid_cash_sales, 0)
        ) / NULLIF(
            COALESCE(e.expected_upfront,    0) +
            COALESCE(e.expected_recharge,   0) +
            COALESCE(e.expected_cash_sales, 0),
        0), 2
    )                                               AS collection_rate_pct
FROM monthly_dates md
LEFT JOIN paid_monthly     p ON p.month_start = md.month_start
LEFT JOIN expected_monthly e ON e.month_start = md.month_start
ORDER BY md.month_start DESC;
