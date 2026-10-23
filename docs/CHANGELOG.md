# Journal des modifications

## Console IQ-6.0.1 : choix du thème, 23 octobre 2026

- Sélecteur Clair, Sombre ou Automatique dans l’en-tête, disponible sur ordinateur et mobile. Le mode automatique suit le réglage du système.
- Préférence mémorisée dans le navigateur et synchronisée entre les onglets du site. Le thème est appliqué avant la feuille de style pour éviter un éclair clair au chargement.
- Contrastes adaptés pour les tableaux, statuts, formulaires et fenêtres en mode sombre. Le choix continue à fonctionner lorsque le stockage du navigateur est indisponible.

## Console IQ-6.0 : interface et suivi des déploiements, 23 octobre 2026

- Navigation bleu nuit, zones de travail claires, tableaux plus lisibles, statuts contrastés et compteur des préparations à vérifier. Adaptation aux écrans étroits et accès au clavier.
- Recherche locale par poste, numéro de série ou profil et filtre par état, avec nombre de résultats. Conservation des filtres pendant les actualisations.
- Réutilisation des fragments HTML inchangés pour préserver le focus et les détails ouverts. Mutualisation des demandes simultanées de maintenance et espacement de leur actualisation à quinze secondes.
- La dernière actualisation réussie est affichée dans la console. Le parcours Windows reste celui d’IQ-5.8.9, sans KB automatiques. Cette mise à jour du site ne nécessite pas de reconstruire WinPE.

## IQ-5.8.9 : retrait des KB automatiques sur les postes, 23 octobre 2026

- Les nouveaux déploiements désactivent le cache KB et son étape initiale. Windows Update automatique reste désactivé.
- HPIA si sélectionné, puis logiciels, personnalisation, dossier IQ et bilan final. Les reprises HP et le correctif du relais de progression sont conservés.
- L’assistant et le site décrivent ce parcours. La veille et le dépôt KB restent disponibles séparément ; aucun correctif déjà installé n’est désinstallé.

## IQ-5.8.8 : vérification des KB après une sortie DISM 552, 23 octobre 2026

- Lorsqu’un code 552 suit une installation signalée comme réussie et un redémarrage requis dans la même session DISM, la préparation attend le redémarrage au lieu de lancer HPIA et les logiciels.
- La KB reste non confirmée jusqu’au contrôle du build Windows après redémarrage. Le code natif 552 est conservé ; un build insuffisant ou un journal sans ces preuves maintient le statut à vérifier sans réinstallation automatique.
- Le parcours est vérifié avec la séquence du journal reçu : .NET terminé, KB Windows en attente, contrôle après redémarrage, puis HPIA. Aucun changement des droits Windows ni intégration dans le WIM.

## IQ-5.8.7 : relais HPIA et diagnostic des échecs KB, 23 octobre 2026

- Capture du destinataire de progression HPIA pour éviter un rappel récursif et le dépassement de profondeur des appels PowerShell.
- DISM cible le MSU de la KB demandée ; les checkpoints restent dans son dossier pour leur résolution automatique. Aucun contrôle de compatibilité n’est ignoré.
- Conservation de la sortie console DISM dans les diagnostics et ajout des HRESULT relevés au message d’échec. Le code 552 conserve un statut à vérifier et nécessite le journal du paquet pour confirmer sa cause.
- La réparation HP locale conserve le résultat des KB, y compris un échec déjà enregistré. Les nouveaux parcours archivent les diagnostics puis gardent le dossier privé en cas de préparation à vérifier, sans répéter la transmission chaque minute.

## IQ-5.8.6 : KB en premier et progression dès la connexion Windows, 23 octobre 2026

- Réactivation des KB du cache .250 au début de Windows, avant HPIA et les logiciels, avec contrôles de compatibilité et reprise après redémarrage. La recherche Windows Update en ligne reste désactivée.
- La fenêtre est lancée dès FirstLogonCommands, avant la tâche de travail, l’attente du bureau et la validation réseau. Le travail planifié démarre immédiatement.
- La progression couvre explicitement le thème, le fond d’écran et la création du dossier IQ. La finalisation réutilise le résultat KB déjà obtenu.

## IQ-5.8.5 : HPIA en premier, sans Windows Update automatique, 23 octobre 2026

- Les nouveaux déploiements désactivent Windows Update et les KB automatiques. HPIA s’exécute avant les autres logiciels si sa case est cochée.
- Préparation du seul outil HP, analyse et installation des SoftPaq, puis logiciels sélectionnés, dossier IQ, rapports et contrôle final.
- La tâche du premier compte reprend après un BIOS et vérifie les checkpoints HP. La finalisation relit le résultat HP déjà obtenu sans nouvelle analyse.
- Les anciens parcours Windows Update restent disponibles pour les anciens payloads et les outils manuels, sans être activés dans les nouveaux déploiements.

## IQ-5.8.4 : lecture des états et protection contre le nettoyage prématuré, 23 octobre 2026

- Reprise des lectures sur les conflits de partage Windows 32 et 33. Les erreurs de droits, de contenu et les fichiers absents ne sont pas masqués.
- Un état temporairement verrouillé maintient la préparation en attente et conserve la tâche SYSTEM ainsi que les checkpoints ; il ne devient pas un échec d’installation.
- Une ancienne tâche de maintenance attend la fin de la préparation des logiciels. Le nettoyage exige Windows Update terminé et prend le même mutex que son moteur avant de verrouiller le dossier privé.

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
