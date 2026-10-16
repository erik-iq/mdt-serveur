# Functions only. Upload through HTTPS with the deployment reporting token, no writable SMB share.
function Send-AtelierInventory {
    param([string]$DataPath,[string]$InventoryDirectory)
    $configuration=Join-Path $DataPath 'reporting.json'
    if (-not (Test-Path $configuration)) { return $false }
    $receiptPath=Join-Path $DataPath 'inventory-sent.json'
    $saved=@{}
    if (Test-Path $receiptPath) {
        try { (Get-Content $receiptPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $saved[$_.Name]=[string]$_.Value } } catch { }
    }
    try {
        $config=Get-Content $configuration -Raw | ConvertFrom-Json
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        foreach ($kind in @('xml','csv')) {
            $path=Join-Path $InventoryDirectory ('Inventaire-Technique.' + $kind)
            if (-not (Test-Path $path -PathType Leaf)) { return $false }
            $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($saved[$kind] -ne $hash) {
                Invoke-RestMethod -Uri ($config.server_url + '/api/windows/' + $config.id + '/inventory/' + $kind) -Method Post -Headers @{Authorization=('Bearer ' + $config.token)} -ContentType 'application/octet-stream' -InFile $path -TimeoutSec 60 | Out-Null
                $saved[$kind]=$hash
                $saved | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
            }
        }
        return $true
    } catch {
        Add-Content -LiteralPath (Join-Path $DataPath 'reporting.log') -Value ((Get-Date -Format o) + ' Inventaire XML/CSV non transmis ; cache privé conservé pour reprise.') -Encoding UTF8
        return $false
    }
}
