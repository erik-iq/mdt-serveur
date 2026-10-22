#requires -Version 5.1
#requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$InstallPath)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$base='http://127.0.0.1:'+ $config.port
$headers=@{}
if (-not $config.internal_mode) { $headers.Authorization='Bearer '+(Get-Content (Join-Path $config.data_dir 'admin-token') -Encoding UTF8 -Raw).Trim() }
$state=Invoke-RestMethod ($base+'/api/state') -Headers $headers
$wallpapers=@($state.assets | Where-Object { $_.kind -eq 'wallpaper' -and ($_.filename -replace '[ _-]','').ToLowerInvariant() -in @('fondatelier.png','fonatelier.png') })
if (-not $wallpapers.Count) {
    $files=@(Get-ChildItem -LiteralPath (Join-Path $config.data_dir 'artifacts') -File | Where-Object { ($_.Name -replace '[ _-]','').ToLowerInvariant() -in @('fondatelier.png','fonatelier.png') } | Sort-Object Name)
    if ($files.Count) {
        $body=@{filename=$files[0].Name;kind='wallpaper'} | ConvertTo-Json
        Invoke-RestMethod ($base+'/api/assets') -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        Write-Host ('Fond d''écran enregistre : '+$files[0].Name)
    } else { Write-Warning 'Fond Atelier.png absent du dossier artifacts. Le déposer puis l''enregistrer comme fond d''écran pour activer la sélection par défaut.' }
}
Write-Host 'Assistant : quatre derniers chiffres du SN à compléter ; région fr-CH ; aucun préfixe, propriétaire ou organisation.'
