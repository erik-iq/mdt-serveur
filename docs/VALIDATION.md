# Recette de validation

## Tests exécutables dans le cloud

```bash
.venv/bin/python -m pytest -q
node --check app/static/app.js
pwsh -NoProfile -File scripts/Test-PowerShellSyntax.ps1
```

Les **32 tests API** exercent l’authentification, le lifecycle, les transitions refusées, l’annulation/révocation, les jobs concurrents, les MAC invalides, les chemins/symlinks, les images modifiées, le transport iPXE et la persistance SQLite. Ils couvrent aussi les bundles, le catalogue figé, les ressources modifiées avant claim, les codes PXE/MAC/expiration/renouvellement et une vraie base au schéma 0.1 migrée deux fois. Ils utilisent des fichiers synthétiques ; ils ne constituent pas une validation DISM ou de véritables médias Windows.

Les **tests de personnalisation** exécutent le générateur PowerShell de fichier Unattend, analysent le XML et vérifient l’échappement des valeurs, les réglages, l’absence d’AutoLogon/mots de passe et les règles HP/Lenovo/autres marques. Ils nécessitent `pwsh` ou `powershell` dans PATH, ou la variable `ATELIER_PWSH` pointant vers l’exécutable. Ils passent avec PowerShell 7.5.4 sous Linux.

La syntaxe des **24 scripts PowerShell** a également été vérifiée avec le parseur PowerShell 7.5.4. Les scripts sont enregistrés en UTF-8 avec BOM pour Windows PowerShell 5.1. Ce contrôle ne valide ni la présence des cmdlets sur Server 2025/WinPE ni leur exécution. La mise à jour par `Update-Console.ps1`, l’interface WinForms et les installateurs ne sont pas exécutables sur ce serveur Linux ; ils restent à tester sur Windows.

`tests/test_winpe_process.py` ajoute trois contrôles réservés à Windows PowerShell 5.1 en administrateur : chemins ADK/sortie avec espaces, transmission de l’environnement entre les deux fichiers batch, puis arrêt avant montage lorsqu’un batch échoue. Il utilise le vrai `cmd.exe` avec un ADK simulé dans un dossier temporaire ; DISM et WDS ne sont pas exécutés. Ces trois contrôles sont ignorés sous Linux. Sur Windows, lancer `.venv\Scripts\python.exe -m pytest -q tests\test_winpe_process.py`.

Le test navigateur optionnel `tests/browser_smoke.py` utilise Chromium installé sur la machine, démarre un serveur isolé et vérifie les formulaires machines/fichiers/logiciels/bundles/profils, la personnalisation enregistrée, le code PXE effacé à la fermeture, le journal, l’annulation et le rendu mobile. Il se lance avec `.venv/bin/python tests/browser_smoke.py` après installation de `requirements-browser.txt`. Il valide la console web, pas l’interface native WinPE.

Les **quatre tests de démarrage** dans `tests/test_winpe_startup.py` exécutent le vrai lanceur avec une interface et un changement de clavier simulés : erreur puis nouvelle tentative, configuration invalide, clavier indisponible et exclusion des secrets des journaux. Ils ne valident pas WinForms ou le clavier natif de WinPE.

Les **22 tests de partitions** exécutent le contrôle PowerShell avec un inventaire disque et des volumes simulés : EFI sans lettre, inventaire retardé, partitions absentes, disque changé, mauvais rôle GPT, mauvaise association lettre/GUID et mauvais système de fichiers. Ils vérifient aussi le résultat et le code retour de `mountvol` simulé. Ils ne partitionnent aucun disque et ne valident pas le fournisseur Storage natif de WinPE.

Résultat cloud après la reprise WinPE FR-REPRISE-2 : **61 tests passés, 3 tests Windows ignorés** avec PowerShell disponible ; contrôle JavaScript et parseur PowerShell sans erreur. Voir la [recette physique sur HP EliteBook 850 G6](ASSISTANT-PXE.md).

Le collecteur `Get-VMSetupDiagnostics.ps1` ajoute **12 tests portables** sur des arborescences synthétiques : présence et octets exacts des fichiers, fichier XML vide ou rempli d’octets nuls, syntaxe XML, encodage cohérent, liens symboliques refusés et conservation de la source. Les commandes de montage Hyper-V et les permissions Windows ne sont pas exécutées par ces tests. Voir [la collecte des journaux](DIAGNOSTIC-PREMIER-DEMARRAGE.md).

Les **14 tests de fichiers de réponses** exécutent l’écriture UTF-8 vérifiée et une réparation dans une arborescence synthétique : octets Unicode exacts, rejet avant écrasement d’un XML nul/invalide, corruption conservant la taille, sauvegarde des 1351 octets nuls, conservation du bundle/fond d’écran et refus d’une personnalisation incomplète. Ils ne montent pas de VHD et n’exécutent pas Windows Setup. La réparation native est à valider avec [la procédure Hyper-V](REPARATION-UNATTEND.md).

Résultat cloud FR-REPRISE-3 avec les collecteurs et la réparation : **87 tests passés, 3 tests Windows ignorés** ; parseur des quinze scripts PowerShell sans erreur. La cause immédiate du premier démarrage est confirmée par le fichier nul collecté ; le moment de son altération n’est pas encore établi.

## Révision INTERNE-1

Résultat : **117 tests passés, 3 contrôles Windows ignorés** avec PowerShell 7.5.4 sous Linux ; analyse des 24 scripts PowerShell et JavaScript sans erreur. Les scénarios Chromium ont passé en mode authentifié et interne, sans erreur JavaScript : ouverture sans jeton, absence du champ de confirmation et de la fenêtre de code en mode interne, formulaires, cycle agent, journal, annulation et rendu mobile.

Les nouveaux tests couvrent le mode interne explicite, la correspondance MAC, la rotation/révocation des jetons, les autorisations expirées et la réponse contenant le secret limitée à HTTPS et à un agent valide. Le déchiffrement DPAPI et les ACL Windows ne sont pas exécutés sous Linux.

Le correctif d'activation ajoute quatre tests exécutant le véritable contrôle PowerShell avec Python et SQLite, en mode de transmission natif `Legacy` : aucune installation active, deux installations actives, base absente sans création de fichier et schéma invalide. Le code Python passe sur stdin plutôt que dans un argument `-c`, fragile sous Windows PowerShell 5.1. Les huit tests ciblés (activation et API du mode interne) passent ; ce contrôle portable ne constitue pas une exécution native sous Windows PowerShell 5.1.

Les tests PowerShell exécutent le XML automatique, les noms issus du numéro BIOS, les décisions Windows Update avec de faux objets COM (résultats partiels, intervention nécessaire, redémarrage préalable), la reprise durable après redémarrage et l'arrêt des boucles. Les tests IQ_ créent réellement une arborescence temporaire, copient le fond, vérifient les lanceurs et les états actif/non actif/sans batterie ; CIM, powercfg et les droits NTFS sont simulés. Aucun de ces tests n'active un compte ou une licence et aucun n'installe de mise à jour.

Sur Windows, suivre [la recette du mode interne](MODE-INTERNE.md) : génération du secret SMB, premier logon sans OOBE interactif, compte SID 500 et UAC, progression, vrais installateurs, permissions des tâches, maintien/retrait de l'ouverture automatique, mises à jour réelles et rapports IQ_. L'actualisation Store est marquée demandée et non certifiée terminée. Les clients ATELIER-2 remontent leurs états Windows et leur rapport ; les anciens clients conservent leurs états locaux.

## À exécuter sur Server 2025 et un PC de test

- Installation de Python/service, permissions LOCAL SERVICE, redémarrage du serveur et accès HTTPS depuis le LAN.
- Construction WinPE avec les packages ADK, drivers NIC/NVMe et certificat racine.
- Import WDS et démarrage UEFI réel avec vos paramètres DHCP ; Secure Boot selon votre matériel.
- Accès SMB chiffré en lecture seule, édition Windows x64 réellement présente dans le WIM.
- Refus d’une mauvaise MAC, d’un hash incorrect, d’un mauvais disque et d’une confirmation incorrecte **en mode authentifié avant tout effacement**. En mode interne, vérifier le récapitulatif et le démarrage par bouton sans phrase à saisir.
- Déploiement sur un disque sacrifiable ; progression DISM, création GPT, BCDBoot, premier démarrage Windows et OOBE.
- Validation de Windows 11 : CPU/TPM/Secure Boot compatibles, drivers, réseau, activation légale, WinRE opérationnel.
- Parcours graphique complet et choix de profils/paramètres/bundles, puis installation silencieuse des vrais logiciels signés au premier logon administrateur.
- Nom, clavier, fuseau, région, thème, fond d’écran du premier compte et journal `result.json`. Les logiciels/fonds d’écran ne sont pas distribués dans le ZIP du code.
- Annulation avant partitionnement et observation d’une coupure réseau. Aucune promesse de rollback après effacement.

## Limites de cette version

Un administrateur partagé, sans rôles utilisateurs/SSO ; opérations supervisées ; UEFI x64 uniquement ; images WIM non fractionnées ; pas de jonction AD, capture d’image, injection automatique de drivers Windows par modèle ou multicast. ATELIER-2 ajoute une reprise locale des mises à jour et leur remontée après OOBE vers la console. Les logiciels exigent leurs paramètres silencieux, une signature valide et une première connexion administrateur. Le bureau est personnalisé pour ce premier compte ; pas de configuration des futurs comptes ou de stratégie de domaine. Les images d’installation téléchargées via HTTP par l’API ne sont pas le parcours choisi par l’agent ; il lit un WIM SMB/local indépendant du disque cible.

La console n’est pas un contrôleur DHCP/TFTP et ne peut pas démarrer le LAN depuis le cloud. Les scripts PowerShell nécessitent une validation Windows réelle avant une utilisation en production. Les tests Python/navigateur ne remplacent pas cette recette.

## Recette ATELIER-2

Exécuter la [recette de mise à jour ATELIER-2](MISE-A-JOUR-ATELIER-2.md) : phases réelles Windows Update, reprise, absence de console vide, ouverture HPIA, choix Pro/Famille et refus d’un index incohérent, HiberbootEnabled=0, tests matériels opérateur, PDF local et téléchargement dans Atelier. Vérifier le renvoi d’un rapport lorsque la console revient en ligne et la garantie assistée sans dates inventées. Le test navigateur IQ simule une caméra : il ne valide pas le matériel réel.
