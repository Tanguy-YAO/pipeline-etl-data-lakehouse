-- ============================================================
-- gold/unified_snapshot_monthly.sql
-- Snapshot mensuel reconstitué avec CLD correct
-- ============================================================
CREATE TABLE IF NOT EXISTS gold.unified_snapshot_monthly (
    month_end            DATE,
    contract_number      TEXT,
    source               TEXT,
    categorie            TEXT,
    snap_cld             INTEGER,
    contract_status      TEXT,
    total_contract_value NUMERIC(18,2),
    total_paid           NUMERIC(18,2),
    paid_off             TEXT,
    snapshot_date        DATE,
    PRIMARY KEY (month_end, contract_number)
);

TRUNCATE gold.unified_snapshot_monthly;

-- ============================================================
-- UPYA
-- ============================================================
INSERT INTO gold.unified_snapshot_monthly
SELECT * FROM (
    SELECT DISTINCT ON (md.month_end, s.contract_number)
        md.month_end,
        s.contract_number,
        'UPYA'                              AS source,
        s.categorie,
        s.consecutive_locked_days           AS snap_cld,
        CASE
            WHEN c.repossession_date IS NOT NULL
             AND c.repossession_date <= md.month_end     THEN 'REPOSSESSED'
            WHEN c.paid_off_date IS NOT NULL
             AND c.paid_off_date <= md.month_end         THEN 'PAIDOFF'
            WHEN c.status = 'CANCELLED'                  THEN 'CANCELLED'
            ELSE s.contract_status
        END                                 AS contract_status,
        s.total_contract_value,
        COALESCE(p.total_paid, s.total_paid) AS total_paid,
        s.paid_off,
        s.snapshot_date::date               AS snapshot_date
    FROM (
        SELECT
            DATE_TRUNC('month', d)::date AS month_start,
            (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end
        FROM generate_series('2026-01-01'::date, CURRENT_DATE, INTERVAL '1 month') d
    ) md
    JOIN gold.unified_snapshot s
        ON s.snapshot_date <= md.month_end
       AND s.snapshot_date >= md.month_start - INTERVAL '45 days'
       AND s.source = 'UPYA'
       AND s.categorie IN ('upya_tevia', 'surge_tevia')
       AND (s.contract_status IS NULL OR s.contract_status != 'CANCELLED')
    JOIN gold.upya_tevia_reference ref
        ON ref.contract_number = s.contract_number
       AND ref.deploy_date <= md.month_end
    JOIN silver.upya_contracts c
        ON c.contract_number = s.contract_number
    LEFT JOIN (
        SELECT contract_number, SUM(amount) AS total_paid
        FROM silver.upya_payments
        WHERE status = 'ACCEPTED'
          AND payment_code NOT IN ('REVERSED', 'SURVEY_SUCCESS')
        GROUP BY contract_number
    ) p ON p.contract_number = s.contract_number
    ORDER BY md.month_end, s.contract_number, s.snapshot_date DESC
) upya_data
ON CONFLICT (month_end, contract_number) DO NOTHING;

-- ============================================================
-- SURGE
-- ============================================================
INSERT INTO gold.unified_snapshot_monthly
SELECT * FROM (
    SELECT DISTINCT ON (md.month_end, s.contract_number)
        md.month_end,
        s.contract_number,
        'SURGE'                             AS source,
        s.categorie,
        GREATEST(0, md.month_end - COALESCE(
            suh.unlocked_until,
            sc.unlocked_until::date
        ))                                  AS snap_cld,
        CASE
            WHEN sc.removed_at IS NOT NULL
             AND sc.removed_at <= md.month_end           THEN 'REPOSSESSED'
            WHEN sc.status = 'Disabled'                  THEN 'REPOSSESSED'
            WHEN sc.status IN ('Active', 'Awaiting Removal') THEN 'ENABLED'
            ELSE s.contract_status
        END                                 AS contract_status,
        s.total_contract_value,
        COALESCE(sp.total_paid_at_month, s.total_paid)   AS total_paid,
        s.paid_off,
        s.snapshot_date::date               AS snapshot_date
    FROM (
        SELECT
            DATE_TRUNC('month', d)::date AS month_start,
            (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end
        FROM generate_series('2026-01-01'::date, CURRENT_DATE, INTERVAL '1 month') d
    ) md
    JOIN gold.unified_snapshot s
        ON s.snapshot_date <= md.month_end + INTERVAL '3 days'
       AND s.snapshot_date >= md.month_start - INTERVAL '45 days'
       AND s.source = 'SURGE'
       AND s.categorie IN ('upya_tevia', 'surge_tevia')
       AND (s.contract_status IS NULL OR s.contract_status != 'CANCELLED')
    JOIN silver.surge_contracts sc
        ON sc.installation_id::TEXT = s.contract_number
    LEFT JOIN (
        SELECT DISTINCT ON (md2.month_end, h.contract_number)
            md2.month_end,
            h.contract_number,
            h.unlocked_until
        FROM (
            SELECT
                (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end
            FROM generate_series('2026-01-01'::date, CURRENT_DATE, INTERVAL '1 month') d
        ) md2
        JOIN gold.unlocked_until_history h
            ON h.transaction_date <= md2.month_end
           AND h.source = 'SURGE'
        ORDER BY md2.month_end, h.contract_number, h.transaction_date DESC
    ) suh ON suh.contract_number = s.contract_number
          AND suh.month_end = md.month_end
    LEFT JOIN (
        SELECT
            m.installation_id::TEXT AS contract_number,
            DATE_TRUNC('month', p.paid_time)::date AS month_start,
            SUM(SUM(p.amount)) OVER (
                PARTITION BY m.installation_id
                ORDER BY DATE_TRUNC('month', p.paid_time)
            ) AS total_paid_at_month
        FROM silver.surge_payments p
        JOIN silver.surge_asset_mapping m ON m.asset_number = p.account
        WHERE p.payment_status != 'REVERSED'
        GROUP BY m.installation_id, DATE_TRUNC('month', p.paid_time)
    ) sp ON sp.contract_number = s.contract_number
         AND sp.month_start = md.month_start
    ORDER BY md.month_end, s.contract_number, s.snapshot_date DESC
) surge_data
ON CONFLICT (month_end, contract_number) DO NOTHING;
