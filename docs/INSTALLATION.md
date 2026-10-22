> IQ-5.0 : le PC est identifié par son numéro de série BIOS, même sur un dock. Les instructions MAC ci-dessous concernent l’ancien parcours. Pour les déploiements actuels, suivre [GUIDE-UTILISATEUR.md](GUIDE-UTILISATEUR.md) et [ATELIER-4.md](ATELIER-4.md).

# Installation neuve , Windows Server 2025

Serveur prévu : **DEPLOY-01 / 192.168.99.250**, hébergé sur Hyper-V `192.168.99.253`. Masque confirmé : `255.255.255.0` ; passerelle et DHCP : routeur `192.168.99.1`. Le premier essai utilise le même LAN pour serveur et client. Pour la console déjà installée, suivre [la mise à jour 0.2 et le parcours physique HP](ASSISTANT-PXE.md). Ce guide couvre une installation neuve.

## 1. Préparer le serveur

- Fixer l’IP `192.168.99.250`, puis vérifier le DNS, la passerelle, la synchronisation horaire et l’absence de doublon d’adresse.
- Prévoir un volume NTFS pour WDS et les images, idéalement `D:` avec 100 Go libres minimum ; adapter les chemins si le volume est différent.
- Installer **Python 3.12 x64 pour tous les utilisateurs**, par exemple `C:\Program Files\Python312\python.exe`, depuis [python.org](https://www.python.org/downloads/windows/).
- Installer un [ADK et son module complémentaire WinPE](https://learn.microsoft.com/windows-hardware/get-started/adk-install) compatibles avec l’image Windows x64 choisie. Les deux installateurs sont distincts. Inclure les outils de déploiement.
- Copier le dépôt dans `C:\AtelierPXE\console`, hors d’un profil utilisateur et hors de `RemoteInstall`.

Pour une nouvelle installation de postes en 2026, choisir une édition Windows 11 encore prise en charge et vérifier les exigences CPU/TPM 2.0/Secure Boot de chaque modèle. L’agent ne contourne pas ces exigences et ne les certifie pas. Windows 10 nécessite de vérifier son cycle de support et vos droits ESU/LTSC éventuels.

## 2. Installer la console

PowerShell administrateur, dans `C:\AtelierPXE\console` :

```powershell
.\scripts\Install-Console.ps1 -ServerUrl 'https://192.168.99.250' -DataPath 'D:\AtelierPXE\data' -InstallStartupTask
```

Ce script crée un environnement Python, la base, un jeton aléatoire et une tâche `AtelierPXE-Console` au démarrage sous **LOCAL SERVICE**, avec des droits de lecture sur le code et de modification sur les données. La tâche ne nécessite pas une session ouverte et redémarre jusqu’à trois fois en cas d’échec. Python écoute uniquement sur `127.0.0.1:8080`. Le script ne remplace ni une tâche ni un fichier de configuration existant.

Vérifier localement :

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health
Get-ScheduledTask -TaskName AtelierPXE-Console
```

Les logs sont dans `D:\AtelierPXE\data\logs\console.log`. Le jeton administrateur est dans `D:\AtelierPXE\data\admin-token` ; l’ouvrir sur le serveur et le saisir dans la console. Les variables `MDT_*` sont des noms internes historiques, aucun composant MDT n’est utilisé.

## 3. Configurer HTTPS

Installer IIS avec **URL Rewrite et Application Request Routing (ARR)** depuis les sources officielles IIS. Activer le proxy ARR au niveau serveur. Créer un site IIS dédié, par exemple dans `C:\inetpub\AtelierPXE`, et y copier `docs/iis.web.config.example` en `web.config`.

Configurer une liaison HTTPS 443 avec un certificat de confiance. Pour utiliser `https://192.168.99.250`, le certificat doit contenir **192.168.99.250 dans son SAN de type IP**. Un simple CN ou SAN DNS ne suffit pas. Un nom DNS interne avec le certificat correspondant convient aussi ; utiliser alors ce nom dans `-ServerUrl` et reconstruire WinPE.

Restreindre le site IIS et le pare-feu aux réseaux d’administration/déploiement. Les identifiants transitent uniquement en HTTPS. Vérifier `/health` depuis un autre poste. L’exemple IIS ne crée pas les bindings, n’installe pas ARR et ne configure pas automatiquement les certificats.

Pour une autorité interne, exporter seulement son certificat racine public `.cer` et le fournir à `Build-WinPE.ps1 -TrustedRootCertificate`. Le lanceur l’ajoute au magasin de confiance de WinPE au démarrage. Ne jamais copier une clé privée ou un fichier PFX dans WinPE. Ne pas désactiver la validation TLS.

## 4. Installer WDS autonome

Le mode autonome convient à un serveur sans Active Directory. Un domaine pourra être ajouté ultérieurement dans un travail distinct.

```powershell
.\scripts\Install-Wds.ps1 -RemoteInstallPath 'D:\RemoteInstall'
```

Si **le service DHCP Windows est réellement installé sur ce même serveur**, ajouter `-DhcpOnThisServer` ; cela ajuste les ports DHCP/WDS et l’option 60. Ne pas utiliser ce paramètre pour un DHCP fourni par un routeur ou un autre serveur.

Les réponses PXE restent désactivées. Le script refuse un rôle WDS déjà installé ou un dossier RemoteInstall déjà présent pour éviter une reconfiguration accidentelle.

WDS sert ici une image **WinPE personnalisée**. Ne pas utiliser le `boot.wim` de l’ISO Windows 11 comme parcours d’installation WDS traditionnel. Voir [les limites WDS actuelles](https://learn.microsoft.com/windows/deployment/wds-boot-support).

## 5. Construire et importer WinPE

```powershell
.\scripts\Build-WinPE.ps1 `
  -ServerUrl 'https://192.168.99.250' `
  -OutputPath 'D:\AtelierPXE\WinPE-v1' `
  -TrustedRootCertificate 'C:\Certificats\racine-interne.cer' `
  -DriversPath 'D:\Pilotes\WinPE-x64' `
  -ImportIntoWds
```

Omettre `-TrustedRootCertificate` si le certificat serveur est déjà reconnu par WinPE. Omettre `-DriversPath` si les pilotes réseau/stockage nécessaires sont inclus. Fournir uniquement des pilotes Windows x64 signés provenant du constructeur ; le script n’active pas de mode d’installation de pilotes non signés.

Le script utilise `copype amd64`, ajoute WMI, .NET, Scripting, PowerShell, StorageWMI et DismCmdlets, puis copie l’assistant graphique et les scripts d’installation/personnalisation. Il refuse d’écraser une image existante. En cas d’erreur de montage, il tente de démonter en annulant ses modifications. Le résultat est `media\sources\boot.wim`, importé comme une image distincte nommée « Atelier PXE - Assistant Windows x64 ».

Le clavier opérateur de WinPE est français AZERTY par défaut, initialisé avant l’assistant. `-WinPEKeyboardLayout '100c:0000100c'` sélectionne le suisse romand ; `'0409:00000409'` sélectionne l’anglais US. Le clavier choisi dans le profil concerne le Windows installé.

Le paramètre `-AllowHttpForLab` sert uniquement à un réseau de laboratoire isolé et expose les jetons en clair sur le réseau. Le parcours normal utilise HTTPS. Secure Boot doit rester activé si votre matériel et la chaîne de démarrage le permettent ; l’image ADK/WDS doit être à jour des exigences de signature/révocation de votre parc.

Les images **FR-REPRISE-1** proposent un choix de clavier et un champ de test avant les identifiants. Après fermeture ou échec, le menu permet de relancer ou de consulter `X:\Atelier\Logs\startup.log`. Au terminal, taper `atelier` pour rouvrir l’assistant. Pour un serveur existant et le test Hyper-V, suivre [la procédure de reprise](REPRISE-PXE.md).

## 6. Préparer une image et un partage SMB

Utiliser une image Windows provenant d’une source Microsoft/licenciée. La console accepte un **WIM non fractionné**, pas un ISO, un ESD ou un SWM. Pour un média avec `install.esd`, exporter l’édition souhaitée vers un WIM :

```powershell
dism /Get-WimInfo /WimFile:E:\sources\install.esd
dism /Export-Image /SourceImageFile:E:\sources\install.esd /SourceIndex:6 /DestinationImageFile:D:\AtelierPXE\data\artifacts\Windows11-Pro.wim /Compress:max /CheckIntegrity
dism /Get-WimInfo /WimFile:D:\AtelierPXE\data\artifacts\Windows11-Pro.wim
```

**6 est un exemple** : choisir l’index affiché par DISM. Le WIM exporté avec une seule édition aurà l’index 1. Pour un média déjà en WIM, copier le fichier dans `data\artifacts` en conservant un nom/version explicite. Éviter les espaces dans les noms de fichiers enregistrés. Ne pas modifier une image après son enregistrement ; utiliser un nouveau fichier/version.

Créer un compte SMB **non administrateur**, avec un mot de passe saisi localement :

```powershell
$password = Read-Host 'Mot de passe du compte lecture images' -AsSecureString
New-LocalUser -Name 'DeployRead' -Password $password -Description 'Lecture des images WinPE'
.\scripts\Publish-ImageShare.ps1 -ReadOnlyAccount "$env:COMPUTERNAME\DeployRead"
```

Ce script publie uniquement `data\artifacts`, avec lecture seule SMB/NTFS et chiffrement SMB requis. Le jeton administrateur et la base restent hors du partage. Le compte ne doit pas appartenir aux administrateurs. Gérer sa rotation et l’expiration du mot de passe selon votre politique ; ne stocker aucun mot de passe dans l’image WinPE.

Dans la console : **Profils Windows → Enregistrer un fichier → Image Windows**. Puis créer un profil avec le bon index DISM et une locale installée dans l’image. Le champ langue ne rajoute pas un pack de langue absent. Le profil contient aussi clavier, région, fuseau, thème, fond d’écran et bundles. Voir [la préparation des logiciels](ASSISTANT-PXE.md#5-enregistrer-le-fond-décran-et-les-logiciels). OOBE reste interactif, sans compte/mot de passe d’administration prédéfini.

## 7. Raccorder DHCP et PXE

WDS ne fournit pas automatiquement des baux DHCP. Identifier d’abord le DHCP existant. Ne pas installer un deuxième DHCP sur le même réseau sans coordination.

| Topologie | Configuration à vérifier |
|---|---|
| DHCP externe, WDS sur le même VLAN | Diffusion PXE joignable par DHCP et WDS ; activer les réponses WDS après l’import WinPE. |
| DHCP et WDS sur le même serveur | `-DhcpOnThisServer` / ports DHCP non utilisés par WDS / option 60. |
| Postes sur un autre VLAN | Relais DHCP/IP helpers vers DHCP **et** `192.168.99.250`, puis règles réseau compatibles WDS. |

Ne pas appliquer aveuglément 66/67 : les fichiers dépendent de l’architecture et du firmware. Préférer la négociation WDS et les relais appropriés. Les flux requis incluent DHCP/PXE UDP 67/68/4011, TFTP UDP 69 et ses ports de transfert WDS, HTTPS TCP 443 et SMB TCP 445. Utiliser les règles WDS installées et leur portée réseau ; ne pas ouvrir tous les ports vers Internet. Voir [les ports WDS](https://learn.microsoft.com/troubleshoot/mem/configmgr/os-deployment/ports-used-by-wds).

Dans la console WDS, sélectionner la politique de réponse adaptée et activer les réponses sur le réseau de laboratoire seulement après la vérification DHCP. L’inventaire MAC d’Atelier et les appareils approuvés WDS sont deux mécanismes distincts.

## 8. Premier déploiement supervisé

1. Démarrer le PC de test en PXE **UEFI x64**, choisir **Atelier PXE - Assistant Windows x64**. L’écran Connexion affiche matériel et MAC avant toute installation.
2. Relever la MAC Ethernet utilisée et l’enregistrer dans **Parc machines** avec son futur nom Windows.
3. Créer un déploiement avec le numéro réel du disque et le choix dans l’assistant autorisé. Saisir `EFFACER NOM-DU-POSTE` côté console.
4. Conserver le code PXE affiché une seule fois, valable deux heures. En cas de perte/expiration, annuler et créer une nouvelle autorisation.
5. Dans l’assistant, saisir code et compte/mot de passe SMB, puis choisir Windows, nom, région et bundle/bureau.
6. Pour le premier parcours, fermer au récapitulatif sans saisir la confirmation et annuler le job : aucun disque n’est effacé.
7. Sur le passage d’installation prévu, vérifier modèle, numéro, série et taille du disque. Taper la phrase exacte `EFFACER NOM-DU-POSTE DISQUE N` uniquement pour le disque de test choisi.
8. Attendre « Image appliquée », fermer l’assistant, éteindre avec `wpeutil shutdown`, puis démarrer Windows depuis le disque.
9. Terminer OOBE avec un premier compte administrateur ; les logiciels et le bureau sont alors configurés. Vérifier `C:\ProgramData\AtelierPXE\result.json`, pilotes, réseau, activation et `reagentc /info`.

Pour le détail du HP EliteBook 850 G6 et des bundles, suivre [la recette graphique](ASSISTANT-PXE.md#8-premier-démarrage-du-hp-sans-effacement). Le lanceur de secours reste disponible avec `powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Atelier\Launch.ps1 -TextMode`, en utilisant l’identifiant/jeton confidentiel de l’autorisation.

Une annulation arrête les opérations aux points de contrôle ; elle ne restaure pas un disque effacé et n’interrompt pas instantanément DISM. Une coupure réseau après le début du partitionnement nécessite un diagnostic local. Il n’y a ni rollback ni reprise automatique.

## Sauvegarde et exploitation

Arrêter la tâche avant une copie cohérente du dossier `data`, puis la redémarrer. Pour une sauvegarde à chaud, utiliser l’API SQLite de sauvegarde ; ne pas copier seulement le `.sqlite3` en ignorant ses fichiers WAL/SHM. Protéger les sauvegardes et les jetons avec les mêmes droits que le serveur. Sauvegarder aussi les images WIM et les paramètres WDS/IIS. Aucune suppression de machine/profil/image n’est proposée dans cette version pour préserver l’historique référencé.

Le DHCP est fourni par le routeur `192.168.99.1`. Si des postes sont sur d’autres VLAN, préciser les relais/règles correspondants avant d’ouvrir le PXE à ces postes.
