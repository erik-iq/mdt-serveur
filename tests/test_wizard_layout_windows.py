"""Measure real WinForms bounds on Windows; never start a deployment."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=shutil.which('powershell') or os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(os.name!='nt' or not PWSH,reason='Real Windows Forms required')


@pytest.mark.parametrize(('width','height'),[(640,480),(800,600),(1024,768),(1366,768),(1920,1080)])
def test_maximized_start_wrapped_header_and_live_resize_preserve_progress(tmp_path,width,height):
    script=tmp_path/'layout.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. 'PROJECT/scripts/Theme.ps1'
$accent=Get-AtelierColor 'accent';$ink=Get-AtelierColor 'ink';$paper=Get-AtelierColor 'paper';$muted=Get-AtelierColor 'muted'
$Config=@{boot_release='TEST'};$script:steps=@('Connexion','Windows','Poste & région','Logiciels & bureau','Récapitulatif','Installation')
$script:page=5;$script:running=$false;$script:resizing=$false
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('PROJECT/scripts/Wizard.ps1',[ref]$tokens,[ref]$errors)
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $node.Extent.Text }
$building=$false
foreach ($node in $ast.EndBlock.Statements) {
 if ($node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$form') { $building=$true }
 if ($node.Extent.Text.StartsWith('$script:back.Add_Click')) { break }
 if ($building) { Invoke-Expression $node.Extent.Text }
}
$closing=$ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('$form.Add_FormClosing') }
Invoke-Expression $closing.Extent.Text
try {
 $maximized=$form.WindowState -eq 'Maximized'
 $form.Show();$form.WindowState='Normal'
 $form.ClientSize=New-Object Drawing.Size(WIDTH,HEIGHT)
 Show-Page
 $script:progress.Value=57;$script:logs.Text='Journal conserve pendant le redimensionnement'
 $logControl=$script:logs
 foreach ($w in @([math]::Max(640,WIDTH-140),WIDTH)) {
  $form.ClientSize=New-Object Drawing.Size($w,HEIGHT)
  Update-WizardLayout
  [Windows.Forms.Application]::DoEvents()
 }
 $script:description.Text='Application de Windows et preparation du premier demarrage. Les logiciels seront installes dans Windows apres le redemarrage automatique.'
 Update-WizardLayout
 [Windows.Forms.Application]::DoEvents()
 $headerFits=$script:description.Bottom -le $header.ClientSize.Height-$header.Padding.Bottom
 $rowsSeparate=$header.Bottom -le $script:body.Top
 $overflow=@($script:body.Controls | Where-Object { $_.Right -gt $script:body.ClientSize.Width }).Count
 $script:running=$true
 $raise=$form.GetType().GetMethod('OnFormClosing',[Reflection.BindingFlags]'Instance,NonPublic')
 $userClose=New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing,$false)
 $shutdown=New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::WindowsShutDown,$false)
 $raise.Invoke($form,@($userClose));$raise.Invoke($form,@($shutdown))
 if (-not $userClose.Cancel -or $shutdown.Cancel) { throw 'Window close guard vetoed reboot or allowed an accidental close' }
 @{maximized=$maximized;header_fits=$headerFits;separate=$rowsSeparate;overflow=$overflow;progress=$script:progress.Value;same_log=($script:logs -eq $logControl);text=$script:logs.Text;logo_width=$headerLogo.Width;button_visible=($buttons.Bottom -le $main.ClientSize.Height)} | ConvertTo-Json -Compress
} finally { $form.Dispose() }
'''.replace('PROJECT',str(ROOT).replace("'","''")).replace('WIDTH',str(width)).replace('HEIGHT',str(height)))
    run=subprocess.run([PWSH,'-NoProfile','-STA','-File',str(script)],capture_output=True,text=True,timeout=40)
    assert run.returncode==0,run.stdout+run.stderr
    result=json.loads(run.stdout.splitlines()[-1])
    assert result['maximized'] and result['header_fits'] and result['separate'] and result['button_visible'],result
    assert result['overflow']==0 and result['progress']==57 and result['same_log'],result
    assert result['text']=='Journal conserve pendant le redimensionnement'
    assert result['logo_width']<=80
