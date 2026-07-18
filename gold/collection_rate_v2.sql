-- gold/collection_rate_v2.sql
-- Collection Rate v2 — Aligné définition EDF
-- Formule :
-- CR = (paid_upfront + paid_recharge + paid_cash_sales)
--      / (expected_upfront + expected_recharge + expected_cash_sales)
-- expected_recharge = monthly_payment fixe (confirmé EDF)
-- Seuil exclusion : CLD > 120j (write-off)
CREATE OR REPLACE VIEW gold.collection_rate_v2 AS
WITH
monthly_dates AS (
    SELECT
        DATE_TRUNC('month', d)::date AS month_start,
        (DATE_TRUNC('month', d) + INTERVAL '1 month'
            - INTERVAL '1 day')::date AS month_end
    FROM generate_series('2025-09-01'::date, CURRENT_DATE, INTERVAL '1 month') d
),
monthly_contracts AS (
    SELECT DISTINCT ON (md.month_end, s.contract_number)
        md.month_start,
        md.month_end,
        s.contract_number,
        s.source,
        uc.registration_date::date             AS start_date,
        uc.deal_type,
        uc.entite,
        uc.categorie,
        COALESCE(uc.monthly_payment, 0)        AS monthly_payment,
        COALESCE(uc.monthly_payment, 0) / 30.0 AS daily_rate,
        COALESCE(uc.upfront_payment, 0)        AS upfront_payment,
        COALESCE(s.consecutive_locked_days, 0) AS cld
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
      AND COALESCE(s.consecutive_locked_days, 0) <= 120
    ORDER BY md.month_end, s.contract_number, s.snapshot_date DESC
),
expected_per_contract AS (
    SELECT
        mc.month_start,
        mc.month_end,
        mc.contract_number,
        mc.deal_type,
        mc.start_date,
        mc.upfront_payment,
        mc.monthly_payment,
        mc.cld,
        CASE
            WHEN mc.deal_type != 'FULL'
             AND DATE_TRUNC('month', mc.start_date) = mc.month_start
            THEN mc.upfront_payment
            ELSE 0
        END AS expected_upfront,
        CASE
            WHEN mc.deal_type = 'FULL'
             AND DATE_TRUNC('month', mc.start_date) = mc.month_start
            THEN mc.monthly_payment
            ELSE 0
        END AS expected_cash_sales,
        CASE
            WHEN mc.cld > 120                                         THEN 0
            WHEN mc.deal_type = 'FULL'                                THEN 0
            WHEN DATE_TRUNC('month', mc.start_date) = mc.month_start THEN 0
            ELSE mc.monthly_payment
        END AS expected_recharge
    FROM monthly_contracts mc
),
expected_monthly AS (
    SELECT
        month_start,
        SUM(expected_upfront)    AS expected_upfront,
        SUM(expected_recharge)   AS expected_recharge,
        SUM(expected_cash_sales) AS expected_cash_sales
    FROM expected_per_contract
    GROUP BY month_start
),
upya_paid AS (
    SELECT
        DATE_TRUNC('month', p.payment_date)::date AS month_start,
        SUM(p.amount) FILTER (
            WHERE p.payment_code IN ('DOWNPAYMENT_SUCCESS','INCOMPLETE_DOWNPAYMENT')
        )          AS paid_upfront,
        SUM(p.amount) FILTER (
            WHERE p.payment_code IN ('PAYMENT_SUCCESS','INCOMPLETE_PAYMENT','FINAL_PAYMENT')
        )          AS paid_recharge,
        0::numeric AS paid_cash_sales
    FROM silver.upya_payments p
    JOIN gold.unified_contracts uc ON uc.contract_number = p.contract_number
    WHERE p.status = 'ACCEPTED'
      AND p.payment_code IS NOT NULL
      AND p.payment_code NOT IN ('REVERSED','SURVEY_SUCCESS')
      AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')
    GROUP BY 1
),
surge_paid AS (
    SELECT
        DATE_TRUNC('month', p.paid_time)::date AS month_start,
        0::numeric    AS paid_upfront,
        SUM(p.amount) AS paid_recharge,
        0::numeric    AS paid_cash_sales
    FROM silver.surge_payments p
    JOIN silver.surge_asset_mapping m ON m.asset_number = p.account
    JOIN gold.unified_contracts uc ON uc.contract_number = m.installation_id::TEXT
    WHERE p.payment_status != 'REVERSED'
      AND uc.categorie = 'surge_tevia'
    GROUP BY 1
),
cash_paid AS (
    SELECT
        DATE_TRUNC('month', p.payment_date)::date AS month_start,
        0::numeric    AS paid_upfront,
        0::numeric    AS paid_recharge,
        SUM(p.amount) AS paid_cash_sales
    FROM silver.upya_payments p
    JOIN gold.unified_contracts uc ON uc.contract_number = p.contract_number
    WHERE p.status = 'ACCEPTED'
      AND uc.deal_type = 'FULL'
      AND (uc.entite = 'TEVIA' OR uc.categorie = 'surge_tevia')
    GROUP BY 1
),
paid_monthly AS (
    SELECT
        month_start,
        SUM(paid_upfront)    AS paid_upfront,
        SUM(paid_recharge)   AS paid_recharge,
        SUM(paid_cash_sales) AS paid_cash_sales
    FROM (
        SELECT * FROM upya_paid
        UNION ALL
        SELECT * FROM surge_paid
        UNION ALL
        SELECT * FROM cash_paid
    ) t
    GROUP BY month_start
)
SELECT
    md.month_start,
    md.month_end,
    TO_CHAR(md.month_start, 'YYYY-MM')             AS month_year,
    ROUND(COALESCE(p.paid_upfront,     0), 0)      AS paid_upfront_fcfa,
    ROUND(COALESCE(p.paid_recharge,    0), 0)      AS paid_recharge_fcfa,
    ROUND(COALESCE(p.paid_cash_sales,  0), 0)      AS paid_cash_sales_fcfa,
    ROUND(
        COALESCE(p.paid_upfront,    0) +
        COALESCE(p.paid_recharge,   0) +
        COALESCE(p.paid_cash_sales, 0), 0
    )                                              AS paid_total_fcfa,
    ROUND(COALESCE(e.expected_upfront,    0), 0)   AS expected_upfront_fcfa,
    ROUND(COALESCE(e.expected_recharge,   0), 0)   AS expected_recharge_fcfa,
    ROUND(COALESCE(e.expected_cash_sales, 0), 0)   AS expected_cash_sales_fcfa,
    ROUND(
        COALESCE(e.expected_upfront,    0) +
        COALESCE(e.expected_recharge,   0) +
        COALESCE(e.expected_cash_sales, 0), 0
    )                                              AS expected_total_fcfa,
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
    )                                              AS collection_rate_pct
FROM monthly_dates md
LEFT JOIN paid_monthly     p ON p.month_start = md.month_start
LEFT JOIN expected_monthly e ON e.month_start = md.month_start
ORDER BY md.month_start DESC;
