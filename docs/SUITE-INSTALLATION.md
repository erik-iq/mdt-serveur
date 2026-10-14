# Suite de l’installation — DEPLOY-01

Ce guide poursuit la création de votre VM Windows Server 2025, une fois le réseau opérationnel. Les commandes sont à exécuter **dans la VM de déploiement**, en **Windows PowerShell administrateur**, sauf les actions explicitement indiquées dans Hyper-V.

| Élément | Configuration confirmée |
|---|---|
| Hôte Hyper-V | 192.168.99.253 |
| VM de déploiement | DEPLOY-01 / 192.168.99.250 |
| Masque | 255.255.255.0 |
| Passerelle et DHCP existant | Routeur 192.168.99.1 |
| Commutateur Hyper-V | vSwitch-LAN, externe, raccordé au port physique du LAN |
| Stockage attendu | D: NTFS, volume de données dédié |
| Console accessible depuis le LAN | https://192.168.99.250 |

Conserver `.250` et `.253` hors des adresses attribuées à d’autres appareils par le DHCP du routeur, par exclusion ou réservation appropriée. Le routeur continue à fournir le DHCP ; ce guide n’installe pas de service DHCP dans la VM. Le premier client sera une VM avec disque vierge sur ce même réseau. Les scripts Windows seront validés par cet essai réel ; les tests Linux déjà exécutés ne constituent pas une validation Windows/PXE.

## 1. Vérifier le serveur et son disque

```powershell
hostname
Get-Volume -DriveLetter D
```

Attendu : nom `DEPLOY-01`, disque D: en NTFS avec l’espace prévu. Si D: n’existe pas, terminer sa création avant la suite. Si une commande affiche une erreur pendant la procédure, corriger ce point avant de passer à l’étape suivante.

## 2. Installer Python 3.12 pour tous les utilisateurs

Les scripts actuels attendent Python **3.12 x64** avec `pip` et `venv`. Pour un installateur Windows classique de cette branche, la [page officielle Python 3.12.10](https://www.python.org/downloads/release/python-31210/) fournit **Windows installer (64-bit)**. Les versions de sécurité plus récentes de la branche 3.12 peuvent ne fournir que les sources ; ne pas télécharger une archive de sources pour cette installation.

Dans l’installateur : **Customize installation → Next → Install for all users**, avec le chemin `C:\Program Files\Python312`. Ne pas choisir une installation seulement dans le profil Administrateur, car la console sera lancée sous LOCAL SERVICE.

Vérifier :

```powershell
& 'C:\Program Files\Python312\python.exe' --version
```

Attendu : `Python 3.12.x`. Si le chemin choisi est différent, fournir ce chemin avec `-PythonExe` à l’étape 4.

## 3. Télécharger et extraire le logiciel

Dans [le dépôt GitHub](https://github.com/erik-iq/mdt-serveur), cliquer **Code → Download ZIP**. Dans les propriétés de l’archive téléchargée, cocher **Débloquer** si cette option est présente, puis extraire les fichiers.

Le résultat doit être :

```text
C:\AtelierPXE\console\requirements.txt
C:\AtelierPXE\console\scripts\Install-Console.ps1
C:\AtelierPXE\console\app\main.py
```

Éviter un niveau supplémentaire `console\mdt-serveur-main\...`. Vérifier :

```powershell
Set-Location C:\AtelierPXE\console
Test-Path .\scripts\Install-Console.ps1
Get-ChildItem .\scripts -File -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

Attendu : `True` pour le chemin. La politique d’exécution est limitée à cette session PowerShell.

## 4. Installer la console et sa tâche de démarrage

```powershell
.\scripts\Install-Console.ps1 `
  -ServerUrl 'https://192.168.99.250' `
  -DataPath 'D:\AtelierPXE\data' `
  -InstallStartupTask
```

Le script installe les dépendances, crée la base et le jeton administrateur, puis lance une tâche `AtelierPXE-Console` sous LOCAL SERVICE. Il ne remplace pas une configuration ou une tâche déjà existante. Après une réussite, vérifier le service au lieu de relancer l’installation.

Après quelques secondes :

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health
Get-ScheduledTask -TaskName AtelierPXE-Console
```

Attendu : `status = ok`, `version = 0.1.0`, tâche `Running`. En cas d’échec, lire `D:\AtelierPXE\data\logs\console.log`.

Ouvrir localement `http://127.0.0.1:8080` dans le navigateur de la VM. Ouvrir le jeton avec :

```powershell
notepad D:\AtelierPXE\data\admin-token
```

Le saisir dans le formulaire de la console. Ne pas publier ce jeton ni le transmettre dans un chat. Le port 8080 écoute uniquement sur la boucle locale ; l’accès réseau sera assuré par IIS à l’étape 6.

## 5. Créer un certificat HTTPS pour le laboratoire

Si vous disposez d’une autorité de certification interne, utiliser son certificat serveur avec SAN **IP 192.168.99.250**, puis exporter uniquement le certificat racine public pour WinPE. Sinon, créer un certificat auto-signé dédié au laboratoire :

```powershell
New-Item -ItemType Directory -Path C:\AtelierPXE\certs -Force | Out-Null
$atelierCert = New-SelfSignedCertificate `
  -Type Custom `
  -Subject 'CN=AtelierPXE-Lab' `
  -FriendlyName 'AtelierPXE-Lab' `
  -CertStoreLocation Cert:\LocalMachine\My `
  -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
  -KeyUsage DigitalSignature,KeyEncipherment `
  -TextExtension @('2.5.29.17={text}IPAddress=192.168.99.250','2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
  -NotAfter (Get-Date).AddMonths(3)
Export-Certificate -Cert $atelierCert -FilePath C:\AtelierPXE\certs\AtelierPXE-lab.cer -Type CERT
Import-Certificate -FilePath C:\AtelierPXE\certs\AtelierPXE-lab.cer -CertStoreLocation Cert:\CurrentUser\Root
```

Le certificat reste avec sa clé privée sur le serveur. Seul le fichier public `.cer` sera copié dans WinPE ou sur le poste d’administration. Pour un autre navigateur/poste, copier ce fichier par un canal de confiance, vérifier son empreinte, puis importer cette copie dans le magasin Root de l’utilisateur concerné. Une installation durable doit utiliser la gestion de certificats de votre organisation. Ne pas désactiver la vérification TLS.

## 6. Installer IIS et configurer son proxy HTTPS

Si le site ou son `web.config` existe déjà, vérifier sa configuration avant toute copie qui le remplacerait. Le bloc suivant refuse de remplacer un fichier existant :

```powershell
Install-WindowsFeature Web-Server -IncludeManagementTools
New-Item -ItemType Directory -Path C:\inetpub\AtelierPXE -Force | Out-Null
if (Test-Path C:\inetpub\AtelierPXE\web.config) { throw 'web.config existe deja : verifier la configuration avant de poursuivre.' }
Copy-Item .\docs\iis.web.config.example C:\inetpub\AtelierPXE\web.config
```

Installer les modules officiels IIS [URL Rewrite](https://www.iis.net/downloads/microsoft/url-rewrite) et [Application Request Routing — ARR](https://www.iis.net/downloads/microsoft/application-request-routing).

Dans **Gestionnaire IIS** :

1. Sélectionner le serveur → **Application Request Routing Cache → Server Proxy Settings**.
2. Cocher **Enable proxy**, puis **Apply**.
3. Sous **Sites → Ajouter un site web** : nom `AtelierPXE`, chemin `C:\inetpub\AtelierPXE`.
4. Liaison : **https**, adresse `192.168.99.250`, port **443**, nom d’hôte vide pour l’accès par IP.
5. Choisir le certificat **AtelierPXE-Lab**, puis démarrer le site. Vérifier qu’aucun autre site n’utilise cette liaison.

Créer la règle HTTPS pour le LAN si elle n’existe pas déjà :

```powershell
New-NetFirewallRule -Name 'AtelierPXE-HTTPS' -DisplayName 'Atelier PXE HTTPS LAN' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443 -RemoteAddress 192.168.99.0/24 -Profile Any
Invoke-RestMethod https://192.168.99.250/health
```

Attendu : `status = ok`, sans erreur de certificat. Ouvrir **https://192.168.99.250** dans le navigateur. Tester aussi depuis le poste d’administration après avoir établi la confiance du certificat public. Le site IIS sert le proxy ; son dossier ne doit pas être celui du code ou des données.

## 7. Installer ADK et son module WinPE

Depuis [la page Microsoft ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install), installer une version compatible avec l’image Windows choisie :

- **Windows ADK**, avec la fonctionnalité **Deployment Tools / Outils de déploiement**.
- **Windows PE add-on / Module complémentaire WinPE**, installé séparément.

Les deux composants sont nécessaires. Le script créera une image WinPE x64 avec les composants PowerShell/WMI/Storage/DISM requis. Pour des PC physiques, prévoir les drivers réseau/stockage signés de leurs constructeurs si WinPE ne les contient pas déjà.

## 8. Installer WDS et importer votre WinPE

Dans `C:\AtelierPXE\console` :

```powershell
.\scripts\Install-Wds.ps1 -RemoteInstallPath 'D:\RemoteInstall'
```

Ne pas créer `D:\RemoteInstall` à l’avance : le script initialise ce stockage et refuse un dossier déjà présent. Votre DHCP est sur le routeur `.1` ; ne pas ajouter `-DhcpOnThisServer`. Si WDS est déjà installé ou exige un redémarrage, terminer sa configuration dans la console WDS au lieu de relancer le script d’installation neuve.

Construire et importer WinPE :

```powershell
.\scripts\Build-WinPE.ps1 `
  -ServerUrl 'https://192.168.99.250' `
  -OutputPath 'D:\AtelierPXE\WinPE-v1' `
  -TrustedRootCertificate 'C:\AtelierPXE\certs\AtelierPXE-lab.cer' `
  -ImportIntoWds
```

Si vous avez utilisé votre autorité interne, remplacer le certificat public par celui de sa racine. Choisir un nouveau dossier à chaque reconstruction. Attendu : image **Atelier PXE - WinPE x64** visible sous **Images de démarrage** dans la console WDS. Les réponses PXE restent désactivées jusqu’à l’essai client.

## 9. Préparer l’image Windows à installer

Télécharger un ISO Windows officiel/licencié, par exemple Windows 11 x64 français, puis le monter dans la VM serveur. Relever sa lettre réelle dans l’Explorateur. Les exemples ci-dessous supposent **E:** ; adapter cette lettre si nécessaire.

Si le média contient `install.wim` :

```powershell
Copy-Item E:\sources\install.wim D:\AtelierPXE\data\artifacts\Windows11-FR.wim
dism.exe /Get-WimInfo /WimFile:D:\AtelierPXE\data\artifacts\Windows11-FR.wim
```

Noter l’index de l’édition voulue. Si le média contient `install.esd` :

```powershell
dism.exe /Get-WimInfo /WimFile:E:\sources\install.esd
$atelierIndex = Read-Host 'Index de l edition a exporter'
dism.exe /Export-Image /SourceImageFile:E:\sources\install.esd "/SourceIndex:$atelierIndex" /DestinationImageFile:D:\AtelierPXE\data\artifacts\Windows11-FR.wim /Compress:max /CheckIntegrity
dism.exe /Get-WimInfo /WimFile:D:\AtelierPXE\data\artifacts\Windows11-FR.wim
```

Un export d’une seule édition vers un nouveau WIM donne normalement l’index **1**. Vérifier le résultat DISM, ne pas supposer qu’un index particulier correspond toujours à Pro. Ne pas écraser/modifier un fichier WIM déjà enregistré ; utiliser un nouveau nom pour une nouvelle version.

Dans la console web :

1. **Profils Windows → Enregistrer un fichier** : `Windows11-FR.wim`, type **Image Windows**. Attendre le calcul SHA-256.
2. **Nouveau profil** : nom `Windows 11 FR`, image enregistrée, index DISM correct et locale `fr-FR` pour une image française.

## 10. Créer le partage d’images en lecture seule

Créer le compte local dédié s’il n’existe pas déjà, puis publier les images :

```powershell
$atelierReadPassword = Read-Host 'Mot de passe du compte DeployRead' -AsSecureString
New-LocalUser -Name DeployRead -Password $atelierReadPassword -Description 'Lecture des images WinPE'
.\scripts\Publish-ImageShare.ps1 -Path 'D:\AtelierPXE\data\artifacts' -ReadOnlyAccount "$env:COMPUTERNAME\DeployRead"
New-NetFirewallRule -Name 'AtelierPXE-SMB' -DisplayName 'Atelier PXE SMB LAN' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress 192.168.99.0/24 -Profile Any
Get-SmbShareAccess -Name AtelierImages
```

Attendu : accès **Read** pour `DEPLOY-01\DeployRead`. Le compte est non administrateur, le partage exige le chiffrement SMB et expose uniquement les fichiers d’images. Les règles réseau sont limitées au LAN `.99.0/24`. Si le compte, le partage ou une règle existe déjà, examiner cet élément plutôt que le recréer. Ne pas enregistrer le mot de passe dans WinPE.

## 11. Créer la VM cliente de test dans Hyper-V

Créer une **seconde VM**, distincte du serveur, avec ces paramètres :

| Paramètre | Valeur |
|---|---|
| Nom Hyper-V | PC-TEST-01 |
| Génération | 2 |
| Mémoire | 4 Go minimum pour Windows 11 |
| CPU | 2 processeurs virtuels minimum |
| Disque | Nouveau VHDX vierge de 80 Go |
| Réseau | vSwitch-LAN |
| Installation | Système d’exploitation ultérieurement, sans ISO |
| Sécurité | Secure Boot, modèle Microsoft Windows ; TPM virtuel activé |
| Microprogramme | Carte réseau en premier pour le premier démarrage |

Vérifier que l’hôte dispose des ressources nécessaires pour les deux VM simultanément. Dans les fonctionnalités avancées de sa carte réseau, relever la MAC et la conserver stable (adresse MAC statique avec la valeur attribuée, unique). Dans la console Atelier, enregistrer `PC-TEST-01` avec **la MAC de cette VM cliente**, séparée par des deux-points ou des tirets : par exemple, la valeur Hyper-V `00155D63FD01` doit être saisie `00:15:5D:63:FD:01` dans Atelier. Utiliser la valeur réellement attribuée au client ; cet exemple de format n’est pas une MAC à recopier.

Créer un déploiement pour cette machine, le profil Windows, disque **0** du client vierge, confirmation **EFFACER PC-TEST-01**. Conserver l’identifiant et le jeton de déploiement affichés une seule fois. Le jeton de déploiement est distinct du jeton administrateur.

## 12. Tester PXE et le refus d’effacement

Les deux VM et le DHCP sont sur le même réseau pour ce premier essai. Sur le serveur, activer les réponses PXE pour l’essai supervisé :

```powershell
wdsutil.exe /Set-Server /AnswerClients:All
Start-Service WDSServer
```

Ne pas ajouter automatiquement les options DHCP 66/67 sur le routeur. Les réponses WDS sont séparées des autorisations d’effacement dans Atelier. Pour des clients sur un autre VLAN, faire configurer les relais appropriés vers DHCP `.1` et WDS `.250`.

Démarrer **PC-TEST-01**, confirmer le démarrage réseau si demandé et sélectionner **Atelier PXE - WinPE x64**. Le lanceur démarre. L’interrompre avec **Ctrl+C avant tout effacement** pour revenir au terminal CMD WinPE, puis connecter le partage et relancer :

```cmd
ipconfig /all
net use \\192.168.99.250\AtelierImages /user:DEPLOY-01\DeployRead *
dir \\192.168.99.250\AtelierImages\Windows11-FR.wim
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Atelier\Launch.ps1
```

Le `*` demande le mot de passe SMB localement. Saisir dans le lanceur l’identifiant et le jeton du job, puis le chemin `\\192.168.99.250\AtelierImages\Windows11-FR.wim`.

Après les contrôles MAC/UEFI/disque/hash/index, à la confirmation d’effacement, taper **ANNULER**. Attendu : refus avant `diskpart clean`, journal `Confirmation locale refusée ; aucun disque effacé`, état **Échec**. Si un prérequis bloque avant ce prompt, diagnostiquer ce point. Un job terminé en échec exige une nouvelle autorisation ; son jeton est révoqué.

## 13. Installer réellement sur le disque vierge et valider Windows

Créer un nouveau déploiement pour le client, utiliser son nouvel identifiant/jeton, puis relancer l’agent. Vérifier numéro, modèle et taille du disque client. Pour le disque client 0 confirmé comme sacrifiable, taper **EFFACER PC-TEST-01 DISQUE 0**. Toutes ses partitions seront supprimées. Il n’y a ni rollback ni reprise automatique ; ne pas utiliser le disque du serveur.

Attendre l’application DISM et **Image appliquée / 100 %**. La progression suit les phases ; le hash et DISM peuvent rester plusieurs minutes sur une phase. Ce résultat signifie que l’image et le démarrage sont préparés, sans certifier le premier démarrage Windows.

Pour la VM Hyper-V cliente, éteindre WinPE :

```cmd
wpeutil shutdown
```

Dans **Paramètres de PC-TEST-01 → Microprogramme**, mettre le disque en premier puis démarrer la VM. Terminer OOBE et contrôler sous Windows : nom du poste, réseau, pilotes, activation légale, TPM/Secure Boot et `reagentc /info` depuis une session administrateur. Ces contrôles valident le poste réellement installé.

À la fin des essais, annuler les jobs abandonnés et désactiver les réponses PXE si vous ne souhaitez plus distribuer WinPE :

```powershell
wdsutil.exe /Set-Server /AnswerClients:None
```

Le dernier contrôle d’exploitation est un redémarrage planifié de DEPLOY-01 : vérifier le retour de la tâche console, l’accès HTTPS et les services requis. Les scripts d’installation ne doivent pas être relancés pour effectuer ce contrôle.
