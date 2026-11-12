-- ============================================================================
-- bi-statut-paiement-v3.4.sql  (12/11/2026)
-- Statut de paiement (ex « classe S1 ») aligné sur le retard consécutif.
--
-- Décision (12/11/2026) : le retard se lit en jours consécutifs pour tous les
-- clients, quelle que soit la catégorie. Le statut de paiement suit donc le
-- retard : seul un client en retard peut avoir des jours de retard.
--   1. En avance       : aucun jour de retard et payé > attendu
--                        (attendu = acompte + mensualité × (mois complets − 1))
--   2. À jour          : aucun jour de retard, sans avance sur l'attendu
--   3. En retard       : au moins un jour de retard consécutif
--   4. Retard inconnu  : actif sans date permettant de calculer le retard
-- Montant en retard (colonne arriere_s1) : jours de retard × mensualité / 30,
--   plafonné au reste à payer ; 0 hors « En retard ».
-- Noms de colonnes inchangés (classe_s1, arriere_s1) : les vues dépendantes
--   et les questions Metabase restent valides ; les libellés sont renommés
--   dans Metabase (« Statut de paiement », « Montant en retard »).
--
-- Exécution : tout le fichier d'un bloc dans pgAdmin (quelques secondes).
-- ============================================================================

CREATE OR REPLACE VIEW bi.v_portefeuille_date AS
 SELECT c.date_photo,
    e.numero_contrat,
    COALESCE(a.entite, r.entite, 'Non classé'::text) AS entite,
    e.categorie,
    COALESCE(a.crm, r.crm) AS crm,
        CASE
            WHEN e.categorie = ANY (ARRAY['upya_tevia'::text, 'surge_tevia'::text]) THEN 'Comité TEVIA'::text
            WHEN e.categorie = 'upya_greeno'::text THEN 'Comité GREENO'::text
            ELSE 'Hors comité'::text
        END AS perimetre,
    COALESCE(a.produit, 'Non renseigné'::text) AS produit,
    COALESCE(a.region, 'Non renseignée'::text) AS region,
    COALESCE(a.commercial, 'Non renseigné'::text) AS commercial,
    COALESCE(a.regional, 'Non rattaché'::text) AS regional,
    COALESCE(a.dsm, 'Non rattaché'::text) AS dsm,
    COALESCE(a.technicien, 'Non renseigné'::text) AS technicien,
    COALESCE(a.agent_recouvrement, 'Non attribué'::text) AS agent_recouvrement,
        CASE
            WHEN e.date_activation < '2026-01-01'::date THEN to_char(e.date_activation::timestamp with time zone, 'YYYY'::text)
            ELSE to_char(e.date_activation::timestamp with time zone, 'YYYY-MM'::text)
        END AS cohorte,
        CASE
            WHEN e.date_activation < '2026-01-01'::date THEN date_trunc('year'::text, e.date_activation::timestamp with time zone)::date
            ELSE date_trunc('month'::text, e.date_activation::timestamp with time zone)::date
        END AS cohorte_debut,
    e.statut_kit,
    k.actif,
    e.date_activation,
    k.age AS age_jours,
    k.retard AS jours_retard,
        CASE
            WHEN k.actif THEN credit.tranche(k.retard)
            ELSE 'Hors portefeuille actif'::text
        END AS tranche_retard,
    k.valeur AS valeur_contrat,
    k.acpt AS acompte,
    k.mens AS mensualite,
    k.paye AS total_paye,
    k.reste AS reste_a_payer,
        CASE
            WHEN k.actif THEN 1
            ELSE 0
        END AS nb_actifs,
        CASE
            WHEN k.actif THEN k.reste
            ELSE 0::numeric
        END AS encours,
        CASE
            WHEN k.actif AND k.retard > 0 THEN k.reste
            ELSE 0::numeric
        END AS encours_par1,
        CASE
            WHEN k.actif AND k.retard > 30 THEN k.reste
            ELSE 0::numeric
        END AS encours_par30,
        CASE
            WHEN k.actif AND k.retard > 60 THEN k.reste
            ELSE 0::numeric
        END AS encours_par60,
        CASE
            WHEN k.actif AND k.retard > 90 THEN k.reste
            ELSE 0::numeric
        END AS encours_par90,
        CASE
            WHEN k.actif AND k.retard > 120 THEN k.reste
            ELSE 0::numeric
        END AS encours_par120,
        CASE
            WHEN k.actif AND k.retard >= 180 THEN k.reste
            ELSE 0::numeric
        END AS encours_par180,
        CASE
            WHEN k.actif AND k.retard IS NULL THEN 1
            ELSE 0
        END AS nb_retard_inconnu,
    k.fpd AS statut_fpd,
        CASE
            WHEN k.fpd <> 'Non évaluable'::text THEN 1
            ELSE 0
        END AS nb_fpd_evaluables,
        CASE
            WHEN k.fpd = 'FPD strict'::text AND COALESCE(k.retard, 0) < 120 THEN 1
            ELSE 0
        END AS nb_fpd_strict,
        CASE
            WHEN k.fpd = 'FPD partiel'::text AND COALESCE(k.retard, 0) < 120 THEN 1
            ELSE 0
        END AS nb_fpd_partiel,
        CASE
            WHEN (k.fpd = ANY (ARRAY['FPD strict'::text, 'FPD partiel'::text])) AND COALESCE(k.retard, 0) < 120 THEN 1
            ELSE 0
        END AS nb_fpd,
        CASE
            WHEN (k.fpd = ANY (ARRAY['FPD strict'::text, 'FPD partiel'::text])) AND COALESCE(k.retard, 0) >= 120 THEN 1
            ELSE 0
        END AS nb_fpd_120_plus,
        CASE
            WHEN (k.fpd = ANY (ARRAY['FPD strict'::text, 'FPD partiel'::text])) AND COALESCE(k.retard, 0) < 120 THEN k.reste
            ELSE 0::numeric
        END AS encours_fpd,
        -- v3.4 : statut de paiement aligné sur le retard consécutif
        CASE
            WHEN NOT k.actif THEN 'Hors portefeuille actif'::text
            WHEN k.retard IS NULL THEN '4. Retard inconnu'::text
            WHEN k.retard > 0 THEN '3. En retard'::text
            WHEN k.paye > k.att THEN '1. En avance'::text
            ELSE '2. À jour'::text
        END AS classe_s1,
        CASE
            WHEN k.actif THEN k.att
            ELSE 0::numeric
        END AS attendu_s1,
        -- v3.4 : montant en retard = jours de retard × mensualité / 30, plafonné au reste
        CASE
            WHEN k.actif AND k.retard > 0 THEN LEAST(round(k.retard::numeric * k.mens / 30.0), k.reste)
            ELSE 0::numeric
        END AS arriere_s1,
        CASE
            WHEN e.statut_kit = 'REPOSSESSED'::text THEN 0::numeric
            ELSE LEAST(k.valeur, k.acpt + k.mens / 30.0 * GREATEST(k.age - 30, 0)::numeric)
        END AS attendu_vintage,
        CASE
            WHEN e.statut_kit = ANY (ARRAY['PAID_OFF'::text, 'PAIDOFF'::text]) THEN 1
            ELSE 0
        END AS nb_soldes,
        CASE
            WHEN e.statut_kit = 'REPOSSESSED'::text THEN 1
            ELSE 0
        END AS nb_repris,
    a.nom_client,
    a.telephone
   FROM bi.calendrier c
     JOIN bi.contrat_etat e ON daterange(e.valide_du, e.valide_au, '[)'::text) @> c.date_photo
     LEFT JOIN bi.contrat_attributs a ON a.numero_contrat = e.numero_contrat AND daterange(a.valide_du, a.valide_au, '[)'::text) @> c.date_photo
     LEFT JOIN bi.ref_source_crm r ON r.source_crm = e.categorie
     CROSS JOIN LATERAL ( SELECT b.actif,
            b.age,
            b.retard,
            b.valeur,
            b.acpt,
            b.mens,
            b.reste,
            b.paye,
                CASE
                    WHEN NOT b.actif OR b.age <= 30 THEN 'Non évaluable'::text
                    WHEN (b.paye - b.acpt) <= 0::numeric THEN 'FPD strict'::text
                    WHEN (b.paye - b.acpt) < b.mens THEN 'FPD partiel'::text
                    ELSE 'Non FPD'::text
                END AS fpd,
            b.acpt + b.mens * GREATEST(floor(b.age::numeric / 30.0) - 1::numeric, 0::numeric) AS att
           FROM ( SELECT e.statut_kit = ANY (ARRAY['ENABLED'::text, 'LOCKED'::text]) AS actif,
                    c.date_photo - e.date_activation AS age,
                        CASE
                            WHEN e.statut_kit <> ALL (ARRAY['ENABLED'::text, 'LOCKED'::text]) THEN NULL::integer
                            WHEN e.source = 'surge'::text THEN COALESCE(c.date_photo - e.debut_blocage, 0)
                            WHEN e.fin_credit IS NULL THEN c.date_photo - e.debut_blocage
                            ELSE GREATEST(c.date_photo - e.fin_credit, 0)
                        END AS retard,
                    COALESCE(a.valeur_contrat, 0::numeric) AS valeur,
                    COALESCE(a.acompte, 0::numeric) AS acpt,
                    COALESCE(a.mensualite, 0::numeric) AS mens,
                    COALESCE(e.reste_a_payer, 0::numeric) AS reste,
                    GREATEST(COALESCE(a.valeur_contrat, 0::numeric) - COALESCE(e.reste_a_payer, 0::numeric), 0::numeric) AS paye) b) k;

-- Contrôle : statut de paiement × tranche, dernière photo, périmètres du comité
SELECT perimetre, classe_s1 AS statut_paiement, tranche_retard,
       SUM(nb_actifs) AS actifs, ROUND(SUM(encours)) AS encours, ROUND(SUM(arriere_s1)) AS montant_en_retard
FROM bi.v_portefeuille
WHERE photo = 'Dernière photo' AND perimetre <> 'Hors comité'
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
