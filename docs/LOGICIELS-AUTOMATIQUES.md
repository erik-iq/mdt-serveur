# Actualiser les logiciels et exporter l’inventaire

La révision **ATELIER-2.1** permet de récupérer les installateurs depuis le catalogue Microsoft WinGet et d’actualiser les logiciels d’Atelier sans modifier les bundles qui les utilisent. Elle ajoute aussi l’inventaire technique XML et CSV dans `C:\IQ_`.

## Pourquoi WinGet plutôt que wget

`wget` ou `Invoke-WebRequest` télécharge une URL. Cela ne suffit pas à trouver la dernière version quand l’adresse contient son numéro. **WinGet** sait rechercher les versions et leurs installateurs. Ici, il télécharge les paquets sur DEPLOY-01 : les PC continuent à recevoir les installateurs depuis le partage de l’atelier.

Les versions récupérées sont les dernières disponibles dans le catalogue WinGet, qui peut être en décalage avec une publication récente de l’éditeur. Le script n’installe pas VLC, Reader, Chrome ou AnyDesk sur le serveur.

| Logiciel | Identifiant WinGet | Installation préparée |
| --- | --- | --- |
| VLC | `VideoLAN.VLC` | EXE x64, mode silencieux |
| Adobe Acrobat Reader | `Adobe.Acrobat.Reader.64-bit` | EXE x64 multilingue, mode silencieux |
| Google Chrome | `Google.Chrome` | MSI x64, pour la machine |
| AnyDesk | `AnyDesk.AnyDesk` | EXE x86 compatible Windows x64, installation et raccourcis |

La configuration est dans `scripts\software-sources.json` : identifiant, architecture, type, paramètres silencieux, domaines éditeurs et signataires attendus. Pour ajouter un autre logiciel, ajouter une source et tester son installation silencieuse une fois. Il n’est pas nécessaire de modifier cette configuration à chaque numéro de version. Les médias WIM et HP Image Assistant restent gérés séparément.

## Préparer WinGet une seule fois

Sur **DEPLOY-01**, sous le compte administrateur utilisé pour les téléchargements, après la mise à jour ATELIER-2.1 :

```powershell
& 'C:\AtelierPXE\console\scripts\Install-WinGet.ps1'
```

Adapter le chemin si la console est installée ailleurs. Le script réutilise WinGet s’il est disponible, tente son enregistrement App Installer, puis utilise le module officiel `Microsoft.WinGet.Client` et `Repair-WinGetPackageManager` si nécessaire. Windows Server 2025 avec interface graphique est pris en charge par Microsoft. Une connexion Internet vers Microsoft, PowerShell Gallery et les éditeurs est nécessaire. Rouvrir PowerShell si l’enregistrement ou le PATH vient de changer.

## Actualiser les quatre logiciels

Terminer ou annuler les autorisations WinPE encore actives, puis lancer :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-Applications.ps1'
```

Pour un choix plus réduit :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-Applications.ps1' -Packages vlc,chrome
```

Le script détecte le dossier installé depuis la tâche `AtelierPXE-Console`. On peut aussi préciser `-InstallPath 'D:\MonAtelier\console'`.

Chaque téléchargement est vérifié : SHA-256 du manifeste WinGet, signature Authenticode valide, signataire et domaine éditeur attendus. Les fichiers sont enregistrés sous un nouveau nom contenant la version et une empreinte. Aucun ancien installateur n’est écrasé ou supprimé. Un téléchargement refusé par WinGet ou un contrôle en échec ne sont pas contournés.

Lorsqu’un logiciel existe déjà, son identifiant Atelier est conservé : les bundles et profils qui le référencent utilisent sa nouvelle version pour les prochaines autorisations. Un logiciel nouveau apparaît dans le catalogue ; l’ajouter une fois au bundle souhaité. Les PC déjà déployés ne sont pas mis à jour par cette synchronisation serveur.

Les premières associations sont recherchées par les noms usuels et les références des bundles. En cas de plusieurs entrées ambiguës, fournir une fois les identifiants voulus :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-Applications.ps1' -Packages vlc `
    -ApplicationBindings @{ vlc = 'identifiant-du-logiciel-dans-Atelier' }
```

Les associations sont mémorisées dans `data\software-sync\bindings.json`. Le bilan est dans `data\software-sync\last-sync.json`. Un résultat `updated` indique un remplacement dans le catalogue, `created` une nouvelle entrée, `unchanged` une version déjà enregistrée et `failed` une opération refusée. Les autres logiciels peuvent réussir malgré l’échec d’un paquet ; le script signale alors une synchronisation partielle.

Créer ensuite de nouvelles autorisations. **Une mise à jour des seuls installateurs ne nécessite pas de reconstruire WinPE.** Aucune tâche périodique n’est créée : relancer cette commande avant une série de déploiements lorsque l’on souhaite actualiser les versions.

## Inventaire XML et CSV dans IQ

Après la fin de la préparation Windows avec la nouvelle image ATELIER-2.1, le dossier racine `C:\IQ_` contient :

| Fichier | Contenu |
| --- | --- |
| `Inventaire-Technique.xml` | Inventaire structuré avec catégories, propriétés typées, date de collecte et état de chaque source. |
| `Inventaire-Technique.csv` | Même relevé sous forme de lignes, séparateur point-virgule, UTF-8 pour Excel. |
| `Export-Inventaire.cmd` | Relancer la collecte détaillée, avec élévation administrateur. |

Le relevé comprend les propriétés matérielles exposées par Windows : constructeur, modèle, SN, carte mère, boîtier, BIOS, processeurs et caches, barrettes et emplacements RAM, disques et firmwares, partitions, volumes et espaces libres, type SSD/HDD, compteurs de santé disponibles, GPU, écrans, réseau, USB, contrôleurs, audio, claviers, souris, batteries, périphériques et pilotes signés.

Les sections système ajoutent Windows et son édition/build, activation et canal de licence, services de licence, TPM, Secure Boot, état BitLocker, démarrage rapide, correctifs, fuseau, routes réseau, services et logiciels installés en 32/64 bits ainsi que les applications Store. Les tableaux sont détaillés par élément : plusieurs barrettes, disques ou adresses IP restent distincts.

Le CSV utilise les colonnes `Ordinateur`, `CollecteUTC`, `Categorie`, `Element`, `Propriete`, `Valeur`, `Type`, `Etat`, `Erreur`. Il n’aplatit pas tout le PC en une seule ligne avec des milliers de colonnes. Les textes susceptibles d’être interprétés comme des formules Excel sont préfixés dans le CSV ; le XML conserve leur texte.

Un état `vide` signifie qu’aucun élément n’est présent pour cette catégorie. `indisponible` signale un fournisseur absent, une fonction non prise en charge ou un accès refusé. Les capteurs SMART/usure/température et certaines données batterie ne sont pas exposés par tous les matériels ou pilotes. L’inventaire ne prétend pas récupérer une information que le matériel ne fournit pas.

Les clés de produit complètes, les mots de passe, les clés de récupération BitLocker et l’authentification propriétaire TPM sont exclus. Le relevé ne lance ni test destructif de stockage ni réparation MSI : `Win32_Product` n’est pas utilisé.

`Generer-Rapport.cmd` actualise également cet inventaire lors d’une régénération manuelle du PDF. Les tentatives automatiques de renvoi du rapport réutilisent les exports existants pour éviter une collecte complète toutes les quinze minutes. Les XML/CSV restent locaux ; le PDF dans Atelier continue à fournir la synthèse et le déroulement du déploiement.

Sur un PC déjà installé, `Export-Inventaire.ps1` est autonome et peut être exécuté directement en PowerShell administrateur avec `-OutputDirectory 'C:\IQ_'`. Il n’exige pas une réinstallation de Windows.

## Détection de la console pendant la mise à jour

L’ancien script supposait `C:\AtelierPXE\console`. Désormais le dossier est recherché à partir de la tâche `AtelierPXE-Console`, de son dossier de travail et du chemin du programme. La présence de `data-runtime.json` est vérifiée avant toute modification. Si la tâche est absente, vérifier que la commande est exécutée sur **DEPLOY-01 / 192.168.99.250**, et non sur le PC installé ou l’hôte Hyper-V. Une configuration manquante n’est jamais recréée automatiquement.

## Références

- [Microsoft WinGet et installation du gestionnaire](https://learn.microsoft.com/en-us/windows/package-manager/winget/)
- [Commande WinGet download](https://learn.microsoft.com/en-us/windows/package-manager/winget/download)
- [Catalogue Microsoft winget-pkgs](https://github.com/microsoft/winget-pkgs)
