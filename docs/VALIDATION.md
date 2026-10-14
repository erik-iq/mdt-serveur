# Recette de validation

## Tests exécutables dans le cloud

```bash
.venv/bin/python -m pytest -q
node --check app/static/app.js
pwsh -NoProfile -File scripts/Test-PowerShellSyntax.ps1
```

Les tests API exercent l’authentification, le lifecycle, les transitions refusées, l’annulation/révocation, les jobs concurrents, les MAC invalides, les chemins/symlinks, les images modifiées, le transport iPXE et la persistance SQLite. Ils utilisent des fichiers synthétiques à en-tête WIM pour tester le contrôle serveur ; ils ne constituent pas une validation DISM ou de véritables images Windows.

La syntaxe des sept scripts PowerShell a également été vérifiée avec le parseur PowerShell 7.5.4. Les scripts sont enregistrés en UTF-8 avec BOM pour Windows PowerShell 5.1. Ce contrôle ne valide ni la présence des cmdlets sur Server 2025/WinPE ni leur exécution.

`tests/test_winpe_process.py` ajoute trois contrôles réservés à Windows PowerShell 5.1 en administrateur : chemins ADK/sortie avec espaces, transmission de l’environnement entre les deux fichiers batch, puis arrêt avant montage lorsqu’un batch échoue. Il utilise le vrai `cmd.exe` avec un ADK simulé dans un dossier temporaire ; DISM et WDS ne sont pas exécutés. Ces trois contrôles sont ignorés sous Linux. Sur Windows, lancer `.venv\Scripts\python.exe -m pytest -q tests\test_winpe_process.py`.

Le test navigateur optionnel `tests/browser_smoke.py` utilise Chromium installé sur la machine, démarre un serveur isolé et vérifie les formulaires, le journal, l’annulation et le rendu mobile. Il se lance avec `.venv/bin/python tests/browser_smoke.py` après installation de `requirements-browser.txt`.

## À exécuter sur Server 2025 et un PC de test

- Installation de Python/service, permissions LOCAL SERVICE, redémarrage du serveur et accès HTTPS depuis le LAN.
- Construction WinPE avec les packages ADK, drivers NIC/NVMe et certificat racine.
- Import WDS et démarrage UEFI réel avec vos paramètres DHCP ; Secure Boot selon votre matériel.
- Accès SMB chiffré en lecture seule, édition Windows x64 réellement présente dans le WIM.
- Refus d’une mauvaise MAC, d’un hash incorrect, d’un mauvais disque et d’une confirmation incorrecte **avant tout effacement**.
- Déploiement sur un disque sacrifiable ; progression DISM, création GPT, BCDBoot, premier démarrage Windows et OOBE.
- Validation de Windows 11 : CPU/TPM/Secure Boot compatibles, drivers, réseau, activation légale, WinRE opérationnel.
- Annulation avant partitionnement et observation d’une coupure réseau. Aucune promesse de rollback après effacement.

## Limites de cette version

Un administrateur partagé, sans rôles utilisateurs/SSO ; opérations supervisées ; UEFI x64 uniquement ; images WIM non fractionnées ; pas de jonction AD, paquet applicatif, capture d’image, injection automatique de drivers Windows, multicast, reprise ou contrôle automatique après OOBE. Les images d’installation téléchargées via HTTP par l’API ne sont pas le parcours choisi par l’agent ; il lit un WIM SMB/local indépendant du disque cible.

La console n’est pas un contrôleur DHCP/TFTP et ne peut pas démarrer le LAN depuis le cloud. Les scripts PowerShell nécessitent une validation Windows réelle avant une utilisation en production. Les tests Python/navigateur ne remplacent pas cette recette.
