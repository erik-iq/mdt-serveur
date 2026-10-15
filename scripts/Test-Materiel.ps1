#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$OutputDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
# Loopback is a secure browser context for camera/audio. No images or sound leave this PC.
$reservation=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$reservation.Start();$port=$reservation.LocalEndpoint.Port;$reservation.Stop()
$nonce=[guid]::NewGuid().ToString('N')
$listener=New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
$url="http://localhost:$port/$nonce/"
$deadline=(Get-Date).AddMinutes(30)
try {
    Start-Process $url
    $finished=$false
    while (-not $finished -and (Get-Date) -lt $deadline) {
        $pending=$listener.BeginGetContext($null,$null)
        while (-not $pending.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not $pending.IsCompleted) { break }
        $context=$listener.EndGetContext($pending);$request=$context.Request;$response=$context.Response
        try {
            $response.Headers.Add('Cache-Control','no-store')
            $response.Headers.Add('X-Content-Type-Options','nosniff')
            if (-not [Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address) -or -not $request.Url.AbsolutePath.StartsWith("/$nonce/")) { $response.StatusCode=403;continue }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq "/$nonce/") {
                $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Tests-Materiel.html'))
                $response.ContentType='text/html; charset=utf-8'
            } elseif ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq "/$nonce/result") {
                if ($request.ContentLength64 -lt 0 -or $request.ContentLength64 -gt 16384) { $response.StatusCode=413;continue }
                if ($request.Headers['Origin'] -ne "http://localhost:$port") { $response.StatusCode=403;continue }
                $reader=New-Object IO.StreamReader($request.InputStream,[Text.Encoding]::UTF8)
                try { $inputJson=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                $tests=@()
                foreach ($name in @('son','webcam','clavier')) {
                    $test=@($inputJson.tests | Where-Object { $_.name -eq $name })
                    if ($test.Count -ne 1 -or $test[0].status -notin @('not_tested','passed','failed')) { throw 'Resultat de test invalide.' }
                    $comment=[string]$test[0].comment
                    if ($comment.Length -gt 500) { throw 'Commentaire trop long.' }
                    $tests += @{name=$name;status=$test[0].status;comment=$comment}
                }
                @{ordinateur=$env:COMPUTERNAME;date=[DateTime]::UtcNow.ToString('o');tests=$tests;validation='operateur'} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'Tests-Materiel.json') -Encoding UTF8
                $response.ContentType='application/json';$bytes=[Text.Encoding]::UTF8.GetBytes('{"saved":true}');$finished=$true
            } else { $response.StatusCode=404;$bytes=@() }
            $response.ContentLength64=$bytes.Length;$response.OutputStream.Write($bytes,0,$bytes.Length)
        } catch { $response.StatusCode=400 }
        finally { $response.Close() }
    }
} finally { $listener.Stop();$listener.Close() }
