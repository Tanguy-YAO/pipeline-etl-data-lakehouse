# Audit des données UPYA dans DELTA · 11/11/2026

Périmètre : `silver.upya_contracts` (93 696 contrats), `silver.upya_clients` (103 885 fiches), `silver.upya_assets` (121 804 kits) et `gold.unified_contracts` (93 696 contrats), extraits le 11/11/2026 ; scripts gold `unified_contracts` (v14 reçue), `bronze/upya/generic_extractor.py` et `silver/upya/contracts_loader.py` v3.4.

Livrables : `audit-donnees-upya-delta-2026-11-11.xlsx` (une feuille par anomalie, avec la liste des contrats) et `qualite-controles-upya.sql` (vue `qualite.v_controles_upya`, à suivre après chaque passage du pipeline).

## Ce qui est sain

- Clés uniques : aucun doublon de contrat ni de fiche client ; 3 contrats seulement sans fiche.
- Fraîcheur : 93 427 contrats et toutes les fiches mis à jour le 11/11 au matin.
- Montants : aucun contrat PAYG sans valeur ni sans mensualité ; aucun acompte supérieur à la valeur.
- Collecte : rapprochée au franc près avec le CRM le 11/11 (contrats migrés) et à 15 000 FCFA près (UPYA).

## Anomalies

| Code | Gravité | Anomalie | Contrats | Encours actif |
|---|---|---|---|---|
| A | Haute | Contrats plus renvoyés par UPYA mais toujours dans silver | 269 | 151 M |
| B | Haute | Statut actif sans date de fin de crédit (jamais déployés) | 9 058 | 3 939 M |
| C | Haute | Non signés (Pending, Approved, Rejected) au statut actif | 2 968 | 1 581 M |
| G | Haute | Titulaire de la fiche différent du signataire du contrat | 62 | 29 M |
| D | Moyenne | Actifs sans reste à payer | 638 | 0 |
| E | Moyenne | paid_off_status vrai mais LOCKED | 35 | 0,6 M |
| F | Moyenne | Montants incohérents | 114 | |
| H | Moyenne | Produit GREENO hors entité GREENO | 19 | 16 M |
| M | Moyenne | ENABLED avec un crédit expiré | 890 | 290 M |
| I | Basse | Entité vide ou « Ivory Cost » (hors migrés) | 5 388 | 2 673 M |
| J | Basse | Préfixe N/T et entité contradictoires | 8 | |
| K | Basse | Contrat sans fiche client | 3 | |
| L | Basse | Activation avant la signature | 21 | |

B et C se recoupent en partie (2 948 contrats non signés n'ont pas non plus de fin de crédit).

### A. Contrats fantômes
269 contrats UPYA (numéros natifs) n'ont plus été mis à jour depuis le 26/10 pour la plupart, alors que tous les autres l'ont été le 11/11. Le chargement fait des mises à jour sans jamais supprimer : un contrat sorti de l'export UPYA reste dans silver avec son dernier état, 268 d'entre eux en LOCKED, dont 122 activés. Ils gonflent le portefeuille et le PAR.
**Action** : ajouter au chargement une date de dernière présence et exclure de gold les contrats absents du dernier export ; demander à UPYA ce que sont devenus ces 269 contrats.

### B et C. Faux actifs
9 058 contrats ENABLED ou LOCKED n'ont aucune date de fin de crédit : 5 341 contrats migrés (2 892 N, 2 449 T) et 3 717 contrats UPYA, dont 2 948 non signés (Pending, Approved, Rejected). Ils n'ont jamais été déployés. Les comités et l'app de recouvrement les écartent (filtre sur l'activation), mais tout calcul qui prend le statut seul les compte comme clients actifs à jour, avec 3,9 Md d'encours : c'est l'erreur de PAR du 11/11 (20,6 % au lieu de 23,9 %). gold ne filtre que `onboarding_status IS NOT NULL` : les dossiers refusés entrent dans le périmètre.
**Action** : dans gold, actif = statut ENABLED ou LOCKED **et** contrat signé **et** activé ; retard inconnu = NULL, jamais 0. Corriger aussi `bi.mv_portefeuille_jour` (Metabase) qui prend le statut seul.

### G. Changement de titulaire
62 contrats affichent le nom d'une personne avec le téléphone d'une autre (cas 387796613, KONATÉ → KOUA le 31/07). **La cause est dans DELTA, pas dans UPYA** : le chargement silver ne met jamais à jour `customer_name` après la première insertion (voir « Le chargement »), alors que le téléphone, lu dans la fiche client, suit les changements. Les changements de titulaire eux-mêmes sont réels (historique UPYA) : liste nominative remise au crédit (49 dans le portefeuille de recouvrement, dont deux paires de noms croisés).
**Action** : chargement v3.5 (toutes les colonnes mises à jour). Pour garder la trace du signataire, gold pourra conserver le premier nom connu dans une colonne `nom_signataire`.

### D, E, F, M. Statuts et montants contradictoires
638 actifs n'ont plus rien à payer (383 T, 221 N) : soldés de fait. 890 contrats ENABLED ont une fin de crédit dépassée : le statut UPYA est en retard sur la réalité. 114 contrats ont des montants impossibles (payé > valeur, reste négatif, soldé avec un reste).
**Action** : listes à UPYA ; dans gold, un contrat sans reste à payer est traité comme soldé.

### H, I, J. Entités
19 contrats de produit GREENO ont une entité vide ou « Ivory Cost » : gold (v14 comme v17) classe GREENO sur l'entité, ils tombent dans upya_tevia. 5 388 contrats TEVIA ont une entité vide ou « Ivory Cost » : sans effet dans DELTA, mais tout export UPYA filtré par entité les perd (8,9 M de collecte manquants le 11/11).
**Action** : gold classe GREENO sur le produit ; correction de masse des entités par UPYA.

## Le chargement (bronze et silver)

**contracts_loader.py v3.4 : 8 colonnes figées à la première insertion.** La clause `ON CONFLICT … DO UPDATE` ne met pas à jour `registration_date`, `product_name`, `asset_number`, `client_number`, `customer_name`, `agent_number`, `agent_name` ni `region`. Un contrat chargé avant son installation garde à vie un kit et une date de déploiement vides : **5 073 contrats** ont `asset_number` vide alors qu'un kit leur est déployé, **2 132** n'ont pas de date de déploiement. gold compense pour le kit et la date (jointure sur `silver.upya_assets`), pas pour le nom, le commercial, le produit ni la région.
**Correctif** : v3.5 (`pipeline/contracts_loader.py`) met à jour toutes les colonnes ; une valeur vide de l'API n'écrase pas une valeur connue ; les dates illisibles sont signalées au lieu de devenir NULL en silence ; le filtre des comptes de test porte sur le mot entier « test ».
À vérifier au premier passage après déploiement : le contrôle G de `qualite.v_controles_upya` doit tomber près de 0.

**generic_extractor.py : extraction partielle journalisée en succès.** Une erreur réseau ou HTTP en cours de pagination arrête la boucle par `break` ; le run est enregistré « success » avec les pages déjà lues. Pour les entités rechargées en entier (contracts, assets, clients), les contrats des pages manquantes ne sont pas mis à jour ce jour-là, sans alerte ; pour les paiements, le watermark avance quand même.
**Correctif** : l'erreur est levée, le run est journalisé « error » (`pipeline/generic_extractor.py`).

**Paiements : changements de statut non relus.** Les paiements sont extraits sur leur date (`date ≥ dernier run − 1 jour`). Un paiement annulé ou corrigé plus tard n'est pas relu : c'est l'écart de 15 000 FCFA du 02/11 avec le CRM (paiement annulé encore ACCEPTED dans DELTA). Le chargeur des paiements n'a pas été audité.
**Piste** : relire une fenêtre glissante de 7 à 15 jours, ou filtrer sur `updatedAt` si l'API le permet.

**Contrats fantômes (A).** `updated_at` est réécrit à chaque passage : il sert de date de dernière présence. Une fois l'extraction fiabilisée, gold peut écarter les contrats absents depuis plus de 3 jours (les 269 datent pour l'essentiel du 26/10).

## gold et assets

- gold contient exactement les 93 696 contrats de silver ; 45 264 actifs, dont 3 930 sans date d'activation et 3 727 sans fin de crédit (faux actifs B et C, en partie écartés par la v17).
- **5 427 contrats REPOSSESSED n'ont pas de date d'activation dans gold** : elle vient uniquement des kits au statut DEPLOYED, et un kit repris ne l'est plus. Ces contrats sortent des cohortes, du vintage et des taux de reprise par cohorte. Correctif v17.2 : prendre la date de déploiement de silver (corrigée par la v3.5) quand le kit n'est plus déployé.
- 19 contrats de produit GREENO classés hors upya_greeno (H).
- 22 contrats ont deux kits ou plus au statut DEPLOYED ; 15 721 kits (presque tous en stock) n'ont pas été revus au dernier chargement des assets.

## Le script gold

Le fichier reçu comme « script actuel » est la **v14** (`gold/unified_contracts.sql`). La base tourne en **v17** (les colonnes `numero_origine`, `origine`, `statut_corrige_surge` sont présentes dans gold le 11/11). Si le dépôt contient encore la v14 et qu'un déploiement la relance, gold revient à l'état d'avant la migration : NEoTCI classé en upya_tevia, contrats SURGE comptés deux fois.
**Action** : vérifier le fichier du dépôt et y committer la v17.1 en vigueur, avant toute autre modification.

Points du script à corriger dans une v17.2 (à valider, après déploiement du chargement v3.5) :
1. Actif = ENABLED/LOCKED, signé, activé (B, C).
2. Nom = fiche client ; `nom_signataire` = nom du contrat (G).
3. Catégorie GREENO sur le produit (H).
4. Contrat sans reste à payer traité comme soldé (D).
5. Exclusion des contrats absents du dernier chargement, une fois la date de dernière présence ajoutée au chargement (A).
6. `consecutive_locked_days` calculé avec `CURRENT_TIMESTAMP` : la valeur dépend de l'heure de lecture, à figer à la date du dernier chargement.
7. Date d'activation des contrats repris : silver quand le kit n'est plus DEPLOYED (5 427 contrats).

## Ordre de mise en œuvre

1. Committer la v17.1 de gold dans le dépôt (risque de retour à la v14).
2. Déployer `generic_extractor.py` corrigé et `contracts_loader.py` v3.5 ; relancer un chargement complet des contrats ; vérifier `qualite.v_controles_upya` (G près de 0, kits et dates de déploiement remplis).
3. gold v17.2 (points 1 à 7) et correction de `bi.mv_portefeuille_jour`.
4. Auditer les chargeurs clients, assets et paiements sur le même modèle.
