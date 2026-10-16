#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation -InstallPath $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw | ConvertFrom-Json
$headers=@{}
if (-not $config.internal_mode) {
    $token=Get-Content (Join-Path $config.data_dir 'admin-token') -Raw
    $headers.Authorization='Bearer ' + $token.Trim()
}
$base=if ($config.port) { 'http://127.0.0.1:' + $config.port } else { [string]$config.base_url }
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$state=Invoke-RestMethod -Uri ($base + '/api/state') -Headers $headers
foreach ($asset in @($state.assets | Where-Object { $_.kind -eq 'windows' })) {
    $path=Join-Path (Join-Path $config.data_dir 'artifacts') $asset.filename
    $template=@($state.profiles | Where-Object { $_.asset_id -eq $asset.id } | Select-Object -First 1)
    if (-not $template.Count) { Write-Warning ('Creer d abord un profil avec la langue et les parametres corrects : ' + $asset.filename);continue }
    foreach ($summary in @(Get-WindowsImage -ImagePath $path)) {
        $image=Get-WindowsImage -ImagePath $path -Index $summary.ImageIndex
        if ($image.EditionId -notin @('Professional','Core','CoreSingleLanguage')) { continue }
        if (@($state.profiles | Where-Object { $_.asset_id -eq $asset.id -and $_.image_index -eq $image.ImageIndex }).Count) { continue }
        if ($template[0].locale -notin @($image.Languages)) { Write-Warning 'Edition ignoree : langue differente du profil modele.';continue }
        $edition=switch ($image.EditionId) { 'Professional' { 'Pro' }; 'Core' { 'Famille' }; 'CoreSingleLanguage' { 'Famille unilingue' } }
        $name=('Windows ' + $edition + ' - ' + $asset.filename)
        if ($name.Length -gt 80) { $name=$name.Substring(0,68) + '-' + $asset.id.Substring(0,8) }
        $body=@{name=$name;asset_id=$asset.id;image_index=[int]$image.ImageIndex;locale=$template[0].locale;windows_version=$template[0].windows_version;edition=$edition;settings=$template[0].settings} | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri ($base + '/api/profiles') -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        Write-Host ('Profil cree : ' + $name + ' (index ' + $image.ImageIndex + ')')
    }
}
Write-Host 'Profils vérifiés. En mode ATELIER-3, choisir Pro ou Famille directement dans WinPE.'
