# Reprise du test PXE dans Hyper-V

Sur **DEPLOY-01 / 192.168.99.250**, reconstruire une image de démarrage avec les nouveaux scripts. Le client est **PC-TEST-PXE**, sur l’hôte Hyper-V **192.168.99.253**. Pour le parcours sans saisies demandé, suivre d'abord [le mode interne](MODE-INTERNE.md). Conserver WDS, IIS, ADK, le certificat, les profils, logiciels et images dans `D:\AtelierPXE\data`. Ne pas relancer `Install-Console.ps1` ou `Install-Wds.ps1` sur le serveur déjà installé.

L’image **INTERNE-1** conserve un menu après fermeture ou erreur, un nouveau processus PowerShell STA à chaque relance, un choix de clavier et un champ de test avant les identifiants. Les erreurs de démarrage et leur emplacement restent affichés. Le journal `X:\Atelier\Logs\startup.log` contient étapes, types d’erreur et lignes de script, sans messages d’erreur, codes PXE, jetons ou mots de passe. Il disparaît au redémarrage de WinPE. L’API reste en **0.2.0** ; INTERNE-1 identifie l’image de démarrage avec les écritures XML vérifiées.

Si Windows affiche une erreur de fichier de réponses après le démarrage sur disque, suivre [la collecte des journaux depuis l’hôte Hyper-V](DIAGNOSTIC-PREMIER-DEMARRAGE.md). Cette collecte distingue un fichier absent, vide, rempli d’octets nuls ou un XML invalide, sans modifier le Windows installé.

Si le diagnostic confirme un fichier de réponses intégralement nul, [réparer ce fichier dans la VM arrêtée](REPARATION-UNATTEND.md) avant de recommencer une installation. Les prochains supports INTERNE-1 conservent une copie XML vérifiée et son empreinte dans le poste.

## Si l’installation s’est arrêtée après DiskPart

Le message `No MSFT_Partition objects found ... DriveLetter ... S` provient du contrôle après partitionnement, avant l’application du WIM. Le disque de test a déjà été repartitionné : il ne faut pas considérer cet essai comme une installation Windows terminée.

La révision **FR-REPRISE-2** remplace la recherche par `Get-Partition -DriveLetter` par une énumération sur le disque cible après rafraîchissement de l’inventaire. Elle vérifie les quatre rôles GPT, les tailles minimales et l’identité du disque. Elle résout les lettres S/W/R avec `mountvol /L` et compare leurs GUID aux chemins des partitions, puis vérifie FAT32/NTFS. Une partition EFI sans propriété DriveLetter peut ainsi être contrôlée ; un volume étranger ou absent bloque toujours DISM. L’attente est limitée à vingt contrôles, espacés d’une demi-seconde, hors durée des commandes.

Fermer l’assistant interrompu et éteindre la VM cliente. Suivre les étapes 1 et 2 ci-dessous : **mettre à jour les scripts ne modifie pas une ancienne image WDS**. Démarrer ensuite la nouvelle image INTERNE-1 et créer une nouvelle autorisation. Conserver l’ancien déploiement en échec dans l’historique ; il ne peut pas être repris avec son ancien code. La nouvelle installation effacera à nouveau uniquement le disque de test confirmé.

Pour diagnostiquer un nouvel arrêt, ces commandes WinPE ne modifient aucun disque :

```cmd
powershell.exe -NoProfile -Command "Get-Partition | Format-List DiskNumber,PartitionNumber,DriveLetter,GptType,AccessPaths"
mountvol.exe S:\ /L
```

## 1. Mettre à jour les scripts

Effectuer cette maintenance sans installation active. Arrêter seulement la VM **cliente** si elle n’installe rien. `Update-Console.ps1` refuse une mise à jour si un déploiement est `running`. Annuler dans la console web l’ancienne autorisation encore en attente si elle doit être remplacée.

Sur **DEPLOY-01**, ouvrir **Windows PowerShell en administrateur** et copier :

```powershell
& {
    $ErrorActionPreference = 'Stop'
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force
    $atelierMaj = Join-Path 'C:\AtelierPXE' ('Maj-PXE-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $atelierMaj | Out-Null
    $atelierZip = Join-Path $atelierMaj 'source.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/erik-iq/mdt-serveur/archive/refs/heads/main.zip' -OutFile $atelierZip
    Unblock-File -LiteralPath $atelierZip
    Expand-Archive -LiteralPath $atelierZip -DestinationPath (Join-Path $atelierMaj 'source')
    $atelierScripts = @(Get-ChildItem (Join-Path $atelierMaj 'source') -Filter 'Update-Console.ps1' -Recurse -File)
    if ($atelierScripts.Count -ne 1) { throw 'Archive incomplete ou ambigue.' }
    $atelierSource = Split-Path (Split-Path $atelierScripts[0].FullName -Parent) -Parent
    Get-ChildItem (Join-Path $atelierSource 'scripts') -File | Unblock-File
    & $atelierScripts[0].FullName -SourcePath $atelierSource
    Invoke-RestMethod https://192.168.99.250/health
}
```

Attendre **status = ok, version = 0.2.0**. La mise à jour sauvegarde le code et SQLite sous `D:\AtelierPXE\backups`, conserve configuration et données puis redémarre la console. En cas d’erreur, suivre [les indications de restauration](ASSISTANT-PXE.md#1-mettre-à-jour-la-console-existante) avant de poursuivre.

## 2. Construire et importer la nouvelle image

Toujours dans PowerShell administrateur sur **DEPLOY-01** :

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $atelierStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $atelierParametres = @{
        ServerUrl = 'https://192.168.99.250'
        OutputPath = "D:\AtelierPXE\WinPE-Reprise-$atelierStamp"
        TrustedRootCertificate = 'C:\AtelierPXE\certs\AtelierPXE-lab.cer'
        WinPEKeyboardLayout = '040c:0000040c'
        WdsImageName = "Atelier PXE - INTERNE-1 - $atelierStamp"
        ImportIntoWds = $true
    }
    & 'C:\AtelierPXE\console\scripts\Build-WinPE.ps1' @atelierParametres
    wdsutil.exe /Set-Server /AnswerClients:All
    if ($LASTEXITCODE -ne 0) { throw 'Impossible d activer les reponses WDS.' }
    Start-Service WDSServer
    Get-WdsBootImage | Format-Table ImageName,Architecture,FileName
}
```

Le dossier et le nom WDS sont nouveaux à chaque exécution. Les anciennes images restent disponibles. Ce test Hyper-V utilise les pilotes inclus dans WinPE. Pour ajouter un dossier de pilotes supplémentaires déjà testé, inclure `DriversPath = 'D:\AtelierPXE\Drivers\WinPE-x64'` dans les paramètres. Pour un clavier suisse romand, remplacer la valeur par `100c:0000100c` ; pour l’anglais US, `0409:00000409`.

Attendre le succès et l’apparition de **Atelier PXE - INTERNE-1 - date** dans WDS. Ne pas poursuivre si une étape échoue. Une erreur UEFI avant le chargement de WinPE nécessite un diagnostic WDS distinct : le menu de reprise s’exécute après ce chargement.

## 3. Démarrer PC-TEST-PXE

1. Vérifier que l’ancien PXE **192.168.99.3** ne répond pas pendant cet essai. Si nécessaire, arrêter temporairement **son** service `WDSServer`, depuis une session sur **.3**, pendant la fenêtre de test. Garder le DHCP du routeur **.1** actif.
2. Conserver **PC-TEST-PXE** de génération 2, sa carte sur **vSwitch-LAN** et sa MAC enregistrée. Mettre le réseau IPv4 avant le disque et tout ISO. Garder Secure Boot avec le modèle **Microsoft Windows** et le TPM virtuel pour Windows 11.
3. Démarrer la VM, confirmer le PXE si demandé et sélectionner exactement **Atelier PXE - INTERNE-1 - date** dans WDS.
4. La barre de titre doit contenir **INTERNE-1**. Dans **Connexion**, choisir le clavier et essayer `azerty` et `123` dans le champ de test. Le collage Hyper-V standard simule une frappe et dépend aussi du clavier de l’hôte ; commencer par une saisie manuelle.

Après fermeture ou erreur, le menu propose **1** pour relancer, **2/3/4** pour choisir le clavier et relancer, **5** pour le journal/réseau, **0** pour le terminal. Au terminal, **`atelier`** rouvre l’assistant et ce menu. Une relance ne démarre aucune installation sans connexion et confirmation.

En cas d’échec, relever le message affiché et consulter le choix **5** avant de redémarrer : le journal est volatil. Ne pas joindre les identifiants ou le code PXE.

## 4. Autoriser et installer sur le VHDX de test

Dans **https://192.168.99.250**, garder la machine **PC-TEST-PXE**, MAC **00:15:5D:63:FD:02** si elle correspond toujours à sa carte. Annuler l’ancienne autorisation seulement si elle est encore en attente. Créer un déploiement interactif, profil **Windows 11 Pro FR — Test**, avec le numéro réel du **VHDX de test**. Le code PXE expire après deux heures et devient inutilisable au début de l’installation.

Dans l’assistant : code PXE, compte **DEPLOY-01\DeployRead** et son mot de passe. Choisir le profil Windows (index **6** pour le WIM multiédition d’origine), nom **PC-TEST-PXE**, région/clavier/fuseau, bundle **Poste standard** et fond **Fond-Atelier.png**. Sur la VM Microsoft, les outils HP et Lenovo sont exclus ; VLC, Chrome et Reader restent sélectionnables.

Au récapitulatif, vérifier numéro et taille du VHDX. La phrase finale affichée, par exemple **EFFACER PC-TEST-PXE DISQUE 0**, autorise la suppression de ses partitions. **0 est un exemple à contrôler.** Le simple démarrage PXE n’efface aucun disque.

Après **Image appliquée**, fermer l’assistant, choisir **0**, puis exécuter `wpeutil shutdown`. Dans Hyper-V, mettre le disque / **Windows Boot Manager** avant le réseau dans la VM arrêtée. Relancer la VM et terminer OOBE avec le premier compte administrateur. Contrôler logiciels et `C:\ProgramData\AtelierPXE\result.json` après cette connexion. Voir [les contrôles de premier démarrage](ASSISTANT-PXE.md#10-installer-réellement-sur-le-disque-de-test).

Le démarrage PXE, l’interface WinForms, DISM et les installateurs restent à valider sur votre infrastructure Windows ; ils ne sont pas exécutables dans l’environnement cloud Linux.
