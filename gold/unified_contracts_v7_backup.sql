-- gold/unified_contracts.sql
-- VUE UNIFIÉE — Contrats UPYA (TEVIA + GREENO) + SURGE
--
-- v8 :
--   - entite = TEVIA ou GREENO (entreprise propriétaire)
--   - source = UPYA ou SURGE (origine technique)
--   - categorie = upya_tevia / upya_greeno / surge_tevia /
--                 surge_neotci / surge_zeci
--   - paid_off SURGE depuis silver.surge_paidoff
--   - total_paid SURGE depuis surge_lease_engine (+ fallback surge_payments)
--   - CLD logique métier corrigée

CREATE OR REPLACE VIEW gold.unified_contracts AS
WITH
neotci AS (
    SELECT contract_number FROM silver.surge_neotci_list
),
-- total_paid SURGE depuis lease_engine (source prioritaire)
surge_lease_total AS (
    SELECT
        installation_id::TEXT AS contract_number,
        SUM(cash_collected)   AS total_paid
    FROM silver.surge_lease_engine
    GROUP BY installation_id
),
-- total_paid SURGE depuis payments (fallback)
surge_financials AS (
    SELECT
        m.installation_id::TEXT AS contract_number,
        SUM(p.amount)           AS total_paid,
        MAX(p.paid_time)        AS last_payment_date
    FROM silver.surge_payments p
    JOIN silver.surge_asset_mapping m ON p.account = m.asset_number
    WHERE p.payment_status != 'REVERSED'
    GROUP BY m.installation_id
),
-- paid_off SURGE depuis fichier Ownership_reached
surge_paidoff_lookup AS (
    SELECT contract_number, paid_off_date
    FROM silver.surge_paidoff
),
upya_assets_latest AS (
    SELECT DISTINCT ON (contract_number)
        contract_number,
        payg_number,
        deploy_date,
        serial_number,
        status AS asset_status
    FROM silver.upya_assets
    WHERE contract_number IS NOT NULL
    ORDER BY contract_number, deploy_date DESC NULLS LAST
),
upya AS (
    SELECT
        c.contract_number,
        -- entite = entreprise propriétaire
        CASE
            WHEN c.entity_name = 'GREENO' THEN 'GREENO'
            ELSE 'TEVIA'
        END                                     AS entite,
        'UPYA'                                  AS source,
        -- categorie = sous-type précis
        CASE
            WHEN c.entity_name = 'GREENO' THEN 'upya_greeno'
            ELSE 'upya_tevia'
        END                                     AS categorie,
        c.client_number,
        c.customer_name,
        c.agent_number,
        c.agent_name,
        c.signing_date                          AS paid_date,
        a.deploy_date                           AS registration_date,
        c.last_status_update,
        c.next_status_update,
        c.paid_off_date,
        c.repossession_date,
        COALESCE(a.payg_number, c.asset_number) AS asset_number,
        c.deal_type                             AS deal_type_raw,
        c.total_cost                            AS total_contract_value,
        c.upfront_payment,
        c.monthly_payment,
        c.total_paid,
        c.remaining_debt,
        c.status                                AS contract_status_raw,
        c.paid_off_status                       AS paid_off_raw,
        c.product_name,
        c.region,
        c.district                              AS sub_prefecture,
        c.village
    FROM silver.upya_contracts c
    LEFT JOIN upya_assets_latest a
        ON a.contract_number = c.contract_number
    WHERE c.contract_number IS NOT NULL
      AND TRIM(c.contract_number) != ''
      AND c.signing_date IS NOT NULL
),
surge AS (
    SELECT
        s.installation_id::TEXT                 AS contract_number,
        -- entite = entreprise propriétaire (SURGE = TEVIA uniquement)
        'TEVIA'                                 AS entite,
        'SURGE'                                 AS source,
        -- categorie = sous-type précis
        CASE
            WHEN s.installation_id::TEXT IN (SELECT contract_number FROM neotci)
                THEN 'surge_neotci'
            WHEN s.paid_at >= '2024-04-01'
                THEN 'surge_tevia'
            ELSE 'surge_zeci'
        END                                     AS categorie,
        s.customer_id                           AS client_number,
        s.customer_name,
        NULL::TEXT                              AS agent_number,
        s.installed_by                          AS agent_name,
        s.paid_at                               AS paid_date,
        s.activated_at                          AS registration_date,
        s.paid_at                               AS last_status_update,
        s.unlocked_until::TIMESTAMPTZ           AS next_status_update,
        -- paid_off_date depuis surge_paidoff (fichier Ownership_reached)
        sp.paid_off_date::TIMESTAMPTZ           AS paid_off_date,
        s.removed_at::TIMESTAMPTZ               AS repossession_date,
        NULL::TEXT                              AS asset_number,
        COALESCE(pl.deal_type, 'PAYG')          AS deal_type_raw,
        pl.total_contract_value,
        pl.upfront_payment,
        pl.monthly_payment,
        -- total_paid : lease_engine prioritaire, surge_payments en fallback
        COALESCE(le.total_paid, sf.total_paid, 0) AS total_paid,
        CASE
            WHEN pl.total_contract_value IS NOT NULL
            THEN GREATEST(0, pl.total_contract_value
                 - COALESCE(le.total_paid, sf.total_paid, 0))
            ELSE NULL
        END                                     AS remaining_debt,
        s.status                                AS contract_status_raw,
        -- paid_off_raw : depuis surge_paidoff uniquement
        CASE
            WHEN sp.paid_off_date IS NOT NULL THEN 'yes'
            ELSE 'no'
        END                                     AS paid_off_raw,
        COALESCE(pl.product_name, s.financial_type) AS product_name,
        s.region,
        s.ward                                  AS sub_prefecture,
        NULL::TEXT                              AS village
    FROM silver.surge_contracts s
    LEFT JOIN surge_lease_total le
        ON le.contract_number = s.installation_id::TEXT
    LEFT JOIN surge_financials sf
        ON sf.contract_number = s.installation_id::TEXT
    LEFT JOIN silver.surge_product_lookup pl
        ON pl.installation_id = s.installation_id::TEXT
    LEFT JOIN surge_paidoff_lookup sp
        ON sp.contract_number = s.installation_id::TEXT
),
unified_raw AS (
    SELECT * FROM upya
    UNION ALL
    SELECT * FROM surge
),
normalized AS (
    SELECT
        *,
        CASE
            WHEN UPPER(TRIM(contract_status_raw)) IN ('ACTIVE', 'ENABLED', 'AWAITING REMOVAL')
                THEN 'ENABLED'
            WHEN UPPER(TRIM(contract_status_raw)) IN ('DISABLED', 'REPOSSESSED')
                THEN 'REPOSSESSED'
            WHEN UPPER(TRIM(contract_status_raw)) = 'LOCKED'
                THEN 'LOCKED'
            WHEN UPPER(TRIM(contract_status_raw)) IN ('PAID_OFF', 'PAIDOFF')
                THEN 'PAID_OFF'
            WHEN UPPER(TRIM(contract_status_raw)) = 'CANCELLED'
                THEN 'CANCELLED'
            ELSE UPPER(TRIM(contract_status_raw))
        END AS contract_status,
        CASE
            WHEN LOWER(TRIM(paid_off_raw)) IN ('yes', 'true', '1') THEN 'true'
            ELSE 'false'
        END AS paid_off,
        CASE
            WHEN UPPER(TRIM(deal_type_raw)) IN ('NO', 'PAYG')  THEN 'PAYG'
            WHEN UPPER(TRIM(deal_type_raw)) IN ('YES', 'FULL') THEN 'FULL'
            ELSE 'PAYG'
        END AS deal_type
    FROM unified_raw
)
SELECT
    contract_number,
    entite,
    source,
    categorie,
    client_number,
    customer_name,
    agent_number,
    agent_name,
    paid_date,
    registration_date,
    last_status_update,
    next_status_update,
    paid_off_date,
    repossession_date,
    product_name,
    asset_number,
    deal_type,
    total_contract_value,
    upfront_payment,
    monthly_payment,
    total_paid,
    remaining_debt,
    contract_status,
    paid_off,
    region,
    sub_prefecture,
    village,
    -- CLD logique métier :
    -- NULL si FULL, REPOSSESSED, CANCELLED, ou paid_off
    -- Calculé depuis next_status_update sinon
    CASE
        WHEN deal_type = 'FULL'                 THEN NULL
        WHEN contract_status = 'REPOSSESSED'    THEN NULL
        WHEN contract_status = 'CANCELLED'      THEN NULL
        WHEN paid_off = 'true'                  THEN NULL
        WHEN next_status_update IS NOT NULL THEN
            GREATEST(0,
                FLOOR(
                    EXTRACT(EPOCH FROM
                        CURRENT_TIMESTAMP -
                        (next_status_update AT TIME ZONE 'Africa/Abidjan')
                    ) / 86400
                )::INTEGER
            )
        ELSE NULL
    END AS consecutive_locked_days,
    CURRENT_TIMESTAMP AS computed_at
FROM normalized;

COMMENT ON VIEW gold.unified_contracts IS
'Vue unifiée TEVIA + GREENO (UPYA) + SURGE v8.
entite       : TEVIA ou GREENO (entreprise propriétaire)
source       : UPYA ou SURGE (origine technique)
categorie    : upya_tevia / upya_greeno / surge_tevia / surge_neotci / surge_zeci
total_paid   : lease_engine prioritaire + fallback surge_payments
paid_off     : surge_paidoff (Ownership_reached) pour SURGE
repossession : upya_contracts.repossession_date / surge_contracts.removed_at
registration : deploy_date UPYA / activated_at SURGE';