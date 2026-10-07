-- gold/unified_contracts.sql
-- VUE UNIFIÉE — Contrats UPYA (TEVIA + GREENO) + SURGE
--
-- v13 :
--   - computed_at : remplace CURRENT_TIMESTAMP par le dernier run pipeline réussi
--     (bronze_meta.run_log WHERE status = 'success')

CREATE OR REPLACE VIEW gold.unified_contracts AS
WITH
neotci AS (
    SELECT contract_number FROM silver.surge_neotci_list
),
surge_financials AS (
    SELECT
        m.installation_id,
        SUM(p.amount)         AS total_paid,
        MAX(p.paid_time)      AS last_payment_date
    FROM silver.surge_payments p
    JOIN silver.surge_asset_mapping m ON p.account = m.asset_number
    WHERE p.payment_status != 'REVERSED'
    GROUP BY m.installation_id
    UNION ALL
    SELECT
        le.installation_id,
        SUM(le.total_cash_collected) AS total_paid,
        MAX(le.posting_date)         AS last_payment_date
    FROM silver.surge_lease_engine le
    WHERE le.installation_id NOT IN (
        SELECT DISTINCT m.installation_id
        FROM silver.surge_payments p
        JOIN silver.surge_asset_mapping m ON p.account = m.asset_number
        WHERE p.payment_status != 'REVERSED'
    )
    GROUP BY le.installation_id
),
surge_paidoff_lookup AS (
    SELECT contract_number, paid_off_date
    FROM silver.surge_paidoff
),
upya_assets_latest AS (
    SELECT DISTINCT ON (contract_number)
        contract_number,
        payg_number,
        COALESCE(deploy_date, date_added) AS deploy_date,
        serial_number,
        status AS asset_status
    FROM silver.upya_assets
    WHERE contract_number IS NOT NULL
      AND status = 'DEPLOYED'
    ORDER BY contract_number,
             COALESCE(deploy_date, date_added) DESC NULLS LAST
),
upya AS (
    SELECT
        c.contract_number,
        CASE
            WHEN c.entity_name = 'GREENO' THEN 'greeno'
            ELSE 'tevia'
        END                                     AS entite,
        'upya'::TEXT                            AS source,
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
        c.sub_prefecture,
        c.village,
        c.latitude,
        c.longitude,
        cl.mobile                               AS phone_number,
        NULL::TEXT                              AS phone_number_2
    FROM silver.upya_contracts c
    LEFT JOIN upya_assets_latest a ON a.contract_number = c.contract_number
    LEFT JOIN silver.upya_clients cl ON cl.client_number = c.client_number
    WHERE c.contract_number IS NOT NULL
      AND TRIM(c.contract_number) != ''
      AND c.signing_date IS NOT NULL
),
surge AS (
    SELECT
        s.installation_id                       AS contract_number,
        'tevia'::TEXT                           AS entite,
        'surge'::TEXT                           AS source,
        CASE
            WHEN s.installation_id IN (SELECT contract_number FROM neotci)
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
        sp.paid_off_date::TIMESTAMPTZ           AS paid_off_date,
        s.removed_at::TIMESTAMPTZ               AS repossession_date,
        m.asset_number,
        COALESCE(pl.deal_type, 'PAYG')          AS deal_type_raw,
        pl.total_contract_value,
        pl.upfront_payment,
        pl.monthly_payment,
        COALESCE(sf.total_paid, 0)              AS total_paid,
        CASE
            WHEN pl.total_contract_value IS NOT NULL
            THEN GREATEST(0, pl.total_contract_value - COALESCE(sf.total_paid, 0))
            ELSE NULL
        END                                     AS remaining_debt,
        s.status                                AS contract_status_raw,
        CASE
            WHEN sp.paid_off_date IS NOT NULL THEN 'yes'
            ELSE 'no'
        END                                     AS paid_off_raw,
        COALESCE(pl.product_name, s.financial_type) AS product_name,
        s.region,
        s.ward                                  AS sub_prefecture,
        NULL::TEXT                              AS village,
        s.latitude,
        s.longitude,
        slc.prim_mobile                         AS phone_number,
        slc.snd_mobile                          AS phone_number_2
    FROM silver.surge_contracts s
    LEFT JOIN surge_financials sf     ON sf.installation_id = s.installation_id
    LEFT JOIN silver.surge_product_lookup pl ON pl.installation_id = s.installation_id
    LEFT JOIN surge_paidoff_lookup sp ON sp.contract_number = s.installation_id
    LEFT JOIN silver.surge_asset_mapping m ON m.installation_id = s.installation_id
    LEFT JOIN silver.surge_legacy_contacts slc ON slc.contract_number = s.installation_id
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
            WHEN paid_off_date IS NOT NULL AND source = 'surge'
                THEN 'PAID_OFF'
            WHEN UPPER(TRIM(contract_status_raw)) = ANY(ARRAY['ACTIVE','ENABLED','AWAITING REMOVAL'])
                THEN 'ENABLED'
            WHEN UPPER(TRIM(contract_status_raw)) = ANY(ARRAY['DISABLED','REPOSSESSED'])
                THEN 'REPOSSESSED'
            WHEN UPPER(TRIM(contract_status_raw)) = 'LOCKED'
                THEN 'LOCKED'
            WHEN UPPER(TRIM(contract_status_raw)) = ANY(ARRAY['PAID_OFF','PAIDOFF'])
                THEN 'PAID_OFF'
            WHEN UPPER(TRIM(contract_status_raw)) = 'CANCELLED'
                THEN 'CANCELLED'
            ELSE UPPER(TRIM(contract_status_raw))
        END AS contract_status,
        CASE
            WHEN LOWER(TRIM(paid_off_raw)) = ANY(ARRAY['yes','true','1']) THEN 'true'
            ELSE 'false'
        END AS paid_off,
        CASE
            WHEN UPPER(TRIM(deal_type_raw)) = ANY(ARRAY['NO','PAYG'])  THEN 'PAYG'
            WHEN UPPER(TRIM(deal_type_raw)) = ANY(ARRAY['YES','FULL']) THEN 'FULL'
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
    latitude,
    longitude,
    CASE
        WHEN deal_type = 'FULL'              THEN NULL::INTEGER
        WHEN contract_status = 'REPOSSESSED' THEN NULL::INTEGER
        WHEN contract_status = 'CANCELLED'   THEN NULL::INTEGER
        WHEN paid_off = 'true'               THEN NULL::INTEGER
        WHEN next_status_update IS NOT NULL THEN
            GREATEST(0,
                FLOOR(
                    EXTRACT(EPOCH FROM
                        CURRENT_TIMESTAMP -
                        (next_status_update AT TIME ZONE 'Africa/Abidjan')
                    ) / 86400
                )::INTEGER
            )
        ELSE NULL::INTEGER
    END AS consecutive_locked_days,
    (
        SELECT MAX(run_at)
        FROM bronze_meta.run_log
        WHERE status = 'success'
          AND entity IN (
              'contracts', 'clients', 'assets',
              'contracts', 'payments'
          )
    ) AS computed_at,
    phone_number,
    phone_number_2
FROM normalized;

COMMENT ON VIEW gold.unified_contracts IS
'Vue unifiée TEVIA + GREENO (UPYA) + SURGE v13.
computed_at    : horodatage du dernier run pipeline réussi (bronze_meta.run_log),
                 non de la requête sur la vue.
agent_number   : UPYA uniquement (NULL pour SURGE)
phone_number   : mobile primaire UPYA / prim_mobile SURGE
phone_number_2 : NULL pour UPYA / snd_mobile SURGE
paid_off       : surge_paidoff pour SURGE / upya_contracts pour UPYA
repossession   : upya_contracts.repossession_date / surge_contracts.removed_at
registration   : deploy_date UPYA / activated_at SURGE';