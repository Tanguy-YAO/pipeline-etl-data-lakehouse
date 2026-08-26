-- gold/collection_rate_by_region_snapshot.sql
--
-- Requete ponctuelle (pas une vue permanente) : taux de paiement par
-- region, a deux dates de reference, pour la demande urgente du Credit
-- TEVIA (affectations territoriales des agents), 26/08/2026.
--
-- NORMALISATION REGION (26/08/2026) : gold.unified_contracts.region melange
-- plusieurs formats de libelles selon la source (UPYA vs SURGE) -- prefixe
-- "Région "/"Region des/du/de la ", accents variables (Gôh vs Goh), tirets
-- vs espaces, et une faute de frappe connue (Cavaly vs Cavally). Sans cette
-- normalisation, 60+ "regions" apparaissaient au lieu des ~34 reelles,
-- avec des taux completement faux sur les fragments mal repartis.
--
-- FORMULE : expected_total_paid = upfront_payment + daily_rate * jours
-- depuis period_1 (registration_date + 30 jours, debut des rechargements),
-- validee manuellement sur 3 contrats le 26/08/2026.
--
-- PERIMETRE : TEVIA uniquement (surge_tevia + upya_tevia).

WITH contrats_snapshot AS (
    SELECT
        contract_number,
        CASE
            WHEN UPPER(TRANSLATE(
                TRIM(REGEXP_REPLACE(
                    REGEXP_REPLACE(region, '^[Rr][ée]gion\s+(de\s+la\s+|des\s+|du\s+|la\s+)?', '', 'i'),
                    '[\s-]+', ' ', 'g'
                )),
                'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇŸàâäéèêëîïôöùûüçÿ',
                'AAAEEEEIIOOUUUCYaaaeeeeiioouuucy'
            )) = 'CAVALY' THEN 'CAVALLY'
            ELSE UPPER(TRANSLATE(
                TRIM(REGEXP_REPLACE(
                    REGEXP_REPLACE(region, '^[Rr][ée]gion\s+(de\s+la\s+|des\s+|du\s+|la\s+)?', '', 'i'),
                    '[\s-]+', ' ', 'g'
                )),
                'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇŸàâäéèêëîïôöùûüçÿ',
                'AAAEEEEIIOOUUUCYaaaeeeeiioouuucy'
            ))
        END AS region_norm,
        registration_date, upfront_payment, monthly_payment
    FROM gold.unified_contracts
    WHERE categorie IN ('surge_tevia', 'upya_tevia')
      AND registration_date IS NOT NULL
),

dates_reference AS (
    SELECT '2025-12-31'::date AS as_of_date
    UNION ALL
    SELECT '2026-07-31'::date
),

expected_par_contrat AS (
    SELECT
        cs.contract_number,
        cs.region_norm,
        dr.as_of_date,
        cs.upfront_payment
            + ROUND(cs.monthly_payment / 30.0, 2)
            * GREATEST(
                (dr.as_of_date - (cs.registration_date::date + INTERVAL '30 days')::date), 0
              ) AS expected_total_paid
    FROM contrats_snapshot cs
    CROSS JOIN dates_reference dr
    WHERE cs.registration_date::date <= dr.as_of_date
),

paiements_a_date AS (
    SELECT
        ut.contract_number,
        dr.as_of_date,
        SUM(ut.amount) AS total_paid
    FROM gold.unified_transactions_tevia ut
    CROSS JOIN dates_reference dr
    WHERE ut.payment_date::date <= dr.as_of_date
    GROUP BY ut.contract_number, dr.as_of_date
)

SELECT
    ep.as_of_date,
    ep.region_norm AS region,
    COUNT(DISTINCT ep.contract_number) AS nb_contrats,
    SUM(COALESCE(pd.total_paid, 0)) AS total_paid_region,
    SUM(ep.expected_total_paid) AS expected_total_paid_region,
    ROUND(
        SUM(COALESCE(pd.total_paid, 0)) / NULLIF(SUM(ep.expected_total_paid), 0) * 100,
        1
    ) AS taux_paiement_pct
FROM expected_par_contrat ep
LEFT JOIN paiements_a_date pd
    ON pd.contract_number = ep.contract_number AND pd.as_of_date = ep.as_of_date
GROUP BY ep.as_of_date, ep.region_norm
ORDER BY ep.as_of_date, taux_paiement_pct ASC;