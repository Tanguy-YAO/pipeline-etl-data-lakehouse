-- ============================================================================
-- pdg-dictionnaire-v3.sql  (12/11/2026)  d'un bloc dans pgAdmin
-- Dictionnaire des indicateurs à jour : commandes payées, deposits réellement
-- payés, PAR30 global, PAR30 hors write-off, statut de paiement, retard
-- consécutif pour toutes les entités. Ajoute une colonne d'ordre d'affichage.
-- ============================================================================

ALTER TABLE pdg.dictionnaire ADD COLUMN IF NOT EXISTS ordre int;
TRUNCATE pdg.dictionnaire;
INSERT INTO pdg.dictionnaire (ordre, indicateur, definition, calcul, source) VALUES
( 1, 'Entité', 'TEVIA (upya_tevia, surge_tevia, surge_zeci), GREENO (upya_greeno) ou NEoTCI (surge_neotci, migré de SURGE vers UPYA le 01/11/2026).', 'Catégorie CRM du contrat', 'bi.ref_source_crm'),
( 2, 'Commande payée', 'Contrat signé dans UPYA, deposit réglé, daté du jour de signature. Les contrats migrés de SURGE (numéros T…, N…) ne sont pas des commandes payées.', 'Nombre de contrats signés', 'pdg.v_ventes_installations_jour.ventes'),
( 3, 'Valeur des commandes payées', 'Deposits réellement payés par les commandes payées, tous paiements de deposit acceptés, quelle que soit leur date. Ce n''est pas le montant prévu au contrat.', 'Somme des deposits payés par ces contrats', 'pdg.v_ventes_installations_jour.valeur_ventes'),
( 4, 'Installation', 'Premier déploiement d''un kit pour le contrat.', 'Nombre de contrats au premier déploiement', 'pdg.v_ventes_installations_jour.installations'),
( 5, 'Délai commande payée → installation', 'Jours entre la signature et le premier déploiement du kit.', 'date d''installation − date de signature', 'COMMANDES & INSTALLATIONS'),
( 6, 'Deposit', 'Paiement initial versé à la commande, parfois en plusieurs fois (surtout GREENO).', 'Somme des paiements de type Deposit', 'pdg.v_collecte_jour'),
( 7, 'Recharge', 'Paiement de remboursement du crédit par le client.', 'Somme des paiements de type Recharge', 'pdg.v_collecte_jour'),
( 8, 'Encaissements', 'Recharges et deposits acceptés sur la période.', 'Recharges + deposits', 'pdg.v_kpi_mensuel.encaissements'),
( 9, 'Contrat actif', 'Contrat PAYG activé dont le kit est ENABLED (fonctionne) ou LOCKED (coupé faute de paiement). Un kit bloqué reste actif tant qu''il n''est ni repris ni soldé.', 'statut ENABLED ou LOCKED', 'pdg.v_portefeuille_jour.actifs'),
(10, 'Encours', 'Ce que les clients actifs doivent encore payer jusqu''à la fin de leur contrat.', 'Somme des restes à payer des actifs', 'pdg.v_portefeuille_jour.encours'),
(11, 'Jours de retard', 'Jours consécutifs écoulés depuis la date jusqu''à laquelle le client avait payé ; retombe à 0 dès qu''il recharge. Même règle pour toutes les entités, GREENO compris.', 'date de la photo − fin du crédit', 'bi.v_portefeuille_date'),
(12, 'PAR30 global', 'Part de l''encours actif portée par des clients en retard de plus de 30 jours, sur tout le portefeuille, contrats à 180 jours et plus compris. Mesure en montant, pas en nombre de clients.', 'encours en retard > 30 j / encours actif', 'pdg.v_portefeuille_jour.par30'),
(13, 'PAR90', 'Même calcul au-delà de 90 jours de retard.', 'encours en retard > 90 j / encours actif', 'pdg.v_portefeuille_jour.par90'),
(14, 'PAR180', 'Part de l''encours à 180 jours de retard et plus : seuil de write-off.', 'encours ≥ 180 j / encours actif', 'pdg.v_portefeuille_jour.par180'),
(15, 'PAR30 hors write-off', 'PAR30 sur le seul portefeuille encore récupérable, sans les contrats à 180 jours et plus, au numérateur comme au dénominateur. Suivi par le comité crédit, non affiché au tableau de bord de la direction.', '(encours > 30 j − encours ≥ 180 j) / (encours − encours ≥ 180 j)', 'pdg.v_portefeuille_jour.par30_hors_perte'),
(16, 'Taux FPD', 'First payment default : clients actifs de plus de 30 jours qui n''ont rien payé, ou moins d''une mensualité, au-delà du deposit. Hors 120 jours et plus.', 'FPD / actifs évaluables', 'pdg.v_portefeuille_jour.taux_fpd'),
(17, 'Statut de paiement', 'En avance (aucun jour de retard et plus payé que l''attendu à date), Normal (aucun jour de retard), En retard (au moins un jour de retard).', 'Retard consécutif, puis payé face à l''attendu', 'bi.v_portefeuille (comité crédit)'),
(18, 'Variation (Var.)', 'Évolution par rapport au mois précédent : ratio pour les volumes (0,10 = +10 %), points pour le PAR30.', 'mois / mois précédent − 1', 'pdg.v_kpi_mensuel.var_*'),
(19, 'Mois en cours', 'Mois non terminé : chiffres partiels, à comparer au même nombre de jours du mois précédent.', 'mois_en_cours = vrai', 'pdg.v_kpi_mensuel.mois_en_cours'),
(20, 'Photo', 'État du portefeuille enregistré chaque nuit ; le passé ne se réécrit pas. Historique depuis le 01/10/2026.', 'bi.calendrier', 'pdg.v_portefeuille_jour.jour');
GRANT SELECT ON pdg.dictionnaire TO pdg_lecture, role_read;
SELECT ordre, indicateur FROM pdg.dictionnaire ORDER BY ordre;
