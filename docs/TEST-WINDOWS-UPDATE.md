# Tester Windows Update sur un poste déjà déployé

Copier le kit `Test-WindowsUpdate` sur une clé USB, puis sur le poste à vérifier. Le poste doit disposer d’une connexion Internet et sa préparation Atelier doit être terminée. Double-cliquer sur `Lancer-TestWindowsUpdate.cmd` et accepter l’élévation administrateur. Aucun PowerShell à saisir sur le poste.

Le lanceur exécute une tâche temporaire SYSTEM, comme pendant la préparation Atelier. Les scripts de cette tâche sont copiés dans un dossier privé sous Program Files, accessible en écriture uniquement à SYSTEM et aux administrateurs. La fenêtre affiche les étapes pendant la recherche, puis ouvre un résumé dans le Bloc-notes.

La recherche utilise l’API officielle Windows Update Agent. Elle demande les mises à jour non installées et non masquées, y compris les pilotes et les mises à jour facultatives. La liste est seulement consultée : aucune acceptation de licence, aucun téléchargement de paquet, aucune installation ni aucun redémarrage ne sont demandés par le kit. Windows peut mettre à jour ses métadonnées de recherche et démarrer ses services à la demande.

Le rapport compare le nombre trouvé avec le filtre logiciel non facultatif utilisé par l’ancien moteur Atelier. La recherche dispose de cinq minutes par source, au lieu des 90 secondes de l’ancien moteur. Si une stratégie WSUS est configurée, une seconde recherche interroge aussi le service configuré. Aucune stratégie ni configuration WSUS n’est modifiée. Une stratégie qui interdit Internet peut donc produire une erreur, qui reste dans le rapport.

Le rapport contient la version Windows, les états des services, quelques indicateurs de stratégie sans les URL WSUS, le besoin de redémarrage, les codes WUA et HRESULT, la liste des mises à jour et les derniers événements Windows Update. Un délai dépassé ou une recherche partielle ne devient jamais un succès « Windows à jour ». Une liste vide signifie seulement que ce service n’a proposé aucun élément lors de cette recherche.

Le ZIP est conservé dans `C:\IQ_\Rapports\WindowsUpdate`, puis copié dans le sous-dossier `Rapports` du kit si celui-ci est accessible en écriture. Il contient `result.json`, `progress.json` et `Lisez-moi.txt`, ainsi qu’un diagnostic de lancement si nécessaire. Le nom du ZIP contient la date et un identifiant pour distinguer les essais. Transmettre ce ZIP pour décider des corrections avant d’activer l’installation Windows Update dans la préparation de production.

La tâche temporaire est retirée après le test. Le kit ne modifie ni les tâches de déploiement, ni le statut de la fiche du poste, ni les rapports HPIA, ni le cache KB de .250.

## Révision WU-DIAG-2

Le premier essai sur le HP a échoué immédiatement avec `0x80004003`, sans résultat de recherche. L’appel asynchrone utilisait un rappel nul. La nouvelle révision fournit un objet de rappel COM avec une méthode DISPID 0, conformément à la documentation Microsoft de `IUpdateSearcher::BeginSearch`. Ce rappel compilé ne lance aucun code PowerShell depuis le thread COM. Le diagnostic conserve l’étape, le type d’exception et la ligne fautive si une autre erreur survient. Une validation du nouvel appel sur le poste physique reste nécessaire.

## Essai d’installation WU-INSTALL-1

Le lanceur distinct `Lancer-InstallationWindowsUpdate.cmd` installe réellement les mises à jour proposées par Windows Update, logiciels, Defender, pilotes et firmwares compris. Enregistrer son travail et brancher le portable sur secteur avant de le lancer. Les changements de version classés « Upgrades » restent exclus. Ce test ne modifie pas le moteur de préparation ni le cache KB de production.

Le kit contient `Test-WindowsUpdateInstallation.ps1`, `WindowsUpdate-InstallTest.ps1` et le rappel COM de `WindowsUpdate-Diagnostic.ps1`. Le lanceur refuse Windows Server et une préparation Atelier active. Il enregistre une tâche SYSTEM au démarrage, puis copie les scripts et les points de reprise dans un dossier privé `Program Files\AtelierPXE-WindowsUpdateTest-ID`. Les comptes ordinaires ne peuvent pas modifier ces fichiers.

Le téléchargement et l’installation utilisent chacun des rappels COM non nuls avec DISPID 0, comme la recherche validée sur le HP. Chaque mise à jour est traitée individuellement : checkpoint avant installation, code global et résultat individuel enregistrés, puis contrôle du besoin de redémarrage. Les logiciels passent avant les pilotes, et les titres de firmware ou BIOS en dernier. Un résultat partiel ou un échec ne donne pas un succès.

Le redémarrage demandé par le kit arrive après 60 secondes. La tâche reprend automatiquement, avec un délai de 60 secondes au démarrage, et recherche à nouveau les mises à jour applicables. Il n’est pas nécessaire de laisser la clé USB branchée. Rouvrir le même lanceur affiche la progression ou le dernier bilan au lieu de créer un autre test. Jusqu’à cinq passes et six demandes de redémarrage sont autorisées, prérequis compris. Ces limites évitent une boucle infinie lorsqu’un correctif reste proposé.

Une interruption pendant une opération sans résultat natif confirmé entraîne une recherche de diagnostic et un bilan à vérifier, sans rejouer automatiquement une installation incertaine. En cas de dépassement du délai d’installation, le kit ne tue aucun processus de maintenance Windows. Une autre installation déjà active bloque le test. La fenêtre du lanceur peut être fermée sans arrêter la tâche SYSTEM.

Le rapport final est vert uniquement après une recherche en ligne réussie sans correctif ni pilote restant proposé, hors changements de version exclus, et après disparition du besoin de redémarrage Windows. Il ne constitue pas un test manuel de chaque périphérique. Le ZIP et le résumé sont dans `C:\IQ_\Rapports\WindowsUpdateInstallation`. Une copie est déposée dans `Rapports` du kit si son chemin est encore disponible. Récupérer le ZIP après la fin des redémarrages. La tâche de reprise est supprimée lorsque le bilan est terminé ; les petits fichiers privés de l’essai restent disponibles pour relire son état jusqu’au nettoyage après validation.
