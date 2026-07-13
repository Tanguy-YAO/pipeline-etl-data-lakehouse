-- ============================================================
-- EFA Report v2 — Jan-Jun 2026
-- Changements vs v1 :
--   - JOIN gold.upya_tevia_reference pour filtrer sur assets
--     physiquement déployés (source: silver.upya_asset_events)
--   - Suppression filtre registration_date (remplacé par ref.deploy_date)
--   - IS NULL OR != 'CANCELLED' sur contract_status
-- ============================================================
WITH monthly_dates AS (
    SELECT
        DATE_TRUNC('month', d)::date AS month_start,
        (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end
    FROM generate_series('2026-01-01'::date, '2026-06-30'::date, INTERVAL '1 month') d
),
snapshot_upya AS (
    SELECT DISTINCT ON (md.month_end, s.contract_number)
        md.month_start,
        md.month_end,
        s.contract_number,
        s.consecutive_locked_days   AS snap_cld,
        s.total_contract_value,
        s.total_paid,
        s.contract_status,
        s.paid_off,
        s.snapshot_date
    FROM monthly_dates md
    JOIN gold.unified_snapshot s
        ON s.snapshot_date <= md.month_end
       AND s.snapshot_date >= md.month_start - INTERVAL '45 days'
       AND s.source = 'UPYA'
       AND s.categorie IN ('upya_tevia', 'surge_tevia')
       AND (s.contract_status IS NULL OR s.contract_status != 'CANCELLED')
    JOIN gold.upya_tevia_reference ref
        ON ref.contract_number = s.contract_number
       AND ref.deploy_date <= md.month_end
    ORDER BY md.month_end, s.contract_number, s.snapshot_date DESC
),
snapshot_surge AS (
    SELECT DISTINCT ON (md.month_end, s.contract_number)
        md.month_start,
        md.month_end,
        s.contract_number,
        s.consecutive_locked_days   AS snap_cld,
        s.total_contract_value,
        s.total_paid,
        s.contract_status,
        s.paid_off,
        s.snapshot_date
    FROM monthly_dates md
    JOIN gold.unified_snapshot s
        ON s.snapshot_date <= md.month_end + INTERVAL '3 days'
       AND s.snapshot_date >= md.month_start - INTERVAL '45 days'
       AND s.source = 'SURGE'
       AND s.categorie IN ('upya_tevia', 'surge_tevia')
       AND (s.contract_status IS NULL OR s.contract_status != 'CANCELLED')
    ORDER BY md.month_end, s.contract_number, s.snapshot_date DESC
),
monthly_data AS (
    SELECT * FROM snapshot_upya
    UNION ALL
    SELECT * FROM snapshot_surge
),
monthly_data_with_meta AS (
    SELECT
        m.*,
        uc.repossession_date,
        uc.paid_off_date,
        uc.next_status_update,
        GREATEST(0, COALESCE(m.total_contract_value,0)
            - COALESCE(m.total_paid,0)) AS receivables
    FROM monthly_data m
    JOIN gold.unified_contracts uc
        ON uc.contract_number = m.contract_number
),
bucketed AS (
    SELECT
        *,
        COALESCE(snap_cld, 0) AS cld,
        CASE
            WHEN contract_status = 'REPOSSESSED'                THEN 'repossessed'
            WHEN paid_off_date IS NOT NULL
             AND paid_off_date <= month_end                     THEN 'paidoff'
            WHEN COALESCE(snap_cld, 0) > 120                   THEN 'hors_portefeuille'
            WHEN COALESCE(snap_cld, 0) = 0                     THEN 'a. pas_de_retard'
            WHEN snap_cld BETWEEN 1   AND 30                   THEN 'b. 1_30j'
            WHEN snap_cld BETWEEN 31  AND 60                   THEN 'c. 31_60j'
            WHEN snap_cld BETWEEN 61  AND 90                   THEN 'd. 61_90j'
            WHEN snap_cld BETWEEN 91  AND 120                  THEN 'e. 91_120j'
            ELSE 'autre'
        END AS retard_bucket
    FROM monthly_data_with_meta
)
SELECT
    TO_CHAR(b.month_end, 'YYYY-MM')                     AS month_year,
    b.month_end,
    COUNT(*) FILTER (
        WHERE retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
    )                                                    AS nb_contrats,
    ROUND(SUM(total_contract_value) FILTER (
        WHERE retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
    ) / 655.957, 0)                                      AS valeur_portefeuille_eur,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
    ) / 655.957, 0)                                      AS receivables_eur,
    COUNT(*) FILTER (
        WHERE cld < 60
          AND retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
    )                                                    AS nb_clients_actifs,
    cr.paid_total_fcfa,
    cr.expected_total_fcfa,
    cr.collection_rate_pct,
    COUNT(*) FILTER (WHERE retard_bucket = 'a. pas_de_retard') AS nb_pas_retard,
    COUNT(*) FILTER (WHERE retard_bucket = 'b. 1_30j')         AS nb_1_30j,
    COUNT(*) FILTER (WHERE retard_bucket = 'c. 31_60j')        AS nb_31_60j,
    COUNT(*) FILTER (WHERE retard_bucket = 'd. 61_90j')        AS nb_61_90j,
    COUNT(*) FILTER (WHERE retard_bucket = 'e. 91_120j')       AS nb_91_120j,
    COUNT(*) FILTER (WHERE retard_bucket = 'hors_portefeuille') AS nb_hors_portefeuille,
    COUNT(*) FILTER (WHERE retard_bucket = 'repossessed')       AS nb_repossessed,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket = 'a. pas_de_retard'
    ) / 655.957, 0)                                      AS rec_pas_retard_eur,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket = 'b. 1_30j'
    ) / 655.957, 0)                                      AS rec_1_30j_eur,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket = 'c. 31_60j'
    ) / 655.957, 0)                                      AS rec_31_60j_eur,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket = 'd. 61_90j'
    ) / 655.957, 0)                                      AS rec_61_90j_eur,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket = 'e. 91_120j'
    ) / 655.957, 0)                                      AS rec_91_120j_eur,
    ROUND(SUM(receivables) FILTER (
        WHERE retard_bucket = 'hors_portefeuille'
    ) / 655.957, 0)                                      AS rec_writeoff_eur,
    COUNT(*) FILTER (
        WHERE cld BETWEEN 60 AND 90
          AND retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
    )                                                    AS nb_new_default,
    ROUND(100.0 *
        COUNT(*) FILTER (
            WHERE cld BETWEEN 60 AND 90
              AND retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
        ) /
        NULLIF(COUNT(*) FILTER (
            WHERE retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
        ), 0)
    , 2)                                                 AS new_default_rate_pct,
    COUNT(*) FILTER (
        WHERE repossession_date >= b.month_start
          AND repossession_date <= b.month_end
    )                                                    AS nb_new_repossessions,
    ROUND(100.0 *
        COUNT(*) FILTER (
            WHERE repossession_date >= b.month_start
              AND repossession_date <= b.month_end
        ) /
        NULLIF(COUNT(*) FILTER (
            WHERE cld > 90
              AND retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
        ), 0)
    , 2)                                                 AS repossession_rate_pct,
    COUNT(*) FILTER (
        WHERE cld > 90
          AND retard_bucket NOT IN ('repossessed','paidoff','hors_portefeuille')
    )                                                    AS nb_default_90j_plus
FROM bucketed b
LEFT JOIN gold.collection_rate_monthly cr
    ON cr.month_end = b.month_end
GROUP BY
    month_year, b.month_end, b.month_start,
    cr.paid_total_fcfa, cr.expected_total_fcfa, cr.collection_rate_pct
ORDER BY b.month_end;
