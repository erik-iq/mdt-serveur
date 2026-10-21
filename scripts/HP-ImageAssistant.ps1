# Functions only. HPIA runs inside the SYSTEM preparation task, never in a desktop GUI.
function Get-AtelierHpiaOutcome {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { return @{status='completed';reboot_required=$false;message='Traitement HP termine ; consulter le rapport HPIA pour les paquets appliques.'} }
        256 { return @{status='completed';reboot_required=$false;message='Analyse HP terminee sans recommandation compatible.'} }
        257 { return @{status='needs_attention';reboot_required=$false;message='Aucune recommandation HP selectionnee ; verifier le rapport HPIA.'} }
        3010 { return @{status='completed';reboot_required=$true;message='Traitement HP termine ; redemarrage manuel necessaire.'} }
        3011 { return @{status='needs_attention';reboot_required=$false;message='Un SoftPaq HP exige une installation manuelle et a ete ignore par HPIA.'} }
        3020 { return @{status='needs_attention';reboot_required=$false;message='Au moins un paquet HP a echoue ; consulter les rapports HPIA.'} }
        4096 { return @{status='needs_attention';reboot_required=$false;message='Ce modele ou cette version de Windows ne sont pas pris en charge par HPIA.'} }
        4097 { return @{status='needs_attention';reboot_required=$false;message='Parametres HPIA invalides ; consulter le journal HP.'} }
        4098 { return @{status='needs_attention';reboot_required=$false;message='HPIA ne peut pas acceder a Internet ; verifier le reseau et le proxy du compte SYSTEM.'} }
        4102 { return @{status='needs_attention';reboot_required=$false;message='Connexion HP refusee : TLS 1.2 ou superieur est necessaire.'} }
        4103 { return @{status='needs_attention';reboot_required=$false;message='Requete vers les serveurs HP incomplete ; verifier le reseau et le proxy.'} }
        4104 { return @{status='needs_attention';reboot_required=$false;message='Version Windows sans reference HP dediee : HPIA utilise une reference generique. Verifier les resultats et le besoin de redemarrage.'} }
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
                # The analysis report also contains Recommendations, but an empty
                # Remediation is not an installation attempt or a package failure.
                if (-not $item.Remediation -or -not @($item.Remediation.PSObject.Properties).Count) { continue }
                $code=if ([string]$item.Remediation.ReturnCode -match '^-?\d+$') { [int]$item.Remediation.ReturnCode } else { $null }
                $description=[string]$item.Remediation.ReturnDescription
                if (-not $description) { $description='Etat HP : '+[string]$item.Remediation.Status }
                $name=[string]$item.Name;$id=[string]$item.SoftPaqID
                [pscustomobject]@{category=[string]$item.Category;code=$code;name=$name.Substring(0,[math]::Min(150,$name.Length));softpaq_id=$id.Substring(0,[math]::Min(40,$id.Length));description=$description.Substring(0,[math]::Min(1000,$description.Length))}
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

function Test-AtelierHpiaAnalysisOnly {
    param([string]$Directory)
    $seen=$false
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File | Select-Object -First 50)) {
        if ($file.Length -gt 16MB) { continue }
        try {
            $report=Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($report.HPIA) {
                if ($report.HPIA.HPIAOperation -ne 'Analyze Action List' -or $report.HPIA.LastOperation -ne 'EndAnalyze') { return $false }
                $seen=$true
            }
        } catch { return $false }
    }
    return $seen
}

function Get-AtelierHpiaInstallableSoftpaqs {
    param([string]$Directory)
    $ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -Recurse | Select-Object -First 50)) {
        if ($file.Length -gt 16MB) { continue }
        try {
            $report=Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
            foreach ($item in @($report.HPIA.Recommendations)) {
                if ([string]$item.SSMCompliant -match '^(?i)true$' -and [string]$item.SoftPaqID -match '^(?i)(?:SP)?([0-9]{4,8})$') { [void]$ids.Add('SP'+$Matches[1]) }
            }
        } catch { }
    }
    return @($ids | Sort-Object | Select-Object -First 200)
}

function Get-AtelierHpiaRecommendedSoftpaqs {
    param([string]$Directory)
    $ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object { $_.Extension -in @('.json','.xml') } | Select-Object -First 50)) {
        if ($file.Length -gt 16MB) { continue }
        # Only recommendation IDs, never installed/obsolete packages elsewhere
        # in the inventory. Hints cannot become commands or download URLs.
        try {
            if ($file.Extension -eq '.json') {
                $report=Get-Content $file.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
                foreach ($item in @($report.HPIA.Recommendations)) {
                    if ([string]$item.SoftPaqID -match '^(?i)(?:SP)?([0-9]{4,8})$') { [void]$ids.Add('SP'+$Matches[1]) }
                }
            } else {
                $reader=$null
                try {
                    $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
                    $reader=[Xml.XmlReader]::Create($file.FullName,$settings);$document=New-Object Xml.XmlDocument;$document.XmlResolver=$null;$document.Load($reader)
                    foreach ($node in $document.SelectNodes("//*[local-name()='Recommendations']//*[translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='softpaqid']")) {
                        if ($node.InnerText -match '^(?i)(?:SP)?([0-9]{4,8})$') { [void]$ids.Add('SP'+$Matches[1]) }
                    }
                } finally { if ($reader) { $reader.Dispose() } }
            }
        } catch { }
    }
    return @($ids | Select-Object -First 200)
}
function Get-AtelierHpBootIdentity {
    # A running installer may be retried only after a real Windows boot change.
    $boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15).LastBootUpTime
    if (-not $boot) { throw 'Date du demarrage Windows indisponible : reprise HP automatique refusee.' }
    return ([datetime]$boot).ToUniversalTime().ToString('o')
}
function Save-AtelierHpCheckpoint {
    param([string]$Path,[hashtable]$State)
    if (-not (Get-Command Write-AtelierVerifiedUtf8File -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Unattend.ps1') }
    # Flush to disk, verify bytes, then replace atomically before launching HP.
    Write-AtelierVerifiedUtf8File -Path $Path -Content ($State | ConvertTo-Json -Depth 14) -NoBackup | Out-Null
}
function Request-AtelierHpBiosRestart {
    param([string]$DataPath)
    $path=Join-Path $DataPath 'hpia-result.json'
    $saved=Get-Content $path -Encoding UTF8 -Raw | ConvertFrom-Json
    $payload=Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $payload.deployment.allow_bios_restart -or $saved.status -ne 'reboot_pending' -or -not $saved.boot_id) { return }
    $boot=Get-AtelierHpBootIdentity
    if ($boot -ne ([datetime]$saved.boot_id).ToUniversalTime().ToString('o') -or ($saved.reboot_requested_boot -and ([datetime]$saved.reboot_requested_boot).ToUniversalTime().ToString('o') -eq $boot)) { return }
    $state=@{};foreach ($property in $saved.PSObject.Properties) { $state[$property.Name]=$property.Value }
    # Persist before requesting a reboot; repeated task triggers cannot restart a countdown.
    $state.reboot_requested_boot=$boot;$state.reboot_requested_at=[DateTime]::UtcNow.ToString('o')
    Save-AtelierHpCheckpoint $path $state
    & shutdown.exe /r /t 60 /d p:2:17 /c 'Atelier PXE : mise a jour BIOS. Reprise automatique de la preparation apres le redemarrage.' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Redemarrage BIOS non accepte par Windows. Redemarrez le poste pour reprendre automatiquement la preparation.' }
}
function Invoke-AtelierHpiaProcess {
    param([string]$Executable,[string]$Arguments,[string]$Directory,[string]$ResultPath,[hashtable]$State,[scriptblock]$OnProgress,[int]$TimeoutSeconds)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable;$info.Arguments=$Arguments;$info.WorkingDirectory=$Directory
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        $State.process_id=$process.Id
        Save-AtelierHpCheckpoint $ResultPath $State
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(5000)) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'HPIA encore actif apres le delai : aucun processus interrompu. Verifier les rapports et les processus avant une reprise manuelle.' }
            $activity=''
            $log=Get-ChildItem -LiteralPath $Directory -Filter '*.log' -File -Recurse | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($log -and $log.Length -le 16MB -and -not ($log.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $lines=(Get-Content -LiteralPath $log.FullName -Encoding UTF8 -Tail 30) -join ' '
                $matches=[regex]::Matches($lines,'(?i)\bSP[0-9]{4,8}\b')
                if ($matches.Count) { $activity=' Dernier paquet mentionne dans le journal : '+$matches[$matches.Count-1].Value.ToUpperInvariant()+'.' }
            }
            & $OnProgress ('HP Image Assistant : '+$State.phase+', '+[int]$clock.Elapsed.TotalSeconds+' s.'+$activity) | Out-Null
        }
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Copy-AtelierHpiaAutoReport {
    param([string]$Directory,[datetime]$Started)
    if (-not $env:ProgramData) { return }
    $source=Join-Path $env:ProgramData 'HP\HP Image Assistant\SoftPaqReport.csv'
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        $file=Get-Item -LiteralPath $source
        if (-not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $file.LastWriteTimeUtc -ge $Started.AddSeconds(-2) -and $file.Length -le 16MB) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $Directory 'SoftPaqReport.csv') -Force
        }
    }
}
function Read-AtelierHpiaAutoReport {
    param([string]$Directory)
    $path=Join-Path $Directory 'SoftPaqReport.csv'
    if (-not (Test-Path $path -PathType Leaf)) { return }
    $file=Get-Item $path
    if ($file.Length -gt 16MB -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    try {
        $csvText=[IO.File]::ReadAllText($path)
        $first=$csvText.Split("`n")[0]
        $separator=if (($first.ToCharArray() | Where-Object { $_ -eq ';' }).Count -gt ($first.ToCharArray() | Where-Object { $_ -eq ',' }).Count) { ';' } else { ',' }
        foreach ($row in @($csvText | ConvertFrom-Csv -Delimiter $separator | Select-Object -First 200)) {
            $fields=@{}
            foreach ($property in $row.PSObject.Properties) { $fields[($property.Name -replace '[^A-Za-z0-9]','').ToLowerInvariant()]=[string]$property.Value }
            $id=@($fields['softpaqid'],$fields['softpaqnumber'],$fields['softpaq']) | Where-Object { $_ -match '^(?i)(SP)?[0-9]{4,8}$' } | Select-Object -First 1
            if (-not $id) { continue };$id='SP'+($id -replace '^(?i)SP','')
            $codeText=@($fields['returncode'],$fields['softpaqreturncode']) | Where-Object { $_ -match '^-?[0-9]+$' } | Select-Object -First 1
            $manual=$fields['autoinstallable'] -match '^(?i)(false|no|0|faux|non)$'
            if (-not $manual -and $null -eq $codeText) { continue }
            $code=if ($codeText) { [int]$codeText } else { $null }
            $description=if ($manual) { 'SoftPaq non automatisable : intervention manuelle necessaire.' } else { 'Resultat du CSV HP AutoReport.' }
            $name=if($fields['name']){$fields['name']}else{$fields['nom']}
            $category=if($fields['category']){$fields['category']}elseif($fields['categorie']){$fields['categorie']}else{$fields['catgorie']}
            [pscustomobject]@{category=([string]$category);softpaq_id=$id.ToUpperInvariant();name=([string]$name);code=$code;manual=$manual;description=$description}
        }
    } catch { }
}

function Export-AtelierHpiaInstallationReport {
    param([string]$Directory,[string]$ToolsPath,[switch]$PublishLatest)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $root=[IO.Path]::GetFullPath($Directory).TrimEnd([char[]]'\/')
    $cursor=Get-Item -LiteralPath $root -Force
    while ($cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Dossier lie refuse pour le rapport HP.' }
        $cursor=$cursor.Parent
    }
    # Keep the native installation summary, not the pre-install analysis HTML.
    $source=Get-ChildItem -LiteralPath $root -Filter 'Readme*.html' -File -Recurse |
        Where-Object { $_.Name -match '^Readme(?: \([0-9]{8} [0-9]{6}\))?\.html$' } |
        Sort-Object LastWriteTimeUtc,FullName -Descending | Select-Object -First 1
    if (-not $source) { return }
    $cursor=$source
    while ($cursor -and $cursor.FullName -ne $root) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Rapport HP lie refuse.' }
        $cursor=if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    if ($source.Length -gt 16MB) { throw 'Rapport HTML HP trop volumineux.' }
    $canonical=Join-Path $root 'Rapport-Installation-HP.html'
    if ((Test-Path -LiteralPath $canonical) -and ((Get-Item -LiteralPath $canonical -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Copie du rapport HP liee refusee.' }
    Copy-Item -LiteralPath $source.FullName -Destination $canonical -Force
    if ($PublishLatest) {
        $latest=Join-Path (Join-Path $ToolsPath 'Rapports') 'Rapport-Installation-HP.html'
        New-Item -ItemType Directory -Path (Split-Path $latest -Parent) -Force | Out-Null
        if ((Test-Path -LiteralPath $latest) -and ((Get-Item -LiteralPath $latest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Destination du rapport HP liee refusee.' }
        Copy-Item -LiteralPath $canonical -Destination $latest -Force
    }
    return $canonical
}

function Invoke-AtelierHpia {
    param([string]$DataPath,[string]$ToolsPath='C:\IQ_',[scriptblock]$OnProgress={param($Message)},[ValidateRange(1,10800)][int]$TimeoutSeconds=2700,[string]$ReportRoot)
    $resultPath=Join-Path $DataPath 'hpia-result.json'
    $process=$null;$timing=''
    $result=@{status='needs_attention';message='Traitement HP non execute.';exit_code=$null;reboot_required=$false;timestamp=[DateTime]::UtcNow.ToString('o');category='All';process_id=$null;script_revision='IQ-5.4.3'}
    try {
        $payload=$null;$allowResume=$false;$boot='';$resume=$false;$previous=$null
        $payloadPath=Join-Path $DataPath 'personalization.json'
        if (Test-Path $payloadPath) {
            $payload=Get-Content $payloadPath -Encoding UTF8 -Raw | ConvertFrom-Json
            $allowResume=[bool]$payload.deployment.allow_bios_restart
        }
        if (Test-Path $resultPath) {
            $previous=Get-Content $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($previous.status -notin @('running','retry_pending','reboot_pending')) { return $previous }
        }
        if ($allowResume) { $boot=Get-AtelierHpBootIdentity }
        if ($previous) {
            $resumable=$previous.status -in @('running','retry_pending','reboot_pending')
            $resume=$allowResume -and $resumable -and $previous.boot_id -and $boot -ne ([datetime]$previous.boot_id).ToUniversalTime().ToString('o')
            if ($resume) {
                foreach ($property in $previous.PSObject.Properties) { $result[$property.Name]=$property.Value }
                if ([int]$previous.resume_count -ge 3) { throw 'Limite de trois reprises HP apres redemarrage atteinte. Rapports conserves ; aucune nouvelle installation lancee.' }
                $history=@($previous.history | Where-Object { $null -ne $_ })
                $history+=@([pscustomobject]@{pass_number=[int]$previous.pass_number;status=[string]$previous.status;message=[string]$previous.message;timestamp=[string]$previous.timestamp;exit_code=$previous.exit_code;packages=@($previous.packages);boot_id=[string]$previous.boot_id})
                $result.history=$history;$result.resume_count=[int]$previous.resume_count+1
                $result.pass_number=[int]$previous.pass_number+1;$result.resumed_after_reboot=$true
                $result.exit_code=$null;$result.process_id=$null;$result.reboot_required=$false;$result.packages=@()
            } elseif ($previous.status -ne 'running') { return $previous }
        }
        if ($previous -and -not $resume) {
            # Same boot: never start a second installer or invent a lost exit code.
            foreach ($property in $previous.PSObject.Properties) { $result[$property.Name]=$property.Value }
            $result.status=if ($allowResume) { 'retry_pending' } else { 'needs_attention' }
            $result.message='Execution HP precedente interrompue ou encore active. Aucun second traitement pendant ce demarrage. Reprise apres un redemarrage Windows.'
        } else {
            if ($allowResume) {
                $result.boot_id=$boot;$result.timestamp=[DateTime]::UtcNow.ToString('o')
                if (-not $resume) { $result.pass_number=1;$result.resume_count=0;$result.history=@() }
            }
            $manufacturer=[string](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15).Manufacturer
            if ($manufacturer -notmatch '(?i)^(HP|Hewlett[ -]Packard)(\b|\s)') {
                $result.status='skipped';$result.message='Autre constructeur : HP Image Assistant non applicable.'
            } else {
                $readyPath=Join-Path $DataPath 'ready-tools.json'
                $tools=@()
                if (Test-Path $readyPath) { $tools=Get-Content $readyPath -Encoding UTF8 -Raw | ConvertFrom-Json }
                $tool=@($tools | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'HPImageAssistant.exe' } | Select-Object -First 1)
                if (-not $tool.Count) { throw 'HP Image Assistant non installe ou non verifie par WinGet. Consulter C:\ProgramData\AtelierPXE\software-logs\hpia.log et result.json.' }
                if (@(Get-Process -Name 'HPImageAssistant' -ErrorAction SilentlyContinue).Count) { throw 'HP Image Assistant est deja actif ; aucun second traitement HP lance.' }
                $tool=$tool[0]
                $root=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'AtelierPXE\Tools')).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
                $exe=[IO.Path]::GetFullPath([string]$tool.path)
                if (-not $exe.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $exe -PathType Leaf)) { throw 'HP Image Assistant hors du dossier approuve.' }
                if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.sha256) { throw 'Empreinte de HP Image Assistant invalide.' }
                $signature=Get-AuthenticodeSignature -LiteralPath $exe
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(HP Inc\.|Hewlett-Packard)') { throw 'Signature HP Image Assistant invalide ou editeur HP non reconnu.' }
                $reports=if ($ReportRoot) { $ReportRoot } else { Join-Path (Join-Path $ToolsPath 'Rapports') 'HPImageAssistant' }
                $downloads=Join-Path $DataPath 'HP-SoftPaqs'
                $payloadPath=Join-Path $DataPath 'personalization.json'
                $useRepository=$false
                if (Test-Path $payloadPath) {
                    $payload=Get-Content $payloadPath -Encoding UTF8 -Raw | ConvertFrom-Json
                    $useRepository=[bool]$payload.deployment.hp_repository
                    if ($useRepository) { $reports=Join-Path $reports ([guid]::Parse([string]$payload.deployment.id).ToString()) }
                }
                New-Item -ItemType Directory -Path $reports,$downloads -Force | Out-Null
                $result.report_directory=$reports
                if ($allowResume) { $reports=Join-Path $reports ('Passage-'+([int]$result.pass_number).ToString('00'));New-Item -ItemType Directory -Path $reports -Force | Out-Null }
                $repository=$null
                $result.status='running';$result.phase='preparation';$result.source='online'
                if (Get-Command Start-AtelierTiming -ErrorAction SilentlyContinue) { $timing=Start-AtelierTiming $DataPath 'hp_updates' }
                if ($useRepository) {
                    $analysis=Join-Path $reports 'Analyse';New-Item -ItemType Directory -Path $analysis -Force | Out-Null
                    $result.phase='analyse des pilotes';$result.message='Recherche des SoftPaq HP necessaires avant utilisation du depot .250.'
                    Save-AtelierHpCheckpoint $resultPath $result
                    & $OnProgress $result.message | Out-Null
                    $discovery='/Operation:Analyze /Category:All /Selection:All /Action:List /Silent /Debug /ReportFolder:"'+$analysis+'"'
                    $result.analysis_exit_code=Invoke-AtelierHpiaProcess -Executable $exe -Arguments $discovery -Directory $analysis -ResultPath $resultPath -State $result -OnProgress $OnProgress -TimeoutSeconds $TimeoutSeconds
                    $required=@(Get-AtelierHpiaRecommendedSoftpaqs $analysis)
                    . (Join-Path $DataPath 'HP-ClientRepository.ps1')
                    $repository=Get-AtelierHpRepository -DataPath $DataPath -RequiredSoftpaqs $required -OnProgress $OnProgress -PrepareOnly:($result.analysis_exit_code -eq 256)
                    $result.repository=$repository
                    $result.source=if ($repository.status -in @('offline','package_cache')) { 'depot_250' } else { 'online' }
                    $reports=Join-Path $reports 'Installation';New-Item -ItemType Directory -Path $reports -Force | Out-Null
                }
                if ($useRepository -and $result.analysis_exit_code -eq 256) {
                    $result.exit_code=256;$result.status='completed';$result.phase='termine';$result.packages=@()
                    $result.message='Analyse HP terminee : aucune mise a jour recommandee. Aucune copie du depot ni installation inutile.'
                } else {
                    # HP documents this switch to expose the actual installation
                    # return code instead of letting generic-reference code 4104
                    # hide e.g. 3010 (reboot) or 3020 (installation failure).
                    # AutoReport is a separate reporting operation: the supplied
                    # 5.3.6 logs ended as Analyze Action List even with Install.
                    # Use the installation operation alone, with its own reports.
                    $arguments='/Operation:Analyze /Category:All /Selection:All /InstallType:AutoInstallable /Silent /IgnoreGenericOsError /Debug /ReportFolder:"'+$reports+'" /SoftpaqDownloadFolder:"'+$downloads+'" /Action:Install'
                    if ($repository -and $repository.status -eq 'offline') { $arguments+=' /OfflineMode:"'+$repository.path+'"' }
                    # HPIA manages its supported packages. Never force unsupported firmware.
                    $sourceText=if ($result.source -eq 'depot_250') { 'depot local .250' } else { 'serveurs HP par Internet' }
                    $result.status='running';$result.phase='analyse et installation';$result.message='Analyse et installation des SoftPaq HP en cours (pilotes, logiciels, BIOS et firmwares compatibles). Source : '+$sourceText+'.'
                    Save-AtelierHpCheckpoint $resultPath $result
                    & $OnProgress $result.message | Out-Null
                    $installStarted=[DateTime]::UtcNow
                    $result.exit_code=Invoke-AtelierHpiaProcess -Executable $exe -Arguments $arguments -Directory $reports -ResultPath $resultPath -State $result -OnProgress $OnProgress -TimeoutSeconds $TimeoutSeconds
                    Copy-AtelierHpiaAutoReport -Directory $reports -Started $installStarted
                    $explicit=@(Get-AtelierHpiaInstallableSoftpaqs $reports)
                    if ($result.exit_code -in @(0,4104) -and $explicit.Count -and (Test-AtelierHpiaAnalysisOnly $reports) -and -not @(Read-AtelierHpiaPackages $reports).Count -and -not @(Read-AtelierHpiaAutoReport $reports | Where-Object { $null -ne $_.code }).Count) {
                        # HP's documented SPList operation selects only IDs from
                        # this PC's own fresh recommendations. Never use Force or
                        # install a catalogue of optional/unrelated devices.
                        $result.initial_install_exit_code=$result.exit_code
                        $result.exit_code=$null
                        $retry=Join-Path $reports 'Selection-Explicite';New-Item -ItemType Directory -Path $retry -Force | Out-Null
                        $list=Join-Path $retry 'SoftPaqs.txt'
                        [IO.File]::WriteAllLines($list,[string[]]@($explicit | ForEach-Object { $_.Substring(2) }),[Text.Encoding]::ASCII)
                        $result.explicit_softpaqs=$explicit;$result.phase='installation des SoftPaq selectionnes'
                        $result.message='HPIA n a confirme aucune installation : reprise unique avec la liste des '+$explicit.Count+' SoftPaq recommandes et automatisables.'
                        Save-AtelierHpCheckpoint $resultPath $result
                        & $OnProgress $result.message | Out-Null
                        $retryArguments=$arguments.Replace(('/ReportFolder:"'+$reports+'"'),('/ReportFolder:"'+$retry+'"'))+' /SPList:"'+$list+'"'
                        $retryStarted=[DateTime]::UtcNow
                        $result.exit_code=Invoke-AtelierHpiaProcess -Executable $exe -Arguments $retryArguments -Directory $retry -ResultPath $resultPath -State $result -OnProgress $OnProgress -TimeoutSeconds $TimeoutSeconds
                        Copy-AtelierHpiaAutoReport -Directory $retry -Started $retryStarted
                    }
                    $outcome=Get-AtelierHpiaOutcome $result.exit_code
                    $result.status=$outcome.status;$result.reboot_required=$outcome.reboot_required;$result.message=$outcome.message
                    $result.packages=@(Read-AtelierHpiaPackages $reports | Select-Object -First 200)
                    foreach ($package in @(Read-AtelierHpiaAutoReport $reports)) {
                        if ($package.manual -or -not @($result.packages | Where-Object { $_.softpaq_id -eq $package.softpaq_id }).Count) { $result.packages+=@($package) }
                    }
                    if (@($result.packages | Where-Object { $_.code -in @(3010,1641) }).Count) { $result.reboot_required=$true }
                    if (@($result.packages | Where-Object { $null -ne $_.code -and $_.code -notin @(0,3010,1641) }).Count) {
                        $result.status='needs_attention';$result.message='Un ou plusieurs SoftPaq HP ont un resultat a verifier ; consulter les rapports HPIA.'
                    } elseif ($result.status -eq 'completed' -and @($result.packages | Where-Object { $null -eq $_.code -or $_.manual }).Count) {
                        $result.status='needs_attention';$result.message='Resultats d installation HP incomplets ou intervention manuelle requise ; aucun succes suppose pour un resultat absent.'
                    } elseif ($result.status -eq 'completed' -and -not $result.packages.Count -and @(Get-AtelierHpiaRecommendedSoftpaqs $reports).Count) {
                        $result.status='needs_attention';$result.message='Recommandations HP presentes, mais aucun resultat d installation confirme. Consulter le journal HPIA.'
                    }
                    $confirmed=@($result.packages | Where-Object { $null -ne $_.code } | ForEach-Object { $_.softpaq_id })
                    $missing=@(Get-AtelierHpiaRecommendedSoftpaqs $reports | Where-Object { $_ -notin $confirmed })
                    if ($result.exit_code -eq 4104 -and $result.packages.Count -and -not $missing.Count -and -not @($result.packages | Where-Object { $null -eq $_.code -or $_.manual -or $_.code -notin @(0,3010,1641) }).Count) {
                        $result.status='completed';$result.message='Installation HP confirmee par les resultats SoftPaq.'
                    }
                    if ($result.status -eq 'completed' -and $missing.Count) {
                        $result.status='needs_attention';$result.unconfirmed_softpaqs=$missing
                        $result.message='Installation non confirmee pour '+$missing.Count+' SoftPaq recommandes : '+($missing -join ', ')+'. Consulter les rapports HP.'
                    }
                    $result.generic_os_reference=$result.analysis_exit_code -eq 4104 -or $result.initial_install_exit_code -eq 4104 -or $result.exit_code -eq 4104
                    if ($result.generic_os_reference) {
                        $result.message+=' Reference HP generique : avertissement de version ignore pour poursuivre l installation ; les resultats des SoftPaq restent controles.'
                    }
                    $biosRestart=@($result.packages | Where-Object { $_.code -in @(3010,1641) -and ($_.category -match '^(?i)BIOS$' -or $_.name -match '(?i)\bBIOS\b') }).Count -gt 0
                    if ($allowResume -and $biosRestart) {
                        $result.status='reboot_pending';$result.phase='redemarrage BIOS';$result.reboot_required=$true
                        $result.message='Mise a jour BIOS : redemarrage necessaire. La preparation reprendra automatiquement apres le demarrage Windows.'
                        if ([int]$result.resume_count -ge 3) { $result.status='needs_attention';$result.message='Limite de trois reprises HP atteinte. Redemarrage encore demande par le BIOS ; verifier les rapports avant toute intervention.' }
                    }
                }
            }
        }
    } catch {
        $result.status=if ($allowResume -and $result.process_id -and $null -eq $result.exit_code -and $result.resume_count -lt 3) { 'retry_pending' } else { 'needs_attention' }
        $result.message=$_.Exception.Message
    }
    finally {
        if ($process) { $process.Dispose() }
        if ($timing) {
            $timingStatus=if ($result.status -eq 'completed') { 'completed' } else { 'deferred' }
            Stop-AtelierTiming $DataPath $timing $timingStatus
            Sync-AtelierTimings $DataPath
        }
    }
    $result.timestamp=[DateTime]::UtcNow.ToString('o')
    # A timeout leaves HP running: never publish its partially written page.
    if ($result.report_directory -and $null -ne $result.exit_code) {
        try {
            $html=Export-AtelierHpiaInstallationReport -Directory $result.report_directory -ToolsPath $ToolsPath -PublishLatest:(-not $ReportRoot)
            if ($html) { $result.installation_report=$html }
        } catch { $result.report_warning='Rapport HTML HP non prepare : '+$_.Exception.Message }
    }
    Save-AtelierHpCheckpoint $resultPath $result
    return [pscustomobject]$result
}
