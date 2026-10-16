**Documentation historique :** pour le parcours actuel, utiliser [IQ Atelier 4](ATELIER-4.md). Les pages Infrastructure PXE et Logiciels & bundles ont ete retirees du site.

# ATELIER-3 — image Windows, logiciels ensuite et inventaires sur .250

## Ce qui change

1. Démarrer le PC en UEFI PXE sur ATELIER-3. Le serveur crée son entrée et sa demande automatiquement : aucun accord à donner sur le site. Une installation déjà préparée doit démarrer sur son disque local pour terminer ; le serveur bloque une boucle PXE qui relancerait l’effacement.
2. Choisir Windows Pro ou Famille, le nom du PC, les logiciels et le disque dans WinPE. Seules les éditions réellement présentes dans les WIM enregistrés sont proposées. Cliquer sur **Installer Windows** confirme l’effacement du disque affiché.
3. WinPE vérifie puis applique le WIM et prépare le premier démarrage. Il ne lit ni ne copie les installateurs VLC/Reader/Chrome/AnyDesk depuis le partage : l’erreur de lecture SMB AnyDesk montrée précédemment n’est plus sur ce parcours.
4. Au premier démarrage Windows, le compte administrateur prépare WinGet si nécessaire, puis télécharge et installe silencieusement les logiciels cochés. Les mises à jour Windows suivent. La progression et les erreurs remontent dans l’activité du site.
5. Le PC transmet ses inventaires XML/CSV au serveur par HTTPS, avec son jeton de rapport. Aucun partage SMB en écriture n’est ouvert aux ordinateurs déployés.

Le choix du disque et son contrôle local restent nécessaires ; l’arrivée automatique dans le site n’efface aucun disque. Le mode interne doit déjà être configuré sur le réseau de l’atelier. Le parcours normal nécessite une connexion Internet sur chaque PC pour WinGet/Microsoft et les éditeurs. L’installation réelle des logiciels dépend de cette connexion et des installateurs disponibles dans WinGet.

Le catalogue et les bundles historiques restent conservés, mais sont masqués et ignorés pour les nouvelles installations lorsque `client_software` est activé. Les choix sont dans **Profils Windows → Installation silencieuse après Windows**, puis modifiables sur le poste dans WinPE. Une liste vide signifie qu’aucun des quatre logiciels ne sera installé. Le bouton de téléchargement serveur des versions précédentes ne pilote plus ce parcours, et sa tâche agent sur .250 est arrêtée/désactivée. Il n’est plus nécessaire de garder une session administrateur ouverte sur le serveur pour les logiciels. Les scripts de diagnostic IQ et le rapport PDF restent disponibles. Si un HP Image Assistant portable est déjà enregistré dans le catalogue, il est téléchargé depuis l’API sur les PC HP après Windows, vérifié puis ouvert à la fin de la préparation comme auparavant. Il ne dépend plus d’un bundle ni d’une copie SMB dans WinPE.

## Dossiers et raccourci dans le site

Le chemin réel dépend de `data_dir` dans `data-runtime.json`. Avec le dossier habituel :

```text
D:\AtelierPXE\data\inventaires\NOM-DU-PC\IDENTIFIANT-DU-DEPLOIEMENT\
    Inventaire-Technique.xml
    Inventaire-Technique.csv
```

Le certificat public de confiance intégré à WinPE est également transmis et enregistré dans Windows pour permettre les remontées HTTPS vers .250. Aucun PFX ni clé privée n’est copié, et la validation TLS reste active.

Le sous-dossier par déploiement évite d’écraser l’historique si un PC est réinstallé. Dans l’activité, cliquer sur **Dossier inventaire** sur la ligne du PC. La fenêtre affiche les fichiers reçus, leurs liens de téléchargement et le chemin Windows à copier sur .250. C’est une vue web du dossier : les navigateurs ne lancent pas automatiquement l’Explorateur du serveur.

Les XML/CSV ne sont plus générés à la racine IQ dans le nouveau parcours. Un cache privé de reprise est conservé sur le PC dans `C:\ProgramData\AtelierPXE\Inventory`. En cas de coupure, seuls les fichiers non transmis ou modifiés sont renvoyés. Un second relevé actualise les informations à la fin des mises à jour Windows ; les reprises de transmission réutilisent ensuite ce cache final sans refaire systématiquement toute la collecte matérielle. `C:\IQ_\Export-Inventaire.cmd` collecte et transmet également vers le serveur dans ce mode.

Les inventaires contiennent les informations exposées par Windows : RAM, CPU, disques, série, modèle, BIOS, pilotes, Windows, activation, logiciels, etc. Les fournisseurs absents sont signalés. Les clés de produit complètes, mots de passe et clés BitLocker/TPM ne sont pas collectés.

## Mise à jour et nouvelle image

Sur **DEPLOY-01 / 192.168.99.250**, en **Windows PowerShell administrateur**, depuis une archive de cette version extraite dans un dossier distinct de l’installation :

```powershell
& '.\scripts\Upgrade-Atelier3.ps1'
```

Le script détecte l’installation, sauvegarde le code/configuration et SQLite, installe la console, active `auto_enroll`, `client_software` et les mises à jour Windows, synchronise les éditions, construit et importe une nouvelle image **Atelier PXE - ATELIER-3 - date**, puis nettoie les anciennes images Atelier. Les paramètres permettent de préciser les chemins réels :

```powershell
& '.\scripts\Upgrade-Atelier3.ps1' `
    -InstallPath 'C:\AtelierPXE\console' `
    -OutputRoot 'D:\AtelierPXE' `
    -TrustedRootCertificate 'C:\AtelierPXE\certs\AtelierPXE-lab.cer' `
    -DriversPath 'D:\AtelierPXE\Drivers\WinPE-x64'
```

Si `-DriversPath` est omis, le script réutilise un dossier `Drivers\WinPE-x64` existant contenant des INF sous la racine Atelier. Si aucun n’existe, seuls les pilotes ADK sont inclus. Il faut Windows ADK, son complément WinPE, WDS et le certificat public .cer déjà utilisés par l’atelier. La construction native exige Windows : elle n’est pas réalisable dans l’environnement Linux de développement. Tester la nouvelle image sur une VM avant les autres PC. Une ancienne version WinPE est refusée lorsque ce nouveau parcours est activé, pour éviter une installation sans ses scripts de logiciels et d’inventaire.

La maintenance refuse de remplacer la console pendant une installation ou une synchronisation serveur active. Elle conserve données, images Windows, profils, rapports et configuration IIS. Les réponses PXE WDS ne sont pas activées ou désactivées par cette mise à jour. Pour les essais, un seul des deux serveurs Atelier/ancien MDT doit répondre au PXE.

## Nettoyage des anciennes versions WinPE

Le nettoyage s’exécute **après** la construction et l’import réussis du remplacement. Il vérifie son marqueur ATELIER-3 et sa présence dans WDS, retire les anciennes images dont le nom commence par Atelier, puis les anciens dossiers `WinPE` ou `WinPE-*` contenant `media\sources\boot.wim` directement sous les racines Atelier configurées. La nouvelle image et son dossier sont conservés ; les dossiers montés et les liens de dossier sont ignorés. Les dossiers pilotes, images Windows, données et images MDT ne font pas partie de la sélection.

Pour afficher la sélection sans supprimer, le script accepte `-WhatIf` :

```powershell
& 'C:\AtelierPXE\console\scripts\Remove-OldAtelierWinPE.ps1' `
    -KeepImageName 'Atelier PXE - ATELIER-3 - date-de-construction' `
    -KeepOutputPath 'D:\AtelierPXE\WinPE-Atelier3-date-de-construction' -WhatIf
```

Les chemins anciens situés hors de `D:\AtelierPXE` / `C:\AtelierPXE` ne sont pas recherchés sur tout le disque. Fournir leur racine exacte avec `-SearchRoots` si nécessaire.

## Journaux et optimisations

Sur le PC : `C:\ProgramData\AtelierPXE\software-logs\vlc.log` (et reader/chrome/anydesk), `first-logon.log`, `maintenance.log` et `reporting.log`. Le résultat logiciel est dans `result.json`, et les installations réussies sont mémorisées dans `winget-client-state.json`. Un logiciel en échec ne masque pas les autres résultats ; le rapport final passe à « À vérifier ». L’installateur dispose d’un délai de 45 minutes avant signalement ; contrôler un processus encore actif avant toute relance.

Les gains visés sont concrets : aucun transfert SMB d’installateurs dans WinPE, aucune publication/validation de ces fichiers avant l’effacement, téléchargement des seuls logiciels sélectionnés, reprise sans réinstaller ceux déjà réussis, un seul hash complet du WIM pendant son application, inventaire mis en cache et transmissions selon empreinte. La vitesse réelle reste liée au WIM, au stockage, au réseau et aux mises à jour ; aucun gain chiffré n’est annoncé sans mesure sur le matériel réel.
