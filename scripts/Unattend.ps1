# Functions only: safe to load for XML validation without executing Windows setup.
function New-AtelierUnattend {
    param([Parameter(Mandatory)][psobject]$Plan)
    $settings = $Plan.settings
    if (-not $settings) {
        $settings = [pscustomobject]@{keyboard='040c:0000040c'; timezone='Romance Standard Time'; user_locale=$Plan.locale; registered_owner=''; organization=''}
    }
    $escape = { param($value) [Security.SecurityElement]::Escape([string]$value) }
    $hostname = & $escape $Plan.hostname
    $language = & $escape $Plan.locale
    $keyboard = & $escape $settings.keyboard
    $region = & $escape $settings.user_locale
    $zone = & $escape $settings.timezone
    $owner = & $escape $settings.registered_owner
    $organization = & $escape $settings.organization
    $identity = ''
    if ($owner) { $identity += "<RegisteredOwner>$owner</RegisteredOwner>" }
    if ($organization) { $identity += "<RegisteredOrganization>$organization</RegisteredOrganization>" }
    # Run on every deployment, including interactive OOBE: disables Windows Fast Startup.
    $prepare = @'
  <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <RunSynchronous>
    <RunSynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add">
     <Order>1</Order><Path>powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\AtelierPXE\Prepare-Windows.ps1"</Path>
     <Description>Atelier PXE - configuration Windows</Description>
    </RunSynchronousCommand>
   </RunSynchronous>
  </component>
'@
    $automatic = ''
    if ($settings.unattended) {
        $automatic = @"
   <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>1</ProtectYourPC></OOBE>
   <UserAccounts><AdministratorPassword><Value></Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
   <AutoLogon><Password><Value></Value><PlainText>true</PlainText></Password><Domain>$hostname</Domain><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>Administrateur</Username></AutoLogon>
"@
    }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
 <settings pass="specialize">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <ComputerName>$hostname</ComputerName><TimeZone>$zone</TimeZone>
   $identity
  </component>
$prepare
 </settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <InputLocale>$keyboard</InputLocale><SystemLocale>$language</SystemLocale><UILanguage>$language</UILanguage><UserLocale>$region</UserLocale>
  </component>
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   $automatic
   <FirstLogonCommands>
    <SynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add">
     <Order>1</Order><Description>Atelier PXE - logiciels et personnalisation</Description>
     <CommandLine>powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\AtelierPXE\FirstLogon.ps1"</CommandLine>
    </SynchronousCommand>
   </FirstLogonCommands>
  </component>
 </settings>
</unattend>
"@
    [xml]$validated = $xml
    return $xml
}

function Test-AtelierManufacturer {
    param([string]$Target, [string]$Actual)
    switch ($Target) {
        'all' { return $true }
        'hp' { return $Actual -match '(^HP\b|Hewlett[- ]Packard)' }
        'lenovo' { return $Actual -match '^LENOVO\b' }
        default { throw 'Constructeur cible inconnu.' }
    }
}

function Assert-AtelierUnattendContent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content) -or $Content.IndexOf([char]0) -ge 0) { throw 'Fichier de reponses vide ou contenant des caracteres nuls.' }
    $options = New-Object Xml.XmlReaderSettings
    $options.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $options.XmlResolver = $null
    $text = New-Object IO.StringReader($Content.TrimStart([char]0xFEFF))
    $reader = [Xml.XmlReader]::Create($text,$options)
    try {
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        if ($document.DocumentElement.LocalName -ne 'unattend' -or $document.DocumentElement.NamespaceURI -ne 'urn:schemas-microsoft-com:unattend') { throw 'Racine XML du fichier de reponses incorrecte.' }
        $names = New-Object Xml.XmlNamespaceManager($document.NameTable)
        $names.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        foreach ($pass in @('specialize','oobeSystem')) {
            if ($document.SelectNodes("/u:unattend/u:settings[@pass='$pass']",$names).Count -ne 1) { throw "Passe $pass absente ou dupliquee dans le fichier de reponses." }
        }
    } finally { $reader.Dispose(); $text.Dispose() }
}

function Get-AtelierBytesHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Assert-AtelierUnattendFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedHash)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ((Get-AtelierBytesHash -Bytes $bytes) -ne $ExpectedHash) { throw 'Le fichier de reponses a change apres son ecriture. Premier demarrage refuse.' }
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    Assert-AtelierUnattendContent -Content ($encoding.GetString($bytes))
}

function Write-AtelierVerifiedUtf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$Unattend,
        [switch]$NoBackup
    )
    if ([string]::IsNullOrWhiteSpace($Content) -or $Content.IndexOf([char]0) -ge 0) { throw 'Contenu vide ou contenant des caracteres nuls : ecriture refusee.' }
    if ($Unattend) { Assert-AtelierUnattendContent -Content $Content }
    $target = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($target)
    $directory = New-Object IO.DirectoryInfo($parent)
    while ($directory) {
        if ($directory.Exists -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Le dossier cible est un lien : ecriture refusee.' }
        $directory = $directory.Parent
    }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    if ([IO.File]::Exists($target) -and ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Le fichier cible est un lien : ecriture refusee.' }
    $temporary = [IO.Path]::Combine($parent,('.atelier-' + [guid]::NewGuid().ToString('N') + '.tmp'))
    $backup = $null
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    $bytes = $encoding.GetBytes($Content)
    $expectedHash = Get-AtelierBytesHash -Bytes $bytes
    try {
        $stream = New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ((Get-AtelierBytesHash -Bytes ([IO.File]::ReadAllBytes($temporary))) -ne $expectedHash) { throw 'Verification des octets ecrits impossible.' }
        if ([IO.File]::Exists($target)) {
            $backup = $target + '.previous-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Replace($temporary,$target,$backup)
        } else { [IO.File]::Move($temporary,$target) }
        if ($Unattend) { Assert-AtelierUnattendFile -Path $target -ExpectedHash $expectedHash }
        elseif ((Get-AtelierBytesHash -Bytes ([IO.File]::ReadAllBytes($target))) -ne $expectedHash) { throw 'Le fichier a change apres son ecriture.' }
        if ($NoBackup -and $backup) { [IO.File]::Delete($backup); $backup=$null }
        return [pscustomobject]@{path=$target;size_bytes=$bytes.Length;sha256=$expectedHash;backup=$backup}
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Repair-AtelierOfflineUnattend {
    param(
        [Parameter(Mandatory)][string]$WindowsPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,14}$')][string]$ComputerName,
        [Parameter(Mandatory)][ValidatePattern('^[a-z]{2}-[A-Z]{2}$')][string]$Locale,
        [Parameter(Mandatory)][string]$BackupDirectory
    )
    $windows = [IO.Path]::GetFullPath($WindowsPath).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Directory]::GetParent($windows).FullName
    $payloadPath = [IO.Path]::Combine($root,'ProgramData','AtelierPXE')
    $answerPath = [IO.Path]::Combine($windows,'Panther','unattend.xml')
    foreach ($path in @($windows,([IO.Path]::Combine($windows,'Panther')),([IO.Path]::Combine($root,'ProgramData')),$payloadPath,$answerPath)) {
        if (([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) -and ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Un chemin de reparation est un lien. Reparation refusee.' }
    }
    # This repair is limited to the exact corruption found in the collected file.
    if (-not [IO.File]::Exists($answerPath)) { throw 'Le fichier de reponses a reparer est absent.' }
    $original = [IO.File]::ReadAllBytes($answerPath)
    foreach ($value in $original) { if ($value -ne 0) { throw 'Le fichier contient des donnees non nulles. Reparation automatique refusee ; collectez les journaux.' } }
    $payloadFile = [IO.Path]::Combine($payloadPath,'personalization.json')
    if (-not [IO.File]::Exists($payloadFile)) { throw 'Personnalisation du poste introuvable. Reparation interrompue.' }
    if ([IO.File]::GetAttributes($payloadFile) -band [IO.FileAttributes]::ReparsePoint) { throw 'Le fichier de personnalisation est un lien.' }
    $payload = [IO.File]::ReadAllText($payloadFile) | ConvertFrom-Json -ErrorAction Stop
    if (-not $payload.settings -or -not $payload.settings.keyboard -or -not $payload.settings.timezone -or -not $payload.settings.user_locale) { throw 'Parametres de personnalisation incomplets.' }
    foreach ($name in @('FirstLogon.ps1','Unattend.ps1')) {
        $scriptPath = [IO.Path]::Combine($payloadPath,$name)
        if (-not [IO.File]::Exists($scriptPath)) { throw "Script de premier demarrage absent : $name" }
        if ([IO.File]::GetAttributes($scriptPath) -band [IO.FileAttributes]::ReparsePoint) { throw "Script de premier demarrage lie : $name" }
        $source = [IO.File]::ReadAllText($scriptPath)
        if ([string]::IsNullOrWhiteSpace($source) -or $source.IndexOf([char]0) -ge 0) { throw "Script de premier demarrage illisible : $name" }
        $tokens=$null; $parseErrors=$null
        [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { throw "Script de premier demarrage invalide : $name" }
    }
    $plan = [pscustomobject]@{hostname=$ComputerName;locale=$Locale;settings=$payload.settings}
    $xml = New-AtelierUnattend -Plan $plan
    Assert-AtelierUnattendContent -Content $xml
    if (-not [IO.Directory]::Exists($BackupDirectory)) { throw 'Le dossier prive de sauvegarde doit exister avant la reparation.' }
    $backupPath = [IO.Path]::Combine($BackupDirectory,'unattend.original.bin')
    [IO.File]::Copy($answerPath,$backupPath,$false)
    $saved = Write-AtelierVerifiedUtf8File -Path $answerPath -Content $xml -Unattend
    $report = [ordered]@{utc=[DateTime]::UtcNow.ToString('o');hostname=$ComputerName;locale=$Locale;original_size=$original.Length;original_sha256=(Get-AtelierBytesHash -Bytes $original);size_bytes=$saved.size_bytes;sha256=$saved.sha256;backup=$backupPath;windows_setup_validation='not_performed'}
    Write-AtelierVerifiedUtf8File -Path ([IO.Path]::Combine($BackupDirectory,'repair.json')) -Content ($report | ConvertTo-Json -Depth 4) | Out-Null
    return [pscustomobject]$report
}
