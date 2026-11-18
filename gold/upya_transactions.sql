-- gold/upya_transactions.sql
--
-- Vue : gold.upya_transactions
--
-- OBJECTIF : classification des transactions UPYA (silver.upya_payments).
-- REGLE (26/08/2026) : FINAL_PAYMENT = 'upfront_payment' ; tout contrat FULL
-- est classe upfront_payment quel que soit son payment_code.
--
-- CORRECTIF v2 (18/11/2026) : paiements reaffectes et statuts.
--   * Quand UPYA reaffecte un paiement, il cree une ligne 'AS-<id>' (puis
--     'AS-AS-<id>'...). L'ancienne ligne restait comptee : elle est ignoree
--     des qu'une version 'AS-' existe (731 paiements, 36,4 M XOF depuis 07/2025).
--   * Seuls les paiements ACCEPTED comptent (avant : seul REVERSED ecarte).
--   * Controle octobre 2026 contre l'export du CRM UPYA : ecart < 0,1 %.
--   Deploye en base le 18/11/2026 (delta/correctif-paiements-reaffectes.sql).

CREATE OR REPLACE VIEW gold.upya_transactions AS
SELECT
    up.contract_number,
    up.transaction_id,
    up.payment_date,
    up.payment_code,
    up.amount,
    'upya'::text AS source,
    CASE
        WHEN uc.deal_type = 'FULL' THEN 'upfront_payment'
        WHEN up.payment_code IN ('DOWNPAYMENT_SUCCESS', 'INCOMPLETE_DOWNPAYMENT', 'FINAL_PAYMENT')
            THEN 'upfront_payment'
        WHEN up.payment_code IN ('PAYMENT_SUCCESS', 'INCOMPLETE_PAYMENT')
            THEN 'recharge'
        ELSE NULL
    END AS normalized_reason,
    false AS is_accessory,
    (
        up.payment_code IS NULL
        OR up.amount < 0
        OR up.payment_code IN ('SURVEY_SUCCESS', 'UNASSIGNED_PAYMENT', 'PAYMENT_SUCCESS_PENALTY_CLEARED')
        OR COALESCE(up.status, '') <> 'ACCEPTED'
        OR EXISTS (
               SELECT 1 FROM silver.upya_payments n
               WHERE n.transaction_id IN ('AS-' || up.transaction_id,
                                          'AS-AS-' || up.transaction_id,
                                          'AS-AS-AS-' || up.transaction_id))
    ) AS ignore_payment,
    NULL::text AS asset_number,
    'as_recorded' AS amount_basis
FROM silver.upya_payments up
LEFT JOIN gold.unified_contracts uc ON uc.contract_number = up.contract_number;