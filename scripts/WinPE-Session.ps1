# Shared WinPE startup helpers. Never record error messages, invocation text or
# session objects: these can contain a boot code, agent token or SMB password.
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
    } catch { Write-Warning 'Impossible de creer le journal de demarrage WinPE.' }
}

function Set-AtelierOperatorKeyboard {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('100c:0000100c')]
        [string]$Layout
    )
    & wpeutil.exe SetKeyboardLayout $Layout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "WinPE ne peut pas activer le clavier $Layout (code $LASTEXITCODE)." }
    # wpeutil sets the WinPE default. Select the layout on this UI thread too,
    # using the same fixed French Swiss layout as the offline boot image.
    Add-Type -AssemblyName System.Windows.Forms
    $cultureId = [Convert]::ToInt32($Layout.Substring(0,4),16)
    $language = [Windows.Forms.InputLanguage]::FromCulture([Globalization.CultureInfo]::GetCultureInfo($cultureId))
    if (-not $language -or $language.Culture.LCID -ne $cultureId) {
        throw "Le clavier francais suisse $Layout est indisponible. Reconstruire WinPE et consulter le journal de demarrage."
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
    $message=if ($ips.Count) { 'IPv4 : '+(@($ips) -join ' / ')+'. Les MAC sont informatives ; identification par numero de serie.' }
        elseif ($interfaces -eq 0 -and $macs.Count -eq 0) { 'Inventaire reseau WinPE incomplet. La connexion sera tentee avec le numero de serie, sans exiger de MAC.' }
        else { 'Aucune IPv4 utilisable dans l inventaire. La connexion au serveur sera testee directement.' }
    return [pscustomobject]@{macs=@($macs | Select-Object -First 16);ipv4=@($ips);message=$message}
}
function Get-AtelierConnectionFailure {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$Failure,[string]$Stage,[string]$ServerUrl)
    # Describe the actual failed operation. Do not infer a missing driver from
    # empty WMI inventory, or record request bodies, headers or credentials.
    $exception=$Failure.Exception
    $status='';$http='';$socket=''
    for ($depth=0;$exception -and $depth -lt 10;$depth++) {
        if ($exception -is [Net.WebException]) { $status=[string]$exception.Status }
        if ($exception -is [Net.Sockets.SocketException]) { $socket=[string]$exception.SocketErrorCode }
        if ($exception.Response -and $exception.Response.StatusCode) { $http=[string][int]$exception.Response.StatusCode }
        $exception=$exception.InnerException
    }
    $cause=if ($http) { 'Le serveur a repondu HTTP '+$http+'.' }
        elseif ($status -in @('TrustFailure','SecureChannelFailure')) { 'La connexion TLS a echoue. Verifier le certificat et la date du poste.' }
        elseif ($status -eq 'NameResolutionFailure') { 'Le nom du serveur ne peut pas etre resolu.' }
        elseif ($status -eq 'Timeout') { 'Le serveur n a pas repondu dans le delai prevu.' }
        elseif ($status -eq 'ConnectFailure') { 'La connexion au serveur n a pas pu etre etablie.' }
        else { 'L operation n a pas abouti.' }
    $codes=@($status,$socket) | Where-Object { $_ }
    if ($codes) { $cause+=' Code : '+($codes -join ' / ')+'.' }
    $destination=try {
        $origin=New-Object UriBuilder($ServerUrl)
        $origin.UserName='';$origin.Password=''
        $origin.Uri.GetLeftPart([UriPartial]::Authority)
    } catch { 'Adresse invalide' }
    return ('Etape : '+$Stage+"`r`nServeur : "+$destination+"`r`n"+$cause)
}
function Assert-AtelierMachineIdentity {
    param($Plan)
    if ($Plan.serial_number) {
        $serial=Get-AtelierHardwareSerial
        if (-not $serial -or $serial -cne [string]$Plan.serial_number) { throw 'Le numero de serie BIOS ne correspond pas au poste autorise. Aucun disque efface.' }
    } else {
        # Retain explicit legacy authorizations; new WinPE discovery always sends a serial.
        $network=Get-AtelierWinPENetwork
        if (-not $Plan.mac -or $Plan.mac -notin $network.macs) { throw 'Ancienne autorisation MAC incompatible. Utiliser une fiche par numero de serie. Aucun disque efface.' }
    }
}
