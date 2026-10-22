# Réparer le fichier de réponses contenant uniquement des octets nuls

Les fichiers collectés sur **PC-TEST-PXE** confirment un `Windows\Panther\unattend.xml` de **1351 octets, tous égaux à zéro**. Ce n’est pas un document XML. Le journal Windows le trouve puis échoue à le désérialiser avec `0x800705b9`. La cause immédiate est confirmée ; ces fichiers ne permettent pas de déterminer à quel moment le contenu a été effacé.

La réparation ci-dessous remplace seulement ce fichier dans le Windows déjà appliqué, en sauvegardant l’original. Elle conserve les logiciels et le fond d’écran préparés dans `ProgramData\AtelierPXE`, et reprend clavier, fuseau, région, propriétaire et organisation depuis `personalization.json`. Le nom du PC et la langue de l’image sont fournis explicitement. Elle ne modifie pas les indicateurs d’état de Windows Setup dans le registre et ne saute aucune étape OOBE.

## 1. Garder la VM arrêtée

Dans Hyper-V, **PC-TEST-PXE doit être arrêtée**. Les commandes suivantes se lancent sur **l’hôte Hyper-V 192.168.99.253**, en Windows PowerShell administrateur. La console DEPLOY-01 reste disponible.

## 2. Télécharger et exécuter la réparation

```powershell
& {
    $ErrorActionPreference = 'Stop'
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force
    $atelierPatch = Join-Path $env:TEMP ('Reparation-PXE-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $atelierPatch | Out-Null
    foreach ($atelierNom in @('Repair-VMUnattend.ps1','Unattend.ps1')) {
        $atelierFichier = Join-Path $atelierPatch $atelierNom
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/erik-iq/mdt-serveur/main/scripts/$atelierNom" -OutFile $atelierFichier
        Unblock-File -LiteralPath $atelierFichier
    }
    & (Join-Path $atelierPatch 'Repair-VMUnattend.ps1') -VMName 'PC-TEST-PXE' -ComputerName 'PC-TEST-PXE' -Locale 'fr-FR'
}
```

Le script refuse une VM active, un disque déjà monté, plusieurs disques ou une installation Windows ambiguë. Il vérifie que le fichier à réparer est vide ou intégralement nul et que le JSON de personnalisation ainsi que les scripts de premier démarrage sont lisibles. Un fichier contenant des données non nulles bloque cette réparation ciblée.

Le disque de la VM est monté **en écriture** pendant la réparation, sans lettre. Un dossier privé sur l’hôte reçoit `unattend.original.bin` et `repair.json`. Le fichier original est aussi conservé à côté de la cible avec un suffixe `.previous-…`. Le XML régénéré est écrit en UTF-8 explicite, avec vidage des tampons, puis relu et vérifié par SHA-256 et analyse XML. Le montage est retiré à la fin, y compris en cas d’erreur ; la VM reste arrêtée.

Attendu : **Fichier de réponses remplace et vérifie**, avec taille, SHA-256 et chemin de sauvegarde. En cas d’erreur, conserver le message ; ne pas démarrer la VM avant diagnostic. L’analyse XML ne remplace pas une validation WSIM avec le catalogue exact de l’image Windows.

## 3. Vérifier la reprise du premier démarrage

Dans les paramètres Hyper-V de **PC-TEST-PXE**, placer le disque / **Windows Boot Manager** avant le réseau. Démarrer la VM sur ce disque. La reprise de Windows Setup doit être vérifiée sur la VM : elle n’a pas été exécutée dans le cloud Linux.

Si OOBE apparaît, terminer Windows avec un premier compte administrateur pour lancer les logiciels et le bureau. Contrôler `C:\ProgramData\AtelierPXE\result.json` après la première connexion. Si une nouvelle erreur apparaît, garder la VM dans cet état puis collecter à nouveau les journaux avec [le collecteur](DIAGNOSTIC-PREMIER-DEMARRAGE.md) après l’avoir arrêtée.

## Protection des prochains déploiements

L’image **FR-REPRISE-3** valide le XML avant l’effacement, écrit le JSON de personnalisation et les fichiers XML par un fichier temporaire avec vidage explicite des tampons et remplacement atomique. Elle relit les octets et conserve une copie privée **Unattend.generated.xml** et son manifeste SHA-256 dans `ProgramData\AtelierPXE`. Après BCDBoot/WinRE, les deux XML sont contrôlés à nouveau avant l’état « image appliquée ».

Cette trace permettra de distinguer une erreur d’écriture ou une modification avant la fin de WinPE d’une altération ultérieure au premier démarrage. Elle ne démontre pas à elle seule l’origine des octets nuls de l’essai précédent. Pour les futurs essais PXE, mettre à jour les scripts puis reconstruire une nouvelle image WDS selon [la procédure de reprise](REPRISE-PXE.md).
