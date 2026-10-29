# Mesures locales facultatives. Un compteur absent ne doit jamais interrompre le déploiement.
function Get-AtelierImageNetworkAdapter {
    param([string]$ImagePath)
    if ($ImagePath -notmatch '^\\\\([^\\]+)\\') { throw 'Source locale : aucune interface réseau attribuée à cette image.' }
    $server=$Matches[1]
    # Une connexion UDP sans envoi permet de lire la route locale, sans lancer de test de débit.
    foreach ($address in [Net.Dns]::GetHostAddresses($server)) {
        if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $socket=New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Dgram,[Net.Sockets.ProtocolType]::Udp)
        try {
            $socket.Connect($address,445)
            $local=$socket.LocalEndPoint.Address.ToString()
            foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
                $addresses=@($adapter.GetIPProperties().UnicastAddresses | ForEach-Object {$_.Address.ToString()})
                if ($local -in $addresses) { return [string]$adapter.Id }
            }
        } finally { $socket.Dispose() }
    }
    throw 'Interface IPv4 vers le partage non identifiée dans WinPE.'
}

function Read-AtelierNetworkCounter {
    param([string]$AdapterId)
    $adapter=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {$_.Id -eq $AdapterId}) | Select-Object -First 1
    if (-not $adapter -or $adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { throw 'Interface réseau absente ou déconnectée.' }
    $speed=$null
    try { if ($adapter.Speed -gt 0 -and $adapter.Speed -le 1000000000000) {$speed=[long]$adapter.Speed} } catch { }
    $received=$null
    try { $received=[long]$adapter.GetIPv4Statistics().BytesReceived } catch { }
    return @{adapter_name=([string]$adapter.Description).Substring(0,[math]::Min(180,([string]$adapter.Description).Length));link_speed_bps=$speed;received=$received}
}

function Start-AtelierImageNetworkMeasurement {
    param([string]$ImagePath)
    $context=@{adapter_id='';image_path=$ImagePath;counter=$null;clock=$null;reason=''}
    try {
        $context.adapter_id=Get-AtelierImageNetworkAdapter $ImagePath
        $context.counter=Read-AtelierNetworkCounter $context.adapter_id
        if ($null -eq $context.counter.received -or $context.counter.received -lt 0) { throw 'Compteur de réception invalide.' }
        $context.clock=[Diagnostics.Stopwatch]::StartNew()
    } catch { $context.reason='Interface ou compteurs réseau indisponibles pendant cette application.' }
    return $context
}

function Stop-AtelierImageNetworkMeasurement {
    param([string]$DataPath,$Context,[ValidateSet('completed','failed')][string]$ApplicationStatus)
    try {
        $record=@{source='winpe_image_rx';status='unavailable';application_status=$ApplicationStatus;adapter_name='';link_speed_bps=$null;received_bytes=$null;duration_seconds=$null;reason='Mesure réseau non disponible dans WinPE.'}
        if ($Context.counter) {
            $record.adapter_name=$Context.counter.adapter_name;$record.link_speed_bps=$Context.counter.link_speed_bps
        }
        if ($Context.reason) { $record.reason=[string]$Context.reason }
        elseif ($Context.clock) {
            try {
                # La route, l’interface et la vitesse sont contrôlées aux deux bornes de la mesure.
                if ((Get-AtelierImageNetworkAdapter $Context.image_path) -ne $Context.adapter_id) { throw 'Route réseau modifiée.' }
                $last=Read-AtelierNetworkCounter $Context.adapter_id
                if ($null -eq $last.received) { throw 'Compteur de réception indisponible.' }
                $Context.clock.Stop()
                $elapsed=$Context.clock.Elapsed.TotalSeconds
                $received=[long]$last.received-[long]$Context.counter.received
                if ($received -lt 0 -or $elapsed -le 0 -or $elapsed -gt 1209600) { throw 'Compteur réinitialisé ou intervalle invalide.' }
                if ($last.link_speed_bps -ne $Context.counter.link_speed_bps) { throw 'Vitesse de liaison modifiée pendant la mesure.' }
                $record.status='measured';$record.received_bytes=$received
                $record.duration_seconds=[math]::Max(0.001,[math]::Round($elapsed,3))
                $record.reason='Octets reçus sur cette interface pendant DISM, autres échanges réseau inclus.'
            } catch {
                $record.link_speed_bps=$null
                $record.reason='Interface déconnectée, vitesse modifiée ou compteur réinitialisé ; débit non confirmé.'
            }
        }
        New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
        $path=Join-Path $DataPath 'deployment-network.json'
        $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try { $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8;Move-Item -LiteralPath $temporary -Destination $path -Force }
        finally { if (Test-Path $temporary) {Remove-Item -LiteralPath $temporary -Force} }
    } catch { }
}

function Sync-AtelierNetworkMeasurement {
    param([string]$DataPath,$Configuration)
    try {
        $path=Join-Path $DataPath 'deployment-network.json'
        if (-not (Test-Path -LiteralPath $path)) { return }
        $receipt=$path+'.sent'
        if (Test-Path -LiteralPath $receipt) { return }
        $body=Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Invoke-RestMethod -Uri ($Configuration.server_url+'/api/windows/'+$Configuration.id+'/network') -Method Post -Headers @{Authorization=('Bearer '+$Configuration.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
        Set-Content -LiteralPath $receipt -Value 'accepted' -Encoding ASCII
    } catch { }
}
