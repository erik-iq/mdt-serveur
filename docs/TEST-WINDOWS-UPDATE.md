# Tester Windows Update sur un poste déjà déployé

Copier le kit `Test-WindowsUpdate` sur une clé USB, puis sur le poste à vérifier. Le poste doit disposer d’une connexion Internet et sa préparation Atelier doit être terminée. Double-cliquer sur `Lancer-TestWindowsUpdate.cmd` et accepter l’élévation administrateur. Aucun PowerShell à saisir sur le poste.

Le lanceur exécute une tâche temporaire SYSTEM, comme pendant la préparation Atelier. Les scripts de cette tâche sont copiés dans un dossier privé sous Program Files, accessible en écriture uniquement à SYSTEM et aux administrateurs. La fenêtre affiche les étapes pendant la recherche, puis ouvre un résumé dans le Bloc-notes.

La recherche utilise l’API officielle Windows Update Agent. Elle demande les mises à jour non installées et non masquées, y compris les pilotes et les mises à jour facultatives. La liste est seulement consultée : aucune acceptation de licence, aucun téléchargement de paquet, aucune installation ni aucun redémarrage ne sont demandés par le kit. Windows peut mettre à jour ses métadonnées de recherche et démarrer ses services à la demande.

Le rapport compare le nombre trouvé avec le filtre logiciel non facultatif utilisé par l’ancien moteur Atelier. La recherche dispose de cinq minutes par source, au lieu des 90 secondes de l’ancien moteur. Si une stratégie WSUS est configurée, une seconde recherche interroge aussi le service configuré. Aucune stratégie ni configuration WSUS n’est modifiée. Une stratégie qui interdit Internet peut donc produire une erreur, qui reste dans le rapport.

Le rapport contient la version Windows, les états des services, quelques indicateurs de stratégie sans les URL WSUS, le besoin de redémarrage, les codes WUA et HRESULT, la liste des mises à jour et les derniers événements Windows Update. Un délai dépassé ou une recherche partielle ne devient jamais un succès « Windows à jour ». Une liste vide signifie seulement que ce service n’a proposé aucun élément lors de cette recherche.

Le ZIP est conservé dans `C:\IQ_\Rapports\WindowsUpdate`, puis copié dans le sous-dossier `Rapports` du kit si celui-ci est accessible en écriture. Il contient `result.json`, `progress.json` et `Lisez-moi.txt`, ainsi qu’un diagnostic de lancement si nécessaire. Le nom du ZIP contient la date et un identifiant pour distinguer les essais. Transmettre ce ZIP pour décider des corrections avant d’activer l’installation Windows Update dans la préparation de production.

La tâche temporaire est retirée après le test. Le kit ne modifie ni les tâches de déploiement, ni le statut de la fiche du poste, ni les rapports HPIA, ni le cache KB de .250.
