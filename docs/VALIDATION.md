# Recette de validation

## Tests exécutables dans le cloud

```bash
.venv/bin/python -m pytest -q
node --check app/static/app.js
pwsh -NoProfile -File scripts/Test-PowerShellSyntax.ps1
```

Les **32 tests API** exercent l’authentification, le lifecycle, les transitions refusées, l’annulation/révocation, les jobs concurrents, les MAC invalides, les chemins/symlinks, les images modifiées, le transport iPXE et la persistance SQLite. Ils couvrent aussi les bundles, le catalogue figé, les ressources modifiées avant claim, les codes PXE/MAC/expiration/renouvellement et une vraie base au schéma 0.1 migrée deux fois. Ils utilisent des fichiers synthétiques ; ils ne constituent pas une validation DISM ou de véritables médias Windows.

Les **trois tests de personnalisation** exécutent le générateur PowerShell de fichier Unattend, analysent le XML et vérifient l’échappement des valeurs, les réglages, l’absence d’AutoLogon/mots de passe et les règles HP/Lenovo/autres marques. Ils nécessitent `pwsh` ou `powershell` dans PATH, ou la variable `ATELIER_PWSH` pointant vers l’exécutable. Ils passent avec PowerShell 7.5.4 sous Linux.

La syntaxe des **douze scripts PowerShell** a également été vérifiée avec le parseur PowerShell 7.5.4. Les scripts sont enregistrés en UTF-8 avec BOM pour Windows PowerShell 5.1. Ce contrôle ne valide ni la présence des cmdlets sur Server 2025/WinPE ni leur exécution. La mise à jour par `Update-Console.ps1`, l’interface WinForms et les installateurs ne sont pas exécutables sur ce serveur Linux ; ils restent à tester sur Windows.

`tests/test_winpe_process.py` ajoute trois contrôles réservés à Windows PowerShell 5.1 en administrateur : chemins ADK/sortie avec espaces, transmission de l’environnement entre les deux fichiers batch, puis arrêt avant montage lorsqu’un batch échoue. Il utilise le vrai `cmd.exe` avec un ADK simulé dans un dossier temporaire ; DISM et WDS ne sont pas exécutés. Ces trois contrôles sont ignorés sous Linux. Sur Windows, lancer `.venv\Scripts\python.exe -m pytest -q tests\test_winpe_process.py`.

Le test navigateur optionnel `tests/browser_smoke.py` utilise Chromium installé sur la machine, démarre un serveur isolé et vérifie les formulaires machines/fichiers/logiciels/bundles/profils, la personnalisation enregistrée, le code PXE effacé à la fermeture, le journal, l’annulation et le rendu mobile. Il se lance avec `.venv/bin/python tests/browser_smoke.py` après installation de `requirements-browser.txt`. Il valide la console web, pas l’interface native WinPE.

Les **quatre tests de démarrage** dans `tests/test_winpe_startup.py` exécutent le vrai lanceur avec une interface et un changement de clavier simulés : erreur puis nouvelle tentative, configuration invalide, clavier indisponible et exclusion des secrets des journaux. Ils ne valident pas WinForms ou le clavier natif de WinPE.

Résultat cloud après la reprise WinPE FR-REPRISE-1 : **39 tests passés, 3 tests Windows ignorés** avec PowerShell disponible ; contrôle JavaScript et parseur PowerShell sans erreur. Voir la [recette physique sur HP EliteBook 850 G6](ASSISTANT-PXE.md).

## À exécuter sur Server 2025 et un PC de test

- Installation de Python/service, permissions LOCAL SERVICE, redémarrage du serveur et accès HTTPS depuis le LAN.
- Construction WinPE avec les packages ADK, drivers NIC/NVMe et certificat racine.
- Import WDS et démarrage UEFI réel avec vos paramètres DHCP ; Secure Boot selon votre matériel.
- Accès SMB chiffré en lecture seule, édition Windows x64 réellement présente dans le WIM.
- Refus d’une mauvaise MAC, d’un hash incorrect, d’un mauvais disque et d’une confirmation incorrecte **avant tout effacement**.
- Déploiement sur un disque sacrifiable ; progression DISM, création GPT, BCDBoot, premier démarrage Windows et OOBE.
- Validation de Windows 11 : CPU/TPM/Secure Boot compatibles, drivers, réseau, activation légale, WinRE opérationnel.
- Parcours graphique complet et choix de profils/paramètres/bundles, puis installation silencieuse des vrais logiciels signés au premier logon administrateur.
- Nom, clavier, fuseau, région, thème, fond d’écran du premier compte et journal `result.json`. Les logiciels/fonds d’écran ne sont pas distribués dans le ZIP du code.
- Annulation avant partitionnement et observation d’une coupure réseau. Aucune promesse de rollback après effacement.

## Limites de cette version

Un administrateur partagé, sans rôles utilisateurs/SSO ; opérations supervisées ; UEFI x64 uniquement ; images WIM non fractionnées ; pas de jonction AD, capture d’image, injection automatique de drivers Windows par modèle, multicast, reprise ou contrôle automatique après OOBE. Les logiciels exigent leurs paramètres silencieux, une signature valide et une première connexion administrateur. Le bureau est personnalisé pour ce premier compte ; pas de configuration des futurs comptes ou de stratégie de domaine. Les images d’installation téléchargées via HTTP par l’API ne sont pas le parcours choisi par l’agent ; il lit un WIM SMB/local indépendant du disque cible.

La console n’est pas un contrôleur DHCP/TFTP et ne peut pas démarrer le LAN depuis le cloud. Les scripts PowerShell nécessitent une validation Windows réelle avant une utilisation en production. Les tests Python/navigateur ne remplacent pas cette recette.
