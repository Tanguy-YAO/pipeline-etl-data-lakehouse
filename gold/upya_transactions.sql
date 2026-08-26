-- gold/upya_transactions.sql
--
-- Vue : gold.upya_transactions
--
-- OBJECTIF : classification des transactions UPYA selon la meme logique
-- metier que l'ancienne vue bi.unified_cleaned_transactions (CTE upya_rows),
-- appliquee directement sur silver.upya_payments -- source unique, stable
-- et complete, sans jointure vers bi_legacy (contrairement a SURGE).
--
-- REGLE CONFIRMEE (26/08/2026) : FINAL_PAYMENT est classe 'upfront_payment',
-- pas 'recharge' -- suit le SQL reel de l'ancienne vue (source de verite
-- pour rester coherent avec toutes les transactions historiques deja
-- produites par cette logique), en divergence assumee avec la documentation
-- ecrite (§8 regle #5) qui indique l'inverse -- documentation a corriger
-- separement, cf. echange avec CONE Aboubacar.
--
-- CORRECTIF (26/08/2026) : les contrats FULL (paiement cash unique) peuvent
-- utiliser DOWNPAYMENT_SUCCESS, INCOMPLETE_DOWNPAYMENT, FINAL_PAYMENT, ou
-- meme PAYMENT_SUCCESS selon l'entite -- confirme sur 3 contrats GREENO FULL
-- portant le code PAYMENT_SUCCESS (normalement classe 'recharge'), avec des
-- montants correspondant exactement a total_contract_value. Le deal_type
-- prime donc desormais sur le payment_code pour ces cas : tout contrat FULL
-- est classe upfront_payment quel que soit son payment_code.
--
-- LIMITE CONNUE (26/08/2026) : PAYMENT_SUCCESS_PENALTY_CLEARED,
-- UNASSIGNED_PAYMENT, et les payment_code NULL a montant negatif (49
-- transactions, -1 861 650 XOF au 26/08/2026) sont mis en ignore_payment=true
-- en attente d'investigation -- ces cas semblent concentres cote GREENO,
-- dont les transactions presentent plusieurs anomalies encore non comprises
-- a ce stade (voir aussi les ecarts sur les contrats FULL ci-dessus).
--
-- FRAICHEUR : vue recalculee a chaque interrogation. silver.upya_payments
-- etant deja recharge quotidiennement par le pipeline GitHub Actions
-- existant, cette vue est TOUJOURS a jour sans aucune action supplementaire.

CREATE OR REPLACE VIEW gold.upya_transactions AS
SELECT
    up.contract_number,
    up.transaction_id,
    up.payment_date,
    up.payment_code,
    up.amount,
    'Upya' AS source,
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
        OR up.status = 'REVERSED'
    ) AS ignore_payment,
    NULL::text AS asset_number,
    'as_recorded' AS amount_basis
FROM silver.upya_payments up
LEFT JOIN gold.unified_contracts uc ON uc.contract_number = up.contract_number;