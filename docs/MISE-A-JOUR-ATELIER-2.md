# Installer la révision ATELIER-2

Cette révision complète INTERNE-1 : progression Windows Update par phase, consoles de fond masquées, ouverture de HP Image Assistant, profils Pro/Famille issus du WIM, démarrage rapide Windows désactivé, tests matériels et PDF local/console. L’API de base reste en version 0.2.0 pour compatibilité ; le marqueur de démarrage est **ATELIER-2**.

## Révision 2.1

Le correctif détecte le dossier installé à partir de la tâche `AtelierPXE-Console` et s’arrête clairement si la commande est lancée sur une autre machine. Il ne recrée jamais `data-runtime.json`. La nouvelle image est marquée **ATELIER-2.1** ; `/health` annonce `release=ATELIER-2`, `revision=2.1`. La [synchronisation des logiciels par WinGet et les inventaires XML/CSV](LOGICIELS-AUTOMATIQUES.md) sont disponibles après la mise à jour.

## Mettre à jour le serveur existant

Attendre la fin de la préparation Windows en cours sur PC-TEST-PXE avant de remplacer la console : l’ancienne version ne sait pas transmettre sa progression ou son rapport. Il n’est pas nécessaire de réinstaller Windows Server, WDS, IIS ou ADK.

Télécharger la révision validée du dépôt, l’extraire hors de `C:\AtelierPXE\console`, débloquer ses scripts et lancer son **nouveau** `scripts\Update-Console.ps1 -SourcePath <dossier extrait>` en PowerShell administrateur sur DEPLOY-01. Le script sauvegarde la console et SQLite et conserve les données et la configuration. Vérifier `/health`, puis `/api/session` (`internal_mode=True`, `automatic_windows=True`).

Les migrations SQLite sont additives. Les anciens déploiements restent consultables et n’ont pas artificiellement de statut Windows ni de rapport. Les données des rapports restent hors du partage SMB des images. Les jetons WinPE sont toujours révoqués à la fin de WinPE ; un jeton distinct, propre au déploiement et limité à quatorze jours, sert uniquement à la remontée Windows.

## Appliquer les trois étapes en une commande

Depuis le dossier des nouvelles sources extraites, `scripts\Upgrade-Atelier2.ps1` enchaîne la mise à jour sauvegardée de la console, la synchronisation des profils Pro/Famille et la construction/import d’une nouvelle image WDS. Lancer ce script en PowerShell administrateur **sur DEPLOY-01**, après la fin des déploiements et de la maintenance Windows en cours :

```powershell
& '.\scripts\Upgrade-Atelier2.ps1'
```

Le clavier WinPE est français AZERTY par défaut. Les paramètres `-WinPEKeyboardLayout '100c:0000100c'`, `-DriversPath 'D:\AtelierPXE\Drivers\WinPE-x64'` et `-TrustedRootCertificate 'C:\chemin\racine.cer'` permettent d’adapter les valeurs existantes. Le script ne réinstalle ni WDS, ni IIS, ni ADK, ni Windows. Il s’arrête si une étape échoue. Les sections suivantes détaillent ces mêmes étapes pour une exécution séparée ou un diagnostic.

## Préparer les éditions du WIM

Sur DEPLOY-01, dans PowerShell administrateur :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-WindowsEditions.ps1'
```

Le script lit les éditions avec DISM, copie les réglages d’un profil existant du même WIM et ajoute les éditions Pro/Famille manquantes. L’image n’est pas modifiée. Il ignore les langues différentes du profil modèle. S’il n’existe aucun profil modèle, en créer d’abord un avec la bonne langue et le bundle souhaité dans la console. Le choix du menu Édition lors d’une création manuelle est une étiquette ; **l’index doit correspondre à l’édition réelle du WIM**.

## Reconstruire WinPE

Toujours sur DEPLOY-01, PowerShell administrateur :

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $atelierStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $atelierParametres = @{
        ServerUrl = 'https://192.168.99.250'
        OutputPath = "D:\AtelierPXE\WinPE-Atelier2-$atelierStamp"
        TrustedRootCertificate = 'C:\AtelierPXE\certs\AtelierPXE-lab.cer'
        WinPEKeyboardLayout = '040c:0000040c'
        WdsImageName = "Atelier PXE - ATELIER-2.1 - $atelierStamp"
        ImportIntoWds = $true
    }
    & 'C:\AtelierPXE\console\scripts\Build-WinPE.ps1' @atelierParametres
    Import-Module WDS
    Get-WdsBootImage | Format-Table ImageName, Architecture, FileName
}
```

Pour le suisse romand, utiliser `100c:0000100c` à la place du clavier français AZERTY. Pour un PC physique nécessitant des pilotes supplémentaires, ajouter un `DriversPath` contenant les INF signés déjà validés. Les images existantes sont conservées.

## Valider dans la VM puis sur le HP

Créer une **nouvelle autorisation** avec le choix du profil activé, démarrer la **nouvelle image ATELIER-2** et suivre le [guide utilisateur](GUIDE-UTILISATEUR.md). Le nouveau parcours s’applique aux nouveaux déploiements ; un poste déjà démarré avec INTERNE-1 garde ses scripts.

Dans la VM, vérifier l’absence de console PowerShell vide, les phases Windows Update, une reprise après redémarrage, l’état Windows dans Atelier et le téléchargement du PDF. Vérifier que le rapport signale normalement l’absence de batterie/caméra. Confirmer `HiberbootEnabled=0` dans `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power`.

Sur le HP, préparer HP Image Assistant sous forme de ZIP extrait officiel avec `HPImageAssistant.exe` comme point d’entrée, mode portable et constructeur HP. Vérifier qu’il s’ouvre une seule fois en fin de préparation, que le raccourci reste disponible et que les mises à jour de pilotes demandent l’action du technicien. Exécuter ensuite les trois tests matériels et régénérer le PDF.

## Performances et limites

La lecture de la console n’acquiert plus systématiquement un verrou d’écriture SQLite ; les opérations qui réservent ou modifient un déploiement conservent leur transaction exclusive de rédaction. Un index accélère les journaux par déploiement. Le WIM est verrouillé en lecture dès sa vérification SHA-256 et jusqu’à la fin de DISM, ce qui évite de relire une seconde fois toute l’image sur SMB. Les états de progression sont remplacés sans accumulation de sauvegardes ; les écritures critiques des fichiers de réponses restent vérifiées. Les logiciels installés avec succès sont mémorisés par identifiant et SHA-256 pour éviter une réinstallation lors d’une reprise partielle.

Le moteur Windows Update utilise ses opérations asynchrones et publie la phase réelle. La cadence locale est limitée à cinq secondes ; un serveur inaccessible espace les tentatives de remontée. Cela améliore la visibilité et la réactivité ; aucun gain de durée des mises à jour Microsoft n’est garanti. Les protections d’image, signatures, TLS et vérifications du disque restent activés.

Le PDF est généré sans navigateur, imprimante PDF, Office ni bibliothèque tierce. Il contient les inventaires CIM accessibles, l’état de licence sans clé produit, les logiciels, les passes Windows Update, les avertissements et les tests opérateur disponibles. Le PDF téléchargé depuis la console ajoute l’historique WinPE. Son état « terminé » ne certifie pas les interventions manuelles effectuées ensuite dans HP Image Assistant.

Si la console reste indisponible, la tâche terminale retente uniquement la génération/transmission du rapport ; elle ne recommence pas l’installation des logiciels ou de Windows Update. Les délais et limites de la maintenance restent bornés. Le PDF local reste accessible après expiration du jeton.
