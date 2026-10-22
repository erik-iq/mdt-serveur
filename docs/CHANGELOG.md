# Journal des modifications

## IQ-5.8.3 : accès concurrent aux états Windows Update, 22 octobre 2026

- Lecture UTF-8 des états avec partage du remplacement atomique, pour que l’attente interactive et la fenêtre de progression ne bloquent pas l’écriture SYSTEM.
- Reprise bornée des écritures uniquement sur les codes Windows de partage 32 et 33, en conservant la vérification des octets et les autres erreurs.
- Réparation directe du poste déployé : conservation des checkpoints Windows Update et HP, mise à jour des modules puis reprise de la préparation sans réinstallation de Windows.

## IQ-5.8.2 : Windows Update au début de la préparation, 22 octobre 2026

- Recherche et installation Windows Update sous SYSTEM avant la personnalisation, les logiciels et HPIA.
- Reprises automatiques au démarrage et contrôles réguliers ; reconnexion unique en mode sans intervention après chaque redémarrage nécessaire.
- Aucun logiciel lancé tant que Windows Update n’est pas terminé et vérifié. Les échecs et résultats inconnus conservent les rapports et bloquent la suite.
- Nouveau module embarqué dans WinPE ; ordre présenté dans l’assistant et sur la page Correctifs Windows.

## IQ-5.8.1 : récupération des résultats Windows Update, 22 octobre 2026

- Vérification des installations sans résultat par l’historique Windows Update ou par une recherche ciblée de l’état installé.
- Conservation des codes natifs retrouvés, de la provenance de la preuve et des échecs connus. Une recherche vide ne devient pas une preuve d’installation.
- Reprise automatique après disparition d’un installateur encore actif, sans tuer de processus ni rejouer une installation incertaine.
- Nouveau bouton de vérification du test existant, sans nouvelle installation ; mise à jour du même ZIP et collecte des événements de tâche disponibles.

## IQ-5.8 : recherche et installation Windows Update automatiques, 22 octobre 2026

- Recherche en ligne et installation sous SYSTEM après les logiciels et HPIA, pilotes et firmwares compris, sans mise à niveau automatique de Windows.
- Tentative silencieuse du pilote Intel au lieu d’un refus fondé uniquement sur CanRequestUserInput. Codes natifs conservés.
- Reprise après redémarrage, recherche finale obligatoire, limites de passes et conservation des installations incertaines.
- Résultat Windows Update archivé dans les diagnostics et les étapes du site avant nettoyage.
- Inclusion des nouveaux moteurs et du module KB historique dans WinPE. Nouveau parcours actif pour les prochains déploiements IQ-5.8.
- Cache KB facultatif, veille des versions quotidienne conservée. Kit existant corrigé en WU-INSTALL-2.

## Test physique d’installation Windows Update, 22 octobre 2026

- Lanceur USB distinct pour installer les mises à jour applicables, pilotes et firmwares compris, avec exclusion des changements de version.
- Rappels COM valides pour le téléchargement et l’installation, checkpoints avant chaque mise à jour et conservation des résultats individuels.
- Reprise SYSTEM au démarrage, nouvelles recherches après redémarrage et nombre de passes limité.
- ZIP du bilan dans IQ et sur la clé lorsqu’elle est disponible. Aucun changement de la préparation en production.

## Correction du rappel COM du diagnostic Windows Update, 22 octobre 2026

- Rappel de fin de recherche non nul, exposé en COM avec DISPID 0 et indépendant des runspaces PowerShell.
- Ajout de la révision du diagnostic, de l’étape fautive, du type d’exception et du numéro de ligne dans les rapports d’erreur.
- Conservation de la recherche seule et des limites de durée. Aucun changement du moteur de préparation en production.

## Diagnostic Windows Update sur poste existant, 22 octobre 2026

- Kit USB lancé par double-clic, sans nouveau déploiement ni PowerShell à saisir sur le poste.
- Recherche WUA sous SYSTEM, liste des logiciels, pilotes et éléments facultatifs, comparaison avec les anciens filtres et délai de cinq minutes par source.
- Codes d’erreur, services, indicateurs WSUS et événements archivés dans un ZIP sous IQ et sur la clé.
- Aucune installation ni demande de redémarrage ; aucune modification de la préparation en production.

## Correction de la lecture Microsoft Release Health, 22 octobre 2026

- Lecture de la colonne officielle « Latest build » et des dates « End of updates » de Famille et Pro.
- Distinction des erreurs HTTP, DNS, TLS, délai dépassé et format inattendu, avec conservation du dernier résultat réussi.
- Journal technique complet côté serveur pour diagnostiquer les erreurs sans exposer les détails privés sur le site.

## Veille des versions Windows, 22 octobre 2026

- Vérification quotidienne des versions stables de Windows 11 depuis Microsoft Release Health, avec contrôle manuel depuis le site.
- Affichage des versions observées, des nouvelles versions disponibles, des builds, des dates de disponibilité et de fin de support Famille et Pro.
- Dernier contrôle réussi conservé et clairement signalé comme ancien en cas d’erreur réseau ou de changement du format Microsoft.
- Accès au média officiel et parcours de préparation puis de validation ; aucune modification automatique des images de production.

## Correctif de nettoyage WDS, 22 octobre 2026

- Conversion des architectures numériques WDS vers les noms attendus par wdsutil.
- Conservation du code et du message natifs en cas de refus de suppression.
- Vérification de la disparition de chaque ancienne inscription avant nettoyage des dossiers.
- Un refus conserve les anciens dossiers et laisse la mise à jour se terminer avec un avertissement. Le nouveau WinPE déjà importé reste disponible.

## IQ-5.7, 22 octobre 2026

- Dépôt KB sur .250 avec recherche Microsoft, téléchargement, cache et accès HTTPS limité au déploiement demandeur.
- Nouvelle page Correctifs Windows : actualisation en ligne, contextes exacts, fichiers disponibles, tailles, empreintes et erreurs.
- Installation Windows et .NET après les logiciels et HPIA, sans recherche Windows Update sur le poste ni intégration préalable au WIM.
- Checkpoints avant chaque installation, contrôle après redémarrage, détection des correctifs déjà présents et conservation des vrais échecs.
- Actualisation quotidienne à 02:00 sur .250. Désactivation de la planification WIM lors du changement de méthode.
- Inclusion des résultats et journaux KB dans les diagnostics archivés avant nettoyage.

## IQ-5.6, 22 octobre 2026

- Redémarrage automatique de fin, point de reprise durable et contrôle des logiciels au nouveau démarrage, sans réinstallation.
- Fenêtre de bilan réouverte à la connexion, même après nettoyage du dossier privé. Une seule reconnexion automatique du compte de préparation.
- Succès en vert dans l’activité et archivage confirmé avant suppression des fichiers temporaires du poste. Les contrôles manuels absents ne créent plus d’avertissement.
- Retrait des profils Famille unilingue du catalogue, sans supprimer leurs historiques ni modifier le WIM de production. La synchronisation ne les recrée plus.
- Suppression du suffixe Test des profils ordinaires de production. Les véritables candidats de maintenance restent identifiés pour leurs tests.
- Stockage serveur affiché uniquement dans la vue globale, retrait des panneaux explicatifs inutiles.
- Correction du contrôle VLC : le nom de désinstallation natif « VLC media player » est conservé.

## IQ-5.5.1, 22 octobre 2026

- Français accentué dans le site, les messages WinPE, la progression Windows, les outils IQ et les guides.
- Suppression des tirets longs des sources et des documents.
- Scripts PowerShell enregistrés en UTF-8 avec BOM pour PowerShell 5.1. Transport UTF-8 vers Python et écritures des fichiers texte explicites.
- Menu de reprise WinPE en UTF-8, page de codes 65001, sans conversion destructive en ASCII.
- Rapports PDF avec libellés français et contrôle de l’extraction des accents et ligatures. Les clés techniques des inventaires déjà reçus restent compatibles.
- Règles permanentes dans AGENTS.md et .editorconfig, contrôles automatiques UTF-8 et typographiques.

La mise à jour de la console actualise le site. Reconstruire WinPE pour intégrer les scripts aux prochains déploiements. Les rapports historiques ne sont pas réécrits automatiquement.
