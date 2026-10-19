# Functions only. HPIA runs inside the SYSTEM preparation task, never in a desktop GUI.
function Get-AtelierHpiaOutcome {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { return @{status='completed';reboot_required=$false;message='Traitement HP termine ; consulter le rapport HPIA pour les paquets appliques.'} }
        256 { return @{status='completed';reboot_required=$false;message='Analyse HP terminee sans recommandation compatible.'} }
        257 { return @{status='needs_attention';reboot_required=$false;message='Aucune recommandation HP selectionnee ; verifier le rapport HPIA.'} }
        3010 { return @{status='completed';reboot_required=$true;message='Traitement HP termine ; redemarrage manuel necessaire.'} }
        3020 { return @{status='needs_attention';reboot_required=$false;message='Au moins un paquet HP a echoue ; consulter les rapports HPIA.'} }
        4096 { return @{status='needs_attention';reboot_required=$false;message='Ce modele ou cette version de Windows ne sont pas pris en charge par HPIA.'} }
        default { return @{status='needs_attention';reboot_required=$false;message=('Traitement HP non confirme (code '+$ExitCode+'). Consulter les rapports HPIA.')} }
    }
}

function Read-AtelierHpiaPackages {
    param([string]$Directory)
    $found=$false
    # Recent HPIA writes installation/remediation outcomes in JSON; XML may
    # contain only the recommendations from the analysis before installation.
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -Recurse | Select-Object -First 50)) {
        if ($file.Length -gt 16MB) { continue }
        try {
            $report=Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
            foreach ($item in @($report.HPIA.Recommendations)) {
                if (-not $item) { continue }
                $code=if ([string]$item.Remediation.ReturnCode -match '^-?\d+$') { [int]$item.Remediation.ReturnCode } else { $null }
                $description=[string]$item.Remediation.ReturnDescription
                if (-not $description) { $description='Etat HP : '+[string]$item.Remediation.Status }
                $name=[string]$item.Name;$id=[string]$item.SoftPaqID
                [pscustomobject]@{code=$code;name=$name.Substring(0,[math]::Min(150,$name.Length));softpaq_id=$id.Substring(0,[math]::Min(40,$id.Length));description=$description.Substring(0,[math]::Min(1000,$description.Length))}
                $found=$true
            }
        } catch { }
    }
    if ($found) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.xml' -File -Recurse | Select-Object -First 50)) {
        if ($file.Length -gt 16MB) { continue }
        $reader=$null
        try {
            $settings=New-Object Xml.XmlReaderSettings
            $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
            $reader=[Xml.XmlReader]::Create($file.FullName,$settings)
            $document=New-Object Xml.XmlDocument
            $document.XmlResolver=$null;$document.Load($reader)
            foreach ($node in @($document.SelectNodes("//*[local-name()='Remediation']"))) {
                if ([string]$node.ReturnCode -notmatch '^-?\d+$') { continue }
                [pscustomobject]@{code=[int]$node.ReturnCode;description=([string]$node.ReturnDescription).Substring(0,[math]::Min(1000,([string]$node.ReturnDescription).Length))}
            }
        } catch { } finally { if ($reader) { $reader.Dispose() } }
    }
}

function Invoke-AtelierHpia {
    param([string]$DataPath,[string]$ToolsPath='C:\IQ_',[scriptblock]$OnProgress={param($Message)},[ValidateRange(1,10800)][int]$TimeoutSeconds=2700)
    $resultPath=Join-Path $DataPath 'hpia-result.json'
    $process=$null;$timing=''
    $result=@{status='needs_attention';message='Traitement HP non execute.';exit_code=$null;reboot_required=$false;timestamp=[DateTime]::UtcNow.ToString('o');category='All';process_id=$null}
    try {
        if (Test-Path $resultPath) {
            $previous=Get-Content $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($previous.status -ne 'running') { return $previous }
            # Never launch a second installer or invent a lost exit code after interruption.
            $result.message='Execution HP precedente interrompue ou encore active. Verifier HPIA et ses processus avant une reprise manuelle.'
            $result.process_id=$previous.process_id
        } else {
            $manufacturer=[string](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15).Manufacturer
            if ($manufacturer -notmatch '(?i)^(HP|Hewlett[ -]Packard)(\b|\s)') {
                $result.status='skipped';$result.message='Autre constructeur : HP Image Assistant non applicable.'
            } else {
                $readyPath=Join-Path $DataPath 'ready-tools.json'
                $tools=if (Test-Path $readyPath) { @(Get-Content $readyPath -Encoding UTF8 -Raw | ConvertFrom-Json) } else { @() }
                $tool=@($tools | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'HPImageAssistant.exe' } | Select-Object -First 1)
                if (-not $tool.Count) { throw 'HP Image Assistant non installe ou non verifie par WinGet. Consulter C:\ProgramData\AtelierPXE\software-logs\hpia.log et result.json.' }
                $tool=$tool[0]
                $root=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'AtelierPXE\Tools')).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
                $exe=[IO.Path]::GetFullPath([string]$tool.path)
                if (-not $exe.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $exe -PathType Leaf)) { throw 'HP Image Assistant hors du dossier approuve.' }
                if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.sha256) { throw 'Empreinte de HP Image Assistant invalide.' }
                $signature=Get-AuthenticodeSignature -LiteralPath $exe
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(HP Inc\.|Hewlett-Packard)') { throw 'Signature HP Image Assistant invalide ou editeur HP non reconnu.' }
                $reports=Join-Path (Join-Path $ToolsPath 'Rapports') 'HPImageAssistant'
                $downloads=Join-Path $DataPath 'HP-SoftPaqs'
                New-Item -ItemType Directory -Path $reports,$downloads -Force | Out-Null
                $arguments='/Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /Noninteractive /Debug /ReportFolder:"'+$reports+'" /SoftpaqDownloadFolder:"'+$downloads+'"'
                # HPIA manages its supported packages. No reboot command/switch is added.
                $info=New-Object Diagnostics.ProcessStartInfo
                $info.FileName=$exe;$info.Arguments=$arguments;$info.WorkingDirectory=$reports
                $info.UseShellExecute=$false;$info.CreateNoWindow=$true
                $result.status='running';$result.message='Analyse et installation des SoftPaq HP en cours (pilotes, logiciels, BIOS et firmwares compatibles).'
                $result | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
                if (Get-Command Start-AtelierTiming -ErrorAction SilentlyContinue) { $timing=Start-AtelierTiming $DataPath 'hp_updates' }
                & $OnProgress $result.message | Out-Null
                $process=[Diagnostics.Process]::Start($info)
                $result.process_id=$process.Id
                $result | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
                $clock=[Diagnostics.Stopwatch]::StartNew()
                while (-not $process.WaitForExit(5000)) {
                    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'HPIA encore actif apres le delai : aucun processus interrompu. Verifier les rapports et les processus avant une reprise manuelle.' }
                    & $OnProgress ('HP Image Assistant en arriere-plan : '+[int]$clock.Elapsed.TotalSeconds+' s. Analyse, telechargement et installation des SoftPaq ; consulter les rapports HP.') | Out-Null
                }
                $result.exit_code=$process.ExitCode
                $outcome=Get-AtelierHpiaOutcome $process.ExitCode
                $result.status=$outcome.status;$result.reboot_required=$outcome.reboot_required;$result.message=$outcome.message
                $result.packages=@(Read-AtelierHpiaPackages $reports | Select-Object -First 200)
                if (@($result.packages | Where-Object { $_.code -in @(3010,1641) }).Count) { $result.reboot_required=$true }
                if (@($result.packages | Where-Object { $_.code -notin @(0,3010) }).Count) {
                    $result.status='needs_attention';$result.message='Un ou plusieurs SoftPaq HP ont un resultat a verifier ; consulter les rapports HPIA.'
                }
            }
        }
    } catch { $result.status='needs_attention';$result.message=$_.Exception.Message }
    finally {
        if ($process) { $process.Dispose() }
        if ($timing) {
            $timingStatus=if ($result.status -eq 'completed') { 'completed' } else { 'deferred' }
            Stop-AtelierTiming $DataPath $timing $timingStatus
            Sync-AtelierTimings $DataPath
        }
    }
    $result.timestamp=[DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
    return [pscustomobject]$result
}
