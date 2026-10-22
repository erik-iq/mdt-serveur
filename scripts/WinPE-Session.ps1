
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Fonctions communes de démarrage WinPE. Ne jamais journaliser les messages d’erreur,
# les appels ou les sessions, qui peuvent contenir des codes PXE, jetons ou mots de passe SMB.
function Write-AtelierBootEvent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('Starting','ConfigurationReady','CertificateReady','KeyboardReady','KeyboardFailed','OpeningWizard','Closed','Failed')]
        [string]$Stage,
        [System.Management.Automation.ErrorRecord]$Failure
    )
    $entry = [ordered]@{utc=[DateTime]::UtcNow.ToString('o'); stage=$Stage}
    if ($Failure) {
        $entry.type = $Failure.Exception.GetType().FullName
        $entry.script = [IO.Path]::GetFileName($Failure.InvocationInfo.ScriptName)
        $entry.line = $Failure.InvocationInfo.ScriptLineNumber
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
    } catch { Write-Warning 'Impossible de créer le journal de démarrage WinPE.' }
}

function Set-AtelierOperatorKeyboard {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('100c:0000100c')]
        [string]$Layout
    )
    & wpeutil.exe SetKeyboardLayout $Layout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "WinPE ne peut pas activer le clavier $Layout (code $LASTEXITCODE)." }
    # wpeutil règle WinPE. Appliquer aussi la disposition au thread de l’interface,
    # avec le même clavier français suisse fixe que dans l’image de démarrage.
    Add-Type -AssemblyName System.Windows.Forms
    $cultureId = [Convert]::ToInt32($Layout.Substring(0,4),16)
    $language = [Windows.Forms.InputLanguage]::FromCulture([Globalization.CultureInfo]::GetCultureInfo($cultureId))
    if (-not $language -or $language.Culture.LCID -ne $cultureId) {
        throw "Le clavier français suisse $Layout est indisponible. Reconstruire WinPE et consulter le journal de démarrage."
    }
    [Windows.Forms.InputLanguage]::CurrentInputLanguage = $language
}

function ConvertTo-AtelierSerialNumber {
    param([AllowEmptyString()][string]$Value)
    $serial=($Value.Trim().ToUpperInvariant() -replace '\s+',' ')
    $compact=$serial -replace '[^A-Z0-9]',''
    $generic=@('TOBEFILLEDBYOEM','DEFAULTSTRING','SYSTEMSERIALNUMBER','SERIALNUMBER','NONE','UNKNOWN','NOTAPPLICABLE','NOTSPECIFIED','NOTAVAILABLE','NOTPRESENT','NOTSET','UNSPECIFIED','NA','INVALID','OEM')
    if ($serial.Length -lt 4 -or $serial.Length -gt 80 -or $serial -notmatch '^[A-Z0-9][A-Z0-9 ._-]*$' -or -not $compact -or $compact -match '^(0+|F+)$' -or $compact -in $generic) { return '' }
    return $serial
}
function Get-AtelierHardwareSerial {
    foreach ($source in @(@{class='Win32_BIOS';property='SerialNumber'},@{class='Win32_ComputerSystemProduct';property='IdentifyingNumber'})) {
        try {
            $hardware=Get-CimInstance -ClassName $source.class -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -First 1
            $serial=ConvertTo-AtelierSerialNumber ([string]$hardware.($source.property))
            if ($serial) { return $serial }
        } catch { }
    }
    return ''
}
function ConvertTo-AtelierMacAddress {
    param([string]$Value)
    $mac=($Value -replace '[:-]','').ToUpperInvariant()
    if ($mac -notmatch '^[0-9A-F]{12}$' -or $mac -eq '000000000000' -or ([Convert]::ToInt32($mac.Substring(0,2),16) -band 1)) { return '' }
    return ($mac -replace '(.{2})(?!$)','$1:')
}
function Get-AtelierNetworkInterfaces {
    return [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
}
function Get-AtelierWinPENetwork {
    $macs=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ips=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $interfaces=0
    try {
        foreach ($adapter in @(Get-CimInstance Win32_NetworkAdapter -OperationTimeoutSec 10 -ErrorAction Stop)) {
            $mac=ConvertTo-AtelierMacAddress ([string]$adapter.MACAddress)
            if ($mac) { [void]$macs.Add($mac);$interfaces++ }
        }
    } catch { }
    try {
        foreach ($adapter in @(Get-CimInstance Win32_NetworkAdapterConfiguration -OperationTimeoutSec 10 -ErrorAction Stop)) {
            $mac=ConvertTo-AtelierMacAddress ([string]$adapter.MACAddress)
            if ($mac) { [void]$macs.Add($mac) }
            foreach ($ip in @($adapter.IPAddress)) {
                if ([string]$ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip -notmatch '^(0\.|127\.|169\.254\.)') { [void]$ips.Add([string]$ip) }
            }
        }
    } catch { }
    try {
        foreach ($adapter in @(Get-AtelierNetworkInterfaces)) {
            if ($adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $interfaces++
            $mac=ConvertTo-AtelierMacAddress ($adapter.GetPhysicalAddress().ToString())
            if ($mac) { [void]$macs.Add($mac) }
            foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
                $ip=$address.Address.ToString()
                if ($address.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $ip -notmatch '^(0\.|127\.|169\.254\.)') { [void]$ips.Add($ip) }
            }
        }
    } catch { }
    $message=if ($ips.Count) { 'IPv4 : '+(@($ips) -join ' / ')+'. Les MAC sont informatives ; identification par numéro de série.' }
        elseif ($interfaces -eq 0 -and $macs.Count -eq 0) { 'Inventaire réseau WinPE incomplet. La connexion sera tentee avec le numéro de série, sans exiger de MAC.' }
        else { 'Aucune IPv4 utilisable dans l''inventaire. La connexion au serveur sera testée directement.' }
    return [pscustomobject]@{macs=@($macs | Select-Object -First 16);ipv4=@($ips);message=$message}
}
function Get-AtelierConnectionFailure {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$Failure,[string]$Stage,[string]$ServerUrl)
    # Décrire l’opération réellement en échec. Un inventaire WMI vide ne prouve pas
    # un pilote absent. Ne jamais journaliser les corps, en-têtes ou identifiants des requêtes.
    $exception=$Failure.Exception
    $status='';$http='';$socket=''
    for ($depth=0;$exception -and $depth -lt 10;$depth++) {
        if ($exception -is [Net.WebException]) { $status=[string]$exception.Status }
        if ($exception -is [Net.Sockets.SocketException]) { $socket=[string]$exception.SocketErrorCode }
        if ($exception.Response -and $exception.Response.StatusCode) { $http=[string][int]$exception.Response.StatusCode }
        $exception=$exception.InnerException
    }
    $cause=if ($http) { 'Le serveur a repondu HTTP '+$http+'.' }
        elseif ($status -in @('TrustFailure','SecureChannelFailure')) { 'La connexion TLS a échoué. Vérifier le certificat et la date du poste.' }
        elseif ($status -eq 'NameResolutionFailure') { 'Le nom du serveur ne peut pas être resolu.' }
        elseif ($status -eq 'Timeout') { 'Le serveur n''a pas repondu dans le délai prévu.' }
        elseif ($status -eq 'ConnectFailure') { 'La connexion au serveur n''a pas pu être établie.' }
        else { 'L''opération n''a pas abouti.' }
    $codes=@($status,$socket) | Where-Object { $_ }
    if ($codes) { $cause+=' Code : '+($codes -join ' / ')+'.' }
    $destination=try {
        $origin=New-Object UriBuilder($ServerUrl)
        $origin.UserName='';$origin.Password=''
        $origin.Uri.GetLeftPart([UriPartial]::Authority)
    } catch { 'Adresse invalide' }
    return ('Étape : '+$Stage+"`r`nServeur : "+$destination+"`r`n"+$cause)
}
function Get-AtelierPreparedWindowsConflict {
    param([System.Management.Automation.ErrorRecord]$Failure,[string]$SerialNumber)
    if (-not $SerialNumber) { return }
    # Seule une réponse structurée pour ce numéro exact autorise le choix de récupération.
    # Un simple HTTP 409 ou son texte n’autorise jamais une réinstallation.
    $exception=$Failure.Exception;$http=0
    for ($depth=0;$exception -and $depth -lt 10;$depth++) {
        if ($exception.Response -and $exception.Response.StatusCode) { $http=[int]$exception.Response.StatusCode;break }
        $exception=$exception.InnerException
    }
    if ($http -ne 409) { return }
    $json=[string]$Failure.ErrorDetails.Message
    if ($json) {
        if ($json.Length -gt 4096) { return }
        try { $null=$json | ConvertFrom-Json -ErrorAction Stop } catch { $json='' }
    }
    try { if (-not $json) {
        $exception=$Failure.Exception
        for ($depth=0;$exception -and $depth -lt 10;$depth++) {
            if ($exception.Response -is [Net.WebResponse]) {
                $stream=$exception.Response.GetResponseStream()
                if ($stream) {
                    if ($stream.CanTimeout) { $stream.ReadTimeout=2000 }
                    $reader=New-Object IO.StreamReader($stream)
                    try {
                        $buffer=New-Object char[] 4097;$length=$reader.ReadBlock($buffer,0,$buffer.Length)
                        if ($length -gt 4096) { return }
                        $json=New-Object string($buffer,0,$length)
                    } finally { $reader.Dispose() }
                }
                break
            }
            $exception=$exception.InnerException
        }
    } } catch { return }
    try {
        if (-not $json -or $json.Length -gt 4096) { return }
        $detail=($json | ConvertFrom-Json -ErrorAction Stop).detail
        $id=[guid]::Empty
        if ($detail.code -cne 'windows_prepared' -or $detail.serial_number -cne $SerialNumber -or -not [guid]::TryParse([string]$detail.deployment_id,[ref]$id) -or $id -eq [guid]::Empty) { return }
        return [pscustomobject]@{deployment_id=$id.ToString();serial_number=$SerialNumber}
    } catch { return }
}
function Assert-AtelierMachineIdentity {
    param($Plan)
    if ($Plan.serial_number) {
        $serial=Get-AtelierHardwareSerial
        if (-not $serial -or $serial -cne [string]$Plan.serial_number) { throw 'Le numéro de série BIOS ne correspond pas au poste autorisé. Aucun disque effacé.' }
    } else {
        # Conserver les anciennes autorisations explicites ; le nouveau WinPE transmet toujours le SN.
        $network=Get-AtelierWinPENetwork
        if (-not $Plan.mac -or $Plan.mac -notin $network.macs) { throw 'Ancienne autorisation MAC incompatible. Utiliser une fiche par numéro de série. Aucun disque effacé.' }
    }
}
function Restart-AtelierStagedWindows {
    param([bool]$Staged)
    if (-not $Staged) { return }
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')) { throw 'Redémarrage automatique autorise uniquement dans WinPE.' }
    Write-Information -MessageData 'ATELIER|100|Redémarrage vers Windows dans 5 secondes...' -InformationAction Continue
    Start-Sleep -Seconds 5
    & wpeutil.exe reboot
    if ($LASTEXITCODE -ne 0) { throw ('Image préparée, mais redémarrage WinPE en échec (code '+$LASTEXITCODE+'). Utiliser le menu pour redémarrer.') }
}
