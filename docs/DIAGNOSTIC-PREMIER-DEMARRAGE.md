# Récupérer les journaux du premier démarrage depuis Hyper-V

Le message Windows « Une erreur interne s’est produite lors du chargement ou de la recherche d’un fichier de réponses sans assistance » nécessite les journaux du Windows installé. Le code `0x800705b9` est `ERROR_XML_PARSE_ERROR` : Windows a échoué à analyser le XML. Un journal indiquant qu’il trouve `C:\Windows\Panther\unattend.xml` ne prouve pas que son contenu est valide.

Un Bloc-notes blanc ne suffit pas à conclure que le fichier fait zéro octet. Par exemple, une position « Ligne 1, colonne 1352 » peut correspondre à des caractères invisibles. Il faut vérifier le fichier et ses octets. Le collecteur distingue fichier absent, taille nulle, octets nuls, erreur XML et XML syntaxiquement valide. La validation du schéma de Windows Setup reste distincte.

Cette méthode utilise le clavier habituel de **l’hôte Hyper-V 192.168.99.253**. Le collecteur vérifie que **PC-TEST-PXE est arrêtée**, monte son disque **en lecture seule**, sans lettre, copie les fichiers sur l’hôte puis démonte uniquement ce montage. Il prend le chemin du disque attaché à la VM, y compris un éventuel disque différentiel de checkpoint. Il refuse un disque déjà monté ou une VM avec plusieurs disques afin de ne pas deviner la cible. Il n’arrête pas la VM lui-même.

## 1. Arrêter seulement la VM cliente

Dans le **Gestionnaire Hyper-V**, sélectionner **PC-TEST-PXE**, dont le premier démarrage est bloqué, puis **Éteindre**. La VM doit être arrêtée avant la collecte.

## 2. Lancer la collecte sur l’hôte

Sur **192.168.99.253**, ouvrir **Windows PowerShell en administrateur**. Télécharger le script du dépôt puis le lancer :

```powershell
& {
    $ErrorActionPreference = 'Stop'
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force
    $atelierOutil = Join-Path $env:TEMP ('Diagnostic-PXE-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/erik-iq/mdt-serveur/main/scripts/Get-VMSetupDiagnostics.ps1' -OutFile $atelierOutil
    Unblock-File -LiteralPath $atelierOutil
    & $atelierOutil -VMName 'PC-TEST-PXE' -OpenFolder
}
```

Le dossier de diagnostic s’ouvre dans l’Explorateur **sur l’hôte**. Son chemin est aussi affiché dans PowerShell. Il est réservé au compte courant, aux administrateurs et à SYSTEM. Sa création ne modifie pas la console, WDS, le catalogue, les paquets ni le disque de la VM.

Il contient, lorsqu’ils existent :

- **diagnostic.json** : présence, taille, encodage reconnu, nombre d’octets nuls et contrôle XML des fichiers de réponses ; présence et taille des journaux.
- **Panther-unattend.xml** : copie exacte du fichier de réponses, même s’il est vide ou illisible.
- **Panther-setuperr.log** et **Panther-setupact.log** : journaux principaux.
- Les journaux **Panther-UnattendGC-…** et **System32-Sysprep-Panther-…** disponibles.

Pour examiner le problème, fournir **diagnostic.json**, **Panther-unattend.xml** et **Panther-setupact.log** depuis ce dossier local. Le collecteur affiche uniquement les métadonnées du fichier de réponses ; son contenu et les journaux restent dans le dossier privé. Un `xml_valid=true` signifie seulement que le document XML est bien formé, sans validation WSIM ou exécution de Windows Setup.

Après collecte, garder la VM arrêtée le temps du diagnostic. Une réparation du XML sera préparée à partir des résultats ; la collecte elle-même ne répare pas le Windows installé.

## Validation du collecteur

Le mode `-WindowsPath` permet de tester la copie depuis une arborescence Windows déjà accessible, sans Hyper-V :

```powershell
.\scripts\Get-VMSetupDiagnostics.ps1 -WindowsPath 'E:\Windows' -OutputPath 'C:\AtelierPXE\Diagnostic-Test'
```

Les tests portables utilisent seulement des fichiers synthétiques : XML UTF-8 et UTF-16, encodage incohérent, XML tronqué, fichier vide, 1351 octets nuls, fichier absent et conservation des octets sources. Ils vérifient aussi le refus d’une sortie existante, d’une sortie dans la source et de liens symboliques. Le montage Hyper-V, les permissions Windows et la copie via chemins de volume GUID nécessitent une validation sur l’hôte Windows ; ils ne sont pas exécutés dans le cloud Linux.
