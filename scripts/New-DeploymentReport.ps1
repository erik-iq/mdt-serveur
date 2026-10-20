#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$DataPath='C:\ProgramData\AtelierPXE',[string]$OutputDirectory='C:\IQ_',[switch]$RefreshInventory)
$ErrorActionPreference='Stop'
. (Join-Path $DataPath 'Reporting.ps1')
. (Join-Path $PSScriptRoot 'IQ-Paths.ps1')
$toolsRoot=$OutputDirectory
$OutputDirectory=Get-AtelierIQDirectory $toolsRoot 'Rapports'
$inventory=[ordered]@{}; $warnings=New-Object 'Collections.Generic.List[string]'
$payloadPath=Join-Path $DataPath 'personalization.json'
$payload=if (Test-Path $payloadPath) { Get-Content $payloadPath -Encoding UTF8 -Raw | ConvertFrom-Json } else { $null }
$centralInventory=$payload.settings.central_inventory -or $payload.deployment.cleanup_after_reporting
$inventoryDirectory=if ($centralInventory) { Join-Path $DataPath 'Inventory' } else { Get-AtelierIQDirectory $toolsRoot 'Inventaire' }
$xmlInventory=Join-Path $inventoryDirectory 'Inventaire-Technique.xml'
$csvInventory=Join-Path $inventoryDirectory 'Inventaire-Technique.csv'
$finalMarker=Join-Path $DataPath 'inventory-finalized.json'
$maintenancePath=Join-Path $DataPath 'maintenance.json'
$finalInventory=$false
if ($centralInventory -and (Test-Path $maintenancePath)) {
    try { $finalInventory=(Get-Content $maintenancePath -Encoding UTF8 -Raw | ConvertFrom-Json).status -in @('completed','needs_attention') } catch { }
}
$inventoryPending=$false
$refreshFinal=$finalInventory -and -not (Test-Path $finalMarker)
if ($RefreshInventory -or $refreshFinal -or -not (Test-Path $xmlInventory) -or -not (Test-Path $csvInventory)) {
    try {
        $inventoryTiming=if (Get-Command Start-AtelierTiming -ErrorAction SilentlyContinue) { Start-AtelierTiming $DataPath 'inventory' } else { '' }
        $export= & (Join-Path $DataPath 'Export-Inventaire.ps1') -OutputDirectory $inventoryDirectory
        if ($inventoryTiming) { Stop-AtelierTiming $DataPath $inventoryTiming }
        if ($finalInventory) { @{date=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $finalMarker -Encoding UTF8 }
        if ($export.SectionsIndisponibles) { $warnings.Add('Certaines categories de l inventaire technique sont indisponibles ; consulter les etats dans XML/CSV.') }
    } catch {
        if ($inventoryTiming) { Stop-AtelierTiming $DataPath $inventoryTiming 'failed' }
        $warnings.Add('Inventaire XML/CSV a regenerer avec Export-Inventaire.cmd.')
        if ($centralInventory) {
            $inventoryPending=$true
            if (Test-Path $finalMarker) { Remove-Item -LiteralPath $finalMarker -Force }
        }
    }
}
function Read-ReportJson([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json }
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
$license=Read-ReportJson (Get-AtelierIQFile $toolsRoot 'Licence' 'Licence-Windows.json')
$inventory['Activation Windows']=if ($license) { [string]$license.etat } else { 'INDETERMINE' }
if (-not $license -or $license.etat -ne 'ACTIVE') { $warnings.Add('Activation Windows a verifier ; aucune cle produit n est collecte ici.') }
if ($payload.deployment) { $inventory['Profil deploye']=[string]$payload.deployment.profile_name; $inventory['Image / index']=([string]$payload.deployment.image_filename + ' / ' + $payload.deployment.image_index) }
$steps=New-Object 'Collections.Generic.List[object]'
$apps=Read-ReportJson (Join-Path $DataPath 'result.json')
$maintenance=Read-ReportJson (Join-Path $DataPath 'maintenance.json')
$software=$null
if ($payload.settings.software_mode -eq 'winget') {
    . (Join-Path $DataPath 'Client-Software.ps1')
    $software=Get-AtelierSoftwareSummary -Packages @($payload.settings.winget_packages) -Results @($apps.applications)
    if ($software.status -ne 'completed') { $warnings.Add(('Logiciels non installes ou non verifies : '+($software.missing -join ', '))) }
}
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
foreach ($manualUpdate in @(@{name='Windows Update';value=$maintenance.windows},@{name='Microsoft Store';value=$maintenance.store})) {
    if ($manualUpdate.value.status -eq 'manual') { $steps.Add(@{name=$manualUpdate.name;status='manual';message=[string]$manualUpdate.value.message;timestamp=[string]$maintenance.timestamp}) }
}
$hp=if ($maintenance.hpia) { $maintenance.hpia } else { Read-ReportJson (Join-Path $DataPath 'hpia-result.json') }
if ($hp) {
    $steps.Add(@{name='HP Image Assistant / SoftPaq';status=[string]$hp.status;message=([string]$hp.message+' / Code '+[string]$hp.exit_code);timestamp=[string]$hp.timestamp})
    foreach ($package in @($hp.packages)) {
        if (-not $package) { continue }
        $packageStatus=if ($package.code -in @(0,3010)) { 'completed' } else { 'needs_attention' }
        $steps.Add(@{name='SoftPaq HP';status=$packageStatus;message=([string]$package.softpaq_id+' '+[string]$package.name+' / Code '+[string]$package.code+' / '+[string]$package.description);timestamp=[string]$hp.timestamp})
    }
    if ($hp.status -notin @('completed','skipped')) { $warnings.Add(('Mises a jour HP a verifier : '+[string]$hp.message)) }
    if ($hp.reboot_required) { $warnings.Add('HP Image Assistant demande un redemarrage manuel.') }
}
if (-not $maintenance -or $maintenance.status -notin @('completed','needs_attention')) { $warnings.Add('Maintenance Windows incomplete ou en attente. Ce rapport peut etre regenere apres la fin.') }
if ($maintenance.windows.status -eq 'deferred') { $warnings.Add(('Windows Update non verifie : ' + $maintenance.windows.message)) }
if ($maintenance.reboot_required) { $warnings.Add('Redemarrage Windows necessaire ; aucune interruption automatique de votre session.') }
$hardware=Read-ReportJson (Get-AtelierIQFile $toolsRoot 'Diagnostics' 'Tests-Materiel.json')
foreach ($test in @($hardware.tests)) {
    if ($test) {
        $steps.Add(@{name=('Test ' + $test.name);status=[string]$test.status;message=[string]$test.comment;timestamp=[string]$hardware.date})
        if ($test.status -eq 'failed') { $warnings.Add('Defaut constate par l operateur : ' + $test.name) }
        elseif ($test.status -eq 'not_tested') { $warnings.Add('Test materiel non effectue : ' + $test.name) }
    }
}
if (-not $hardware) { $warnings.Add('Tests son, webcam et clavier non effectues ou non enregistres.') }
$warranty=Read-ReportJson (Get-AtelierIQFile $toolsRoot 'Garantie' 'Garantie.json')
if ($warranty) {
    $inventory['Garantie constructeur']=[string]$warranty.statut
    if ($warranty.statut -in @('active_confirmee_operateur','expiree_confirmee_operateur')) {
        $inventory['Garantie debut / fin']=([string]$warranty.debut + ' / ' + $warranty.fin)
        $inventory['Garantie mois restants']=[string]$warranty.mois_restants
        $steps.Add(@{name='Garantie constructeur';status=[string]$warranty.statut;message=('Verification operateur sur ' + $warranty.source_url);timestamp=[string]$warranty.verifie_le})
    } else { $warnings.Add('Garantie constructeur non verifiee.') }
}
if ($apps.software_status -eq 'needs_attention') { $warnings.Add('Certains logiciels WinGet sont en echec ; consulter software-logs et les etapes du rapport.') }
$status=if ($apps.status -eq 'failed') { 'failed' } elseif ($software -and $software.status -ne 'completed') { 'needs_attention' } elseif ($hp -and $hp.status -notin @('completed','skipped')) { 'needs_attention' } elseif ($maintenance.status -eq 'completed' -and $apps.status -eq 'completed' -and $apps.software_status -ne 'needs_attention') { 'completed' } else { 'needs_attention' }
foreach ($key in @($inventory.Keys)) { if ($inventory[$key].Length -gt 2000) { $inventory[$key]=$inventory[$key].Substring(0,2000) } }
$timingDirectory=Join-Path $DataPath 'timings'
if (Test-Path $timingDirectory) {
    $stageNames=@{image='Application de Windows';software='Logiciels';manufacturer_tools='Preparation des outils constructeur';hp_updates='Mises a jour HP';windows_update='Windows Update';inventory='Inventaire';personalization='Personnalisation'}
    foreach ($timingFile in @(Get-ChildItem -LiteralPath $timingDirectory -Filter '*.json' -File | Select-Object -First 200)) {
        $timing=Read-ReportJson $timingFile.FullName
        if ($timing -and $timing.status -ne 'running' -and $stageNames.ContainsKey([string]$timing.stage)) {
            $steps.Add(@{name=('Duree - '+$stageNames[[string]$timing.stage]);status=[string]$timing.status;message=([string]$timing.duration_seconds+' secondes mesurees');timestamp=[string]$timing.started_at})
        }
    }
}
if ($steps.Count -gt 230) { $warnings.Add('Historique PDF limite aux 230 dernieres entrees. Consulter aussi les journaux de preparation archives sur le serveur.') }
$report=[ordered]@{hostname=$env:COMPUTERNAME;status=$status;generated_at=[DateTime]::UtcNow.ToString('o');inventory=$inventory;steps=@($steps.ToArray() | Select-Object -Last 230);warnings=@($warnings.ToArray())}
$json=$report | ConvertTo-Json -Depth 12
$json | Set-Content (Join-Path $OutputDirectory 'Rapport-Deploiement.json') -Encoding UTF8
$lines=@('ATELIER PXE - Rapport de deploiement',('Poste : ' + $env:COMPUTERNAME + ' | Etat : ' + $status),('Genere : ' + $report.generated_at),'','INVENTAIRE')
foreach ($entry in $inventory.GetEnumerator()) { $lines += ($entry.Key + ' : ' + $entry.Value) }
$lines += @('','DEROULEMENT')
foreach ($step in $steps) { $lines += ('[' + $step.status + '] ' + $step.name + ' : ' + $step.message) }
$lines += @('','AVERTISSEMENTS ET LIMITES') + @($warnings.ToArray()) + @('Son, webcam et clavier : verification humaine requise. Le BIOS Fast Boot n est pas modifie. Windows Update et Microsoft Store sont manuels dans IQ-4.8.')
Write-AtelierPdf -Path (Join-Path $OutputDirectory 'Rapport-Deploiement.pdf') -Lines $lines
if (Get-Command Sync-AtelierTimings -ErrorAction SilentlyContinue) { Sync-AtelierTimings $DataPath }
$configuration=Join-Path $DataPath 'reporting.json'
if ((Test-Path $configuration) -and ($maintenance.status -in @('completed','needs_attention') -or $apps.status -eq 'failed')) {
    try {
        $config=Get-Content $configuration -Encoding UTF8 -Raw | ConvertFrom-Json
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $reportBytes=[Text.Encoding]::UTF8.GetBytes($json)
        $reply=Invoke-RestMethod -Uri ($config.server_url + '/api/windows/' + $config.id + '/report') -Method Post -Headers @{Authorization=('Bearer ' + $config.token)} -ContentType 'application/json; charset=utf-8' -Body $reportBytes -TimeoutSec 15
        $algorithm=[Security.Cryptography.SHA256]::Create()
        try { $reportHash=([BitConverter]::ToString($algorithm.ComputeHash($reportBytes))).Replace('-','').ToLowerInvariant() } finally { $algorithm.Dispose() }
        if ($payload.deployment.cleanup_after_reporting -and (-not $reply.accepted -or $reply.deployment_id -ne $config.id -or $reply.sha256 -ne $reportHash)) { throw 'Rapport serveur non confirme.' }
        if ($centralInventory) {
            . (Join-Path $DataPath 'Inventory-Transfer.ps1')
            if ($inventoryPending -or -not (Send-AtelierInventory -DataPath $DataPath -InventoryDirectory $inventoryDirectory)) { throw 'Transmission inventaire en attente.' }
        }
        $receipt=@{status='sent';date=[DateTime]::UtcNow.ToString('o');deployment_id=$config.id;report_sha256=$reportHash}
        foreach ($name in @('result','maintenance')) {
            $path=Join-Path $DataPath ($name+'.json')
            if (Test-Path $path) { $receipt[($name+'_sha256')]=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $receipt | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'Transmission-Rapport.json') -Encoding UTF8
    } catch {
        @{status='pending';message='Rapport local conserve. Relancer Generer-Rapport.cmd lorsque la console est joignable.'} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'Transmission-Rapport.json') -Encoding UTF8
    }
}
