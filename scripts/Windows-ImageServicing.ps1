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
    $temporary=$Path+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
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
    try { $ErrorActionPreference='Continue';$output=@(& $Executable @Arguments '/English' ('/LogPath:'+$LogPath) 2>&1);$code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$saved }
    $output | ForEach-Object { [string]$_ } | Add-Content -LiteralPath ($LogPath+'.console.log') -Encoding UTF8
    if ($code -notin @(0,3010)) { throw ('DISM en echec (code '+$code+'). Journal : '+$LogPath) }
    return [int]$code
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
        $backupRoot=Join-Path $root 'backups';New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backup=Join-Path $backupRoot ($actual+'.wim')
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
        $id=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $run=Join-Path (Join-Path $root 'runs') $id
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        $candidate=Join-Path $run 'candidate.wim';$mount=Join-Path $run 'mount'
        $report=[ordered]@{schema=1;run_id=$id;status='preparing';source_asset_id=$SourceAssetId;source_path=$source;source_sha256=$actual;backup_path=$backup;candidate_path=$candidate;started_at=[DateTime]::UtcNow.ToString('o');selected_indexes=@($indexes | ForEach-Object { @{index=[int]$_.ImageIndex;edition=[string]$_.EditionId;name=[string]$_.ImageName} });skipped_indexes=@($skipped | ForEach-Object { @{index=[int]$_.ImageIndex;edition=[string]$_.EditionId;name=[string]$_.ImageName} });indexes=@();error=$null}
        Write-AtelierServicingJson $report (Join-Path $run 'report.json')
        Copy-Item -LiteralPath $backup -Destination $candidate
        (Get-Item -LiteralPath $candidate).IsReadOnly=$false
        $reader.Dispose();$reader=$null
        New-Item -ItemType Directory -Path $mount | Out-Null
        $plans=@{}
        foreach ($info in $indexes) {
            $index=[int]$info.ImageIndex;$log=Join-Path $run ('dism-index-'+$index+'.log')
            Write-Host ('Maintenance de l index '+$index+' : '+$info.ImageName)
            # Mark before calling DISM: even a failed mount may need discarding.
            $mounted=$true
            Invoke-AtelierImageDism $dism @('/Mount-Image',('/ImageFile:'+$candidate),('/Index:'+$index),('/MountDir:'+$mount),'/CheckIntegrity') $log | Out-Null
            $version=Get-AtelierOfflineWindowsVersion $mount
            $arch=if ([int]$info.Architecture -eq 9) {'x64'} else {'arm64'}
            $planPath=Join-Path $run ('updates-index-'+$index+'.json')
            $dotnet=if ($version.dotnet) { $version.dotnet } else { 'none' }
            $planKey=$version.family+'-'+$version.release+'-'+$arch+'-'+$dotnet
            if (-not $plans.ContainsKey($planKey)) {
                $catalogLog=Join-Path $run ('catalog-index-'+$index+'.log')
                Write-AtelierServicingJson @{family=$version.family;release=$version.release;architecture=$arch;dotnet=$dotnet;build=$version.build} (Join-Path $run ('catalog-input-index-'+$index+'.json'))
                Write-Host ('Catalogue Microsoft : Windows '+$version.family+' '+$version.release+' '+$arch+' ; .NET '+$dotnet+'. Journal : '+$catalogLog)
                $savedPreference=$ErrorActionPreference
                try {
                    # PS 5.1 surfaces native stderr as error records. Preserve it
                    # as text without interrupting Python before its exit code.
                    $ErrorActionPreference='Continue'
                    & $PythonPath (Join-Path $PSScriptRoot 'windows_update_catalog.py') --family $version.family --release $version.release --arch $arch --dotnet $dotnet --cache (Join-Path $root 'packages') --output $planPath 2>&1 | ForEach-Object {
                        $line=[string]$_
                        Add-Content -LiteralPath $catalogLog -Value $line -Encoding UTF8 -ErrorAction Stop
                        Write-Host $line
                    }
                    $catalogExitCode=$LASTEXITCODE
                } finally { $ErrorActionPreference=$savedPreference }
                if ($catalogExitCode -ne 0 -or -not (Test-Path -LiteralPath $planPath)) {
                    $detail=if (Test-Path -LiteralPath $catalogLog) { (Get-Content -LiteralPath $catalogLog -Encoding UTF8 -Tail 8) -join ' ' } else { 'Aucune sortie Python.' }
                    throw ('Telechargement ou selection des correctifs Microsoft en echec (code '+$catalogExitCode+'). '+$detail+' Journal : '+$catalogLog)
                }
                $plans[$planKey]=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
                $code=Invoke-AtelierImageDism $dism @(('/Image:'+$mount),'/Add-Package',('/PackagePath:'+$group.target_path),'/NoRestart') $log
                $steps+=@{kind=$group.kind;kb=$group.kb;title=$group.title;exit_code=$code;files=@($group.files);target_build=$group.target_build}
            }
            $packages=@(Get-WindowsPackage -Path $mount)
            if (-not $packages.Count -or @($packages | Where-Object { [string]$_.PackageState -in @('PartiallyInstalled','UninstallPending') }).Count) { throw 'Etat des paquets Windows incoherent apres integration.' }
            $packages | Select-Object PackageName,PackageState,ReleaseType,InstallTime | Export-Csv -LiteralPath (Join-Path $run ('packages-index-'+$index+'.csv')) -NoTypeInformation -Encoding UTF8
            Invoke-AtelierImageDism $dism @('/Unmount-Image',('/MountDir:'+$mount),'/Commit','/CheckIntegrity') $log | Out-Null
            $mounted=$false
            $report.indexes+=@{index=$index;name=[string]$info.ImageName;edition=[string]$info.EditionId;version=$version;architecture=$arch;updates=$steps;package_count=$packages.Count}
            Write-AtelierServicingJson $report (Join-Path $run 'report.json')
        }
        # Read back the committed WIM. Source and its recorded hash stay intact.
        if (@(Get-WindowsImage -ImagePath $candidate).Count -ne $allIndexes.Count) { throw 'Le WIM final ne contient plus tous ses index.' }
        $report['candidate_sha256']=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        $report['finished_at']=[DateTime]::UtcNow.ToString('o')
        $report.status='ready_for_test'
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
