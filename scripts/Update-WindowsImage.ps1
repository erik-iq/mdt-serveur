#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,
      [ValidateSet('Prepare','RegisterTest','Status','Publish')][string]$Mode='Prepare',
      [string]$AssetId,[string]$ReportPath,[string]$RunId,[string[]]$TestDeploymentId)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
. (Join-Path $PSScriptRoot 'Windows-ImageServicing.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content -LiteralPath (Join-Path $InstallPath 'data-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$runtime=Join-Path $InstallPath '.venv\Scripts\python.exe'
$profiles=Join-Path $InstallPath 'scripts\windows_image_profiles.py'
$root=Assert-AtelierServicingPath (Join-Path $config.data_dir 'windows-servicing')
New-Item -ItemType Directory -Path $root -Force | Out-Null
if ($Mode -eq 'RegisterTest') {
    if (-not $ReportPath) { throw 'Fournir -ReportPath avec le report.json de la préparation.' }
    & $runtime $profiles --data $config.data_dir register-test --report $ReportPath
    if ($LASTEXITCODE -ne 0) { throw 'Enregistrement du profil de test en échec.' };return
}
if ($Mode -eq 'Publish') {
    if (-not $RunId -or -not $TestDeploymentId.Count) { throw 'Fournir -RunId et -TestDeploymentId (un test réussi par index utilise).' }
    $arguments=@($profiles,'--data',[string]$config.data_dir,'promote','--run-id',$RunId)
    foreach ($identifier in $TestDeploymentId) { $arguments+=@('--deployment-id',$identifier) }
    & $runtime @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Publication refusée ; les profils de production restent inchanges.' };return
}
if ($Mode -eq 'Status') {
    $arguments=@($profiles,'--data',[string]$config.data_dir,'status')
    if ($RunId) { $arguments+=@('--run-id',$RunId) }
    & $runtime @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Lecture des validations en échec.' };return
}
$log=Join-Path $root ('maintenance-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.log')
Start-Transcript -LiteralPath $log | Out-Null
try {
    $arguments=@($profiles,'--data',[string]$config.data_dir,'sources')
    if ($AssetId) { $arguments+=@('--asset-id',$AssetId) }
    $result=& $runtime @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de lire les images de production. Mettre la console à jour avant la maintenance.' }
    $sources=@($result | ConvertFrom-Json)
    $failures=0
    foreach ($source in $sources) {
        try {
            Write-Host ('Préparation de '+$source.filename)
            $report=New-AtelierServicedWindowsImage -ImagePath $source.path -ExpectedHash $source.sha256 -WorkRoot $root -PythonPath $runtime -SourceAssetId $source.id
            if ($report.status -eq 'up_to_date') {
                Write-Host ('Aucune nouvelle KB : image déjà à jour. Aucun export, montage ou téléchargement MSU. Contrôle : '+$report.check_seconds+' s') -ForegroundColor Green
            } elseif ($report.reused) {
                Write-Host ('Candidate existante vérifiée et réutilisée : '+$report.report_path+'. Aucun export, montage ou téléchargement MSU. Contrôle : '+$report.check_seconds+' s') -ForegroundColor Green
            } else {
                Write-Host ('Image candidate Famille/Pro prête. Rapport : '+(Join-Path (Split-Path $report.candidate_path -Parent) 'report.json')) -ForegroundColor Green
            }
        } catch { $failures++;Write-Warning ($source.filename+' : '+$_.Exception.Message) }
    }
    if ($failures) { throw ($failures.ToString()+' image(s) non préparée(s). Consulter '+$log) }
    Write-Host 'Aucun profil de production modifie. Enregistrer une image candidate pour un déploiement de test avant publication.'
} finally { Stop-Transcript | Out-Null }
