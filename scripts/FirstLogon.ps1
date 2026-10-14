#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE')
$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $DataPath 'result.json'
$logPath = Join-Path $DataPath 'first-logon.log'
if (Test-Path $resultPath) {
    $previous = Get-Content $resultPath -Raw | ConvertFrom-Json
    if ($previous.status -eq 'completed') { Write-Host 'Personnalisation Atelier PXE deja terminee.'; exit 0 }
}
$payload = Get-Content (Join-Path $DataPath 'personalization.json') -Raw | ConvertFrom-Json
. (Join-Path $DataPath 'Unattend.ps1')
$manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
$results = New-Object 'System.Collections.Generic.List[object]'
$restartNeeded = $false

function Write-Trace([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $Message
}
function Assert-FileHash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Integrite du fichier refusee : $Path"
    }
}
function Expand-SafeZip([string]$Path, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $size = 0L
        foreach ($entry in $zip.Entries) {
            $size += $entry.Length
            if ($size -gt 25GB) { throw 'Archive trop volumineuse apres extraction.' }
            $target = [IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName -match '[:\x00]') {
                throw 'Chemin dangereux dans le ZIP.'
            }
            if (-not $entry.Name) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
}
function Invoke-Installer([string]$Executable, [string]$Arguments, [string]$WorkingDirectory) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { Split-Path $Executable -Parent }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(2700000)) { throw 'Installateur encore actif apres 45 minutes : consultez le processus avant toute reprise.' }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

try {
    Write-Trace 'Debut de la personnalisation du premier compte administrateur.'
    $theme = $payload.settings.theme
    if ($theme -in @('light','dark')) {
        $registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        New-Item -Path $registry -Force | Out-Null
        $value = if ($theme -eq 'light') { 1 } else { 0 }
        New-ItemProperty -Path $registry -Name AppsUseLightTheme -Value $value -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $registry -Name SystemUsesLightTheme -Value $value -PropertyType DWord -Force | Out-Null
    }
    if ($payload.wallpaper) {
        $wallpaper = Join-Path $DataPath ('Resources\' + $payload.wallpaper.filename)
        Assert-FileHash $wallpaper $payload.wallpaper.sha256
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaper
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class AtelierWallpaper { [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SystemParametersInfo(int action,int parameter,string value,int flags); }'
        if (-not [AtelierWallpaper]::SystemParametersInfo(20,0,$wallpaper,3)) { throw 'Impossible de rafraichir le fond d ecran.' }
        Write-Trace 'Fond d ecran applique.'
    }
    foreach ($application in @($payload.applications)) {
        if (-not (Test-AtelierManufacturer $application.manufacturer $manufacturer)) {
            $results.Add(@{name=$application.name; status='skipped'; reason='Autre constructeur'})
            Write-Trace ("Outil ignore pour ce constructeur : " + $application.name)
            continue
        }
        $asset = $application.asset
        $source = Join-Path $DataPath ('Packages\' + $asset.filename)
        Assert-FileHash $source $asset.sha256
        $executable = $source
        if ([IO.Path]::GetExtension($source) -eq '.zip') {
            $folder = if ($application.install_mode -eq 'portable') {
                Join-Path $env:ProgramFiles ('AtelierPXE\Tools\' + $application.id)
            } else { Join-Path $DataPath ('Expanded\' + $application.id) }
            Expand-SafeZip $source $folder
            $executable = [IO.Path]::GetFullPath((Join-Path $folder $application.entry_point))
            if (-not $executable.StartsWith(([IO.Path]::GetFullPath($folder).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Point d entree hors du bundle.' }
        }
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw ("Installateur absent : " + $application.name) }
        $signature = Get-AuthenticodeSignature -LiteralPath $executable
        if ($signature.Status -ne 'Valid') { throw ("Signature editeur invalide : " + $application.name) }
        if ($application.install_mode -eq 'portable') {
            $shell = New-Object -ComObject WScript.Shell
            try {
                $safeName = $application.name -replace '[^\p{L}\p{N} _-]', '_'
                $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) ($safeName + '.lnk')))
                $shortcut.TargetPath = $executable
                $shortcut.WorkingDirectory = Split-Path $executable -Parent
                $shortcut.Save()
            } finally { if ($shell) { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } }
            $exitCode = 0
        } elseif ([IO.Path]::GetExtension($executable) -eq '.msi') {
            $installerLog = Join-Path $DataPath ('msi-' + $application.id + '.log')
            $arguments = '/i "{0}" /qn /norestart /L*v "{1}" {2}' -f $executable, $installerLog, $application.arguments
            $exitCode = Invoke-Installer (Join-Path $env:SystemRoot 'System32\msiexec.exe') $arguments (Split-Path $executable -Parent)
        } else { $exitCode = Invoke-Installer $executable $application.arguments }
        if ($exitCode -notin @(0,3010)) { throw ("Echec de " + $application.name + " (code $exitCode)") }
        if ($exitCode -eq 3010) { $restartNeeded = $true }
        $results.Add(@{name=$application.name; version=$application.version; status='completed'; exit_code=$exitCode})
        Write-Trace ("Logiciel prepare : " + $application.name)
    }
    @{status='completed'; timestamp=(Get-Date).ToString('o'); restart_needed=$restartNeeded; applications=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content $resultPath -Encoding UTF8
    Write-Trace 'Personnalisation terminee. Consultez result.json pour les logiciels et le redemarrage eventuel.'
} catch {
    @{status='failed'; timestamp=(Get-Date).ToString('o'); message=$_.Exception.Message; applications=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content $resultPath -Encoding UTF8
    Write-Trace ('Echec : ' + $_.Exception.Message)
    throw
}
