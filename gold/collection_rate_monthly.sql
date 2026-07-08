-- ============================================================
-- gold/collection_rate_monthly.sql
--
-- VUE : gold.collection_rate_monthly
-- Equivalent de collection_rate_general_monthly_v2
--
-- PÉRIMÈTRE : surge_tevia + upya_tevia uniquement
-- PÉRIODE   : depuis sept 2025 (début activité TEVIA)
--
-- Classification payment_code UPYA :
--   upfront → DOWNPAYMENT_SUCCESS, INCOMPLETE_DOWNPAYMENT
--   recharge → PAYMENT_SUCCESS, INCOMPLETE_PAYMENT, FINAL_PAYMENT
--
-- Collection Rate = paid_total / expected_total × 100
--
-- CORRECTION v2 :
-- Le numérateur capture TOUS les paiements des contrats
-- upya_tevia/surge_tevia du mois, indépendamment du CLD.
-- Le dénominateur filtre uniquement les contrats actifs
-- (CLD ≤ 60j) en fin de mois.
-- ============================================================

CREATE OR REPLACE VIEW gold.collection_rate_monthly AS

WITH

-- Génération des mois depuis sept 2025
monthly_dates AS (
    SELECT
        DATE_TRUNC('month', d)::date AS month_start,
        (DATE_TRUNC('month', d) + INTERVAL '1 month'
            - INTERVAL '1 day')::date AS month_end
    FROM generate_series(
        '2025-09-01'::date,
        CURRENT_DATE,
        INTERVAL '1 month'
    ) d
),

-- ============================================================
-- TRANSACTIONS UPYA NETTOYÉES
-- Classification upfront vs recharge
-- ============================================================
upya_transactions AS (
    SELECT
        p.contract_number,
        p.payment_date,
        p.amount,
        CASE
            WHEN p.payment_code IN (
                'DOWNPAYMENT_SUCCESS',
                'INCOMPLETE_DOWNPAYMENT'
            ) THEN 'upfront'
            WHEN p.payment_code IN (
                'PAYMENT_SUCCESS',
                'INCOMPLETE_PAYMENT',
                'FINAL_PAYMENT'
            ) THEN 'recharge'
            ELSE NULL
        END AS payment_class
    FROM silver.upya_payments p
    WHERE p.status = 'ACCEPTED'
      AND p.payment_code IS NOT NULL
      AND p.payment_code NOT IN ('REVERSED', 'SURVEY_SUCCESS')
),

-- ============================================================
-- TRANSACTIONS SURGE TEVIA
-- Premier paiement = upfront, suivants = recharge
-- ============================================================
surge_transactions AS (
    SELECT
        m.installation_id               AS contract_number,
        p.paid_time                     AS payment_date,
        p.amount,
        CASE
            WHEN ROW_NUMBER() OVER (
                PARTITION BY m.installation_id
                ORDER BY p.paid_time ASC
            ) = 1
            THEN 'upfront'
            ELSE 'recharge'
        END                             AS payment_class
    FROM silver.surge_payments p
    JOIN silver.surge_asset_mapping m
        ON m.asset_number = p.account
    JOIN silver.surge_contracts sc
        ON sc.installation_id = m.installation_id
    WHERE p.payment_status != 'REVERSED'
      AND sc.paid_at >= '2024-04-01'
      AND sc.installation_id NOT IN (
          SELECT contract_number FROM silver.surge_neotci_list
      )
),

-- ============================================================
-- UNION DES TRANSACTIONS
-- ============================================================
all_transactions AS (
    SELECT contract_number, payment_date, amount, payment_class
    FROM upya_transactions
    WHERE payment_class IS NOT NULL
    UNION ALL
    SELECT contract_number, payment_date, amount, payment_class
    FROM surge_transactions
    WHERE payment_class IS NOT NULL
),

-- ============================================================
-- SNAPSHOT MENSUEL DES CONTRATS ACTIFS
-- Utilisé UNIQUEMENT pour le dénominateur (expected)
-- Filtre : CLD <= 60j en fin de mois
-- ============================================================
monthly_snapshots AS (
    SELECT
        md.month_start,
        md.month_end,
        uc.contract_number,
        uc.registration_date,
        (uc.registration_date + INTERVAL '30 days')::date AS end_free_period,
        COALESCE(uc.total_contract_value, 0)    AS total_contract_value,
        COALESCE(uc.upfront_payment, 0)         AS upfront_payment,
        COALESCE(uc.monthly_payment, 0)         AS monthly_payment,
        COALESCE(uc.monthly_payment, 0) / 30.0  AS daily_rate,
        uc.contract_status,
        uc.deal_type,
        uc.categorie,
        uc.paid_off,
        uc.paid_off_date,
        COALESCE(uc.consecutive_locked_days, 0) AS consecutive_locked_days
    FROM monthly_dates md
    CROSS JOIN LATERAL (
        SELECT DISTINCT ON (s.contract_number)
            s.contract_number,
            s.contract_status,
            s.deal_type,
            s.categorie,
            s.paid_off,
            s.total_contract_value,
            s.consecutive_locked_days,
            uc.registration_date,
            uc.paid_date       AS paid_off_date,
            uc.upfront_payment,
            uc.monthly_payment
        FROM gold.unified_snapshot s
        JOIN gold.unified_contracts uc
            ON uc.contract_number = s.contract_number
        WHERE s.snapshot_date <= md.month_end
          AND s.categorie IN ('upya_tevia', 'surge_tevia')
          AND s.contract_status NOT IN ('REPOSSESSED', 'CANCELLED')
        ORDER BY s.contract_number, s.snapshot_date DESC
    ) uc
    WHERE uc.registration_date IS NOT NULL
      AND uc.registration_date <= md.month_end
      AND COALESCE(uc.consecutive_locked_days, 0) <= 60
      AND uc.contract_status NOT IN ('REPOSSESSED', 'CANCELLED')
),

-- ============================================================
-- MONTANTS PAYÉS PAR MOIS
-- CORRECTION : on prend TOUS les paiements des contrats
-- upya_tevia/surge_tevia, sans filtrer par CLD.
-- Le filtre CLD s'applique uniquement au dénominateur.
-- ============================================================
paid_monthly AS (
    SELECT
        md.month_start,
        SUM(CASE
            WHEN c.deal_type != 'FULL'
             AND t.payment_class = 'upfront'
            THEN t.amount ELSE 0
        END) AS paid_upfront,
        SUM(CASE
            WHEN c.deal_type != 'FULL'
             AND t.payment_class = 'recharge'
            THEN t.amount ELSE 0
        END) AS paid_recharge,
        SUM(CASE
            WHEN c.deal_type = 'FULL'
            THEN t.amount ELSE 0
        END) AS paid_full
    FROM monthly_dates md
    JOIN all_transactions t
        ON DATE_TRUNC('month', t.payment_date) = md.month_start
    JOIN gold.unified_contracts c
        ON c.contract_number = t.contract_number
    WHERE c.categorie IN ('upya_tevia', 'surge_tevia')
    GROUP BY md.month_start
),

-- ============================================================
-- MONTANTS ATTENDUS PAR MOIS (dénominateur)
-- Filtre CLD <= 60j appliqué ici
-- ============================================================
expected_monthly AS (
    SELECT
        ms.month_start,
        -- FULL : attendu si activé dans le mois
        SUM(CASE
            WHEN ms.deal_type = 'FULL'
             AND DATE_TRUNC('month', ms.registration_date) = ms.month_start
            THEN ms.total_contract_value ELSE 0
        END) AS expected_full,
        -- Upfront : attendu si activé dans le mois
        SUM(CASE
            WHEN ms.deal_type != 'FULL'
             AND DATE_TRUNC('month', ms.registration_date) = ms.month_start
            THEN ms.upfront_payment ELSE 0
        END) AS expected_upfront,
        -- Recharge : après 30j de gratuité
        SUM(CASE
            WHEN ms.deal_type != 'FULL'
             AND ms.end_free_period >= ms.month_end
            THEN 0
            WHEN ms.paid_off = 'true'
             AND ms.paid_off_date < ms.month_start
            THEN 0
            ELSE GREATEST(0,
                (ms.month_end
                 - GREATEST(ms.month_start, ms.end_free_period) + 1)
            ) * ms.daily_rate
        END) AS expected_recharge
    FROM monthly_snapshots ms
    WHERE ms.contract_status NOT IN ('REPOSSESSED', 'CANCELLED')
    GROUP BY ms.month_start
)

-- ============================================================
-- SELECT FINAL
-- ============================================================
SELECT
    md.month_start,
    md.month_end,
    TO_CHAR(md.month_start, 'YYYY-MM')                    AS month_year,
    -- Montants payés
    ROUND(COALESCE(p.paid_upfront,  0), 0)                AS paid_upfront_fcfa,
    ROUND(COALESCE(p.paid_recharge, 0), 0)                AS paid_recharge_fcfa,
    ROUND(COALESCE(p.paid_full,     0), 0)                AS paid_full_fcfa,
    ROUND(
        COALESCE(p.paid_upfront,  0) +
        COALESCE(p.paid_recharge, 0) +
        COALESCE(p.paid_full,     0), 0
    )                                                      AS paid_total_fcfa,
    -- Montants attendus
    ROUND(COALESCE(e.expected_upfront,  0), 0)            AS expected_upfront_fcfa,
    ROUND(COALESCE(e.expected_recharge, 0), 0)            AS expected_recharge_fcfa,
    ROUND(COALESCE(e.expected_full,     0), 0)            AS expected_full_fcfa,
    ROUND(
        COALESCE(e.expected_upfront,  0) +
        COALESCE(e.expected_recharge, 0) +
        COALESCE(e.expected_full,     0), 0
    )                                                      AS expected_total_fcfa,
    -- Collection Rate
    ROUND(
        100.0 * (
            COALESCE(p.paid_upfront,  0) +
            COALESCE(p.paid_recharge, 0) +
            COALESCE(p.paid_full,     0)
        ) / NULLIF(
            COALESCE(e.expected_upfront,  0) +
            COALESCE(e.expected_recharge, 0) +
            COALESCE(e.expected_full,     0),
        0), 2
    )                                                      AS collection_rate_pct
FROM monthly_dates md
LEFT JOIN paid_monthly     p ON p.month_start = md.month_start
LEFT JOIN expected_monthly e ON e.month_start = md.month_start
ORDER BY md.month_start DESC;

COMMENT ON VIEW gold.collection_rate_monthly IS
'Collection Rate mensuel TEVIA — surge_tevia + upya_tevia uniquement.
v2: numérateur = tous paiements du mois (sans filtre CLD),
    dénominateur = expected des contrats actifs CLD <= 60j.
Classification UPYA: DOWNPAYMENT/INCOMPLETE_DOWNPAYMENT=upfront,
PAYMENT/INCOMPLETE/FINAL=recharge.';