"""Real PowerShell bootstrap + fresh child; PSGallery and Task Scheduler are fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH or os.name=='nt',reason='PowerShell/Linux native child fixture required')


def ps(value):return str(value).replace("'","''")


def module(path,name,version,source,exports):
    target=path/name/version;target.mkdir(parents=True)
    (target/(name+'.psm1')).write_text(source)
    (target/(name+'.psd1')).write_text("@{RootModule='"+name+".psm1';ModuleVersion='"+version+"';FunctionsToExport=@("+','.join("'"+e+"'" for e in exports)+");CmdletsToExport=@();AliasesToExport=@()}\n")
    return target/(name+'.psd1')


@pytest.mark.parametrize('case',['old','modern','installed','bootstrap_failure','child_failure','missing_command','running_worker'])
def test_setup_handles_old_powershellget_and_reports_real_readiness(tmp_path,case):
    console=tmp_path/'Console with spaces';scripts=console/'scripts';scripts.mkdir(parents=True)
    for name in ['Enable-HPRepository.ps1','Console-Installation.ps1','HP-Repository.ps1']:
        shutil.copy(ROOT/'scripts'/name,scripts/name)
    data=tmp_path/'data';(data/'hp-repository').mkdir(parents=True)
    (data/'hp-repository'/'worker-key').write_text('fixture-local-key-not-a-real-credential')
    (console/'data-runtime.json').write_text(json.dumps({'data_dir':str(data)}))
    program=tmp_path/'Program Files';modules=program/'WindowsPowerShell'/'Modules'
    modules.mkdir(parents=True)
    hp_names=['Initialize-HPRepository','Set-HPRepositoryConfiguration','Add-HPRepositoryFilter','Invoke-HPRepositorySync','Invoke-HPRepositoryCleanup']
    hp_source=tmp_path/'hp-source';hp_source.mkdir()
    (hp_source/'HPCMSL.psm1').write_text('\n'.join('function '+n+' {}' for n in hp_names if case!='missing_command' or n!=hp_names[-1]))
    (hp_source/'HPCMSL.psd1').write_text("@{RootModule='HPCMSL.psm1';ModuleVersion='1.9.0';FunctionsToExport=@('*');CmdletsToExport=@();AliasesToExport=@()}\n")
    modern=r'''
function Install-Module {
 [CmdletBinding()]param($Name,$RequiredVersion,$Repository,$Scope,[switch]$AcceptLicense,[switch]$Force,[switch]$AllowClobber,[switch]$Confirm)
 @{kind='install';name=$Name;version='2.2.5';process=$PID;accept=[bool]$AcceptLicense}|ConvertTo-Json -Compress|Add-Content $env:FixtureCalls
 if ($Name -ne 'HPCMSL' -or $RequiredVersion -ne '1.9.0' -or $Repository -ne 'PSGallery' -or $Scope -ne 'AllUsers' -or -not $AcceptLicense) { throw 'Wrong HP install parameters' }
 if ($env:FixtureCase -eq 'child_failure') { throw 'Fixture CMSL download failure' }
 $target=Join-Path $env:FixtureModuleRoot 'HPCMSL/1.9.0'
 New-Item -ItemType Directory -Path $target -Force|Out-Null
 Copy-Item (Join-Path $env:FixtureHpSource '*') $target
}
Export-ModuleMember -Function Install-Module
'''
    modern_source=tmp_path/'modern-source.psm1';modern_source.write_text(modern)
    legacy=r'''
function Install-Module {
 [CmdletBinding()]param($Name,$RequiredVersion,$Repository,$Scope,[switch]$Force,[switch]$AllowClobber,[switch]$Confirm)
 @{kind='install';name=$Name;version='1.0.0.1';process=$PID;accept=$false}|ConvertTo-Json -Compress|Add-Content $env:FixtureCalls
 if ($Name -ne 'PowerShellGet' -or $RequiredVersion -ne '2.2.5' -or $Repository -ne 'PSGallery' -or $Scope -ne 'AllUsers') { throw 'Old installer must only bootstrap PowerShellGet' }
 if ($env:FixtureCase -eq 'bootstrap_failure') { throw 'Fixture PowerShellGet download failure' }
 $target=Join-Path $env:FixtureModuleRoot 'PowerShellGet/2.2.5'
 New-Item -ItemType Directory -Path $target -Force|Out-Null
 Copy-Item $env:FixtureModernSource (Join-Path $target 'PowerShellGet.psm1')
 "@{RootModule='PowerShellGet.psm1';ModuleVersion='2.2.5';FunctionsToExport=@('Install-Module');CmdletsToExport=@();AliasesToExport=@()}"|Set-Content (Join-Path $target 'PowerShellGet.psd1')
}
Export-ModuleMember -Function Install-Module
'''
    installer=module(modules,'PowerShellGet','1.0.0.1',legacy,['Install-Module'])
    if case=='modern':installer=module(modules,'PowerShellGet','2.2.5',modern,['Install-Module'])
    if case in {'installed','missing_command'}:
        hp_target=modules/'HPCMSL'/'1.9.0';shutil.copytree(hp_source,hp_target)
    system=tmp_path/'Windows';native=system/'System32'/'WindowsPowerShell'/'v1.0'/'powershell.exe';native.parent.mkdir(parents=True)
    native.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execv('+repr(str(PWSH))+',['+repr(str(PWSH))+']+sys.argv[1:])\n');native.chmod(0o755)
    calls=tmp_path/'calls.jsonl'
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
$env:ProgramFiles='PROGRAM'
$env:SystemRoot='__SYSTEM_ROOT__'
$env:PSModulePath='MODULES'+[IO.Path]::PathSeparator+$env:PSModulePath
$env:FixtureCalls='CALLS';$env:FixtureModuleRoot='MODULES';$env:FixtureHpSource='HP';$env:FixtureModernSource='MODERN';$env:FixtureCase='CASE'
function Install-PackageProvider { [CmdletBinding()]param($Name,$MinimumVersion,$Scope,[switch]$Force,[switch]$Confirm);if($Name -ne 'NuGet'){throw 'Wrong provider'} }
function Get-ScheduledTask { [CmdletBinding()]param($TaskName);if('CASE' -eq 'running_worker'){[pscustomobject]@{State='Running'}} }
function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory);[pscustomobject]@{Exécute=$Execute;Argument=$Argument}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);if($UserId -ne 'SYSTEM'){throw 'Wrong worker account'};[pscustomobject]@{UserId=$UserId}}
function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,$RestartCount,$RestartInterval,$MultipleInstances,[switch]$StartWhenAvailable);[pscustomobject]@{}}
function New-ScheduledTaskTrigger {param([switch]$AtStartup);if(-not $AtStartup){throw 'Missing startup trigger'};[pscustomobject]@{}}
function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,$Description,[switch]$Force);Add-Content 'TASKS' ('registered '+$TaskName)}
function Start-ScheduledTask {param($TaskName);Add-Content 'TASKS' ('started '+$TaskName)}
Import-Module 'INSTALLER' -Force
@{kind='parent';process=$PID}|ConvertTo-Json -Compress|Add-Content 'CALLS'
& 'SCRIPT' -InstallPath 'CONSOLE'
'''.replace('PROGRAM',ps(program)).replace('__SYSTEM_ROOT__',ps(system)).replace('MODULES',ps(modules)).replace('CALLS',ps(calls)).replace('HP',ps(hp_source)).replace('MODERN',ps(modern_source)).replace('CASE',case).replace('TASKS',ps(tmp_path/'tasks')).replace('INSTALLER',ps(installer)).replace('SCRIPT',ps(scripts/'Enable-HPRepository.ps1')).replace('CONSOLE',ps(console)))
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=40)
    assert run.returncode==0,run.stderr+run.stdout
    events=[json.loads(line) for line in calls.read_text().splitlines()]
    installs=[e for e in events if e['kind']=='install']
    success=case not in {'bootstrap_failure','child_failure','missing_command'}
    assert ('CMSL charge et commandes vérifiées.' in run.stdout)==success,run.stdout
    if success:assert not (data/'hp-repository'/'setup.log').exists()
    else:
        log=(data/'hp-repository'/'setup.log').read_text(encoding='utf-8-sig')
        assert ('mise à niveau de PowerShellGet' if case=='bootstrap_failure' else 'installation de HPCMSL' if case=='child_failure' else 'vérification des commandes') in log
        assert 'Fixture' in log if case!='missing_command' else 'Commande CMSL absente' in log
        assert 'CMSL indisponible' in run.stdout
    if case in {'installed','missing_command'}:assert not installs
    elif case=='bootstrap_failure':assert [i['name'] for i in installs]==['PowerShellGet']
    else:
        assert [i['name'] for i in installs]==(['HPCMSL'] if case=='modern' else ['PowerShellGet','HPCMSL'])
        hp=installs[-1]
        assert hp['accept'] and hp['process']!=events[0]['process']
    if case=='running_worker':assert not (tmp_path/'tasks').exists()
    else:assert (tmp_path/'tasks').read_text().splitlines()==['registered AtelierPXE-HpRepository','started AtelierPXE-HpRepository']
