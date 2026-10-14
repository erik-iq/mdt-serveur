# Procédure de test — Atelier PXE sur Windows Server 2025

Serveur : **192.168.99.250**. Commencer par la console locale, puis tester le démarrage PXE et enfin une installation Windows sur un **poste de laboratoire avec disque sacrifiable**. Les tests API ont été exécutés dans le cloud ; les étapes Windows ci-dessous constituent la recette à exécuter sur votre matériel, pas une installation déjà validée sur Server 2025.

Les commandes serveur utilisent **Windows PowerShell en administrateur**. Les exemples supposent un volume **D: NTFS** pour les images et WDS. Si ce volume n’existe pas, adapter tous les chemins, y compris `-Path` du partage SMB. Prévoir au moins 100 Go libres. Pour le poste, utiliser un PC UEFI x64 sauvegardé, ou une VM UEFI/Génération 2 avec disque vierge de 80 Go et compatibilité Windows 11 (TPM 2.0, Secure Boot, CPU pris en charge). Déconnecter les disques contenant des données à conserver avant le test destructif.

## 1. Récupérer le logiciel et installer Python

Dans GitHub : [erik-iq/mdt-serveur](https://github.com/erik-iq/mdt-serveur) → **Code → Download ZIP**. Extraire le contenu du dépôt dans **C:\AtelierPXE\console**. Le fichier `requirements.txt` doit se trouver directement dans ce dossier, pas dans un sous-dossier supplémentaire.

Installer **Python 3.12 x64 pour tous les utilisateurs**, avec `pip` et `venv`, depuis [python.org](https://www.python.org/downloads/windows/). Les commandes suivantes supposent `C:\Program Files\Python312\python.exe`. Adapter uniquement ce chemin si vous l’avez installé ailleurs.

```powershell
Set-Location C:\AtelierPXE\console
& 'C:\Program Files\Python312\python.exe' --version
& 'C:\Program Files\Python312\python.exe' -m venv .venv
& .\.venv\Scripts\python.exe -m pip install -c constraints.txt -r requirements-dev.txt
& .\.venv\Scripts\python.exe -m pytest -q -k 'not test_database_survives_restart_and_generated_token_is_private'
```

**Attendu :** Python `3.12.x`, puis **17 tests passés et 1 désélectionné**, sans échec. Le test exclu utilise des permissions POSIX `0600`, adaptées à Linux ; les droits NTFS du jeton seront contrôlés à l’étape 3. Les 18 tests complets ont été validés dans le cloud Linux. Le test de lien symbolique nécessite les privilèges Windows appropriés : utiliser la session administrateur demandée. Ces tests portent sur la console et l’API ; ils n’installent pas Windows et n’effacent aucun disque. Si une commande échoue, corriger ce point avant de continuer ; ne pas désactiver d’autres tests pour contourner un échec.

## 2. Tester la console sur le serveur, sans PXE

Toujours dans le dossier du projet :

```powershell
$env:MDT_DATA_DIR = 'C:\AtelierPXE\test-data'
$env:MDT_BASE_URL = 'http://127.0.0.1:8080'
& .\.venv\Scripts\python.exe -m uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8080
```

Garder cette fenêtre ouverte. Dans une **deuxième fenêtre PowerShell sur le serveur** :

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health
notepad C:\AtelierPXE\test-data\admin-token
```

**Attendu :** `status = ok`, `version = 0.1.0`.

Sur le serveur avec interface graphique, ouvrir le navigateur et saisir **http://127.0.0.1:8080**. Copier le jeton affiché dans le fichier vers le formulaire de connexion. Ne pas l’envoyer dans un chat ni le mettre dans Git. Si le serveur est en édition Core, valider `/health` ici et tester le navigateur depuis un autre poste après l’étape HTTPS.

Vérifier que les quatre pages s’ouvrent : Vue d’ensemble, Parc machines, Profils Windows, Infrastructure PXE. Tester une connexion avec un jeton incorrect : elle doit être refusée. L’infrastructure iPXE peut apparaître non préparée ; le parcours choisi utilise **WDS** et n’exige pas les quatre fichiers iPXE.

À la fin, revenir dans la première fenêtre, arrêter Uvicorn avec **Ctrl+C**, puis retirer les variables de test dans cette fenêtre :

```powershell
Remove-Item Env:MDT_DATA_DIR,Env:MDT_BASE_URL -ErrorAction SilentlyContinue
```

Les données de `C:\AtelierPXE\test-data` sont celles de cet essai local. La console installée ensuite utilisera une **autre base**, dans `D:\AtelierPXE\data`, avec son propre jeton. Ne pas recopier le jeton de test.

## 3. Installer la console au démarrage

Après avoir vérifié le volume de stockage et arrêté le serveur de test :

```powershell
Set-Location C:\AtelierPXE\console
# Seulement pour les fichiers téléchargés depuis ce dépôt de confiance :
Get-ChildItem .\scripts -File -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\scripts\Install-Console.ps1 -ServerUrl 'https://192.168.99.250' -DataPath 'D:\AtelierPXE\data' -InstallStartupTask
```

Après quelques secondes :

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health
Get-ScheduledTask -TaskName AtelierPXE-Console
Get-ScheduledTaskInfo -TaskName AtelierPXE-Console
```

**Attendu :** `/health` répond `ok` et la tâche est `Running`. Une tâche de serveur reste normalement en cours d’exécution ; ne pas attendre une fin d’exécution pour la déclarer opérationnelle.

En cas d’échec :

```powershell
Get-Content D:\AtelierPXE\data\logs\console.log -Tail 50
```

Le script refuse un `data-runtime.json` ou une tâche déjà présents. Ne pas les supprimer pour forcer une réinstallation : examiner d’abord la configuration et les journaux. Le port 8080 doit être libre.

Contrôler aussi les droits NTFS, sans afficher le jeton :

```powershell
icacls.exe D:\AtelierPXE\data
icacls.exe D:\AtelierPXE\data\admin-token
```

**Attendu :** accès pour Administrateurs, SYSTEM et LOCAL SERVICE, sans droit de lecture pour un groupe général comme Users/Utilisateurs ou Authenticated Users/Utilisateurs authentifiés. Les noms peuvent être localisés ; les SID configurés par le script sont `S-1-5-32-544`, `S-1-5-18` et `S-1-5-19`. Une permission héritée trop large doit être corrigée avant le test réseau.

## 4. Rendre la console accessible en HTTPS

Python écoute seulement sur **127.0.0.1**. Pour les postes du réseau, préparer **IIS comme proxy HTTPS** :

1. Installer IIS : `Install-WindowsFeature Web-Server -IncludeManagementTools`.
2. Installer [URL Rewrite](https://www.iis.net/downloads/microsoft/url-rewrite) et [Application Request Routing (ARR)](https://www.iis.net/downloads/microsoft/application-request-routing) depuis les sources officielles IIS.
3. Dans le Gestionnaire IIS, sélectionner le serveur → **Application Request Routing Cache → Server Proxy Settings → Enable proxy → Apply**.
4. Créer `C:\inetpub\AtelierPXE` et y copier `docs\iis.web.config.example` sous le nom `web.config`. Ce site ne doit pas pointer vers le code source ni vers le dossier de données.
5. Créer un site **AtelierPXE** avec ce dossier et une liaison **HTTPS / 443 / 192.168.99.250**, en sélectionnant un certificat serveur de confiance.
6. Le certificat doit inclure **192.168.99.250 dans un SAN de type IP**. Un simple nom CN ou un SAN DNS contenant l’IP ne suffit pas. Une autorité interne peut émettre ce certificat ; exporter uniquement son certificat racine **public `.cer`** pour WinPE. Les navigateurs de test doivent aussi faire confiance à cette autorité.
7. Autoriser TCP 443 uniquement depuis les réseaux de test/administration concernés. Vérifier la liaison IIS, la portée du pare-feu et qu’aucun autre site n’utilise la même liaison.

### Variante de laboratoire si vous n’avez aucune autorité de certification

Vous pouvez créer un certificat auto-signé **sur le serveur**, avec le SAN IP requis, puis lui faire explicitement confiance sur les seuls postes du laboratoire. Pour une installation durable, utiliser la gestion de certificats de votre organisation. Ces commandes n’ont pas été exécutées dans l’environnement Linux ; vérifier leur résultat dans le magasin de certificats Windows.

```powershell
New-Item -ItemType Directory -Path C:\Certificats -Force | Out-Null
$atelierLabCert = New-SelfSignedCertificate `
  -Type Custom `
  -Subject 'CN=AtelierPXE-Lab' `
  -FriendlyName 'Atelier PXE - Lab 192.168.99.250' `
  -CertStoreLocation Cert:\LocalMachine\My `
  -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
  -KeyUsage DigitalSignature,KeyEncipherment `
  -TextExtension @('2.5.29.17={text}IPAddress=192.168.99.250','2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
  -NotAfter (Get-Date).AddMonths(3)
Export-Certificate -Cert $atelierLabCert -FilePath C:\Certificats\AtelierPXE-lab.cer -Type CERT
$atelierLabCert | Select-Object Subject,Thumbprint,NotAfter
```

Dans IIS, choisir **Atelier PXE - Lab 192.168.99.250** pour la liaison HTTPS. Copier uniquement `AtelierPXE-lab.cer` sur le poste d’administration par un canal de confiance, vérifier son empreinte avec celle affichée sur le serveur, puis importer cette copie localement pour l’utilisateur qui testera le navigateur :

```powershell
Import-Certificate -FilePath C:\Certificats\AtelierPXE-lab.cer -CertStoreLocation Cert:\CurrentUser\Root
```

Pour une requête HTTPS exécutée directement sur le serveur, importer aussi le certificat public dans le magasin de confiance du compte qui effectuera cette requête. À l’étape 6, utiliser **`-TrustedRootCertificate 'C:\Certificats\AtelierPXE-lab.cer'`** à la place de `racine-interne.cer`. Le lanceur ajoutera ce certificat public au magasin de confiance de WinPE. Ne pas exporter ni copier de clé privée/PFX.

Depuis **un autre poste du même réseau**, exécuter :

```powershell
Test-NetConnection 192.168.99.250 -Port 443
Invoke-RestMethod https://192.168.99.250/health
```

**Attendu :** `TcpTestSucceeded = True`, puis `status = ok`, **sans erreur de certificat**. Ouvrir `https://192.168.99.250` dans son navigateur et utiliser le jeton de **D:\AtelierPXE\data\admin-token**, lu localement sur le serveur.

Si vous utilisez un nom DNS à la place de l’IP, remplacer l’URL dans `Install-Console.ps1`, la configuration IIS et la construction WinPE. Ne pas désactiver la vérification TLS pour franchir cette étape. La configuration du certificat est un prérequis réel du parcours réseau.

## 5. Vérifier qui fournit le DHCP

Pour le premier essai, placer le poste de test et le serveur sur **le même VLAN de laboratoire**, avec un DHCP fonctionnel. Sur un PC Windows de ce réseau :

```cmd
ipconfig /all
```

Relever **DHCP activé**, **Serveur DHCP**, l’adresse, le masque et la passerelle. Dans votre installation, le DHCP et la passerelle ont été confirmés à `192.168.99.1`, avec le masque `255.255.255.0`. Cette vérification permet de contrôler les paramètres du poste et toute modification future du réseau.

Sur Server 2025, voir les rôles déjà installés :

```powershell
Get-WindowsFeature -Name DHCP,WDS,Web-Server
```

Ne pas installer un second DHCP si un routeur, pare-feu ou autre serveur fournit déjà les baux. Si les postes sont sur un autre VLAN, configurer les relais DHCP/IP helpers vers le DHCP existant **et vers 192.168.99.250**. Ne pas définir automatiquement les options 66/67, car le fichier de boot dépend du firmware et de l’architecture.

**Attendu :** le client reçoit une adresse valide sur le réseau prévu. Une adresse `169.254.x.x` sur son interface de test indique qu’un bail DHCP n’a pas été obtenu.

## 6. Installer WDS et préparer WinPE

Sur le serveur, installer l’[ADK et son module complémentaire WinPE](https://learn.microsoft.com/windows-hardware/get-started/adk-install), compatibles avec votre version Windows cible. Sélectionner **Deployment Tools** dans ADK. Installer le module complémentaire WinPE séparément.

Pour un serveur neuf sans WDS :

```powershell
.\scripts\Install-Wds.ps1 -RemoteInstallPath 'D:\RemoteInstall'
```

Ajouter `-DhcpOnThisServer` **uniquement si le service DHCP Windows est effectivement sur ce serveur**. Si WDS est déjà installé ou si un redémarrage est demandé, terminer sa configuration via la console WDS ; ne pas relancer aveuglément le script d’installation neuve.

**Attendu :** rôle WDS installé en mode autonome, stockage initialisé, réponses PXE encore **désactivées**.

Créer l’image de démarrage, avec le certificat racine public correspondant à votre HTTPS :

```powershell
.\scripts\Build-WinPE.ps1 `
  -ServerUrl 'https://192.168.99.250' `
  -OutputPath 'D:\AtelierPXE\WinPE-test-v1' `
  -TrustedRootCertificate 'C:\Certificats\racine-interne.cer' `
  -ImportIntoWds
```

Omettre le paramètre de certificat si WinPE reconnaît déjà l’autorité. Si des pilotes réseau ou stockage sont nécessaires, ajouter `-DriversPath 'D:\Pilotes\WinPE-x64'` avec leurs fichiers INF signés provenant du constructeur. Ne pas fournir un PFX ni une clé privée. Pour reconstruire l’image, choisir un **nouveau dossier de sortie**.

**Attendu :** fichier `D:\AtelierPXE\WinPE-test-v1\media\sources\boot.wim` et image **Atelier PXE - WinPE x64** visible dans les images de démarrage WDS. Utiliser cette image personnalisée, pas le `boot.wim` de l’ISO Windows 11.

## 7. Préparer le WIM et son partage

Monter un ISO Windows officiel/licencié. Les exemples supposent qu’il apparaît en **E:**.

Si le média contient `install.wim` :

```powershell
Copy-Item E:\sources\install.wim D:\AtelierPXE\data\artifacts\Windows11-test.wim
dism.exe /Get-WimInfo /WimFile:D:\AtelierPXE\data\artifacts\Windows11-test.wim
```

Si le média contient `install.esd`, lister les éditions, relever celle voulue puis l’exporter :

```powershell
dism.exe /Get-WimInfo /WimFile:E:\sources\install.esd
$atelierImageIndex = Read-Host "Index de l'édition à exporter"
dism.exe /Export-Image /SourceImageFile:E:\sources\install.esd "/SourceIndex:$atelierImageIndex" /DestinationImageFile:D:\AtelierPXE\data\artifacts\Windows11-test.wim /Compress:max /CheckIntegrity
dism.exe /Get-WimInfo /WimFile:D:\AtelierPXE\data\artifacts\Windows11-test.wim
```

**Attendu :** un WIM valide, non fractionné, et un index connu. Un export d’une seule édition vers un nouveau WIM donne normalement **l’index 1**. Ne pas écraser un fichier déjà enregistré ; choisir un nouveau nom de version. Les ISO/ESD/SWM ne s’enregistrent pas directement dans la console.

Créer un compte de lecture dédié si `DeployRead` n’existe pas déjà :

```powershell
$atelierReadPassword = Read-Host 'Mot de passe SMB pour DeployRead' -AsSecureString
New-LocalUser -Name DeployRead -Password $atelierReadPassword -Description 'Lecture des images de test'
.\scripts\Publish-ImageShare.ps1 -Path 'D:\AtelierPXE\data\artifacts' -ReadOnlyAccount "$env:COMPUTERNAME\DeployRead"
Get-SmbShareAccess -Name AtelierImages
$env:COMPUTERNAME
```

**Attendu :** partage `AtelierImages`, droit **Read** pour le compte dédié, sans jeton ni base exposés. Le partage exige le chiffrement SMB. Noter le nom du serveur affiché ; ne pas placer ce compte dans Administrateurs. Si le compte/partage existe déjà, vérifier ses droits au lieu de le recréer.

## 8. Préparer un déploiement dans la console

Depuis le navigateur connecté à `https://192.168.99.250` :

1. **Profils Windows → Enregistrer un fichier** : nom `Windows11-test.wim`, type **Image Windows**. Attendre le calcul SHA-256.
2. **Nouveau profil** : nom `Windows 11 - Test`, fichier précédemment enregistré, index exact donné par DISM, langue réellement présente dans l’image (`fr-FR` pour une image française).
3. **Parc machines → Enregistrer un poste** : nom `PC-TEST-01`, MAC de l’interface Ethernet qui fera le PXE. Relever cette MAC sur le poste de test avec `ipconfig /all` ou dans son firmware ; ne pas utiliser celle du serveur.
4. **Nouveau déploiement** : sélectionner le poste et le profil. Le disque `0` est un exemple qui devra être vérifié dans WinPE. Saisir `EFFACER PC-TEST-01`.
5. Conserver l’**identifiant** et le **jeton de déploiement** affichés une seule fois. Ce jeton est distinct du jeton administrateur. En cas de perte, annuler le déploiement et créer une nouvelle autorisation.

**Attendu :** une ligne **En attente**, progression 0 %, sans installation déclenchée sur le poste.

## 9. Tester le démarrage PXE et le refus d’effacement

Après les vérifications réseau, activer les réponses WDS dans la console WDS sur le réseau de laboratoire. Si ce réseau est bien isolé et que vous souhaitez répondre à ses clients connus et inconnus :

```powershell
wdsutil.exe /Set-Server /AnswerClients:All
Start-Service WDSServer
```

Démarrer le **poste de test**, sélectionner le boot réseau **UEFI IPv4** et l’image **Atelier PXE - WinPE x64**. Le lanceur Atelier s’ouvre automatiquement. Pour préparer SMB et vérifier le disque, interrompre ce lanceur avec **Ctrl+C** avant de confirmer une installation. Cela peut afficher une demande liée au batch `startnet.cmd` ; le but est de revenir à un **terminal CMD WinPE**, sans redémarrer le poste ni lancer DISM. Si un terminal est nécessaire, l’ouvrir avec **Maj+F10** lorsque disponible. Dans ce terminal :

```cmd
ipconfig /all
net use \\192.168.99.250\AtelierImages /user:NOM-DU-SERVEUR\DeployRead *
dir \\192.168.99.250\AtelierImages\Windows11-test.wim
powershell.exe -NoProfile -Command "Get-Disk | Format-Table Number,FriendlyName,SerialNumber,Size; Get-Partition | Format-Table DiskNumber,PartitionNumber,DriveLetter,Type,Size"
```

Remplacer `NOM-DU-SERVEUR` par le nom relevé à l’étape 7. Le `*` demande le mot de passe localement. Relever l’état des partitions et l’identité du disque pour les comparer après ce premier essai.

**Attendu :** WinPE a une IP correcte, le WIM est accessible, le disque interne sacrifiable est visible. Si le numéro diffère de celui du déploiement, annuler celui-ci dans la console et le recréer avec le numéro correct. Ne pas déployer avec une cible ambiguë.

Relancer le lanceur :

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Atelier\Launch.ps1
```

Saisir l’identifiant, le jeton de déploiement puis le chemin :

```text
\\192.168.99.250\AtelierImages\Windows11-test.wim
```

L’agent vérifie MAC, firmware, disque, WIM, SHA-256 et index. Au message **« Tapez exactement : EFFACER PC-TEST-01 DISQUE … »**, saisir volontairement **ANNULER** pour ce premier test.

**Attendu :** `Confirmation locale refusée ; aucun disque effacé.` La console affiche **Échec** avec cette cause. Relire les partitions avec la commande précédente et vérifier qu’elles sont inchangées. Si l’agent bloque plus tôt, diagnostiquer ce prérequis avant de continuer. Le déploiement `failed` est terminé et son jeton ne peut pas être réutilisé.

## 10. Tester l’installation Windows sur le disque sacrifiable

Créer un **nouveau déploiement** pour le même poste/profil, avec le bon numéro de disque, et utiliser son nouvel identifiant/jeton dans le lanceur WinPE.

Vérifier le **numéro, modèle, série et taille** affichés. Si la cible est bien le disque de test numéro 0, saisir :

```text
EFFACER PC-TEST-01 DISQUE 0
```

Cette confirmation autorise la suppression de **toutes les partitions de ce disque**. Aucun retour arrière automatique n’est fourni. Adapter le numéro à celui réellement vérifié ; ne pas recopier `0` si ce n’est pas la cible.

**Attendu :** vérification du WIM, partitionnement GPT, application DISM, préparation UEFI puis **Image appliquée / 100 %**. Le hash peut prendre plusieurs minutes : le WIM est lu avant l’effacement et revérifié sous verrou avant l’application. Une erreur à ce stade doit être examinée dans le journal et sur le poste, pas masquée par une nouvelle tentative d’effacement.

Lorsque l’agent confirme la préparation :

```cmd
wpeutil reboot
```

Choisir ensuite **Windows Boot Manager / disque local** pour ne pas relancer le PXE. Terminer OOBE. Dans Windows, ouvrir **PowerShell en administrateur sur le poste nouvellement installé**, puis vérifier :

```powershell
hostname
Get-NetIPConfiguration
Get-PnpDevice -PresentOnly | Where-Object Status -ne 'OK'
Get-Tpm
Confirm-SecureBootUEFI
reagentc.exe /info
slmgr.vbs /xpr
```

**Attendu :** nom `PC-TEST-01`, réseau fonctionnel, drivers nécessaires, conformité TPM/Secure Boot, Windows RE opérationnel et état d’activation conforme à votre licence. Un périphérique en erreur ou WinRE désactivé doit être diagnostiqué ; la console ne corrige pas ces points automatiquement. `staged` signifie seulement que l’image et le démarrage ont été préparés : le déploiement complet est validé après ces contrôles dans Windows.

## 11. Tester le redémarrage et fermer le laboratoire

Une fois la configuration enregistrée, redémarrer le serveur à un moment approprié. Après reconnexion, vérifier que la tâche console repart et que `https://192.168.99.250/health` répond depuis le poste d’administration. Vérifier aussi WDS si vous devez poursuivre les essais.

Annuler les déploiements abandonnés dans la console. Si les essais PXE sont terminés :

```powershell
wdsutil.exe /Set-Server /AnswerClients:None
```

Si le certificat auto-signé était réservé à ce laboratoire temporaire, retirer son entrée de confiance des postes lorsque la configuration est démontée, en vérifiant son empreinte pour ne pas retirer un autre certificat. Ne pas retirer cette confiance tant que les essais HTTPS reposent encore dessus.

L’annulation d’un job ne restaure pas un disque effacé et n’arrête pas instantanément un DISM déjà lancé. Un essai d’annulation doit être fait **avant la confirmation locale**, puis vérifié par un refus de plan/jeton dans l’agent.

## Diagnostic rapide

| Symptôme | Vérification suivante |
|---|---|
| Python ou pip introuvable | Python 3.12 installé pour tous les utilisateurs, chemin exact, pip/venv inclus. |
| `/health` local ne répond pas | Fenêtre Uvicorn/tâche, port 8080 libre, logs `data\logs\console.log`. |
| IIS affiche 502 | Backend local joignable, ARR proxy activé, URL Rewrite installé, règle de proxy. |
| HTTPS est refusé | SAN IP, autorité de confiance du client/WinPE, certificat non expiré, date/heure. |
| Le poste PXE ne reçoit pas d’IP | DHCP existant, VLAN, câblage, relais ; ne pas créer un DHCP concurrent. |
| Le poste reçoit une IP mais WinPE ne démarre pas | Réponses WDS, image importée, UEFI x64, service WDS, flux TFTP/PXE autorisés. |
| WinPE n’a pas de réseau ou ne voit pas le disque | Pilotes NIC/NVMe/RAID du constructeur dans WinPE, firmware/contrôleur compatible. |
| Accès SMB refusé | Nom serveur/compte, mot de passe, droits Read SMB + RX NTFS, TCP 445, client SMB compatible chiffrement. |
| Lettres S/W/R déjà occupées | Relever les volumes ; choisir un poste de test approprié, ne pas supprimer des volumes sans identification. |
| MAC, index ou hash rejetés | MAC du client, index DISM, WIM exact et immuable correspondant au profil. |
| Le poste repart en PXE après DISM | Sélectionner Windows Boot Manager ; vérifier le résultat BCDBoot et le journal. |

Pour conserver la recette, noter la version ADK/WinPE, le modèle/NIC du poste, le SHA-256 de l’image, l’index et l’identifiant du job. **Ne pas enregistrer les jetons ou mots de passe** dans le compte rendu.
