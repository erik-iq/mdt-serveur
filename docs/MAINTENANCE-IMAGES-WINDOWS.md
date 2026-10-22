# Maintenance mensuelle des images Windows - IQ-5.5

## Lancer la préparation Famille et Pro

Sur DEPLOY-01, PowerShell administrateur :

```powershell
& 'C:\AtelierPXE\console\scripts\Enable-WindowsImageMaintenance.ps1' `
    -InstallPath 'C:\AtelierPXE\console' -RunNow
```

Cette commande prépare une copie contenant uniquement Famille et Pro, avec compression rapide. Elle refuse de remplacer une tâche déjà en cours. Les correctifs Microsoft et les prérequis sont mis en cache. Un candidat intact est réutilisé si le contenu et les correctifs n’ont pas changé. La première intégration dépend de la vitesse du stockage et de DISM ; aucune durée fixe n’est garantie.

Suivre ensuite **Images et correctifs**. Le bouton de recherche des KB ne fait qu’interroger les métadonnées. La tâche de préparation effectue le téléchargement et l’intégration. Lorsque la candidate est prête, copier la commande de mise en test depuis cette page, déployer les éditions utilisées, puis publier avec leurs identifiants de déploiement réussis. L’image de production reste inchangée pendant la préparation.


Cette fonction prépare les mises à jour une seule fois sur DEPLOY-01 (.250), dans une copie de chaque WIM utilisé par les profils de production. Les postes suivants reçoivent cette image après sa validation. Aucun correctif n’est installé dans Windows Server et aucun WIM actif n’est écrasé. Windows Update et Microsoft Store restent manuels sur les postes. HPIA garde son fonctionnement actuel ; cette maintenance ne corrige pas ses erreurs et ne fournit pas les pilotes propres au modèle.

## Installer et lancer la première préparation

Mettre la console à jour avec les sources IQ-5.5 et `Update-Console.ps1`. Cette fonction est uniquement serveur : aucun nouveau WinPE n’est nécessaire si le WinPE actuel fonctionne. Ouvrir Windows PowerShell administrateur sur .250 :

```powershell
& 'C:\AtelierPXE\console\scripts\Enable-WindowsImageMaintenance.ps1' -RunNow
```

La tâche `AtelierPXE-WindowsImageMaintenance` démarre en arrière-plan. Elle prépare ensuite les images le **15 de chaque mois à 02:00, heure locale du serveur** (après le deuxième mardi du mois). Elle reprend à la prochaine disponibilité du serveur s’il était arrêté. Une seconde exécution est ignorée lorsqu’une préparation fonctionne déjà. Pour conserver le travail en cours, laisser DISM terminer. Pour abandonner volontairement la copie candidate, utiliser la procédure d’annulation ci-dessous ; ne pas tuér tous les processus DISM, redémarrer .250 ou supprimer un dossier encore monté.

Si une première installation affiche `0x80041318` et `LogonType:ServiceAccount`, la tâche n’a pas été créée et la maintenance n’a pas démarré. Utiliser le script corrigé puis relancer la même commande `-RunNow` ; aucune reconstruction WinPE n’est nécessaire. Le compte SYSTEM est déclaré par son SID `S-1-5-18`, sans élément XML LogonType. Un échec de création ou de démarrage arrête le script sans annoncer une planification réussie.

Pour préparer manuellement, sans nouvelle planification :

```powershell
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1'
```

Les WIM utilisés par les profils de production Famille/Pro sont préparés. Les anciens profils sans édition explicite restent compatibles lorsqu’ils utilisent un index préparé. `-AssetId 'identifiant-du-fichier'` limite une exécution manuelle à une image. **Seuls Windows Famille (EditionId Core) et Windows Pro (EditionId Professional) sont exportés dans une nouvelle candidate en compression fast.** Le WIM original complet reste conservé et sauvegardé. Les éditions N, Single Language, Éducation et Workstations ne sont pas exportées. Un WIM sans Famille ni Pro est refusé. Fast privilégie la vitesse de compression mais peut produire un fichier plus volumineux que max.

Les index de la candidate sont renumérotés : par exemple Famille source 1 devient candidat 1 et Pro source 6 devient candidat 2. Le rapport schéma 2 indiqué source_index et index dans selected_indexes et indexes, ainsi que skipped_indexes, layout=home_pro_fast_v1 et scope=home_pro. Le workflow de test/publication effectue lui-même cette correspondance. Les profils des autres éditions restent sur leur image originale.

Ces changements concernent les nouvelles exécutions ; une tâche déjà lancée a chargé l’ancien code. La sortie DISM est maintenant transmise au journal .console.log au fil des lignes reçues. Le rapport contient active_stage, active_index, updated_at, progress_text et timings : sauvegarde, export, montage, catalogue/téléchargement, intégration par KB, enregistrement et SHA-256. Les sorties disponibles actualisent le suivi au plus toutes les dix secondes ; une commande silencieuse ne donne pas de pourcentage inventé.

## Éviter un travail identique

Avant de sauvegarder, exporter ou monter, le script recherche une candidate terminée au nouveau format et associée au SHA-256 exact du WIM source. Il consulte les métadonnées du catalogue Microsoft avec select-only, sans télécharger de MSU, et compare les identifiants Microsoft, KB et builds Windows/.NET.

Si les correctifs sont identiques et si la candidate existe avec le SHA-256 attendu, le même report.json est réutilisé sans export, montage, téléchargement ou commit. Si le WIM source correspond déjà à la candidate préparée et que le catalogue n’a pas changé, le résultat est up_to_date. Une nouvelle KB, un candidat absent ou modifié, ou un rapport incomplet/annulé ne donne pas de faux résultat à jour. Un catalogue inaccessible reste un échec explicite. Le contrôle lit encore le WIM source pour vérifier son SHA-256.

La première préparation d’une source inconnue reste nécessaire et sa durée n’est pas garantie en quelques minutes. La vitesse du disque physique de la VM compte : placer les données sur un SSD adapté exige une configuration de l’hyperviseur, pas un changement PowerShell qui transformerait le stockage.

## Suivi dans le site

La page **Images et correctifs** affiche l’état mesuré de la tâche, les WIM, les passages, les étapes et durées, les index source/candidat, les KB et la validation. **Vérifier les nouveaux correctifs** recherche seulement les métadonnées Microsoft en arrière-plan : aucun MSU téléchargé et aucun DISM lancé. Les versions viennent des rapports transmis ; une version déjà détectée est nécessaire. Nouveau signifie différent du passage comparé, pas déjà installé ou publié dans l’image de production.

Les dossiers privés windows-servicing, sauvegardes et montages restent réservés à SYSTEM et aux administrateurs. Les métadonnées sont copiées dans `<data_dir>\maintenance-overview` ; l’agent serveur les actualise environ toutes les trente secondes. La console lit ce miroir. Les pages et les téléchargements demandent l’autorisation administrateur habituelle. Les dates des mesures restent visibles ; les tailles logiques de stockage excluent les arborescences montées.

## Annuler une préparation trop longue

L’annulation abandonne la copie candidate, y compris les éditions déjà traitées dans cette copie. L’image originale utilisée par PXE, sa sauvegarde, les correctifs en cache et les journaux restent conservés. Ce n’est pas une reprise de la préparation ; aucune image annulée ne peut être enregistrée pour test ou publiée.

Si une fenêtre PowerShell attend la fin de la maintenance pour lancer une mise à jour de la console, interrompre d’abord cette attente avec Ctrl+C dans cette fenêtre. Dans une autre fenêtre PowerShell administrateur sur .250, utiliser le RunId du journal :

```powershell
& 'C:\AtelierPXE\console\scripts\Stop-WindowsImageMaintenance.ps1' `
    -InstallPath 'C:\AtelierPXE\console' -RunId '20261021-103851-f52d8739'
```

Le script vérifie le rapport, la tâche et l’appartenance du montage au candidate.wim privé. Il désactive les prochains déclenchements, arrête la tâche puis uniquement les DISM dont les arguments correspondent exactement a cette copie. Il ne tue pas les WimServ ou les DISM étrangers. Il demande ensuite le démontage avec abandon des changements, vérifie la disparition du montage et la libération du candidat, et marque le rapport cancelled. Le temps de libération du montage dépend de Windows ; il ne peut pas être garanti instantané. Aucun fichier WIM ni dossier de montage n’est supprimé par cet outil.

Avec IQ-5.5, omettre RunId et ajouter `-IfActive` identifie automatiquement l’exécution à partir des arguments exacts de DISM ou du candidat monté. Si aucune maintenance ne tourne, cette option ne fait rien. Plusieurs exécutions possibles ou une tâche active sans candidat identifiable provoquent un refus avant tout arrêt ; utiliser alors le RunId du journal courant.

Un échec de récupération laisse le rapport cancelled_cleanup_required et tous les fichiers conservés. Ne pas lancer une nouvelle préparation ou mise à jour de console avant résolution. Si la tâche active ne correspond plus au RunId indiqué, le script refuse l’arrêt : relire la transcription plutôt que réutiliser un ancien PID.

Après le message Maintenance annulée et montage libère, la mise à jour de la console et la reconstruction WinPE peuvent reprendre. La maintenance WIM reste en pause. Quand l’opérateur souhaite la réactiver, `Enable-WindowsImageMaintenance.ps1` sans RunNow rétablit la planification ; ajouter RunNow lance une nouvelle préparation Famille/Pro avec les scripts récents.

## Sauvegardes et correctifs

Le dossier `<data_dir>\windows-servicing`, soit normalement `D:\AtelierPXE\data\windows-servicing`, contient :

| Chemin | Contenu |
| --- | --- |
| backups\SHA256.wim | Copie complète du WIM source, vérifiée par SHA-256. Une source identique réutilise sa sauvegarde. |
| packages\GUID-Microsoft | Cache des MSU Microsoft. Un dossier contient seulement la mise à jour cible et ses checkpoints. |
| runs\DATE-IDENTIFIANT\candidate.wim | Copie maintenue, jamais le fichier de production. |
| runs\DATE-IDENTIFIANT\report.json | État global, source, sauvegarde, index, correctifs et erreur éventuelle. |
| runs\DATE-IDENTIFIANT\updates-index-N.json | Titres, KB, URL Microsoft, taille et empreintes de chaque fichier. |
| runs\DATE-IDENTIFIANT\catalog-index-N.log | Sortie Python et erreur précise du catalogue ou du téléchargement Microsoft, également reprises dans la transcription. |
| runs\DATE-IDENTIFIANT\catalog-input-index-N.json | Version, build, architecture et .NET lus dans cet index du WIM avant la recherche. |
| runs\DATE-IDENTIFIANT\packages-index-N.csv | État des paquets après intégration. InstallPending demande un premier démarrage de test. |
| runs\DATE-IDENTIFIANT\dism-index-N.log | Journal DISM ; le fichier .console.log contient aussi sa sortie texte. |
| maintenance-DATE-IDENTIFIANT.log | Journal de l’exécution de la tâche, y compris les erreurs avant création d’un rapport. |

Le dossier de travail est réservé aux administrateurs et à SYSTEM. Les sauvegardes ne sont pas publiées dans le partage des images. Le cache évite de télécharger de nouveau un paquet identique, mais l’espace doit permettre une sauvegarde, le WIM candidat, le montage et les correctifs. La vérification initiale exige au moins trois fois la taille du WIM et 25 Go disponibles. Le volume réel peut être supérieur pour une image avec beaucoup d’index. Aucune ancienne image ou sauvegarde n’est supprimée automatiquement.

Le script lit DisplayVersion, le build et .NET Framework dans le registre du WIM monte. Il recherche la dernière cumulative Windows stable et la cumulative du .NET Framework présent. Il exclut les apercus Preview, Insider, changements de version, pilotes, correctifs Setup et SafeOS. Les prérequis checkpoints fournis dans la fenêtre de téléchargement Microsoft sont tous telecharges avec le paquet cible. DISM les resout depuis ce dossier. Les langues, composants facultatifs et paramètres français suisse ne sont pas changés ; .NET 3.5 n’est pas activé de forcé.

Les téléchargements utilisent HTTPS vers les domaines Microsoft autorisés. Les empreintes annoncees dans les noms de fichiers du catalogue sont vérifiées, puis un SHA-256 local est conservé et relu avant DISM. Les contrôles normaux de signature et d’applicabilité DISM restent actifs, sans IgnoreCheck ni ForceUnsigned. Le catalogue Microsoft ne fournit pas d’API publique stable : si sa page change, si une version est inconnue, si la recherche est ambiguë ou si les fichiers attendus manquent, la préparation échoue au lieu de substituer un autre correctif.

L’ADK doit prendre en charge le Windows de l’image. Pour Windows 11 26H2, Microsoft indiqué l’ADK 10.1.26100.9457 de septembre 2026. Le script sait que 24H2/25H2/26H2 partagent une plateforme de maintenance : il n’exige pas un DISM 26300 inexistant pour une image 26300. En cas d’outil trop ancien, mettre les outils de déploiement ADK à jour selon la documentation Microsoft. Le script ne remplace pas lui-même l’ADK de .250.

## Enregistrer un candidat pour le test

Un rapport `ready_for_test` signifie que DISM a accepte les intégrations et que le WIM a été relu, pas que Windows a déjà démarré avec succès. Un échec provoque un démontage avec abandon des modifications ; le candidat incomplet est retire. Si le démontage échoue, l’état est `failed_cleanup_required` et les fichiers sont conservés pour diagnostic, sans nettoyage récursif du montage.

Repérer le dossier `runs\DATE-IDENTIFIANT` annonce dans le journal. Exemple, en remplaçant uniquement le chemin du rapport par le vrai :

```powershell
$atelierRapport = 'D:\AtelierPXE\data\windows-servicing\runs\DATE-IDENTIFIANT\report.json'
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1' -Mode RegisterTest -ReportPath $atelierRapport
```

Le WIM candidat est copié dans artifacts sous un nouveau nom. Des profils **TEST DATE-IDENTIFIANT** sont créés pour les profils Famille/Pro concernes, avec les index exportés, la même langue et les mêmes réglages. Les anciennes préparations non réduites restent compatibles. Les profils TEST apparaissent dans WinPE sans être choisis automatiquement ; la production garde son ancien WIM. La synchronisation des éditions ignore un candidat encore en validation. La page Images et correctifs permet de copier la commande de mise en test.

Démarrer un PC de test en PXE, choisir explicitement le profil TEST de la bonne édition et confirmer son disque comme pour un déploiement normal. **Le disque du PC de test est effacé.** Attendre le premier démarrage et la fin de la préparation Windows, puis vérifier les applications, le matériel et le rapport. Faire un test pour chaque index utilise : Pro et Famille si les deux sont disponibles. Les tests de versions d’image sont distincts des essais HPIA sur le HP physique.

## Publier après les tests

Lire les identifiants et les résultats depuis .250, sans commande sur le PC déployé :

```powershell
$atelierRun = (Get-Content -LiteralPath $atelierRapport -Raw | ConvertFrom-Json).run_id
$atelierEtat = & 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1' -Mode Status -RunId $atelierRun | ConvertFrom-Json
$atelierEtat.test_deployments | Format-Table id, name, status, windows_status
```

Après vérification visuelle du poste, remplacer les exemples ci-dessous par les vrais identifiants des déploiements TEST réussis :

```powershell
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1' -Mode Publish -RunId $atelierRun -TestDeploymentId @('ID-TEST-PRO','ID-TEST-FAMILLE')
```

Si un seul index est utilisé, fournir un seul identifiant. Le contrôle exige `status=staged` et `windows_status=completed` pour chaque index des profils concernes. Image appliquée seule, une préparation encore activé, un avertissement HPIA non resolu ou un déploiement d’une autre image ne suffisent pas. Les déploiements en attente ou en cours doivent être terminés avant publication. Un WIM modifie ou une liste de profils source changée annulent aussi la publication.

La publication change en une transaction le WIM et l’index correspondant des profils Famille/Pro. Elle conserve leur nom, leur langue et leurs réglages. Les profils des autres éditions restent sur l’ancien WIM. L’ancien WIM et les tests restent disponibles ; aucune image active n’est écrasée. La maintenance mensuelle ne publie jamais automatiquement.

## Limites et vérification

Cette fonction maintient install.wim et ses index. Elle ne met pas à jour WinRE/WinPE, les applications Store, les runtimes .NET installés par les applications, les pilotes ou les firmwares. Elle n’effectue pas de changement de version Windows et ne garantit pas zéro proposition restante dans Windows Update.

Les tests du projet exécutent les transactions avec SQLite et l’API réelles, les sélections et contrôles de téléchargements sur des réponses catalogue simulées, et l’orchestration PowerShell avec DISM simule. L’intégration native DISM et le premier démarrage ne peuvent être validés que sur .250 et un ordinateur de test. Aucun WIM réel de l’atelier n’est disponible dans l’environnement de développement.

Sources officielles :

- [Microsoft - ajouter des mises à jour à une image Windows](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/servicing-the-image-with-windows-updates-sxs?view=windows-11)
- [Microsoft - checkpoints et catalogue](https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates)
- [Microsoft - ADK compatibles](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
