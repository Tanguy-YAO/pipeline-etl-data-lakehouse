-- delta/recouvrement-views.sql
-- Couche de service de l'application de recouvrement (AppSheet)
-- v6, 16/10/2026
--
-- Changement v6 : règles GREENO alignées le 16/10/2026 après analyse de greenodb.
--   * Jointure greenodb : numéro de série, départagé par le téléphone (8 derniers
--     chiffres) ou le nom (au moins deux mots communs). 32 séries sont portées par
--     deux clients différents ; la v5 en rattachait certains au mauvais client.
--   * Clients migrés : date_activation = installation_date de greenodb ;
--     premiere_echeance = first_amt_date ; agent_credit_greeno = id_agent_credit.
--   * Acompte = « échéance 0 », datée un mois avant la première échéance : un
--     manque sur l'acompte entre dans le RAR, compte pour un mois manqué et fait
--     partir le retard de cette date (vérifié sur les 5 cas greenodb concernés,
--     au jour près : greenodb compte le retard depuis P1 - 1 mois).
--   * pending_repossession : retard cumulé figé le 1er du mois > 150 jours
--     (table recouvrement.gel_mensuel, conservée d'un passage à l'autre ;
--     octobre 2026 = retard_debut_mois de greenodb, puis figé par rafraichir()
--     au premier passage de chaque mois). Le client en sort seulement s'il a payé
--     depuis le gel ET que son retard cumulé est revenu à 179 jours ou moins.
--   * solde_jours (TEVIA et GREENO) : positif = jours de crédit restants,
--     0 = échéance aujourd'hui, négatif = jours de retard.
--   * jours_retard UPYA : calculé sur des dates entières (date du jour - date de
--     next_status_update, 0 si l'échéance est aujourd'hui ou plus tard) ; le CLD
--     source, calculé en heures, comptait un jour de moins selon l'heure.
--     SURGE garde consecutive_locked_days.
--   * GREENO : jours_manques_cumules = jours_retard_greeno.
--
-- v5, 15/10/2026
--
-- Changement v5 : retard GREENO cumulé sur échéancier fixe (règles validées par
--   Tanguy le 15/10/2026), pour les contrats upya_greeno uniquement :
--   * net payé = total payé - acompte ; mensualités fixes, sans tarif journalier ;
--   * échéances dues à T = mois écoulés depuis la première échéance + 1, plafonnées au
--     nombre total de mensualités ; l'échéance est due dès son jour ;
--   * RAR (reste à recouvrer) = échéances dues x mensualité - net payé, jamais négatif ;
--   * en retard dès qu'il manque un franc : un paiement partiel réduit le RAR mais le
--     client reste en retard ; mois manqués = PLAFOND(RAR / mensualité) ;
--   * PAR GREENO = mois manqués cumulés (tranche_retard) et RAR en numéraire (arriere) ;
--   * un client soldé n'a plus de retard.
--   Nouvelles colonnes GREENO (absentes de contrats_tevia) : echeances_dues_greeno,
--   mois_manques_greeno, rar_greeno, jours_retard_greeno, situation_paiement_greeno,
--   avance_greeno. Pour GREENO, attendu_a_date, arriere, tranche_ordre,
--   tranche_retard, perte_seuil_efa (> 4 mois) et perte_seuil_credit (>= 6 mois)
--   suivent ces règles ; TEVIA est inchangé.
--
-- v4.1, 14/10/2026
--
-- Changement v4.1 : contrats_tevia liste ses colonnes explicitement et n'expose plus
--   les trois colonnes propres à GREENO (reference_greeno, retard_debut_mois_greeno,
--   source_premiere_echeance). contrats_greeno garde toutes les colonnes.
--
-- Changement v4 : contrats GREENO.
--   * Nouvelle vue recouvrement.contrats_greeno (filtre entite = 'greeno').
--   * premiere_echeance GREENO : date installment_date de greenodb
--     (silver.greeno_client_contracts_greeno) quand le kit y figure, sinon règle du
--     jour d'installation (1-5 → 5 M+1, 6-15 → 15 M+1, 16-25 → 25 M+1,
--     26-31 → 5 M+2). Règle vérifiée sur 50 contrats greenodb : 49 conformes,
--     1 exception (installé le 26/03, P1 au 25/04) : greenodb prime donc.
--   * Jointure greenodb ↔ unified_contracts par numéro de kit réduit à ses
--     chiffres (certains numéros de série finissent par "A").
--   * Nouvelles colonnes : source_premiere_echeance (greenodb / regle_greeno /
--     regle_tevia), reference_greeno (account_ref), retard_debut_mois_greeno.
--
-- Changement v3.2 : remise à zéro complète du schéma en tête de fichier (tout
--   objet présent est supprimé, quel que soit l'état laissé par les essais),
--   entite nettoyée des espaces (LOWER(TRIM(...))), et contrôle final exécuté
--   en fin de fichier (dernier résultat affiché par pgAdmin).
--
-- Changement v3.1 : nouvelle colonne jours_manques_cumules.
--   Nombre total de jours sans crédit depuis l'activation, coupure en cours
--   comprise (jours_retard ne compte que la coupure en cours).
--   Le champ UPYA accumulatedLateDays n'est PAS utilisé : vérifié sur l'export
--   du 29/09/2026, il vaut 0 pour tous les contrats LOCKED et, pour les contrats
--   ENABLED récents, il égale le délai acompte → installation dans 88 % des cas.
--   Il compte donc l'attente d'installation et ignore la coupure en cours.
--   Limites du calcul DELTA : suppose 1 mensualité = 30 jours de crédit.
--   * Contrats UPYA anciens qui ont reçu plus de jours que le cash ne l'explique
--     (jours offerts, changement de tarif) : valeur surestimée.
--   * SURGE : total_paid inclut les pénalités de retard, valeur sous-estimée.
--
-- Changement v3 : la vue matérialisée est remplacée par une table.
--   Constat du 13/10/2026 : AppSheet ne lit pas les vues construites sur la vue
--   matérialisée (contrats_tevia, test_rec_contrats_tevia), alors qu'il lit une
--   vue simple branchée directement sur gold (vw_contrats). Une vue simple seule
--   recalculerait toute la chaîne à chaque synchronisation : c'est la lenteur
--   qu'on cherchait à supprimer. Une table ordinaire, remplie par la fonction de
--   rafraîchissement, garde les deux avantages : stockée et indexée comme la vue
--   matérialisée, et lisible par AppSheet comme n'importe quelle table.
--
--   Corrections par rapport au vw_contrats écrit le 13/10 :
--   * entite : LOWER(b.source) donnait 'upya'/'surge' au lieu de 'tevia'/'greeno'.
--     Corrigé en LOWER(b.entite).
--   * Tranches : la tranche "151-180 j" ne contenait que les contrats à 151 jours
--     exactement (condition <= 151) ; 152 à 179 tombaient dans "180 j et plus".
--     Corrigé, et la limite des 180 jours est alignée sur perte_seuil_credit.
--   * Conservé : le filtre asset_number IS NOT NULL ajouté le 13/10.
--
-- Architecture :
--   gold.unified_contracts ───┐
--                             ├─> recouvrement.vw_contrats   (vue simple : la logique,
--   gold.unified_transactions ┘     source de vérité des calculs)
--                                         │
--                         recouvrement.rafraichir()  copie le résultat
--                                         ▼
--                              recouvrement.contrats      (table : stockée, indexée,
--                                         │                 lue par AppSheet)
--                                         ▼
--                              recouvrement.contrats_tevia (vue simple : WHERE entite)
--
-- Périmètre :
--   PAYG, activé, avec un kit (asset_number), statut ENABLED ou LOCKED.
--   Catégories : upya_tevia, surge_tevia (portefeuille TEVIA), upya_greeno.
--
-- Règles de calcul : inchangées depuis la v2.1 (voir les commentaires du SELECT).
--   prochaine_echeance = next_status_update (vérifié : 94 % des contrats UPYA
--   récents égalent activation + 30 j + jours achetés) ; premiere_echeance =
--   date_activation + 30 j ; mois_ecoules = FLOOR(age_jours / 30) ;
--   nb_mois_payes = (total_paye - acompte) / mensualite.
--
-- Points ouverts :
--   * GREENO : arriere, attendu_a_date, nb_mois_payes et jours_manques_cumules
--     suivent encore la logique TEVIA (30 jours après activation). À aligner
--     sur premiere_echeance si l'équipe crédit le valide.
--   * Saisies de l'app (appels, promesses) : à stocker dans une table dédiée.


-- ---------------------------------------------------------------------------
-- 1. Remise à zéro : supprime TOUT ce que contient le schéma recouvrement
--    (vues, vues matérialisées, tables), quel que soit son état actuel.
--    Vues d'abord, puis vues matérialisées, puis tables. CASCADE emporte aussi
--    les objets d'autres schémas qui en dépendent (ex. une vue de test dans gold).
--    La fonction rafraichir() n'est pas une table : elle est recréée plus bas.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS recouvrement;

DO $$
DECLARE o record;
BEGIN
  FOR o IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'recouvrement'
      AND c.relkind IN ('v', 'm', 'r')
      AND c.relname <> 'gel_mensuel'   -- historique des gels : jamais supprimé
    ORDER BY CASE c.relkind WHEN 'v' THEN 1 WHEN 'm' THEN 2 ELSE 3 END
  LOOP
    EXECUTE format('DROP %s IF EXISTS recouvrement.%I CASCADE',
                   CASE o.relkind WHEN 'v' THEN 'VIEW'
                                  WHEN 'm' THEN 'MATERIALIZED VIEW'
                                  ELSE 'TABLE' END,
                   o.relname);
    RAISE NOTICE 'supprimé : %', o.relname;
  END LOOP;
END $$;

DROP VIEW IF EXISTS gold.test_rec_contrats_tevia;

-- Gel mensuel du retard cumulé (GREENO) : une ligne par contrat et par mois.
-- Créée une seule fois, jamais vidée par ce fichier : c'est un historique.
CREATE TABLE IF NOT EXISTS recouvrement.gel_mensuel (
    mois                     date    NOT NULL,   -- 1er jour du mois figé
    numero_contrat           text    NOT NULL,
    jours_retard_debut_mois  integer,
    source                   text    NOT NULL,   -- 'greenodb' (octobre 2026) ou 'delta'
    fige_le                  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (mois, numero_contrat)
);


-- ---------------------------------------------------------------------------
-- 2. Vue de calcul : toute la logique métier, une ligne par contrat
-- ---------------------------------------------------------------------------
CREATE VIEW recouvrement.vw_contrats AS
WITH paiements AS (
    SELECT
        t.contract_number::text                                   AS numero_contrat,
        t.payment_date,
        t.amount,
        ROW_NUMBER() OVER (PARTITION BY t.contract_number
                           ORDER BY t.payment_date DESC, t.transaction_id DESC) AS rang
    FROM gold.unified_transactions t
    WHERE t.normalized_reason IN ('recharge', 'upfront_payment')
      AND COALESCE(t.ignore_payment, false) = false
),
synthese_paiements AS (
    SELECT
        numero_contrat,
        COUNT(*)                                                  AS nb_paiements,
        MAX(payment_date)::date                                   AS date_dernier_paiement,
        MAX(amount) FILTER (WHERE rang = 1)                       AS montant_dernier_paiement,
        COALESCE(SUM(amount) FILTER (WHERE payment_date >= CURRENT_DATE - 30), 0)
                                                                  AS paye_30_derniers_jours
    FROM paiements
    GROUP BY numero_contrat
),
greeno_src AS (
    -- Clients greenodb : une ligne par client (account_ref), photo la plus récente.
    -- cle_kit = numéro de série réduit à ses chiffres ("868064077655410A" → "868064077655410")
    -- tel8    = 8 derniers chiffres du téléphone (2250757997665 et 0757997665 → 57997665)
    -- mots    = mots du nom en majuscules sans accents, de 2 lettres ou plus
    SELECT DISTINCT ON (account_ref)
        account_ref, id_agent_credit, cle_kit, tel8, mots,
        first_amt_date, installation_date, retard_debut_mois
    FROM (
        SELECT
            NULLIF(TRIM(account_ref), '')                         AS account_ref,
            NULLIF(TRIM(id_agent_credit::text), '')               AS id_agent_credit,
            regexp_replace(serial_number, '\D', '', 'g')          AS cle_kit,
            NULLIF(right(regexp_replace(COALESCE(phone_number::text, ''), '\D', '', 'g'), 8), '') AS tel8,
            ARRAY(SELECT m FROM regexp_split_to_table(
                      UPPER(translate(COALESCE(customer_name, ''),
                            'éèêëàâäîïôöùûüçÉÈÊËÀÂÄÎÏÔÖÙÛÜÇ',
                            'eeeeaaaiioouuucEEEEAAAIIOOUUUC')), '[^A-Z]+') m
                  WHERE length(m) >= 2)                           AS mots,
            first_amt_date::date                                  AS first_amt_date,
            installation_date::date                               AS installation_date,
            NULLIF(TRIM(retard_debut_mois::text), '')::int        AS retard_debut_mois,
            date_snapshot,
            loaded_at
        FROM silver.greeno_client_contracts_greeno
        WHERE serial_number IS NOT NULL
    ) g
    WHERE cle_kit <> '' AND account_ref IS NOT NULL
    ORDER BY account_ref, date_snapshot DESC, loaded_at DESC
),
upya_greeno AS (
    -- Contrats GREENO d'UPYA, avec les mêmes clés de rapprochement
    SELECT
        uc.contract_number::text                                  AS numero_contrat,
        regexp_replace(split_part(uc.asset_number::text, '.', 1), '\D', '', 'g') AS cle_kit,
        NULLIF(right(regexp_replace(split_part(COALESCE(uc.phone_number::text, ''),   '.', 1), '\D', '', 'g'), 8), '') AS tel8_1,
        NULLIF(right(regexp_replace(split_part(COALESCE(uc.phone_number_2::text, ''), '.', 1), '\D', '', 'g'), 8), '') AS tel8_2,
        ARRAY(SELECT m FROM regexp_split_to_table(
                  UPPER(translate(COALESCE(uc.customer_name, ''),
                        'éèêëàâäîïôöùûüçÉÈÊËÀÂÄÎÏÔÖÙÛÜÇ',
                        'eeeeaaaiioouuucEEEEAAAIIOOUUUC')), '[^A-Z]+') m
              WHERE length(m) >= 2)                               AS mots
    FROM gold.unified_contracts uc
    WHERE uc.categorie = 'upya_greeno'
      AND uc.asset_number IS NOT NULL
),
greeno_candidats AS (
    -- Toutes les paires contrat UPYA / client greenodb qui partagent un kit
    SELECT
        u.numero_contrat,
        g.*,
        (g.tel8 IS NOT NULL AND g.tel8 IN (u.tel8_1, u.tel8_2))   AS tel_ok,
        (SELECT COUNT(*) FROM (SELECT unnest(g.mots) INTERSECT SELECT unnest(u.mots)) x) >= 2
                                                                  AS nom_ok,
        COUNT(*) OVER (PARTITION BY u.numero_contrat)             AS nb_clients_greenodb_sur_kit,
        COUNT(*) OVER (PARTITION BY g.account_ref)                AS nb_contrats_upya_sur_kit
    FROM upya_greeno u
    JOIN greeno_src g ON g.cle_kit = u.cle_kit
    WHERE u.cle_kit <> ''
),
greeno_ext AS (
    -- Rattachement retenu, un client greenodb au plus par contrat :
    --   kit sans ambiguïté (un seul client de chaque côté) : accepté d'office ;
    --   kit partagé : seulement si le téléphone ou le nom concorde,
    --   le téléphone l'emportant sur le nom.
    SELECT DISTINCT ON (numero_contrat)
        numero_contrat, account_ref, id_agent_credit,
        first_amt_date, installation_date, retard_debut_mois
    FROM greeno_candidats
    WHERE tel_ok OR nom_ok
       OR (nb_clients_greenodb_sur_kit = 1 AND nb_contrats_upya_sur_kit = 1)
    ORDER BY numero_contrat, (tel_ok::int * 2 + nom_ok::int) DESC
),
base AS (
    SELECT
        uc.*,
        uc.contract_number::text                                  AS numero_contrat,
        -- Date d'activation : installation greenodb pour les clients GREENO migrés
        COALESCE(ge.installation_date, uc.registration_date::date) AS date_activation,
        uc.next_status_update::date                               AS prochaine_echeance,
        ge.account_ref                                            AS reference_greeno,
        ge.id_agent_credit                                        AS agent_credit_greeno,
        ge.retard_debut_mois                                      AS retard_debut_mois_greeno,
        -- Première échéance (P1)
        --   TEVIA  : activation + 30 jours
        --   GREENO : date greenodb si le kit y figure (elle prime : elle porte
        --            les exceptions), sinon règle du jour d'installation :
        --              1-5   → le 5  du mois suivant
        --              6-15  → le 15 du mois suivant
        --              16-25 → le 25 du mois suivant
        --              26-31 → le 5  du mois M+2
        CASE
            WHEN uc.categorie <> 'upya_greeno'
                THEN uc.registration_date::date + 30
            WHEN ge.first_amt_date IS NOT NULL
                THEN ge.first_amt_date
            ELSE (date_trunc('month', uc.registration_date::date)
                  + CASE
                        WHEN EXTRACT(DAY FROM uc.registration_date) <= 5  THEN INTERVAL '1 month 4 days'
                        WHEN EXTRACT(DAY FROM uc.registration_date) <= 15 THEN INTERVAL '1 month 14 days'
                        WHEN EXTRACT(DAY FROM uc.registration_date) <= 25 THEN INTERVAL '1 month 24 days'
                        ELSE INTERVAL '2 months 4 days'
                    END)::date
        END                                                       AS premiere_echeance,
        CASE
            WHEN uc.categorie <> 'upya_greeno'   THEN 'regle_tevia'
            WHEN ge.first_amt_date IS NOT NULL   THEN 'greenodb'
            ELSE 'regle_greeno'
        END                                                       AS source_premiere_echeance,
        -- Jours de blocage en cours
        --   UPYA  : en dates entières depuis next_status_update (0 si l'échéance est
        --           aujourd'hui ou plus tard) ; le CLD source, calculé en heures,
        --           comptait un jour de moins selon l'heure de l'échéance
        --   SURGE : consecutive_locked_days de l'export
        CASE
            WHEN uc.source = 'upya' AND uc.next_status_update IS NOT NULL
                THEN GREATEST(CURRENT_DATE - uc.next_status_update::date, 0)
            ELSE COALESCE(uc.consecutive_locked_days, 0)
        END                                                       AS jours_retard,
        CURRENT_DATE - COALESCE(ge.installation_date, uc.registration_date::date) AS age_jours,
        LEAST(
            uc.total_contract_value,
            uc.upfront_payment
              + GREATEST((CURRENT_DATE - uc.registration_date::date) - 30, 0)
                * (uc.monthly_payment / 30.0)
        )                                                         AS attendu_a_date
    FROM gold.unified_contracts uc
    LEFT JOIN greeno_ext ge
           ON uc.categorie = 'upya_greeno'
          AND ge.numero_contrat = uc.contract_number::text
    WHERE uc.categorie IN ('upya_tevia', 'surge_tevia', 'upya_greeno')
      AND uc.deal_type = 'PAYG'
      AND uc.contract_status IN ('ENABLED', 'LOCKED')
      AND uc.registration_date IS NOT NULL
      AND uc.asset_number IS NOT NULL
),
greeno_base AS (
    -- Échéancier fixe GREENO (règles validées par Tanguy le 15/10/2026)
    SELECT
        b.*,
        GREATEST(COALESCE(b.total_paid, 0) - COALESCE(b.upfront_payment, 0), 0)
                                                                  AS net_paye,
        ROUND((b.total_contract_value - b.upfront_payment)
              / NULLIF(b.monthly_payment, 0))::int                AS nb_mensualites,
        CASE
            WHEN b.categorie <> 'upya_greeno' OR b.monthly_payment IS NULL OR b.monthly_payment <= 0
                THEN NULL
            WHEN CURRENT_DATE < b.premiere_echeance
                THEN 0
            ELSE (EXTRACT(YEAR  FROM age(CURRENT_DATE, b.premiere_echeance)) * 12
                + EXTRACT(MONTH FROM age(CURRENT_DATE, b.premiere_echeance)))::int + 1
        END                                                       AS echeances_ecoulees
    FROM base b
),
greeno_calc AS (
    SELECT
        g.*,
        -- échéances dues : plafonnées au nombre total de mensualités
        LEAST(g.echeances_ecoulees, g.nb_mensualites)             AS echeances_dues_greeno,
        FLOOR(g.net_paye / NULLIF(g.monthly_payment, 0))::int     AS echeances_couvertes_greeno,
        -- échéance 0 : part de l'acompte non payée (datée P1 - 1 mois, comme greenodb)
        GREATEST(COALESCE(g.upfront_payment, 0) - COALESCE(g.total_paid, 0), 0)
                                                                  AS manque_acompte_greeno,
        -- soldé : acompte et mensualités entièrement payés, plus aucun retard
        (COALESCE(g.total_paid, 0) >= COALESCE(g.upfront_payment, 0)
         AND g.net_paye >= g.nb_mensualites * g.monthly_payment)  AS solde_greeno
    FROM greeno_base g
),
greeno_rar AS (
    SELECT
        c.*,
        -- stock d'arriéré (RAR) = manque sur l'acompte + mensualités échues non couvertes
        CASE
            WHEN c.echeances_ecoulees IS NULL THEN NULL
            WHEN c.solde_greeno               THEN 0
            ELSE c.manque_acompte_greeno
               + GREATEST(c.echeances_dues_greeno * c.monthly_payment - c.net_paye, 0)
        END                                                       AS rar_greeno,
        -- date de la plus ancienne échéance non couverte (acompte compris) :
        -- base des jours de retard (si passée) ou des jours restants (si à venir)
        CASE
            WHEN c.echeances_ecoulees IS NULL OR c.solde_greeno THEN NULL
            WHEN c.manque_acompte_greeno > 0
                THEN (c.premiere_echeance - INTERVAL '1 month')::date
            ELSE (c.premiere_echeance
                  + make_interval(months => c.echeances_couvertes_greeno))::date
        END                                                       AS echeance_non_couverte_greeno
    FROM greeno_calc c
),
greeno_final AS (
    SELECT
        r.*,
        -- échéances manquées : l'acompte incomplet compte pour une, et une
        -- mensualité payée en partie compte comme manquée
        CASE WHEN r.rar_greeno IS NULL THEN NULL
             ELSE (r.manque_acompte_greeno > 0)::int
                + CEIL(GREATEST(r.rar_greeno - r.manque_acompte_greeno, 0)
                       / NULLIF(r.monthly_payment, 0))::int
        END                                                       AS mois_manques_greeno,
        -- jours depuis la plus ancienne échéance non couverte (0 si à jour)
        CASE
            WHEN r.rar_greeno IS NULL THEN NULL
            WHEN r.rar_greeno = 0     THEN 0
            ELSE GREATEST(CURRENT_DATE - r.echeance_non_couverte_greeno, 0)
        END                                                       AS jours_retard_greeno,
        CASE
            WHEN r.rar_greeno IS NULL OR r.solde_greeno THEN NULL
            ELSE GREATEST(r.net_paye - r.echeances_dues_greeno * r.monthly_payment, 0)
        END                                                       AS avance_greeno
    FROM greeno_rar r
),
gel AS (
    -- Retard cumulé figé au 1er du mois en cours
    SELECT numero_contrat, jours_retard_debut_mois
    FROM recouvrement.gel_mensuel
    WHERE mois = date_trunc('month', CURRENT_DATE)::date
),
greeno_statut AS (
    SELECT
        f.*,
        gl.jours_retard_debut_mois                                AS retard_gele_mois,
        -- pending_repossession : figé au 1er du mois au-delà de 150 jours ;
        -- en sort seulement s'il a payé depuis le gel ET que son retard cumulé
        -- est revenu à 179 jours ou moins (ou s'il est soldé)
        (f.categorie = 'upya_greeno'
         AND COALESCE(gl.jours_retard_debut_mois, 0) > 150
         AND NOT COALESCE(f.solde_greeno, false)
         AND NOT (COALESCE(sp.date_dernier_paiement >= date_trunc('month', CURRENT_DATE)::date, false)
                  AND COALESCE(f.jours_retard_greeno, 0) <= 179))  AS pending_repossession
    FROM greeno_final f
    LEFT JOIN gel gl                ON gl.numero_contrat = f.numero_contrat
    LEFT JOIN synthese_paiements sp ON sp.numero_contrat = f.numero_contrat
),
telephones AS (
    -- Partie entière seulement (au cas où la colonne serait flottante),
    -- chiffres seuls ; le 0 initial est restauré dans le SELECT final
    SELECT
        numero_contrat,
        NULLIF(regexp_replace(split_part(phone_number::text,   '.', 1), '\D', '', 'g'), '') AS tel1,
        NULLIF(regexp_replace(split_part(phone_number_2::text, '.', 1), '\D', '', 'g'), '') AS tel2
    FROM base
)
SELECT
    -- Identité du contrat
    b.numero_contrat,
    LOWER(TRIM(b.entite))                                         AS entite,   -- tevia / greeno (jamais source), sans espaces parasites
    b.source,
    b.categorie,
    b.client_number                                               AS numero_client,
    b.customer_name                                               AS nom_client,
    CASE WHEN length(tp.tel1) = 9 THEN '0' || tp.tel1 ELSE tp.tel1 END AS telephone_1,
    CASE WHEN length(tp.tel2) = 9 THEN '0' || tp.tel2 ELSE tp.tel2 END AS telephone_2,
    b.agent_number                                                AS code_agent,
    b.agent_name                                                  AS nom_agent,
    b.product_name                                                AS produit,
    b.asset_number::text                                          AS numero_kit,
    b.reference_greeno,                                           -- account_ref greenodb (NULL hors GREENO)
    b.agent_credit_greeno,                                        -- id_agent_credit greenodb : agent qui suit le client
    b.retard_debut_mois_greeno,                                   -- retard au 01/10/2026 selon greenodb
    b.retard_gele_mois,                                           -- GREENO : retard cumulé figé au 1er du mois en cours
    b.echeances_dues_greeno,                                      -- GREENO : mensualités échues à date
    b.mois_manques_greeno,                                        -- GREENO : échéances manquées cumulées, acompte compris (base du PAR)
    ROUND(b.manque_acompte_greeno)                                AS manque_acompte_greeno,
    ROUND(b.rar_greeno)                                           AS rar_greeno,  -- GREENO : reste à recouvrer (stock d'arriéré)
    b.jours_retard_greeno,                                        -- GREENO : jours depuis la plus ancienne échéance impayée
    CASE
        WHEN b.categorie <> 'upya_greeno' OR b.rar_greeno IS NULL THEN NULL
        WHEN b.solde_greeno         THEN 'Soldé'
        WHEN b.pending_repossession THEN 'Pending repossession'
        WHEN b.rar_greeno > 0       THEN 'En retard'
        WHEN b.avance_greeno > 0    THEN 'En avance'
        ELSE 'À jour'
    END                                                           AS situation_paiement_greeno,
    b.pending_repossession,
    ROUND(b.avance_greeno)                                        AS avance_greeno,

    -- Localisation : région seule ("Région nawa" → "NAWA")
    -- (préfixe retiré AVANT UPPER : en locale C, UPPER ne majuscule pas é)
    NULLIF(UPPER(regexp_replace(TRIM(b.region), '^r(é|É|e)gion\s+', '', 'i')), '')
                                                                  AS region,

    -- Dates et échéances
    b.paid_date::date                                             AS date_paiement_acompte,
    b.date_activation,
    b.age_jours,
    FLOOR(b.age_jours / 30.0)::int                                AS mois_ecoules,
    b.premiere_echeance,
    b.source_premiere_echeance,
    b.prochaine_echeance,
    b.last_status_update::date                                    AS derniere_maj_statut,
    CASE WHEN b.contract_status = 'ENABLED'
         THEN GREATEST(b.prochaine_echeance - CURRENT_DATE, 0)
    END                                                           AS jours_credit_restants,
    -- Solde en jours, signé : +12 = 12 jours de crédit restants, 0 = échéance
    -- aujourd'hui, -35 = 35 jours de retard
    --   TEVIA  : date de next_status_update - date du jour
    --   GREENO : plus ancienne échéance non couverte (acompte compris) - date du jour ;
    --            NULL si soldé
    CASE WHEN b.categorie = 'upya_greeno'
         THEN b.echeance_non_couverte_greeno - CURRENT_DATE
         ELSE b.prochaine_echeance - CURRENT_DATE
    END                                                           AS solde_jours,
    (b.contract_status = 'ENABLED'
     AND b.prochaine_echeance - CURRENT_DATE BETWEEN 0 AND 3)     AS expire_sous_3_jours,

    -- Statut et retard
    b.contract_status                                             AS statut_contrat,
    b.jours_retard,
    -- Tranches de retard
    --   TEVIA  : jours de blocage consécutifs (jours_retard)
    --   GREENO : mensualités manquées cumulées (mois_manques_greeno), 1 mois ≈ 30 jours
    CASE
        WHEN b.categorie = 'upya_greeno' THEN LEAST(COALESCE(b.mois_manques_greeno, 0), 7)
        WHEN b.jours_retard = 0               THEN 0
        WHEN b.jours_retard <= 30             THEN 1
        WHEN b.jours_retard <= 60             THEN 2
        WHEN b.jours_retard <= 90             THEN 3
        WHEN b.jours_retard <= 120            THEN 4
        WHEN b.jours_retard <= 150            THEN 5
        WHEN b.jours_retard <  180            THEN 6
        ELSE 7
    END                                                           AS tranche_ordre,
    CASE
        WHEN b.categorie = 'upya_greeno' THEN
            CASE
                WHEN COALESCE(b.mois_manques_greeno, 0) = 0 THEN 'À jour'
                WHEN b.mois_manques_greeno = 1              THEN '1 mois manqué'
                WHEN b.mois_manques_greeno < 7              THEN b.mois_manques_greeno || ' mois manqués'
                ELSE '7 mois manqués et plus'
            END
        WHEN b.jours_retard = 0               THEN 'À jour'
        WHEN b.jours_retard <= 30             THEN '1-30 j'
        WHEN b.jours_retard <= 60             THEN '31-60 j'
        WHEN b.jours_retard <= 90             THEN '61-90 j'
        WHEN b.jours_retard <= 120            THEN '91-120 j'
        WHEN b.jours_retard <= 150            THEN '121-150 j'
        WHEN b.jours_retard <  180            THEN '151-179 j'
        ELSE '180 j et plus'                       -- même limite que perte_seuil_credit
    END                                                           AS tranche_retard,
    -- Seuils de perte : GREENO en mensualités manquées (4 mois ≈ 120 j, 6 mois ≈ 180 j)
    CASE WHEN b.categorie = 'upya_greeno' THEN COALESCE(b.mois_manques_greeno, 0) > 4
         ELSE b.jours_retard > 120 END                            AS perte_seuil_efa,
    CASE WHEN b.categorie = 'upya_greeno' THEN COALESCE(b.mois_manques_greeno, 0) >= 6
         ELSE b.jours_retard >= 180 END                           AS perte_seuil_credit,
    (b.consecutive_locked_days IS NULL)                           AS jours_retard_inconnu,
    -- Jours sans crédit depuis l'activation, coupure en cours comprise.
    --   GREENO : jours_retard_greeno (retard cumulé sur l'échéancier fixe)
    --   TEVIA  : jours écoulés - jours déjà consommés, où jours consommés = jours
    --   achetés (30 j d'acompte + paiements nets / tarif journalier) - crédit
    --   restant. Plafonné à age_jours, puis jamais inférieur à jours_retard : la
    --   coupure en cours (donnée UPYA) prime, même si les dates source sont incohérentes.
    CASE WHEN b.categorie = 'upya_greeno' THEN COALESCE(b.jours_retard_greeno, 0) ELSE
    GREATEST(
        LEAST(
            b.age_jours,
            ROUND(
                b.age_jours
                - (30 + GREATEST(COALESCE(b.total_paid, 0) - COALESCE(b.upfront_payment, 0), 0)
                        * 30.0 / NULLIF(b.monthly_payment, 0))
                + CASE WHEN b.contract_status = 'ENABLED'
                       THEN GREATEST(b.prochaine_echeance - CURRENT_DATE, 0) ELSE 0 END
            )::int
        ),
        b.jours_retard
    ) END                                                         AS jours_manques_cumules,

    -- Montants (XOF)
    b.total_contract_value                                        AS valeur_contrat,
    b.upfront_payment                                             AS acompte,
    b.monthly_payment                                             AS mensualite,
    ROUND(b.monthly_payment / 30.0)                               AS tarif_journalier,
    b.total_paid                                                  AS total_paye,
    b.remaining_debt                                              AS reste_a_payer,
    ROUND(100.0 * b.total_paid / NULLIF(b.total_contract_value, 0), 1)
                                                                  AS pct_rembourse,
    ROUND(GREATEST(COALESCE(b.total_paid, 0) - COALESCE(b.upfront_payment, 0), 0)
          / NULLIF(b.monthly_payment, 0), 2)                      AS nb_mois_payes,
    CEIL(b.remaining_debt / NULLIF(b.monthly_payment, 0))::int   AS mensualites_restantes,
    -- Attendu et arriéré
    --   TEVIA  : acompte + accrual journalier après 30 jours de grâce
    --   GREENO : acompte + mensualités fixes échues (paliers) ; arriéré = RAR
    ROUND(CASE WHEN b.categorie = 'upya_greeno'
               THEN b.upfront_payment + b.echeances_dues_greeno * b.monthly_payment
               ELSE b.attendu_a_date END)                         AS attendu_a_date,
    ROUND(CASE WHEN b.categorie = 'upya_greeno'
               THEN b.rar_greeno
               ELSE GREATEST(b.attendu_a_date - COALESCE(b.total_paid, 0), 0) END)
                                                                  AS arriere,

    -- Paiements
    sp.date_dernier_paiement,
    sp.montant_dernier_paiement,
    CURRENT_DATE - sp.date_dernier_paiement                       AS jours_depuis_dernier_paiement,
    COALESCE(sp.nb_paiements, 0)                                  AS nb_paiements,
    COALESCE(sp.paye_30_derniers_jours, 0)                        AS paye_30_derniers_jours,

    -- Fraîcheur : dans la table, now() fige l'heure du rafraîchissement
    b.computed_at                                                 AS source_calculee_le,
    now()                                                         AS rafraichi_le
FROM greeno_statut b
JOIN telephones tp              ON tp.numero_contrat = b.numero_contrat
LEFT JOIN synthese_paiements sp ON sp.numero_contrat = b.numero_contrat;


-- ---------------------------------------------------------------------------
-- 3. Table de service : copie stockée de vw_contrats, lue par AppSheet
--    Mêmes colonnes et mêmes types que la vue, créés automatiquement.
-- ---------------------------------------------------------------------------
CREATE TABLE recouvrement.contrats AS
SELECT * FROM recouvrement.vw_contrats;

-- Clé primaire : AppSheet la détecte comme colonne clé
ALTER TABLE recouvrement.contrats ADD PRIMARY KEY (numero_contrat);
CREATE INDEX idx_rec_contrats_entite ON recouvrement.contrats (entite);
CREATE INDEX idx_rec_contrats_agent  ON recouvrement.contrats (code_agent);

-- Gel d'octobre 2026 : retard_debut_mois de greenodb (photo du 01/10/2026).
-- Sans effet si le mois est déjà figé (ON CONFLICT DO NOTHING).
-- La table contrats vient d'être créée : pending_repossession y est encore faux
-- tant que ce gel n'existait pas, d'où le rafraîchissement juste après.
INSERT INTO recouvrement.gel_mensuel (mois, numero_contrat, jours_retard_debut_mois, source)
SELECT DATE '2026-10-01', numero_contrat, retard_debut_mois_greeno, 'greenodb'
FROM recouvrement.contrats
WHERE entite = 'greeno'
  AND retard_debut_mois_greeno IS NOT NULL
ON CONFLICT (mois, numero_contrat) DO NOTHING;


-- ---------------------------------------------------------------------------
-- 4. Vue lue par l'app TEVIA (un simple filtre sur la table)
-- ---------------------------------------------------------------------------
CREATE VIEW recouvrement.contrats_tevia AS
-- Colonnes listées explicitement : les colonnes propres à GREENO
-- (reference_greeno, retard_debut_mois_greeno, source_premiere_echeance) sont exclues.
SELECT
    numero_contrat, entite, source, categorie,
    numero_client, nom_client, telephone_1, telephone_2,
    code_agent, nom_agent, produit, numero_kit,
    region, date_paiement_acompte, date_activation, age_jours,
    mois_ecoules, premiere_echeance, prochaine_echeance, derniere_maj_statut,
    jours_credit_restants, solde_jours, expire_sous_3_jours, statut_contrat, jours_retard,
    tranche_ordre, tranche_retard, perte_seuil_efa, perte_seuil_credit,
    jours_retard_inconnu, jours_manques_cumules, valeur_contrat, acompte,
    mensualite, tarif_journalier, total_paye, reste_a_payer,
    pct_rembourse, nb_mois_payes, mensualites_restantes, attendu_a_date,
    arriere, date_dernier_paiement, montant_dernier_paiement, jours_depuis_dernier_paiement,
    nb_paiements, paye_30_derniers_jours, source_calculee_le, rafraichi_le
FROM recouvrement.contrats
WHERE entite = 'tevia';

CREATE VIEW recouvrement.contrats_greeno AS
SELECT * FROM recouvrement.contrats WHERE entite = 'greeno';


-- ---------------------------------------------------------------------------
-- 5. Rafraîchissement
--    Même nom qu'avant : l'étape du workflow GitHub ne change pas.
--    DELETE puis INSERT dans une seule transaction (le corps d'une fonction
--    s'exécute d'un bloc) : pendant le recalcul, AppSheet continue de lire
--    l'ancienne version ; la nouvelle apparaît d'un coup à la fin.
--    Un TRUNCATE serait plus rapide mais bloquerait les lectures.
--    v6 : au premier passage de chaque mois, le retard cumulé GREENO est d'abord
--    figé dans gel_mensuel (base de pending_repossession pour tout le mois).
--    Le pipeline passe vers 02h30 UTC : le gel se fait normalement le 1er ;
--    si le pipeline échoue ce jour-là, il se fait au passage suivant.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS recouvrement.rafraichir();
CREATE FUNCTION recouvrement.rafraichir()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM recouvrement.gel_mensuel
                   WHERE mois = date_trunc('month', CURRENT_DATE)::date) THEN
        INSERT INTO recouvrement.gel_mensuel (mois, numero_contrat, jours_retard_debut_mois, source)
        SELECT date_trunc('month', CURRENT_DATE)::date, numero_contrat, jours_retard_greeno, 'delta'
        FROM recouvrement.vw_contrats
        WHERE entite = 'greeno'
          AND jours_retard_greeno IS NOT NULL;
    END IF;

    DELETE FROM recouvrement.contrats;
    INSERT INTO recouvrement.contrats SELECT * FROM recouvrement.vw_contrats;
END;
$$;

-- Premier remplissage avec le gel d'octobre en place
SELECT recouvrement.rafraichir();


-- ---------------------------------------------------------------------------
-- 6. Droits
--    Les privilèges par défaut du schéma couvrent déjà les objets créés par
--    postgres. GRANT explicite par sécurité.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA recouvrement TO role_read, lucien;
GRANT SELECT ON recouvrement.contrats, recouvrement.contrats_tevia,
                recouvrement.contrats_greeno, recouvrement.vw_contrats,
                recouvrement.gel_mensuel
    TO role_read, lucien;


-- ---------------------------------------------------------------------------
-- 7. Contrôles
-- ---------------------------------------------------------------------------
-- a. La table égale la vue de calcul (les deux nombres doivent être identiques)
-- SELECT (SELECT COUNT(*) FROM recouvrement.contrats)   AS table_contrats,
--        (SELECT COUNT(*) FROM recouvrement.vw_contrats) AS vue_calcul;
--
-- b. Le split entité est bon (tevia et greeno, jamais upya/surge)
-- SELECT entite, categorie, COUNT(*) FROM recouvrement.contrats GROUP BY 1, 2 ORDER BY 1, 2;
--
-- c. Répartition par tranche, 151-179 doit maintenant être peuplée
-- SELECT tranche_ordre, tranche_retard, COUNT(*), MIN(jours_retard), MAX(jours_retard)
-- FROM recouvrement.contrats GROUP BY 1, 2 ORDER BY 1;
--
-- d. jours_manques_cumules : jamais sous jours_retard (incoherents doit valoir 0) ;
--    depasse_age compte les contrats dont la coupure en cours dépasse l'âge
--    depuis l'activation (dates source incohérentes, à signaler à l'équipe CRM)
-- SELECT COUNT(*) FILTER (WHERE jours_manques_cumules < jours_retard) AS incoherents,
--        COUNT(*) FILTER (WHERE jours_manques_cumules > age_jours)    AS depasse_age
-- FROM recouvrement.contrats;
-- SELECT categorie, statut_contrat,
--        ROUND(AVG(jours_retard))          AS retard_moyen,
--        ROUND(AVG(jours_manques_cumules)) AS manques_cumules_moyen,
--        MAX(jours_manques_cumules)        AS manques_cumules_max
-- FROM recouvrement.contrats GROUP BY 1, 2 ORDER BY 1, 2;
--
-- e. GREENO : rattachement à greenodb (attendu : ~2 078 'greenodb')
-- SELECT source_premiere_echeance, COUNT(*)
-- FROM recouvrement.contrats_greeno GROUP BY 1;
--    Kits greenodb absents des contrats GREENO (à investiguer s'il y en a)
-- SELECT COUNT(*) FROM silver.greeno_client_contracts_greeno g
-- WHERE NOT EXISTS (SELECT 1 FROM recouvrement.contrats_greeno c
--                   WHERE regexp_replace(c.numero_kit, '\D', '', 'g')
--                       = regexp_replace(g.serial_number, '\D', '', 'g'));
--    (comparer les deux numéros nettoyés : certains numero_kit gardent un suffixe,
--     ex. 868064077653886A ; vérifié le 14/10 : les 59 kits greenodb hors vue sont
--     46 contrats soldés ou repossédés et 13 faux écarts dus à ce suffixe)
--
-- f. Heure du dernier rafraîchissement
-- SELECT MAX(rafraichi_le) FROM recouvrement.contrats;
--
-- Si la structure de vw_contrats change (colonne ajoutée ou renommée) :
-- relancer tout ce fichier (la table est recréée à partir de la vue),
-- puis "Regenerate structure" dans AppSheet.


-- ---------------------------------------------------------------------------
-- 8. Contrôle final (dernier résultat affiché par pgAdmin)
--    vue_calcul = table_contrats ; vue_tevia > 0 ; lucien_lit_tevia = true
-- ---------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM recouvrement.vw_contrats)    AS vue_calcul,
       (SELECT COUNT(*) FROM recouvrement.contrats)       AS table_contrats,
       (SELECT COUNT(*) FROM recouvrement.contrats_tevia) AS vue_tevia,
       (SELECT COUNT(*) FROM recouvrement.contrats_greeno) AS vue_greeno,
       (SELECT COUNT(*) FROM recouvrement.contrats_greeno
         WHERE source_premiere_echeance = 'greenodb')     AS greeno_rattaches_greenodb,
       (SELECT COUNT(*) FROM recouvrement.contrats_greeno
         WHERE pending_repossession)                      AS greeno_pending_repossession,
       has_table_privilege('lucien', 'recouvrement.contrats_tevia', 'SELECT') AS lucien_lit_tevia;