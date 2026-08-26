-- gold/surge_transactions.sql
--
-- Vue : gold.surge_transactions
--
-- OBJECTIF : table unifiée et FIABLE des transactions SURGE TEVIA, combinant :
--   1. L'historique reconcilié (bi_legacy.unified_cleaned_transactions) --
--      montants "net" (avec un mécanisme de solde reporté selon la logique de surge), jusqu'à l'arrêt
--      d'alimentation de l'ancien systeme BI cote SURGE depuis le 06 mars 2026.
--   2. Les nouvelles transactions (silver.surge_payments) -- montants "gross"
--      (brut mobile money, sans réconciliation), pour tout ce qui est survenu
--      APRES la dernière transaction connue de CHAQUE CONTRAT (coupure par
--      contrat, pas une date fixe globale -- certains contrats ont pu cesser
--      d'etre suivis par l'ancien système à des moments differents).
--
-- LIMITE CONNUE ET ASSUMEE (documentée le 26/08/2026) -- documentation à partagée avec mon N+1 CONE Aboubacar:
-- Les montants "gross" et "net_reconciled" ne portent pas exactement la même
-- sémantique financière -- le net intègre un solde de crédit reporté d'un
-- paiement à l'autre (base sur daily_rate = monthly_payment/30), que j'ai
-- choisi de ne PAS reconstruire pour les nouvelles transactions : une
-- simulation à grande échelle (migrations/validate_surge_reconciliation.py)
-- a revele des données historiques incomplètes (asset_number ne capture que
-- le n° du kit ACTUEL d'un contrat, pas l'historique de remplacement de kits),
-- rendant la validation de la formule moins fiable au-dela d'un échantillon
-- restreint. L'écart mesuré sur les cas validés reste toutefois faible : le
-- solde reporté n'a jamais depassé un daily_rate (quelques centaines de XOF
-- par contrat). Chaque ligne porte sa base de calcul via `amount_basis`
-- ('net_reconciled' ou 'gross') pour une transparence totale...
--
-- FRAICHEUR : cette vue se recalcule à chaque interrogation -- des que
-- silver.surge_payments est rechargé (actuellement un processus manuel, gold.surge_transactions
-- réflètera automatiquement les nouvelles lignes, sans script a relancer.
--
-- CORRECTIF (26/08/2026) -- BUG DE DOUBLON A LA DATE DE COUPURE :
-- Quality check sur contrat 737425 a revele un ecart de 21 000 XOF entre
-- notre vue (597 350) et le CRM (576 350). Cause : bi_legacy.payment_date
-- est stocke sans heure (00:00:00 par defaut), alors que
-- silver.surge_payments.paid_time garde l'heure exacte. Le filtre original
-- `sp.paid_time > lk.last_date` comparait par exemple '2026-02-10 20:28:34'
-- a '2026-02-10 00:00:00' -- toujours vrai le jour meme -- reinjectant une
-- transaction du 10/02 DEJA comptee dans l'historique comme si elle etait
-- nouvelle (doublon exact de 19 500 XOF confirme). Corrige en comparant les
-- dates seules (::date) plutot que les timestamps complets.
-- Ecart residuel de 1 500 XOF sur ce contrat non explique par ce correctif,
-- a investiguer separement si besoin (hors cause du doublon principal).
-- RISQUE RESIDUEL ASSUME : un contrat ayant reellement deux transactions
-- distinctes le meme jour calendaire QUE le jour de coupure verrait la
-- seconde exclue a tort -- prefere a un doublon systematique garanti.

CREATE OR REPLACE VIEW gold.surge_transactions AS

SELECT
    contract_number,
    transaction_id,
    payment_date,
    payment_code,
    amount,
    source,
    normalized_reason,
    is_accessory,
    ignore_payment,
    asset_number,
    'net_reconciled' AS amount_basis
FROM bi_legacy.unified_cleaned_transactions
WHERE source = 'Surge' AND ignore_payment = false

UNION ALL

SELECT
    sc.contract_number,
    'SURGE_NEW_' || sp.transaction_id AS transaction_id,
    sp.paid_time AS payment_date,
    'Mobile Payment (gross, non reconcilie)' AS payment_code,
    sp.amount,
    'Surge' AS source,
    'recharge' AS normalized_reason,
    false AS is_accessory,
    false AS ignore_payment,
    sc.asset_number,
    'gross' AS amount_basis
FROM silver.surge_payments sp
JOIN gold.unified_contracts sc
    ON sc.asset_number = sp.account
   AND sc.categorie = 'surge_tevia'
LEFT JOIN (
    SELECT contract_number, MAX(payment_date) AS last_date
    FROM bi_legacy.unified_cleaned_transactions
    WHERE source = 'Surge' AND ignore_payment = false
    GROUP BY contract_number
) lk ON lk.contract_number = sc.contract_number
WHERE sp.payment_status = 'Processed'
  AND (lk.last_date IS NULL OR sp.paid_time::date > lk.last_date::date);