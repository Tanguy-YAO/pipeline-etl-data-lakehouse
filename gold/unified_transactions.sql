-- gold/unified_transactions.sql
--
-- Vue finale : combine SURGE (gold.surge_transactions) et UPYA
-- (gold.upya_transactions) en une seule table de transactions.
--
-- NOTE (26/08/2026) : une ancienne table gold.unified_transactions existait
-- deja en production depuis 2018 (colonnes daily_rate/nb_jours/payment_class),
-- alimentee jusqu'au 08/07/2026 par un processus non identifie (source
-- introuvable dans le repo actuel). Renommee en
-- gold.unified_transactions_legacy_pre_20260826 avant remplacement, plutot
-- que supprimee, par prudence -- a investiguer plus tard si besoin de
-- comprendre son usage/alimentation d'origine.

CREATE OR REPLACE VIEW gold.unified_transactions AS
SELECT * FROM gold.surge_transactions
UNION ALL
SELECT * FROM gold.upya_transactions;