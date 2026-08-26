-- gold/unified_transactions_tevia.sql
--
-- Perimetre TEVIA uniquement (SURGE + UPYA), paiements valides seulement.
-- GREENO exclu : ses transactions presentent plusieurs anomalies non
-- encore comprises (codes de paiement incoherents avec deal_type sur les
-- contrats FULL, entre autres) -- a investiguer separement avant integration.

CREATE OR REPLACE VIEW gold.unified_transactions_tevia AS
SELECT ut.*
FROM gold.unified_transactions ut
JOIN gold.unified_contracts uc ON uc.contract_number = ut.contract_number
WHERE uc.categorie IN ('surge_tevia', 'upya_tevia')
  AND ut.ignore_payment = false;