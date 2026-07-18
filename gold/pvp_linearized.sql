-- ============================================================
-- gold/pvp_linearized.sql
-- PvP Linearized — Taux de remboursement linéarisé
-- Développé avec Alexandre (PAYGOLab)
-- Périmètre : upya_tevia + surge_tevia uniquement
-- ============================================================
CREATE OR REPLACE VIEW gold.pvp_linearized AS
WITH base AS (
    SELECT
        uc.contract_number,
        uc.customer_name,
        uc.categorie,
        uc.registration_date::date,
        30                                          AS deposit_free_days,
        uc.total_contract_value,
        uc.upfront_payment                          AS deposit,
        uc.monthly_payment / 30.0                   AS daily_rate,
        uc.total_contract_value
            - uc.upfront_payment                    AS total_without_deposit,
        uc.total_paid,
        uc.remaining_debt,
        uc.contract_status                          AS status,
        uc.next_status_update::date                 AS next_status_update,
        uc.last_status_update::date                 AS last_status_update,
        uc.consecutive_locked_days,
        CURRENT_DATE                                AS snapshot_date,
        GREATEST(
            CURRENT_DATE - uc.registration_date::date - 30, 0
        )                                           AS days_on_books,
        GREATEST(
            uc.total_paid - uc.upfront_payment, 0
        )                                           AS paid_without_deposit,
        CASE
            WHEN uc.contract_status = 'LOCKED'
                THEN uc.last_status_update::date - CURRENT_DATE
            WHEN uc.contract_status = 'ENABLED'
                THEN uc.next_status_update::date - CURRENT_DATE
            ELSE 0
        END                                         AS days_to_cutoff
    FROM gold.unified_contracts uc
    WHERE uc.categorie IN ('upya_tevia', 'surge_tevia')
      AND uc.contract_status IN ('ENABLED', 'LOCKED', 'PAID_OFF')
      AND uc.registration_date IS NOT NULL
      AND uc.monthly_payment > 0
      AND uc.total_contract_value > 0
),
linearized AS (
    SELECT
        *,
        CASE
            WHEN days_on_books > 0
             AND status IN ('LOCKED', 'ENABLED')
            THEN GREATEST(
                paid_without_deposit
                - (GREATEST(days_to_cutoff, 0) * daily_rate),
                0
            )
            ELSE paid_without_deposit
        END                                         AS paid_linearized,
        CASE
            WHEN days_on_books > 0
            THEN LEAST(
                days_on_books * daily_rate,
                total_without_deposit
            )
            ELSE 0
        END                                         AS expected_to_date,
        CASE
            WHEN status IN ('ENABLED', 'PAID_OFF')
            THEN remaining_debt
            ELSE 0
        END                                         AS active_receivable,
        CEIL(
            GREATEST(paid_without_deposit, 0)
            / NULLIF(total_without_deposit, 0) * 10
        ) * 10                                      AS loan_paid_bin
    FROM base
)
SELECT
    contract_number,
    customer_name,
    categorie,
    registration_date,
    deposit_free_days,
    total_contract_value,
    deposit,
    daily_rate,
    total_without_deposit,
    status,
    days_to_cutoff,
    days_on_books,
    total_paid                                      AS cumulative_paid,
    paid_without_deposit,
    remaining_debt                                  AS account_receivable,
    loan_paid_bin,
    paid_linearized,
    expected_to_date,
    CASE
        WHEN expected_to_date > 0
        THEN ROUND(paid_linearized / expected_to_date, 4)
        ELSE 1
    END                                             AS pvp_linearized,
    active_receivable,
    paid_without_deposit
        + active_receivable                         AS paid_plus_receivable,
    snapshot_date
FROM linearized;
