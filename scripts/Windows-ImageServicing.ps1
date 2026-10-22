# Functions only. Every DISM write targets a private candidate, never the source.
function Assert-AtelierServicingPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $item=$full
    while ($item) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw ('Chemin lie interdit : '+$item) }
        $parent=Split-Path $item -Parent
        if ($parent -eq $item) { break };$item=$parent
    }
    return $full
}

function Write-AtelierServicingJson {
    param($Value,[string]$Path)
    $temporary=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    # The web service reads a separate status mirror, never the private mounts.
    $run=Split-Path $Path -Parent;$runs=Split-Path $run -Parent;$root=Split-Path $runs -Parent
    if ((Split-Path $Path -Leaf) -eq 'report.json' -and (Split-Path $root -Leaf) -eq 'windows-servicing' -and $Value.run_id -match '^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$') {
        $mirrorTemp=$null
        try {
        $public=Assert-AtelierServicingPath (Join-Path (Join-Path (Split-Path $root -Parent) 'maintenance-overview') 'runs')
        New-Item -ItemType Directory -Path $public -Force | Out-Null
        $mirror=Assert-AtelierServicingPath (Join-Path $public ($Value.run_id+'.json'))
        $mirrorTemp=$mirror+'.tmp-'+[guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($mirrorTemp,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $mirrorTemp -Destination $mirror -Force
        } catch { Write-Warning ('Suivi web non publie ; le rapport prive reste conserve : '+$_.Exception.Message) }
        finally { if($mirrorTemp){Remove-Item -LiteralPath $mirrorTemp -Force -ErrorAction SilentlyContinue} }
    }
}

function Publish-AtelierServicingStatus {
    param([string]$DataRoot)
    $root=Assert-AtelierServicingPath (Join-Path $DataRoot 'windows-servicing')
    $public=Assert-AtelierServicingPath (Join-Path $DataRoot 'maintenance-overview')
    New-Item -ItemType Directory -Path (Join-Path $public 'runs') -Force | Out-Null
    $task=Get-ScheduledTask -TaskName 'AtelierPXE-WindowsImageMaintenance' -ErrorAction SilentlyContinue
    $taskInfo=if($task){Get-ScheduledTaskInfo -TaskName 'AtelierPXE-WindowsImageMaintenance' -ErrorAction SilentlyContinue}else{$null}
    $categories=@()
    foreach ($name in @('backups','packages','runs')) {
        $directory=Join-Path $root $name;$bytes=0L;$count=0
        if (Test-Path -LiteralPath $directory) {
            Assert-AtelierServicingPath $directory | Out-Null
            $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($directory)
            while ($pending.Count -and $count -lt 50000) {
                foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($item.PSIsContainer) { if ($item.Name -ne 'mount') { $pending.Push($item.FullName) } }
                    else { $bytes+=$item.Length;$count++ }
                }
            }
        }
        $categories+=@{name=$name;bytes=$bytes;files=$count;complete=($count -lt 50000)}
    }
    $candidateFiles=@()
    foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $root 'runs') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 100)) {
        if ($directory.Name -notmatch '^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$') { continue }
        $candidateFile=Assert-AtelierServicingPath (Join-Path $directory.FullName 'candidate.wim')
        $present=Test-Path -LiteralPath $candidateFile -PathType Leaf
        $candidateFiles+=@{run_id=$directory.Name;present=$present;size=$(if($present){(Get-Item -LiteralPath $candidateFile).Length}else{$null})}
        $path=Assert-AtelierServicingPath (Join-Path $directory.FullName 'report.json')
        if (-not (Test-Path $path)) { continue }
        try {
            $mirror=Join-Path (Join-Path $public 'runs') ($directory.Name+'.json')
            if ((Test-Path -LiteralPath $mirror) -and (Get-Item -LiteralPath $mirror).LastWriteTimeUtc -ge (Get-Item -LiteralPath $path).LastWriteTimeUtc) { continue }
            $report=Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $mirrorTemp=$mirror+'.tmp-'+[guid]::NewGuid().ToString('N')
            try {
                [IO.File]::WriteAllText($mirrorTemp,($report | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $mirrorTemp -Destination $mirror -Force
            } finally { Remove-Item -LiteralPath $mirrorTemp -Force -ErrorAction SilentlyContinue }
        } catch { Write-Verbose ('Statut WIM non relu : '+$directory.Name) }
    }
    $snapshot=@{generated_at=[DateTime]::UtcNow.ToString('o');task_state=$(if($task){[string]$task.State}else{'NotConfigured'});last_result=$(if($taskInfo){$taskInfo.LastTaskResult}else{$null});last_run=$(if($taskInfo){$taskInfo.LastRunTime.ToUniversalTime().ToString('o')}else{$null});storage=$categories;candidates=$candidateFiles}
    Write-AtelierServicingJson $snapshot (Join-Path $public 'status.json')
}

function Get-AtelierOfflineWindowsVersion {
    param([string]$MountPath)
    $hive='AtelierWim_'+[guid]::NewGuid().ToString('N')
    & reg.exe load ('HKLM\'+$hive) (Join-Path $MountPath 'Windows\System32\config\SOFTWARE') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de lire le registre du WIM.' }
    try {
        $version=Get-ItemProperty -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\'+$hive+'\Microsoft\Windows NT\CurrentVersion')
        $release=[string]$version.DisplayVersion
        $build=[int]$version.CurrentBuildNumber
        if ($version.InstallationType -ne 'Client' -or $release -notmatch '^\d{2}H[12]$' -or $build -lt 19041) { throw 'Le WIM doit contenir un Windows 10/11 client avec DisplayVersion connue.' }
        $net=Get-ItemProperty -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\'+$hive+'\Microsoft\NET Framework Setup\NDP\v4\Full') -ErrorAction SilentlyContinue
        $dotnet=if ($net -and [int]$net.Release -ge 533320) { '4.8.1' } elseif ($net -and [int]$net.Release -ge 528040) { '4.8' } else { '' }
        return [pscustomobject]@{family=$(if ($build -ge 22000) {'11'} else {'10'});release=$release;build=$build;dotnet=$dotnet}
    } finally {
        [GC]::Collect();[GC]::WaitForPendingFinalizers()
        & reg.exe unload ('HKLM\'+$hive) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('Registre du WIM encore ouvert : HKLM\'+$hive+'. Fermer ce registre avant de demonter le WIM.') }
    }
}

function Get-AtelierServicingDism {
    param([int]$Build)
    $paths=@((Join-Path $env:SystemRoot 'System32\dism.exe'))
    if (${env:ProgramFiles(x86)}) { $paths+=(Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe') }
    # Enablement releases share the underlying servicing platform. The official
    # September 2026 ADK 26100.9457 explicitly supports Windows 11 26H2 (26300).
    $minimum=switch ($Build) {
        {$_ -in @(19042,19043,19044,19045)} { [version]'10.0.19041.0';break }
        22631 { [version]'10.0.22621.0';break }
        26200 { [version]'10.0.26100.0';break }
        26300 { [version]'10.0.26100.0';break }
        default { [version]('10.0.'+$Build+'.0') }
    }
    $tools=@($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object { [version]::new($_.VersionInfo.FileMajorPart,$_.VersionInfo.FileMinorPart,$_.VersionInfo.FileBuildPart,$_.VersionInfo.FilePrivatePart) } -Descending)
    if (-not $tools.Count) { throw 'DISM absent ; installer les outils de deploiement de l ADK.' }
    $selected=$tools[0].VersionInfo
    $version=[version]::new($selected.FileMajorPart,$selected.FileMinorPart,$selected.FileBuildPart,$selected.FilePrivatePart)
    if ($version -lt $minimum) { throw ('DISM trop ancien pour le build '+$Build+' (minimum '+$minimum+'). Mettre l ADK a jour sur .250 avant la maintenance.') }
    return $tools[0].FullName
}

function Invoke-AtelierImageDism {
    param([string]$Executable,[string[]]$Arguments,[string]$LogPath)
    $saved=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $Executable @Arguments '/English' ('/LogPath:'+$LogPath) 2>&1 | ForEach-Object {
            $line=[string]$_
            Add-Content -LiteralPath ($LogPath+'.console.log') -Value $line -Encoding UTF8 -ErrorAction Stop
            Write-Host $line
            if ($script:AtelierServicingProgress -and ([DateTime]::UtcNow-$script:AtelierServicingProgress.last).TotalSeconds -ge 10) {
                $script:AtelierServicingProgress.last=[DateTime]::UtcNow
                $script:AtelierServicingProgress.report.progress_text=$line
                $script:AtelierServicingProgress.report.updated_at=[DateTime]::UtcNow.ToString('o')
                Write-AtelierServicingJson $script:AtelierServicingProgress.report (Join-Path $script:AtelierServicingProgress.run 'report.json')
            }
        }
        $code=$LASTEXITCODE
    }
    finally { $ErrorActionPreference=$saved }
    if ($code -notin @(0,3010)) { throw ('DISM en echec (code '+$code+'). Journal : '+$LogPath) }
    return [int]$code
}

function Invoke-AtelierServicingStage {
    param($Report,[string]$Run,[string]$Name,[int]$Index=0,[scriptblock]$Action)
    $started=[DateTime]::UtcNow;$watch=[Diagnostics.Stopwatch]::StartNew();$status='failed'
    $Report.active_stage=$Name;$Report.active_index=$Index;$Report.updated_at=$started.ToString('o')
    $script:AtelierServicingProgress=@{report=$Report;run=$Run;last=$started}
    Write-AtelierServicingJson $Report (Join-Path $Run 'report.json')
    Write-Host ('Etape '+$Name+$(if($Index){' - index '+$Index}else{''}))
    try { & $Action;$status='completed' }
    finally {
        $watch.Stop()
        $Report.timings+=@{stage=$Name;index=$Index;status=$status;started_at=$started.ToString('o');duration_seconds=[math]::Round($watch.Elapsed.TotalSeconds,2)}
        $Report.updated_at=[DateTime]::UtcNow.ToString('o')
        Write-AtelierServicingJson $Report (Join-Path $Run 'report.json')
        Write-Host ('Duree '+$Name+' : '+[math]::Round($watch.Elapsed.TotalSeconds,1)+' s')
        $script:AtelierServicingProgress=$null
    }
}

function Get-AtelierServicingPlan {
    param($Version,[string]$Architecture,[string]$PythonPath,[string]$Root,[string]$OutputPath,[switch]$SelectOnly,[string]$LogPath)
    $dotnet=if ($Version.dotnet) { [string]$Version.dotnet } else { 'none' }
    $log=if ($LogPath) { $LogPath } else { [IO.Path]::ChangeExtension($OutputPath,'.log') }
    Write-AtelierServicingJson @{family=$Version.family;release=$Version.release;architecture=$Architecture;dotnet=$dotnet;build=$Version.build} ($OutputPath+'.input.json')
    $arguments=@((Join-Path $PSScriptRoot 'windows_update_catalog.py'),'--family',[string]$Version.family,'--release',[string]$Version.release,'--arch',$Architecture,'--dotnet',$dotnet,'--cache',(Join-Path $Root 'packages'),'--output',$OutputPath)
    if ($SelectOnly) { $arguments+='--select-only' }
    $saved=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $PythonPath @arguments 2>&1 | ForEach-Object {
            $line=[string]$_;Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction Stop;Write-Host $line
        }
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$saved }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        $detail=if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Encoding UTF8 -Tail 8) -join ' ' } else { 'Aucune sortie Python.' }
        throw ('Telechargement ou selection des correctifs Microsoft en echec (code '+$code+'). '+$detail+' Journal : '+$log)
    }
    return (Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Find-AtelierServicingCache {
    param([string]$Root,[string]$Hash,[string]$SourceAssetId,$Indexes,[string]$PythonPath)
    $runs=Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $runs)) { return }
    $plans=@{};$checkRoot=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
    foreach ($folder in @(Get-ChildItem -LiteralPath $runs -Directory | Sort-Object Name -Descending)) {
        if ($folder.Name -notmatch '^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$') { continue }
        $path=Join-Path $folder.FullName 'report.json'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Assert-AtelierServicingPath $path | Out-Null
        try { $previous=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($previous.status -ne 'ready_for_test' -or $previous.layout -ne 'home_pro_fast_v1') { continue }
        $upToDate=$previous.candidate_sha256 -eq $Hash
        if (-not $upToDate -and ($previous.source_sha256 -ne $Hash -or $previous.source_asset_id -ne $SourceAssetId)) { continue }
        $expected=@($Indexes | ForEach-Object { ([string]$_.ImageIndex)+'|'+$_.EditionId+'|'+$_.Architecture } | Sort-Object)
        $actual=@($previous.indexes | ForEach-Object {
            $number=if ($upToDate) { $_.index } else { $_.source_index }
            ([string]$number)+'|'+$_.edition+'|'+$(if ($_.architecture -eq 'x64') {'9'} else {'12'})
        } | Sort-Object)
        if (($expected -join ',') -ne ($actual -join ',')) { continue }
        $candidate=Assert-AtelierServicingPath ([string]$previous.candidate_path)
        if ($candidate -ne (Join-Path $folder.FullName 'candidate.wim')) { continue }
        $same=$true
        foreach ($entry in @($previous.indexes)) {
            if (-not $entry.version.release -or -not @($entry.updates).Count) { $same=$false;break }
            $key=$entry.version.family+'|'+$entry.version.release+'|'+$entry.architecture+'|'+$entry.version.dotnet
            if (-not $plans.ContainsKey($key)) {
                if (-not $checkRoot) {
                    $checkRoot=Join-Path (Join-Path $Root 'checks') ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
                    New-Item -ItemType Directory -Path $checkRoot -Force | Out-Null
                }
                $plans[$key]=Get-AtelierServicingPlan -Version $entry.version -Architecture $entry.architecture -PythonPath $PythonPath -Root $Root -OutputPath (Join-Path $checkRoot ('selection-'+$plans.Count+'.json')) -SelectOnly
            }
            $selected=@($plans[$key].groups | ForEach-Object { $_.kind+'|'+$_.id+'|'+$_.kb+'|'+$_.target_build } | Sort-Object)
            $installed=@($entry.updates | ForEach-Object { $_.kind+'|'+$_.update_id+'|'+$_.kb+'|'+$_.target_build } | Sort-Object)
            if (($selected -join ',') -ne ($installed -join ',')) { $same=$false;break }
        }
        if (-not $same) { continue }
        if ($upToDate) {
            return [pscustomobject]@{status='up_to_date';report_path=$path;source_asset_id=$SourceAssetId;check_seconds=[math]::Round($watch.Elapsed.TotalSeconds,2)}
        }
        if (-not (Test-Path -LiteralPath $candidate) -or (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $previous.candidate_sha256) { continue }
        $previous | Add-Member NoteProperty reused $true -Force
        $previous | Add-Member NoteProperty report_path $path -Force
        $previous | Add-Member NoteProperty check_seconds ([math]::Round($watch.Elapsed.TotalSeconds,2)) -Force
        return $previous
    }
}

function New-AtelierServicedWindowsImage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ImagePath,[Parameter(Mandatory)][string]$ExpectedHash,
          [Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$PythonPath,
          [Parameter(Mandatory)][string]$SourceAssetId)
    $source=Assert-AtelierServicingPath $ImagePath
    $root=Assert-AtelierServicingPath $WorkRoot
    if ([IO.Path]::GetExtension($source) -ine '.wim' -or $ExpectedHash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Source WIM ou SHA-256 invalide.' }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $held=[IO.File]::Open((Join-Path $root 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $reader=$null;$mounted=$false;$report=$null;$dism=$null;$mount=$null;$run=$null
    try {
        # Holding a read-only sharing handle prevents source replacement or writes
        # while copying. Existing deployments may continue reading the source.
        $reader=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $actual=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $ExpectedHash.ToLowerInvariant()) { throw 'Le WIM source a change depuis son enregistrement. Ne pas maintenir un fichier modifie.' }
        $summaries=@(Get-WindowsImage -ImagePath $source)
        if (-not $summaries.Count) { throw 'Aucun index Windows dans le WIM.' }
        $allIndexes=@($summaries | ForEach-Object { Get-WindowsImage -ImagePath $source -Index $_.ImageIndex })
        # Match Windows edition IDs, not translated names or unstable WIM positions.
        # N, Single Language, Education and Workstations are separate editions.
        $indexes=@($allIndexes | Where-Object { $_.EditionId -in @('Core','Professional') })
        $skipped=@($allIndexes | Where-Object { $_.EditionId -notin @('Core','Professional') })
        if (-not $indexes.Count) { throw 'Aucun index Windows Famille (Core) ou Pro (Professional) dans ce WIM.' }
        Write-Host ('Maintenance limitee a Famille et Pro : '+$indexes.Count+' index sur '+$allIndexes.Count+'.')
        foreach ($info in $skipped) { Write-Host ('Index ignore '+$info.ImageIndex+' : '+$info.ImageName+' ('+$info.EditionId+').') }
        if (@($indexes | Where-Object { [int]$_.Architecture -notin @(9,12) }).Count) { throw 'Seules les images Windows x64 ou ARM64 sont prises en charge.' }
        $maxBuild=($indexes | ForEach-Object { ([version]$_.Version).Build } | Measure-Object -Maximum).Maximum
        $dism=Get-AtelierServicingDism -Build $maxBuild
        $drive=Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).TrimEnd([char[]]'\/:')) -ErrorAction SilentlyContinue
        if ($drive -and $null -ne $drive.Free -and $drive.Free -lt ($reader.Length*3+25GB)) { throw 'Espace insuffisant : prevoir trois fois le WIM et 25 Go pour les correctifs et le montage.' }
        $cached=Find-AtelierServicingCache -Root $root -Hash $actual -SourceAssetId $SourceAssetId -Indexes $indexes -PythonPath $PythonPath
        if ($cached) { return $cached }
        $backupRoot=Join-Path $root 'backups';New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backup=Join-Path $backupRoot ($actual+'.wim')
        $id=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $run=Join-Path (Join-Path $root 'runs') $id
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        $candidate=Join-Path $run 'candidate.wim';$mount=Join-Path $run 'mount'
        $mapping=@();$target=0
        foreach ($info in $indexes) { $target++;$mapping+=@{source_index=[int]$info.ImageIndex;index=$target;edition=[string]$info.EditionId;name=[string]$info.ImageName} }
        $report=[ordered]@{schema=2;layout='home_pro_fast_v1';scope='home_pro';compression='fast';run_id=$id;status='preparing';source_asset_id=$SourceAssetId;source_path=$source;source_sha256=$actual;backup_path=$backup;candidate_path=$candidate;started_at=[DateTime]::UtcNow.ToString('o');selected_indexes=$mapping;skipped_indexes=@($skipped | ForEach-Object { @{index=[int]$_.ImageIndex;edition=[string]$_.EditionId;name=[string]$_.ImageName} });indexes=@();timings=@();active_stage='backup';active_index=0;progress_text='';updated_at=[DateTime]::UtcNow.ToString('o');error=$null}
        Write-AtelierServicingJson $report (Join-Path $run 'report.json')
        Invoke-AtelierServicingStage -Report $report -Run $run -Name 'backup' -Action {
        if (Test-Path -LiteralPath $backup) {
            Assert-AtelierServicingPath $backup | Out-Null
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ine $actual) { throw 'Sauvegarde existante corrompue ; aucun remplacement automatique.' }
        } else {
            $temporary=$backup+'.partial'
            Assert-AtelierServicingPath $temporary | Out-Null
            try {
                Copy-Item -LiteralPath $source -Destination $temporary
                if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $actual) { throw 'Verification de sauvegarde en echec.' }
                Move-Item -LiteralPath $temporary -Destination $backup
            } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
        } | Out-Null
        foreach ($entry in $mapping) {
            Invoke-AtelierServicingStage -Report $report -Run $run -Name 'export_fast' -Index $entry.index -Action {
                Invoke-AtelierImageDism $dism @('/Export-Image',('/SourceImageFile:'+$backup),('/SourceIndex:'+$entry.source_index),('/DestinationImageFile:'+$candidate),'/Compress:fast','/CheckIntegrity') (Join-Path $run ('export-index-'+$entry.index+'.log')) | Out-Null
            } | Out-Null
        }
        $reader.Dispose();$reader=$null
        New-Item -ItemType Directory -Path $mount | Out-Null
        $plans=@{}
        foreach ($entry in $mapping) {
            $info=@($indexes | Where-Object { [int]$_.ImageIndex -eq $entry.source_index })[0]
            $index=[int]$entry.index;$log=Join-Path $run ('dism-index-'+$index+'.log')
            Write-Host ('Maintenance de l index '+$index+' : '+$info.ImageName)
            # Mark before calling DISM: even a failed mount may need discarding.
            $mounted=$true
            Invoke-AtelierServicingStage -Report $report -Run $run -Name 'mount' -Index $index -Action {
                Invoke-AtelierImageDism $dism @('/Mount-Image',('/ImageFile:'+$candidate),('/Index:'+$index),('/MountDir:'+$mount),'/CheckIntegrity') $log | Out-Null
            } | Out-Null
            $version=Get-AtelierOfflineWindowsVersion $mount
            $arch=if ([int]$info.Architecture -eq 9) {'x64'} else {'arm64'}
            $planPath=Join-Path $run ('updates-index-'+$index+'.json')
            $dotnet=if ($version.dotnet) { $version.dotnet } else { 'none' }
            $planKey=$version.family+'-'+$version.release+'-'+$arch+'-'+$dotnet
            if (-not $plans.ContainsKey($planKey)) {
                $catalogLog=Join-Path $run ('catalog-index-'+$index+'.log')
                Write-AtelierServicingJson @{family=$version.family;release=$version.release;architecture=$arch;dotnet=$dotnet;build=$version.build} (Join-Path $run ('catalog-input-index-'+$index+'.json'))
                Write-Host ('Catalogue Microsoft : Windows '+$version.family+' '+$version.release+' '+$arch+' ; .NET '+$dotnet+'. Journal : '+$catalogLog)
                $plans[$planKey]=Invoke-AtelierServicingStage -Report $report -Run $run -Name 'catalog_download' -Index $index -Action {
                    Get-AtelierServicingPlan -Version $version -Architecture $arch -PythonPath $PythonPath -Root $root -OutputPath $planPath -LogPath $catalogLog
                }
            } else { Write-AtelierServicingJson $plans[$planKey] $planPath }
            $plan=$plans[$planKey]
            $steps=@()
            foreach ($group in @($plan.groups)) {
                Write-Host ('Integration '+$group.kb+' : '+$group.title)
                foreach ($file in @($group.files)) {
                    if ((Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ine $file.sha256) { throw ('Paquet modifie avant integration : '+$file.path) }
                }
                # The target's folder contains only its MSU and the checkpoints
                # returned by Microsoft. DISM resolves their required order.
                $code=Invoke-AtelierServicingStage -Report $report -Run $run -Name ('integrate_'+$group.kb) -Index $index -Action {
                    Invoke-AtelierImageDism $dism @(('/Image:'+$mount),'/Add-Package',('/PackagePath:'+$group.target_path),'/NoRestart') $log
                }
                $steps+=@{kind=$group.kind;update_id=$group.id;kb=$group.kb;title=$group.title;exit_code=$code;files=@($group.files);target_build=$group.target_build}
            }
            $packages=@(Get-WindowsPackage -Path $mount)
            if (-not $packages.Count -or @($packages | Where-Object { [string]$_.PackageState -in @('PartiallyInstalled','UninstallPending') }).Count) { throw 'Etat des paquets Windows incoherent apres integration.' }
            $packages | Select-Object PackageName,PackageState,ReleaseType,InstallTime | Export-Csv -LiteralPath (Join-Path $run ('packages-index-'+$index+'.csv')) -NoTypeInformation -Encoding UTF8
            Invoke-AtelierServicingStage -Report $report -Run $run -Name 'commit' -Index $index -Action {
                Invoke-AtelierImageDism $dism @('/Unmount-Image',('/MountDir:'+$mount),'/Commit','/CheckIntegrity') $log | Out-Null
            } | Out-Null
            $mounted=$false
            $report.indexes+=@{source_index=[int]$entry.source_index;index=$index;name=[string]$info.ImageName;edition=[string]$info.EditionId;version=$version;architecture=$arch;updates=$steps;package_count=$packages.Count}
            Write-AtelierServicingJson $report (Join-Path $run 'report.json')
        }
        # Read back the committed WIM. Source and its recorded hash stay intact.
        if (@(Get-WindowsImage -ImagePath $candidate).Count -ne $mapping.Count) { throw 'Le WIM final doit contenir uniquement les index Famille et Pro exportes.' }
        foreach ($entry in $mapping) {
            if ((Get-WindowsImage -ImagePath $candidate -Index $entry.index).EditionId -ne $entry.edition) { throw 'Edition du WIM exporte incorrecte ; aucune publication.' }
        }
        $report['candidate_sha256']=Invoke-AtelierServicingStage -Report $report -Run $run -Name 'verify_hash' -Action {
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $report['finished_at']=[DateTime]::UtcNow.ToString('o')
        $report.status='ready_for_test'
        $report.active_stage='ready_for_test';$report.active_index=0
        Write-AtelierServicingJson $report (Join-Path $run 'report.json')
        return [pscustomobject]$report
    } catch {
        $failure=$_.Exception.Message
        if ($mounted -and $dism) {
            try { Invoke-AtelierImageDism $dism @('/Unmount-Image',('/MountDir:'+$mount),'/Discard') (Join-Path $run 'discard.log') | Out-Null;$mounted=$false }
            catch { $failure+=' Demontage en echec : '+$_.Exception.Message }
        }
        if ($report) {
            $report.status=if ($mounted) {'failed_cleanup_required'} else {'failed'}
            $report.error=$failure
            Write-AtelierServicingJson $report (Join-Path $run 'report.json')
            # Never recursively delete a mounted Windows directory.
            if (-not $mounted -and (Test-Path -LiteralPath $report.candidate_path)) { Remove-Item -LiteralPath $report.candidate_path -Force }
        }
        throw $failure
    } finally {
        if ($reader) { $reader.Dispose() };$held.Dispose()
    }
}
