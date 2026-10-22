# Maintenance mensuelle des images Windows - IQ-5.5

Cette fonction prepare les mises a jour une seule fois sur DEPLOY-01 (.250), dans une copie de chaque WIM utilise par les profils de production. Les postes suivants recoivent cette image apres sa validation. Aucun correctif n est installe dans Windows Server et aucun WIM actif n est ecrase. Windows Update et Microsoft Store restent manuels sur les postes. HPIA garde son fonctionnement actuel ; cette maintenance ne corrige pas ses erreurs et ne fournit pas les pilotes propres au modele.

## Installer et lancer la premiere preparation

Mettre la console a jour avec les sources IQ-5.5 et `Update-Console.ps1`. Cette fonction est uniquement serveur : aucun nouveau WinPE n est necessaire si le WinPE actuel fonctionne. Ouvrir Windows PowerShell administrateur sur .250 :

```powershell
& 'C:\AtelierPXE\console\scripts\Enable-WindowsImageMaintenance.ps1' -RunNow
```

La tache `AtelierPXE-WindowsImageMaintenance` demarre en arriere-plan. Elle prepare ensuite les images le **15 de chaque mois a 02:00, heure locale du serveur** (apres le deuxieme mardi du mois). Elle reprend a la prochaine disponibilite du serveur s il etait arrete. Une seconde execution est ignoree lorsqu une preparation fonctionne deja. Pour conserver le travail en cours, laisser DISM terminer. Pour abandonner volontairement la copie candidate, utiliser la procedure d annulation ci-dessous ; ne pas tuer tous les processus DISM, redemarrer .250 ou supprimer un dossier encore monte.

Si une premiere installation affiche `0x80041318` et `LogonType:ServiceAccount`, la tache n a pas ete creee et la maintenance n a pas demarre. Utiliser le script corrige puis relancer la meme commande `-RunNow` ; aucune reconstruction WinPE n est necessaire. Le compte SYSTEM est declare par son SID `S-1-5-18`, sans element XML LogonType. Un echec de creation ou de demarrage arrete le script sans annoncer une planification reussie.

Pour preparer manuellement, sans nouvelle planification :

```powershell
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1'
```

Les WIM utilises par les profils de production Famille/Pro sont prepares. Les anciens profils sans edition explicite restent compatibles lorsqu ils utilisent un index prepare. `-AssetId 'identifiant-du-fichier'` limite une execution manuelle a une image. **Seuls Windows Famille (EditionId Core) et Windows Pro (EditionId Professional) sont exportes dans une nouvelle candidate en compression fast.** Le WIM original complet reste conserve et sauvegarde. Les editions N, Single Language, Education et Workstations ne sont pas exportees. Un WIM sans Famille ni Pro est refuse. Fast privilegie la vitesse de compression mais peut produire un fichier plus volumineux que max.

Les index de la candidate sont renumerotes : par exemple Famille source 1 devient candidat 1 et Pro source 6 devient candidat 2. Le rapport schema 2 indique source_index et index dans selected_indexes et indexes, ainsi que skipped_indexes, layout=home_pro_fast_v1 et scope=home_pro. Le workflow de test/publication effectue lui-meme cette correspondance. Les profils des autres editions restent sur leur image originale.

Ces changements concernent les nouvelles executions ; une tache deja lancee a charge l ancien code. La sortie DISM est maintenant transmise au journal .console.log au fil des lignes recues. Le rapport contient active_stage, active_index, updated_at, progress_text et timings : sauvegarde, export, montage, catalogue/telechargement, integration par KB, enregistrement et SHA-256. Les sorties disponibles actualisent le suivi au plus toutes les dix secondes ; une commande silencieuse ne donne pas de pourcentage invente.

## Eviter un travail identique

Avant de sauvegarder, exporter ou monter, le script recherche une candidate terminee au nouveau format et associee au SHA-256 exact du WIM source. Il consulte les metadonnees du catalogue Microsoft avec select-only, sans telecharger de MSU, et compare les identifiants Microsoft, KB et builds Windows/.NET.

Si les correctifs sont identiques et si la candidate existe avec le SHA-256 attendu, le meme report.json est reutilise sans export, montage, telechargement ou commit. Si le WIM source correspond deja a la candidate preparee et que le catalogue n a pas change, le resultat est up_to_date. Une nouvelle KB, un candidat absent ou modifie, ou un rapport incomplet/annule ne donne pas de faux resultat a jour. Un catalogue inaccessible reste un echec explicite. Le controle lit encore le WIM source pour verifier son SHA-256.

La premiere preparation d une source inconnue reste necessaire et sa duree n est pas garantie en quelques minutes. La vitesse du disque physique de la VM compte : placer les donnees sur un SSD adapte exige une configuration de l hyperviseur, pas un changement PowerShell qui transformerait le stockage.

## Suivi dans le site

La page **Images et correctifs** affiche l etat mesure de la tache, les WIM, les passages, les etapes et durees, les index source/candidat, les KB et la validation. **Verifier les nouveaux correctifs** recherche seulement les metadonnees Microsoft en arriere-plan : aucun MSU telecharge et aucun DISM lance. Les versions viennent des rapports transmis ; une version deja detectee est necessaire. Nouveau signifie different du passage compare, pas deja installe ou publie dans l image de production.

Les dossiers prives windows-servicing, sauvegardes et montages restent reserves a SYSTEM et aux administrateurs. Les metadonnees sont copiees dans `<data_dir>\maintenance-overview` ; l agent serveur les actualise environ toutes les trente secondes. La console lit ce miroir. Les pages et les telechargements demandent l autorisation administrateur habituelle. Les dates des mesures restent visibles ; les tailles logiques de stockage excluent les arborescences montees.

## Annuler une preparation trop longue

L annulation abandonne la copie candidate, y compris les editions deja traitees dans cette copie. L image originale utilisee par PXE, sa sauvegarde, les correctifs en cache et les journaux restent conserves. Ce n est pas une reprise de la preparation ; aucune image annulee ne peut etre enregistree pour test ou publiee.

Si une fenetre PowerShell attend la fin de la maintenance pour lancer une mise a jour de la console, interrompre d abord cette attente avec Ctrl+C dans cette fenetre. Dans une autre fenetre PowerShell administrateur sur .250, utiliser le RunId du journal :

```powershell
& 'C:\AtelierPXE\console\scripts\Stop-WindowsImageMaintenance.ps1' `
    -InstallPath 'C:\AtelierPXE\console' -RunId '20261021-103851-f52d8739'
```

Le script verifie le rapport, la tache et l appartenance du montage au candidate.wim prive. Il desactive les prochains declenchements, arrete la tache puis uniquement les DISM dont les arguments correspondent exactement a cette copie. Il ne tue pas les WimServ ou les DISM etrangers. Il demande ensuite le demontage avec abandon des changements, verifie la disparition du montage et la liberation du candidat, et marque le rapport cancelled. Le temps de liberation du montage depend de Windows ; il ne peut pas etre garanti instantane. Aucun fichier WIM ni dossier de montage n est supprime par cet outil.

Avec IQ-5.5, omettre RunId et ajouter `-IfActive` identifie automatiquement l execution a partir des arguments exacts de DISM ou du candidat monte. Si aucune maintenance ne tourne, cette option ne fait rien. Plusieurs executions possibles ou une tache active sans candidat identifiable provoquent un refus avant tout arret ; utiliser alors le RunId du journal courant.

Un echec de recuperation laisse le rapport cancelled_cleanup_required et tous les fichiers conserves. Ne pas lancer une nouvelle preparation ou mise a jour de console avant resolution. Si la tache active ne correspond plus au RunId indique, le script refuse l arret : relire la transcription plutot que reutiliser un ancien PID.

Apres le message Maintenance annulee et montage libere, la mise a jour de la console et la reconstruction WinPE peuvent reprendre. La maintenance WIM reste en pause. Quand l operateur souhaite la reactiver, `Enable-WindowsImageMaintenance.ps1` sans RunNow retablit la planification ; ajouter RunNow lance une nouvelle preparation Famille/Pro avec les scripts recents.

## Sauvegardes et correctifs

Le dossier `<data_dir>\windows-servicing`, soit normalement `D:\AtelierPXE\data\windows-servicing`, contient :

| Chemin | Contenu |
| --- | --- |
| backups\SHA256.wim | Copie complete du WIM source, verifiee par SHA-256. Une source identique reutilise sa sauvegarde. |
| packages\GUID-Microsoft | Cache des MSU Microsoft. Un dossier contient seulement la mise a jour cible et ses checkpoints. |
| runs\DATE-IDENTIFIANT\candidate.wim | Copie maintenue, jamais le fichier de production. |
| runs\DATE-IDENTIFIANT\report.json | Etat global, source, sauvegarde, index, correctifs et erreur eventuelle. |
| runs\DATE-IDENTIFIANT\updates-index-N.json | Titres, KB, URL Microsoft, taille et empreintes de chaque fichier. |
| runs\DATE-IDENTIFIANT\catalog-index-N.log | Sortie Python et erreur precise du catalogue ou du telechargement Microsoft, egalement reprises dans la transcription. |
| runs\DATE-IDENTIFIANT\catalog-input-index-N.json | Version, build, architecture et .NET lus dans cet index du WIM avant la recherche. |
| runs\DATE-IDENTIFIANT\packages-index-N.csv | Etat des paquets apres integration. InstallPending demande un premier demarrage de test. |
| runs\DATE-IDENTIFIANT\dism-index-N.log | Journal DISM ; le fichier .console.log contient aussi sa sortie texte. |
| maintenance-DATE-IDENTIFIANT.log | Journal de l execution de la tache, y compris les erreurs avant creation d un rapport. |

Le dossier de travail est reserve aux administrateurs et a SYSTEM. Les sauvegardes ne sont pas publiees dans le partage des images. Le cache evite de telecharger de nouveau un paquet identique, mais l espace doit permettre une sauvegarde, le WIM candidat, le montage et les correctifs. La verification initiale exige au moins trois fois la taille du WIM et 25 Go disponibles. Le volume reel peut etre superieur pour une image avec beaucoup d index. Aucune ancienne image ou sauvegarde n est supprimee automatiquement.

Le script lit DisplayVersion, le build et .NET Framework dans le registre du WIM monte. Il recherche la derniere cumulative Windows stable et la cumulative du .NET Framework present. Il exclut les apercus Preview, Insider, changements de version, pilotes, correctifs Setup et SafeOS. Les prerequis checkpoints fournis dans la fenetre de telechargement Microsoft sont tous telecharges avec le paquet cible. DISM les resout depuis ce dossier. Les langues, composants facultatifs et parametres francais suisse ne sont pas changes ; .NET 3.5 n est pas active de force.

Les telechargements utilisent HTTPS vers les domaines Microsoft autorises. Les empreintes annoncees dans les noms de fichiers du catalogue sont verifiees, puis un SHA-256 local est conserve et relu avant DISM. Les controles normaux de signature et d applicabilite DISM restent actifs, sans IgnoreCheck ni ForceUnsigned. Le catalogue Microsoft ne fournit pas d API publique stable : si sa page change, si une version est inconnue, si la recherche est ambigue ou si les fichiers attendus manquent, la preparation echoue au lieu de substituer un autre correctif.

L ADK doit prendre en charge le Windows de l image. Pour Windows 11 26H2, Microsoft indique l ADK 10.1.26100.9457 de septembre 2026. Le script sait que 24H2/25H2/26H2 partagent une plateforme de maintenance : il n exige pas un DISM 26300 inexistant pour une image 26300. En cas d outil trop ancien, mettre les outils de deploiement ADK a jour selon la documentation Microsoft. Le script ne remplace pas lui-meme l ADK de .250.

## Enregistrer un candidat pour le test

Un rapport `ready_for_test` signifie que DISM a accepte les integrations et que le WIM a ete relu, pas que Windows a deja demarre avec succes. Un echec provoque un demontage avec abandon des modifications ; le candidat incomplet est retire. Si le demontage echoue, l etat est `failed_cleanup_required` et les fichiers sont conserves pour diagnostic, sans nettoyage recursif du montage.

Reperer le dossier `runs\DATE-IDENTIFIANT` annonce dans le journal. Exemple, en remplacant uniquement le chemin du rapport par le vrai :

```powershell
$atelierRapport = 'D:\AtelierPXE\data\windows-servicing\runs\DATE-IDENTIFIANT\report.json'
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1' -Mode RegisterTest -ReportPath $atelierRapport
```

Le WIM candidat est copie dans artifacts sous un nouveau nom. Des profils **TEST DATE-IDENTIFIANT** sont crees pour les profils Famille/Pro concernes, avec les index exportes, la meme langue et les memes reglages. Les anciennes preparations non reduites restent compatibles. Les profils TEST apparaissent dans WinPE sans etre choisis automatiquement ; la production garde son ancien WIM. La synchronisation des editions ignore un candidat encore en validation. La page Images et correctifs permet de copier la commande de mise en test.

Demarrer un PC de test en PXE, choisir explicitement le profil TEST de la bonne edition et confirmer son disque comme pour un deploiement normal. **Le disque du PC de test est efface.** Attendre le premier demarrage et la fin de la preparation Windows, puis verifier les applications, le materiel et le rapport. Faire un test pour chaque index utilise : Pro et Famille si les deux sont disponibles. Les tests de versions d image sont distincts des essais HPIA sur le HP physique.

## Publier apres les tests

Lire les identifiants et les resultats depuis .250, sans commande sur le PC deploye :

```powershell
$atelierRun = (Get-Content -LiteralPath $atelierRapport -Raw | ConvertFrom-Json).run_id
$atelierEtat = & 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1' -Mode Status -RunId $atelierRun | ConvertFrom-Json
$atelierEtat.test_deployments | Format-Table id, name, status, windows_status
```

Apres verification visuelle du poste, remplacer les exemples ci-dessous par les vrais identifiants des deploiements TEST reussis :

```powershell
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1' -Mode Publish -RunId $atelierRun -TestDeploymentId @('ID-TEST-PRO','ID-TEST-FAMILLE')
```

Si un seul index est utilise, fournir un seul identifiant. Le controle exige `status=staged` et `windows_status=completed` pour chaque index des profils concernes. Image appliquee seule, une preparation encore active, un avertissement HPIA non resolu ou un deploiement d une autre image ne suffisent pas. Les deploiements en attente ou en cours doivent etre termines avant publication. Un WIM modifie ou une liste de profils source changee annulent aussi la publication.

La publication change en une transaction le WIM et l index correspondant des profils Famille/Pro. Elle conserve leur nom, leur langue et leurs reglages. Les profils des autres editions restent sur l ancien WIM. L ancien WIM et les tests restent disponibles ; aucune image active n est ecrasee. La maintenance mensuelle ne publie jamais automatiquement.

## Limites et verification

Cette fonction maintient install.wim et ses index. Elle ne met pas a jour WinRE/WinPE, les applications Store, les runtimes .NET installes par les applications, les pilotes ou les firmwares. Elle n effectue pas de changement de version Windows et ne garantit pas zero proposition restante dans Windows Update.

Les tests du projet executent les transactions avec SQLite et l API reelles, les selections et controles de telechargements sur des reponses catalogue simulees, et l orchestration PowerShell avec DISM simule. L integration native DISM et le premier demarrage ne peuvent etre valides que sur .250 et un ordinateur de test. Aucun WIM reel de l atelier n est disponible dans l environnement de developpement.

Sources officielles :

- [Microsoft - ajouter des mises a jour a une image Windows](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/servicing-the-image-with-windows-updates-sxs?view=windows-11)
- [Microsoft - checkpoints et catalogue](https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates)
- [Microsoft - ADK compatibles](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
