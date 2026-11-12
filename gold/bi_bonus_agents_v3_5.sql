-- ============================================================================
-- bi-bonus-agents-v3.5.sql  (12/11/2026)
-- Données du bonus des agents de recouvrement TEVIA, à une date de photo
-- choisie dans Metabase (filtre Photo du tableau de bord COMITE CREDIT).
--
-- 1. bi.v_bonus_a_jour : clients installés 2 ou 3 mois avant la photo, en
--    mois calendaires (photo du 31/10 : 3 mois = installés en juillet,
--    2 mois = installés en août), avec leur situation à la photo.
--    À jour = actif sans aucun jour de retard (consécutif), ou soldé.
-- 2. bi.v_bonus_recouvrement_90j : clients en retard de plus de 90 jours au
--    début du mois de la photo, et ce qu'ils ont payé (recharges) entre le
--    début du mois et la date de la photo. Début du mois = dernière photo du
--    mois précédent ; à défaut, première photo du mois (octobre 2026 : 01/10,
--    l'historique commençant ce jour-là).
-- Périmètre : Comité TEVIA (upya_tevia + surge_tevia). Agents : agent de
-- recouvrement actuel (règle des acteurs du tableau de bord).
--
-- Exécution : tout le fichier d'un bloc dans pgAdmin (quelques secondes).
-- ============================================================================

CREATE OR REPLACE VIEW bi.v_bonus_a_jour AS
SELECT
    ch.photo,
    p.date_photo,
    ((extract(year FROM p.date_photo) * 12 + extract(month FROM p.date_photo))
     - (extract(year FROM p.date_activation) * 12 + extract(month FROM p.date_activation)))::int
                                                    AS mois_apres_installation,
    p.numero_contrat,
    p.nom_client,
    p.telephone,
    p.categorie,
    p.produit,
    p.agent_recouvrement,
    p.commercial,
    p.regional,
    p.dsm,
    p.technicien,
    p.date_activation,
    p.cohorte,
    p.statut_kit,
    p.jours_retard,
    p.tranche_retard,
    p.classe_s1                                     AS statut_paiement,
    p.reste_a_payer,
    CASE WHEN (p.actif AND p.jours_retard = 0)
           OR p.statut_kit IN ('PAID_OFF', 'PAIDOFF') THEN 'À jour'
         ELSE 'Pas à jour' END                      AS situation,
    1                                               AS nb_clients,
    CASE WHEN (p.actif AND p.jours_retard = 0)
           OR p.statut_kit IN ('PAID_OFF', 'PAIDOFF') THEN 1 ELSE 0 END AS nb_a_jour
FROM bi.v_choix_photo ch
JOIN bi.v_portefeuille_date p ON p.date_photo = ch.date_photo
WHERE p.perimetre = 'Comité TEVIA'
  AND ((extract(year FROM p.date_photo) * 12 + extract(month FROM p.date_photo))
       - (extract(year FROM p.date_activation) * 12 + extract(month FROM p.date_activation))) IN (2, 3);


CREATE OR REPLACE VIEW bi.v_bonus_recouvrement_90j AS
WITH ph AS (
    SELECT ch.photo,
           ch.date_photo,
           COALESCE(
               (SELECT MAX(date_photo) FROM bi.calendrier
                 WHERE date_photo < date_trunc('month', ch.date_photo)::date),
               (SELECT MIN(date_photo) FROM bi.calendrier
                 WHERE date_photo >= date_trunc('month', ch.date_photo)::date)) AS date_depart
    FROM bi.v_choix_photo ch
)
SELECT
    ph.photo,
    ph.date_photo,
    ph.date_depart,
    p0.numero_contrat,
    p0.nom_client,
    p0.telephone,
    p0.categorie,
    p0.produit,
    p0.agent_recouvrement,
    p0.commercial,
    p0.regional,
    p0.dsm,
    p0.jours_retard                                 AS jours_retard_depart,
    p0.tranche_retard                               AS tranche_depart,
    p0.reste_a_payer                                AS encours_depart,
    COALESCE(pay.montant, 0)                        AS montant_paye,
    COALESCE(pay.nb, 0)                             AS nb_paiements,
    CASE WHEN COALESCE(pay.montant, 0) > 0 THEN 1 ELSE 0 END AS nb_payeurs,
    1                                               AS nb_clients
FROM ph
JOIN bi.v_portefeuille_date p0
  ON p0.date_photo = ph.date_depart
 AND p0.perimetre = 'Comité TEVIA'
 AND p0.actif
 AND p0.jours_retard > 90
LEFT JOIN LATERAL (
    SELECT SUM(c.montant) AS montant, COUNT(*) AS nb
    FROM bi.collecte c
    WHERE c.numero_contrat = p0.numero_contrat
      AND c.type_paiement = 'Recharge'
      AND c.date_paiement >  ph.date_depart
      AND c.date_paiement <= ph.date_photo
) pay ON true;

GRANT SELECT ON bi.v_bonus_a_jour, bi.v_bonus_recouvrement_90j TO role_read;

-- Contrôles au 31/10
SELECT mois_apres_installation, agent_recouvrement, SUM(nb_clients) AS clients, SUM(nb_a_jour) AS a_jour,
       ROUND(100.0 * SUM(nb_a_jour) / SUM(nb_clients), 1) AS taux
FROM bi.v_bonus_a_jour WHERE date_photo = DATE '2026-10-31' AND photo <> 'Dernière photo'
GROUP BY ROLLUP (1, 2) ORDER BY 1, 2;

SELECT agent_recouvrement, SUM(nb_clients) AS clients_90j, SUM(nb_payeurs) AS payeurs,
       ROUND(SUM(encours_depart)) AS encours_depart, ROUND(SUM(montant_paye)) AS montant_paye
FROM bi.v_bonus_recouvrement_90j WHERE date_photo = DATE '2026-10-31' AND photo <> 'Dernière photo'
GROUP BY ROLLUP (1) ORDER BY 1;
