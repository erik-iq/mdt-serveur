
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
if (Test-Path (Join-Path $PSScriptRoot 'Network-Measurement.ps1')) { . (Join-Path $PSScriptRoot 'Network-Measurement.ps1') }
# Durées réelles dans un même processus, sans inventer les intervalles de redémarrage ou d’arrêt.
if (-not $script:AtelierTimingClocks) { $script:AtelierTimingClocks=@{} }
function Start-AtelierTiming {
    param([string]$DataPath,[string]$Stage,[ValidateSet('winpe','windows')][string]$Source='windows')
    try {
        $directory=Join-Path $DataPath 'timings';New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $id=[guid]::NewGuid().ToString()
        $record=@{run_id=$id;source=$Source;stage=$Stage;status='running';started_at=[DateTime]::UtcNow.ToString('o');duration_seconds=0}
        $record | ConvertTo-Json | Set-Content (Join-Path $directory ($id+'.json')) -Encoding UTF8
        $script:AtelierTimingClocks[$id]=[Diagnostics.Stopwatch]::StartNew()
        return $id
    } catch { return '' }
}
function Stop-AtelierTiming {
    param([string]$DataPath,[string]$Id,[ValidateSet('completed','failed','deferred','interrupted')][string]$Status='completed')
    if (-not $Id) { return }
    try {
        $path=Join-Path (Join-Path $DataPath 'timings') ($Id+'.json')
        $record=Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($record.status -ne 'running') { return }
        $clock=$script:AtelierTimingClocks[$Id]
        if ($clock) {
            $clock.Stop();$record.duration_seconds=[math]::Round($clock.Elapsed.TotalSeconds,3)
            $script:AtelierTimingClocks.Remove($Id)
            $record.status=$Status
        } else { $record.status='interrupted' }
        $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try { $record | ConvertTo-Json | Set-Content $temp -Encoding UTF8;Move-Item -LiteralPath $temp -Destination $path -Force }
        finally { if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Force } }
    } catch { }
}
function Sync-AtelierTimings {
    param([string]$DataPath,$Configuration=$null)
    if ($script:AtelierTimingRetryAfter -and [DateTime]::UtcNow -lt $script:AtelierTimingRetryAfter) { return }
    try {
        if (-not $Configuration) {
            $path=Join-Path $DataPath 'reporting.json'
            if (-not (Test-Path $path)) { return }
            $Configuration=Get-Content $path -Encoding UTF8 -Raw | ConvertFrom-Json
        }
        if (Get-Command Sync-AtelierNetworkMeasurement -ErrorAction SilentlyContinue) { Sync-AtelierNetworkMeasurement $DataPath $Configuration }
        $directory=Join-Path $DataPath 'timings'
        if (-not (Test-Path $directory)) { return }
        $receipt=Join-Path $directory 'sent.txt'
        $sent=if (Test-Path $receipt) { @(Get-Content $receipt -Encoding UTF8) } else { @() }
        $batch=@();$hashes=@()
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Select-Object -First 200)) {
            $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            if ($hash -in $sent) { continue }
            try { $record=Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw | ConvertFrom-Json } catch { continue }
            $batch+=@($record);$hashes+=@($hash)
        }
        if (-not $batch.Count) { return }
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $body=ConvertTo-Json -InputObject @{measurements=@($batch)} -Depth 5 -Compress
        Invoke-RestMethod -Uri ($Configuration.server_url + '/api/windows/' + $Configuration.id + '/timings') -Method Post -Headers @{Authorization=('Bearer '+$Configuration.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
        @($sent+$hashes | Select-Object -Unique) | Set-Content $receipt -Encoding ASCII
    } catch { $script:AtelierTimingRetryAfter=[DateTime]::UtcNow.AddMinutes(1) }
}
