# Maintenance mensuelle des images Windows - IQ-5.4

Cette fonction prepare les mises a jour une seule fois sur DEPLOY-01 (.250), dans une copie de chaque WIM utilise par les profils de production. Les postes suivants recoivent cette image apres sa validation. Aucun correctif n est installe dans Windows Server et aucun WIM actif n est ecrase. Windows Update et Microsoft Store restent manuels sur les postes. HPIA garde son fonctionnement actuel ; cette maintenance ne corrige pas ses erreurs et ne fournit pas les pilotes propres au modele.

## Installer et lancer la premiere preparation

Mettre la console a jour avec les sources IQ-5.4 et `Update-Console.ps1`. Cette fonction est uniquement serveur : aucun nouveau WinPE n est necessaire si le WinPE actuel fonctionne. Ouvrir Windows PowerShell administrateur sur .250 :

```powershell
& 'C:\AtelierPXE\console\scripts\Enable-WindowsImageMaintenance.ps1' -RunNow
```

La tache `AtelierPXE-WindowsImageMaintenance` demarre en arriere-plan. Elle prepare ensuite les images le **15 de chaque mois a 02:00, heure locale du serveur** (apres le deuxieme mardi du mois). Elle reprend a la prochaine disponibilite du serveur s il etait arrete. Une seconde execution est ignoree lorsqu une preparation fonctionne deja. Ne pas arreter de force la tache, redemarrer .250 ou demonter manuellement un WIM pendant DISM.

Si une premiere installation affiche `0x80041318` et `LogonType:ServiceAccount`, la tache n a pas ete creee et la maintenance n a pas demarre. Utiliser le script corrige puis relancer la meme commande `-RunNow` ; aucune reconstruction WinPE n est necessaire. Le compte SYSTEM est declare par son SID `S-1-5-18`, sans element XML LogonType. Un echec de creation ou de demarrage arrete le script sans annoncer une planification reussie.

Pour preparer manuellement, sans nouvelle planification :

```powershell
& 'C:\AtelierPXE\console\scripts\Update-WindowsImage.ps1'
```

Par defaut tous les WIM references par les profils de production sont prepares. `-AssetId 'identifiant-du-fichier'` limite une execution manuelle a une image. **Seuls Windows Famille (EditionId Core) et Windows Pro (EditionId Professional) sont maintenus.** Les numeros d index sont detectes dans le WIM : ils ne sont pas supposes etre 1 et 6. Les editions N, Single Language, Education et Pro for Workstations sont ignorees. Elles restent dans le fichier, avec leur numerotation initiale, sans integration de correctifs. Le rapport indique selected_indexes, skipped_indexes et les index effectivement termines. Un WIM sans Famille ni Pro est refuse. La sauvegarde et la copie restent celles du WIM complet ; seuls deux index au maximum dans un WIM standard sont montes et mis a jour, ce qui evite les integrations inutiles. Ce travail ne se repete pas sur chaque poste deploye.

Cette restriction s applique aux nouvelles executions. Une tache deja lancee a charge l ancien code et continue son traitement ; remplacer le fichier sur disque ne change pas cette execution. Ne pas arreter DISM pendant une integration ou une validation du WIM. La derniere transcription maintenance-*.log indique l index et la KB en cours ; le journal dism-index-N.log.console.log du meme dossier runs donne la sortie DISM. Les profils utilisant une edition ignoree ne peuvent pas etre publies comme mis a jour : la verification des index prepares reste obligatoire.

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

Le WIM candidat est copie dans artifacts sous un nouveau nom. Des profils **TEST DATE-IDENTIFIANT** sont crees pour les profils actuels, avec les memes index, langue et reglages. Ils apparaissent dans le choix Windows de WinPE, mais ne sont jamais choisis automatiquement. Les profils de production continuent d utiliser l ancien WIM. La synchronisation des editions ignore un candidat encore en validation.

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

La publication change en une transaction la reference des profils de production vers le WIM teste. Elle conserve leur nom, leur index, leur langue et leurs reglages. L ancien WIM et les deploiements TEST restent disponibles ; aucune image active n est ecrasee. La preparation mensuelle ne publie jamais de sa propre initiative.

## Limites et verification

Cette fonction maintient install.wim et ses index. Elle ne met pas a jour WinRE/WinPE, les applications Store, les runtimes .NET installes par les applications, les pilotes ou les firmwares. Elle n effectue pas de changement de version Windows et ne garantit pas zero proposition restante dans Windows Update.

Les tests du projet executent les transactions avec SQLite et l API reelles, les selections et controles de telechargements sur des reponses catalogue simulees, et l orchestration PowerShell avec DISM simule. L integration native DISM et le premier demarrage ne peuvent etre valides que sur .250 et un ordinateur de test. Aucun WIM reel de l atelier n est disponible dans l environnement de developpement.

Sources officielles :

- [Microsoft - ajouter des mises a jour a une image Windows](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/servicing-the-image-with-windows-updates-sxs?view=windows-11)
- [Microsoft - checkpoints et catalogue](https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates)
- [Microsoft - ADK compatibles](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
