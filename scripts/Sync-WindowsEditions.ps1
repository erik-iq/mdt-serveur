#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation -InstallPath $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$headers=@{}
if (-not $config.internal_mode) {
    $token=Get-Content (Join-Path $config.data_dir 'admin-token') -Encoding UTF8 -Raw
    $headers.Authorization='Bearer ' + $token.Trim()
}
$base=if ($config.port) { 'http://127.0.0.1:' + $config.port } else { [string]$config.base_url }
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$state=Invoke-RestMethod -Uri ($base + '/api/state') -Headers $headers
foreach ($asset in @($state.assets | Where-Object { $_.kind -eq 'windows' })) {
    if ($asset.image_validation -eq 'testing') { continue }
    $path=Join-Path (Join-Path $config.data_dir 'artifacts') $asset.filename
    $template=@($state.profiles | Where-Object { $_.asset_id -eq $asset.id -and -not $_.image_test } | Select-Object -First 1)
    if ($asset.image_validation -and -not $template.Count) { continue }
    if (-not $template.Count) { Write-Warning ('Créer d''abord un profil avec la langue et les paramètres corrects : ' + $asset.filename);continue }
    foreach ($summary in @(Get-WindowsImage -ImagePath $path)) {
        $image=Get-WindowsImage -ImagePath $path -Index $summary.ImageIndex
        if ($image.EditionId -notin @('Professional','Core')) { continue }
        if (@($state.profiles | Where-Object { $_.asset_id -eq $asset.id -and $_.image_index -eq $image.ImageIndex }).Count) { continue }
        if ($template[0].locale -notin @($image.Languages)) { Write-Warning 'Édition ignorée : langue différente du profil modèle.';continue }
        $edition=switch ($image.EditionId) { 'Professional' { 'Pro' }; 'Core' { 'Famille' } }
        $name=('Windows ' + $edition + ' - ' + $asset.filename)
        if ($name.Length -gt 80) { $name=$name.Substring(0,68) + '-' + $asset.id.Substring(0,8) }
        $body=@{name=$name;asset_id=$asset.id;image_index=[int]$image.ImageIndex;locale=$template[0].locale;windows_version=$template[0].windows_version;edition=$edition;settings=$template[0].settings} | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri ($base + '/api/profiles') -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        Write-Host ('Profil crée : ' + $name + ' (index ' + $image.ImageIndex + ')')
    }
}
Write-Host 'Profils vérifiés. En mode ATELIER-4, choisir Pro ou Famille directement dans WinPE.'
