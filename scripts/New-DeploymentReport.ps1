#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$DataPath='C:\ProgramData\AtelierPXE',[string]$OutputDirectory='C:\IQ_')
$ErrorActionPreference='Stop'
. (Join-Path $DataPath 'Reporting.ps1')
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$inventory=[ordered]@{}; $warnings=New-Object 'Collections.Generic.List[string]'
function Read-ReportJson([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
        catch { $warnings.Add('Fichier de diagnostic illisible : ' + [IO.Path]::GetFileName($Path)) }
    }
    return $null
}
foreach ($class in @('Win32_ComputerSystem','Win32_BIOS','Win32_OperatingSystem','Win32_Processor','Win32_DiskDrive','Win32_VideoController','Win32_NetworkAdapterConfiguration')) {
    try {
        $items=@(Get-CimInstance -ClassName $class -OperationTimeoutSec 15)
        switch ($class) {
            'Win32_ComputerSystem' { $inventory['Constructeur']=[string]$items[0].Manufacturer; $inventory['Modele']=[string]$items[0].Model; $inventory['RAM (Go)']=[string][math]::Round($items[0].TotalPhysicalMemory/1GB,2) }
            'Win32_BIOS' { $inventory['Numero de serie']=[string]$items[0].SerialNumber; $inventory['BIOS']=[string]$items[0].SMBIOSBIOSVersion }
            'Win32_OperatingSystem' { $inventory['Windows']=[string]$items[0].Caption; $inventory['Version / build']=([string]$items[0].Version + ' / ' + $items[0].BuildNumber); $inventory['Architecture']=[string]$items[0].OSArchitecture }
            'Win32_Processor' { $inventory['Processeur']=(@($items | ForEach-Object { $_.Name + ' (' + $_.NumberOfCores + ' coeurs / ' + $_.NumberOfLogicalProcessors + ' threads)' }) -join '; ') }
            'Win32_DiskDrive' { $inventory['Disques']=(@($items | ForEach-Object { $_.Model + ' / SN ' + $_.SerialNumber + ' / ' + [math]::Round($_.Size/1GB,1) + ' Go' }) -join '; ') }
            'Win32_VideoController' { $inventory['Graphique']=(@($items | ForEach-Object { $_.Name }) -join '; ') }
            'Win32_NetworkAdapterConfiguration' { $inventory['Reseau']=(@($items | Where-Object { $_.IPEnabled } | ForEach-Object { $_.Description + ' / MAC ' + $_.MACAddress + ' / ' + ($_.IPAddress -join ', ') }) -join '; ') }
        }
    } catch { $warnings.Add('Inventaire indisponible : ' + $class) }
}
$inventory['Nom du PC']=$env:COMPUTERNAME
try { $inventory['Edition Windows']=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID } catch { $warnings.Add('Edition Windows indisponible.') }
try {
    $fast=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled).HiberbootEnabled
    $inventory['Demarrage rapide Windows']=if ($fast -eq 0) { 'Desactive (verifie)' } else { 'Actif' }
    if ($fast -ne 0) { $warnings.Add('Le demarrage rapide Windows est encore actif.') }
} catch { $inventory['Demarrage rapide Windows']='Non verifie'; $warnings.Add('Reglage du demarrage rapide non verifie.') }
$license=Read-ReportJson (Join-Path $OutputDirectory 'Licence-Windows.json')
$inventory['Activation Windows']=if ($license) { [string]$license.etat } else { 'INDETERMINE' }
if (-not $license -or $license.etat -ne 'ACTIVE') { $warnings.Add('Activation Windows a verifier ; aucune cle produit n est collecte ici.') }
$payload=Read-ReportJson (Join-Path $DataPath 'personalization.json')
if ($payload.deployment) { $inventory['Profil deploye']=[string]$payload.deployment.profile_name; $inventory['Image / index']=([string]$payload.deployment.image_filename + ' / ' + $payload.deployment.image_index) }
$steps=New-Object 'Collections.Generic.List[object]'
$apps=Read-ReportJson (Join-Path $DataPath 'result.json')
$maintenance=Read-ReportJson (Join-Path $DataPath 'maintenance.json')
$steps.Add(@{name='Personnalisation';status=$(if($apps){$apps.status}else{'unknown'});message=[string]$apps.message;timestamp=[string]$apps.timestamp})
foreach ($app in @($apps.applications)) {
    if (-not $app) { continue }
    $steps.Add(@{name=[string]$app.name;status=[string]$app.status;message=('Version ' + $app.version + ' / code ' + $app.exit_code + ' ' + $app.reason);timestamp=''})
}
if (Test-Path (Join-Path $DataPath 'maintenance.log')) {
    foreach ($line in @(Get-Content (Join-Path $DataPath 'maintenance.log') -Tail 100)) {
        $steps.Add(@{name='Maintenance Windows';status='info';message=([string]$line).Substring(0,[math]::Min(1500,$line.Length));timestamp=''})
    }
}
foreach ($pass in @($maintenance.windows_history)) {
    foreach ($title in @($pass.result.titles | Select-Object -First 50)) {
        if ($title) { $steps.Add(@{name='Mise a jour Windows';status=[string]$pass.result.status;message=[string]$title;timestamp=[string]$pass.timestamp}) }
    }
}
if ($maintenance.store.status -eq 'requested') { $warnings.Add('Microsoft Store : actualisation demandee, achevement non verifie.') }
if (-not $maintenance -or $maintenance.status -ne 'completed') { $warnings.Add('Maintenance Windows incomplete ou en attente. Ce rapport peut etre regenere apres la fin.') }
$hardware=Read-ReportJson (Join-Path $OutputDirectory 'Tests-Materiel.json')
foreach ($test in @($hardware.tests)) {
    if ($test) {
        $steps.Add(@{name=('Test ' + $test.name);status=[string]$test.status;message=[string]$test.comment;timestamp=[string]$hardware.date})
        if ($test.status -eq 'failed') { $warnings.Add('Defaut constate par l operateur : ' + $test.name) }
        elseif ($test.status -eq 'not_tested') { $warnings.Add('Test materiel non effectue : ' + $test.name) }
    }
}
if (-not $hardware) { $warnings.Add('Tests son, webcam et clavier non effectues ou non enregistres.') }
$warranty=Read-ReportJson (Join-Path $OutputDirectory 'Garantie.json')
if ($warranty) {
    $inventory['Garantie constructeur']=[string]$warranty.statut
    if ($warranty.statut -in @('active_confirmee_operateur','expiree_confirmee_operateur')) {
        $inventory['Garantie debut / fin']=([string]$warranty.debut + ' / ' + $warranty.fin)
        $inventory['Garantie mois restants']=[string]$warranty.mois_restants
        $steps.Add(@{name='Garantie constructeur';status=[string]$warranty.statut;message=('Verification operateur sur ' + $warranty.source_url);timestamp=[string]$warranty.verifie_le})
    } else { $warnings.Add('Garantie constructeur non verifiee.') }
}
$status=if ($apps.status -eq 'failed') { 'failed' } elseif ($maintenance.status -eq 'completed' -and $apps.status -eq 'completed') { 'completed' } else { 'needs_attention' }
foreach ($key in @($inventory.Keys)) { if ($inventory[$key].Length -gt 2000) { $inventory[$key]=$inventory[$key].Substring(0,2000) } }
if ($steps.Count -gt 230) { $warnings.Add('Historique PDF limite aux 230 dernieres entrees. Les journaux complets restent dans ProgramData.') }
$report=[ordered]@{hostname=$env:COMPUTERNAME;status=$status;generated_at=[DateTime]::UtcNow.ToString('o');inventory=$inventory;steps=@($steps.ToArray() | Select-Object -Last 230);warnings=@($warnings.ToArray())}
$json=$report | ConvertTo-Json -Depth 12
$json | Set-Content (Join-Path $OutputDirectory 'Rapport-Deploiement.json') -Encoding UTF8
$lines=@('ATELIER PXE - Rapport de deploiement',('Poste : ' + $env:COMPUTERNAME + ' | Etat : ' + $status),('Genere : ' + $report.generated_at),'','INVENTAIRE')
foreach ($entry in $inventory.GetEnumerator()) { $lines += ($entry.Key + ' : ' + $entry.Value) }
$lines += @('','DEROULEMENT')
foreach ($step in $steps) { $lines += ('[' + $step.status + '] ' + $step.name + ' : ' + $step.message) }
$lines += @('','AVERTISSEMENTS ET LIMITES') + @($warnings.ToArray()) + @('Son, webcam et clavier : verification humaine requise. Le BIOS Fast Boot n est pas modifie.')
Write-AtelierPdf -Path (Join-Path $OutputDirectory 'Rapport-Deploiement.pdf') -Lines $lines
$configuration=Join-Path $DataPath 'reporting.json'
if ((Test-Path $configuration) -and ($maintenance.status -in @('completed','needs_attention') -or $apps.status -eq 'failed')) {
    try {
        $config=Get-Content $configuration -Raw | ConvertFrom-Json
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri ($config.server_url + '/api/windows/' + $config.id + '/report') -Method Post -Headers @{Authorization=('Bearer ' + $config.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 15 | Out-Null
        @{status='sent';date=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'Transmission-Rapport.json') -Encoding UTF8
    } catch {
        @{status='pending';message='Rapport local conserve. Relancer Generer-Rapport.cmd lorsque la console est joignable.'} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'Transmission-Rapport.json') -Encoding UTF8
    }
}
