# Parcours interne — INTERNE-1

Pour l'installation existante **DEPLOY-01 / 192.168.99.250**, hôte Hyper-V **192.168.99.253**, client **PC-TEST-PXE**. Cette révision s'installe après le test Windows réussi avec FR-REPRISE-3. Elle nécessite une nouvelle construction WinPE ; elle ne change pas les postes déjà installés.

## Comportement demandé

- La console web s'ouvre sans jeton en mode interne.
- L'assistant retrouve l'autorisation en attente de la MAC du poste, sans code à recopier. La MAC reste une identification, pas une authentification forte.
- Le partage SMB reste chiffré et en lecture seule. Le serveur gère le compte dédié `AtelierPXERead`, un mot de passe aléatoire et un secret DPAPI protégé par les permissions Windows. WinPE récupère ce secret via HTTPS avec son jeton temporaire ; aucune saisie SMB et aucun mot de passe dans l'image de démarrage, les paramètres du processus ou le Windows installé.
- Le récapitulatif montre le disque et l'effacement prévu. Le bouton **Installer Windows** lance l'installation, sans phrase à saisir ni fenêtre de confirmation supplémentaire.
- Le nom est proposé depuis le numéro de série BIOS : préfixe **LE-T15-** et quatre derniers **chiffres numériques**. Exemple `5CD123AB78` → `LE-T15-2378`. Le préfixe et le nom restent modifiables dans WinPE. Un numéro générique/absent ou contenant moins de quatre chiffres impose une saisie manuelle ; aucun numéro n'est inventé.
- Le compte intégré SID 500 est activé et nommé **Administrateur**, sans mot de passe, avec ses droits d'administrateur. Aucun deuxième compte portant ce nom n'est créé. UAC et le refus Windows des connexions réseau avec mot de passe vide restent activés.
- Le fichier de réponses prépare région, clavier, fuseau, OOBE et première session automatique. Aucune modification des marqueurs d'avancement de Windows Setup ou suppression des exigences matérielles Windows 11.
- Une fenêtre de progression apparaît dans Windows pour le bureau, les logiciels et la maintenance.
- Windows Update installe les mises à jour logicielles nécessaires du service configuré, y compris WSUS s'il existe. Les pilotes, BIOS et mises à jour facultatives ne sont pas sélectionnés. Des redémarrages automatiques avec délai de deux minutes permettent la reprise. Le processus est limité à cinq passes, quatre redémarrages et six tentatives ; il s'arrête avec un état explicite si une intervention est nécessaire.
- Le service Windows reçoit une demande d'actualisation des applications Microsoft Store. Le résultat indique **requested / completion_verified=false** : il ne certifie pas que toutes les applications Store ont terminé. Le Store, ses services et l'accès Internet doivent être opérationnels.

Le mode interne rend les fonctions administratives accessibles à toute personne pouvant joindre la console sur le LAN. Il est désactivé par défaut dans les installations existantes et s'active explicitement ci-dessous.

## 1. Mettre à jour le serveur

Sans déploiement actif, sur **DEPLOY-01**, ouvrir **Windows PowerShell administrateur**. Utiliser le bloc de [mise à jour de la console](REPRISE-PXE.md#1-mettre-à-jour-les-scripts), puis vérifier `/health` : `ok / 0.2.0`. L'API garde cette version pour la compatibilité ; le marqueur de support change en **INTERNE-1**.

Ne pas réinstaller WDS, IIS ou ADK. Les données, le certificat et les anciens supports WDS sont conservés.

## 2. Activer une fois le mode interne

Sur **DEPLOY-01**, dans **Windows PowerShell administrateur** :

```powershell
& 'C:\AtelierPXE\console\scripts\Enable-InternalMode.ps1'
Invoke-RestMethod 'https://192.168.99.250/api/session'
```

Attendre `internal_mode=True` et `automatic_windows=True`. Le script vérifie le partage existant, crée son compte de lecture si nécessaire, sauvegarde `data-runtime.json`, ajoute les paramètres de nommage et redémarre la tâche console. Une seconde exécution réutilise le secret géré ; elle ne modifie pas un compte homonyme non géré.

Recharger la console avec **Ctrl+F5** : elle s'ouvre sans demander de jeton. Les profils existants héritent des réglages automatiques pour les **nouvelles autorisations**.

## 3. Reconstruire WinPE

Toujours sur **DEPLOY-01** :

```powershell
& {
    $ErrorActionPreference='Stop'
    $atelierStamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $atelierParametres=@{
        ServerUrl='https://192.168.99.250'
        OutputPath="D:\AtelierPXE\WinPE-Interne-$atelierStamp"
        TrustedRootCertificate='C:\AtelierPXE\certs\AtelierPXE-lab.cer'
        WinPEKeyboardLayout='040c:0000040c'
        WdsImageName="Atelier PXE - INTERNE-1 - $atelierStamp"
        ImportIntoWds=$true
    }
    & 'C:\AtelierPXE\console\scripts\Build-WinPE.ps1' @atelierParametres
    Import-Module WDS
    Get-WdsBootImage | Format-Table ImageName,Architecture,FileName
}
```

Choisir cette nouvelle image dans WDS au prochain boot. Une ancienne image demandera toujours les anciens identifiants.

## 4. Test de bout en bout

1. Dans la console, conserver la MAC de **PC-TEST-PXE** et créer une **nouvelle autorisation** avec le profil Windows 11 Pro FR, index 6 du WIM d'origine, le bon disque et le choix dans l'assistant activé. Aucun code ni phrase ne sont demandés en mode interne. Une autorisation expire après deux heures et n'est plus récupérable dès le début de l'installation.
2. Démarrer la VM sur la nouvelle image **INTERNE-1**. L'assistant se connecte automatiquement si l'autorisation existe ; sinon créer l'autorisation dans la console et cliquer sur **Connexion**.
3. Vérifier Windows, le nom BIOS proposé et son préfixe, région, clavier, bundle **Poste standard** et **Fond-Atelier.png**.
4. Lire le récapitulatif du disque. **Installer Windows** efface ses partitions. Attendre la fin WinPE ; `staged` signifie seulement que l'image et le premier démarrage sont préparés.
5. Éteindre WinPE avec `wpeutil shutdown`, puis placer Windows Boot Manager/le disque avant le réseau dans Hyper-V. Relancer : Windows doit préparer le compte Administrateur puis ouvrir sa première session et la fenêtre de progression.
6. Laisser le réseau et Internet disponibles. Les logiciels s'installent, les diagnostics sont créés et la maintenance commence. La session automatique est limitée et désactivée à la fin ou à l'arrêt définitif de la maintenance.
7. Contrôler `C:\ProgramData\AtelierPXE\result.json` (logiciels), `maintenance.json` (Windows Update / demande Store), `maintenance.log`, `first-logon.log` et le dossier ci-dessous. La console web ne reçoit pas encore les états de maintenance après `staged`.

## Dossier C:\IQ_

Le premier démarrage crée :

| Fichier | Rôle |
| --- | --- |
| `Test-Batterie.ps1` / `.cmd` | Relancer `powercfg /batteryreport`, durée 14 jours |
| `Rapport-batterie.html` | Rapport batterie sur un portable doté d'une batterie détectée |
| `Batterie-absente.txt` | Cas normal d'une VM/ordinateur fixe, sans faux rapport de capacité |
| `Verifier-Licence.ps1` / `.cmd` | Vérifier l'activation Windows sans modifier la licence |
| `Licence-Windows.txt` / `.json` | État actif, non actif ou indéterminé, sans clé de produit |
| `Fond-Atelier.png` | Copie vérifiée du fond sélectionné, sous son nom d'origine |
| `Diagnostics.json` | Résultat de l'exécution des deux scripts |
| `Lisez-moi.txt` | Utilisation locale |

Les lanceurs `.cmd` demandent une élévation Windows pour pouvoir écrire leurs rapports dans le dossier. Un diagnostic de licence est relancé à la fin de la maintenance. Le dossier reste lisible pour les utilisateurs ; ses scripts sont modifiables par Administrateurs/SYSTEM.

## Diagnostic et retour au mode précédent

- Si une ancienne version de `Enable-InternalMode.ps1` affiche une erreur Python `SyntaxError: '(' was never closed`, puis « Terminez les deploiements », le contrôle n'a pas abouti : ce message ne prouve pas qu'un déploiement est actif. Mettre à jour ce script et relancer l'activation. Le correctif transmet le code Python sur l'entrée standard pour Windows PowerShell 5.1, ouvre SQLite en lecture seule et distingue une erreur de contrôle d'un nombre réel de déploiements en cours. Cette erreur survient avant la création du compte et la modification de la configuration.
- Une erreur de connexion du partage doit être corrigée sur DEPLOY-01 avec `Enable-InternalMode.ps1`, jamais en copiant un mot de passe dans WinPE.
- `retry_pending` annonce une nouvelle tentative quinze minutes plus tard ; `needs_attention` signifie arrêt après la limite et désactivation de l'ouverture automatique. Consulter `maintenance.log` avant une reprise manuelle.
- Après une limite atteinte, vérifier Internet, Windows Update, les services Store et les journaux. Ne pas supprimer l'état ou relancer une boucle sans diagnostic.
- Pour désactiver ce parcours, remettre `internal_mode` et `automatic_windows` à `false` dans `data-runtime.json`, redémarrer la tâche `AtelierPXE-Console`, puis reconstruire WinPE. Cela n'efface ni les données du serveur ni les comptes des postes déjà déployés.

La syntaxe, les états persistants et les appels simulés sont testables sous Linux ; la création du compte local, OOBE, les permissions DPAPI/SMB, les véritables installations, powercfg et les mises à jour doivent être validés sur la VM Windows avant diffusion aux PC physiques.
