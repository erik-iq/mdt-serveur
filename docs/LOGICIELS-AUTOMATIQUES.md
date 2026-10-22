**Documentation historique :** pour le parcours actuel, utiliser [IQ Atelier 4](ATELIER-4.md). Les pages Infrastructure PXE et Logiciels & bundles ont été retirées du site.

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

## Bouton dans Atelier PXE (révision 2.2)

Après la mise à jour de la console, exécuter une fois dans **Windows PowerShell administrateur sur DEPLOY-01**, avec le compte Windows qui utilisera WinGet :

```powershell
& 'C:\AtelierPXE\console\scripts\Install-WinGet.ps1'
# Rouvrir PowerShell si nécessaire, puis :
& 'C:\AtelierPXE\console\scripts\Enable-SoftwareSync.ps1'
```

Adapter le chemin au dossier installé. La tâche `AtelierPXE-SoftwareSync` démarre immédiatement et à l’ouverture de cette session. Elle s’exécute sans fenêtre et sans mot de passe enregistré, sous ce compte administrateur. **Garder la session Windows ouverte** : le verrouillage et la déconnexion RDP sont possibles, la fermeture de session arrête l’agent. La console web continue à fonctionner avec ses droits limités ; elle n’exécute pas WinGet elle-même.

1. Dans **Logiciels & bundles**, cliquer sur **Mettre à jour les logiciels**.
2. Sélectionner VLC, Adobe Reader, Chrome et/ou AnyDesk.
3. Cocher les bundles auxquels ajouter ces logiciels s’ils n’y sont pas encore. Laisser vide pour actualiser uniquement le catalogue et les références existantes.
4. Cliquer sur **Télécharger et appliquer**, puis suivre les étapes et le bilan dans la page. L’onglet peut être fermé pendant le travail ; le dernier résultat est conservé en base.

Le pourcentage suit les étapes, sans prétendre mesurer les octets téléchargés. Les versions visibles dans les cartes des bundles confirment le catalogue actualisé. Les autres logiciels du bundle sont conservés, les doublons évités. Seuls les logiciels téléchargés et vérifiés avec succès sont ajoutés aux bundles sélectionnés. Les associations déjà mémorisées gardent leur identifiant, même si un logiciel porte un autre nom dans votre atelier.

Les autorisations WinPE doivent être terminées ou annulées avant le lancement. Pendant la synchronisation, la création d’une nouvelle autorisation est bloquée pour éviter un catalogue incohérent. Les fichiers anciens sont conservés ; les machines déjà installées ne sont pas mises à jour par ce bouton. Il n’installe pas les logiciels sur le serveur.

Une demande encore en attente peut être annulée depuis la page si l’agent est devenu indisponible. Une opération déjà démarrée se termine avant une nouvelle demande.

Un agent hors ligne signifie que la session configurée est fermée, que la tâche est arrêtée ou que WinGet n’est pas disponible dans ce profil. Consulter la tâche `AtelierPXE-SoftwareSync` et `data\software-sync\worker.log`. Pour redémarrer l’agent après correction :

```powershell
Start-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync'
```

Une tâche en cours est limitée à quatre heures. Après un arrêt brutal de Windows ou de l’agent, la demande en cours passe à « Interrompu » au redémarrage de l’agent ; relancer le bouton pour reprendre. Un téléchargement ne peut pas modifier le catalogue après que sa demande a été interrompue. Le fichier privé `software-sync\worker-key` sert uniquement à l’agent : ne pas le partager.

La révision 2.2 se met à jour avec `Update-Console.ps1` ; **aucune reconstruction WinPE ni modification des réponses WDS n’est nécessaire pour le bouton**. Le script refuse de remplacer la console pendant une synchronisation et relance un agent déjà actif après la mise à jour. Pour changer de compte Windows, attendre la fin des travaux, arrêter la tâche puis exécuter `Enable-SoftwareSync.ps1` sous le nouveau compte.

## Diagnostic des échecs (révision 2.3)

Le message de la révision 2.2 « Échec avant la publication des résultats » indiquait que le processus PowerShell n’avait pas écrit son bilan. Il ne permettait pas de savoir pourquoi : certaines erreurs du processus étaient supprimées, même si l’agent restait disponible. Un état « Agent prêt » signifiait que la commande WinGet était trouvée, sans garantir qu’un téléchargement réussirait.

La révision 2.3 conserve les erreurs du processus, les affiche dans le bilan de la page et les écrit dans `data\software-sync\worker.log`. Les secrets de l’agent sont masqués. En cas d’échec WinGet, le message contient son code décimal/hexadécimal et les dernières lignes de sortie utiles. Les lignes écrites sur stderr sont traitées avec le code de sortie, pour éviter qu’un message informatif soit pris pour un échec sous Windows PowerShell 5.1.

Les demandes du bouton utilisent l’API sur `127.0.0.1`, déjà employée par l’agent. Elles ne dépendent plus de la confiance du compte de l’agent dans le certificat HTTPS public de la console ni du chemin via IIS. HTTPS reste utilisé pour le site et pour les téléchargements des éditeurs ; aucun contrôlé de certificat n’est désactivé.

Un échec avant la première étape conserve une progression de 0 %, au lieu d’afficher automatiquement 100 %. Mettre à jour la console avec `Update-Console.ps1`, puis relancer le bouton : le bilan précédent n’est pas réécrit rétroactivement. La mise à jour redémarre l’agent qui était actif et ne modifie pas WDS/WinPE. La capture de l’ancien message seule ne permet pas d’identifier la cause initiale ; si le nouvel essai échoue, transmettre le message précis du bilan.

### Erreur System.Object[] sur le paramètre Message

Windows PowerShell 5.1 émet le tableau JSON des sources comme un seul objet du pipeline. L’ancienne expression `@(Get-Content ... | ConvertFrom-Json)` ajoutait une enveloppe : la recherche de VLC renvoyait alors la liste des quatre logiciels, et le journal échouait avec « Impossible de convertir System.Object[] en System.String, requis par le paramètre Message ». Le chargement affecte maintenant directement le résultat de `ConvertFrom-Json` pour conserver le tableau au bon niveau.

Ce correctif ne demande que le remplacement de `scripts\Sync-Applications.ps1`. Le processus de synchronisation recharge ce script à chaque clic : il n’est pas nécessaire de réinstaller WinGet ou de redémarrer la console. Le test de régression reproduit le comportement JSON de Windows PowerShell 5.1 ; il échoue avec l’ancienne ligne et réussit après correction. Les essais sous PowerShell 7 seuls ne reproduisaient pas ce comportement.

## Actualiser les quatre logiciels

Terminer ou annuler les autorisations WinPE encore activés, puis lancer :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-Applications.ps1'
```

Pour un choix plus réduit, ou pour ajouter les logiciels sélectionnés à un bundle :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-Applications.ps1' -Packages vlc,chrome
# Option : -BundleIds 'identifiant-du-bundle'
```

Le script détecte le dossier installé depuis la tâche `AtelierPXE-Console`. On peut aussi préciser `-InstallPath 'D:\MonAtelier\console'`.

Chaque téléchargement est vérifié : SHA-256 du manifeste WinGet, signature Authenticode valide, signataire et domaine éditeur attendus. Les fichiers sont enregistrés sous un nouveau nom contenant la version et une empreinte. Aucun ancien installateur n’est écrasé ou supprimé. Un téléchargement refusé par WinGet ou un contrôle en échec ne sont pas contournés.

Lorsqu’un logiciel existe déjà, son identifiant Atelier est conservé : les bundles et profils qui le référencent utilisent sa nouvelle version pour les prochaines autorisations. Un logiciel nouveau apparaît dans le catalogue ; choisir ses bundles dans le bouton, ou l’ajouter une fois manuellement. Les PC déjà déployés ne sont pas mis à jour par cette synchronisation serveur.

Les premières associations sont recherchées par les noms usuels et les références des bundles. En cas de plusieurs entrées ambiguës, fournir une fois les identifiants voulus :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-Applications.ps1' -Packages vlc `
    -ApplicationBindings @{ vlc = 'identifiant-du-logiciel-dans-Atelier' }
```

Les associations sont mémorisées dans `data\software-sync\bindings.json`. Le bilan est dans `data\software-sync\last-sync.json`. Un résultat `updated` indiqué un remplacement dans le catalogue, `created` une nouvelle entrée, `unchanged` une version déjà enregistrée et `failed` une opération refusée. Les autres logiciels peuvent réussir malgré l’échec d’un paquet ; le script signale alors une synchronisation partielle.

Créer ensuite de nouvelles autorisations. **Une mise à jour des seuls installateurs ne nécessite pas de reconstruire WinPE.** Aucune mise à jour automatique périodique n’est lancée : utiliser le bouton ou cette commande avant une série de déploiements. L’agent attend les demandes explicites du bouton.

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
