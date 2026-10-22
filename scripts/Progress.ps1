#requires -Version 5.1
param([string]$DataPath = 'C:\ProgramData\AtelierPXE')
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$mutex = New-Object Threading.Mutex($false,'Local\AtelierPXE-Progress')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return }
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'Theme.ps1')
$form = New-Object Windows.Forms.Form
$form.Text = 'IQ Atelier | Préparation en arrière-plan'
$form.ClientSize = New-Object Drawing.Size(720,390)
$form.StartPosition='CenterScreen'; $form.BackColor=Get-AtelierColor 'paper'
$form.Font = New-AtelierFont -Size 11
$title=New-Object Windows.Forms.Label
$header=New-Object Windows.Forms.Panel
$header.Location=New-Object Drawing.Point(12,8);$header.Size=New-Object Drawing.Size(696,60)
$logo=New-AtelierLogo;$logo.Location=New-Object Drawing.Point(646,10)
$title.Text='Préparation du poste'; $title.Location=New-Object Drawing.Point(13,13); $title.Size=New-Object Drawing.Size(610,38)
$title.Font=New-AtelierFont -Size 20 -Bold $true
$message=New-Object Windows.Forms.Label
$message.Text='Chargement de la progression...';$message.Location=New-Object Drawing.Point(25,80);$message.Size=New-Object Drawing.Size(670,90)
$bar=New-Object Windows.Forms.ProgressBar
$bar.Location=New-Object Drawing.Point(25,174);$bar.Size=New-Object Drawing.Size(670,24);$bar.Maximum=100
$note=New-Object Windows.Forms.Label
$note.Text='Votre bureau est disponible. Vous pouvez réduire cette fenêtre.'
$note.Location=New-Object Drawing.Point(25,210);$note.Size=New-Object Drawing.Size(670,45);$note.Font=New-AtelierFont -Size 9
$details=New-Object Windows.Forms.TextBox
$details.Location=New-Object Drawing.Point(25,263);$details.Size=New-Object Drawing.Size(670,95)
$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical'
$header.Controls.AddRange(@($logo,$title))
$form.Controls.AddRange(@($header,$message,$bar,$note,$details))
Set-AtelierFormTheme $form
Set-AtelierGradient $header
$title.BackColor=[Drawing.Color]::Transparent;$logo.BackColor=[Drawing.Color]::Transparent
$form.MinimizeBox=$true;$form.MaximizeBox=$false
# Les styles visuels natifs imposent sinon le vert Windows à la progression.
Set-AtelierProgressTheme $bar
$script:lastMessage=''
$script:lastRead=[DateTime]::MinValue
$started=Get-Date
$timer=New-Object Windows.Forms.Timer
$timer.Interval=1000
$timer.Add_Tick({
    try {
        $path=Join-Path $DataPath 'progress.json'
        if (Test-Path $path) { $state=Get-Content $path -Encoding UTF8 -Raw | ConvertFrom-Json }
        else {
            $report=Get-Content 'C:\IQ_\Rapports\Rapport-Deploiement.json' -Encoding UTF8 -Raw | ConvertFrom-Json
            $state=[pscustomobject]@{status=$report.status;progress=100;detail=$null;message='Préparation archivee. Consulter le rapport et les journaux sur Atelier PXE.'}
        }
        $message.Text=$state.message
        $elapsed=(Get-Date)-$started
        $note.Text='Session : ' + $elapsed.ToString('hh\:mm\:ss') + ' | Bureau disponible ; préparation en arrière-plan.'
        if ($state.detail -and $state.status -eq 'running') {
            if ($state.detail.percent -lt 0) { $bar.Style='Marquee';$note.Text += ' Traitement en cours ; durée variable selon le téléchargement et les pilotes.' }
            else { $bar.Style='Continuous';$bar.Value=[math]::Max(0,[math]::Min(100,[int]$state.detail.percent));$note.Text += ' Avancement de cette étape : ' + $state.detail.percent + ' %.' }
        } else { $bar.Style='Continuous';$bar.Value=[math]::Max(0,[math]::Min(100,[int]$state.progress)) }
        if ($state.message -ne $script:lastMessage) { $details.AppendText((Get-Date -Format 'HH:mm:ss') + ' ' + $state.message + "`r`n");$script:lastMessage=$state.message }
        if ($state.status -eq 'completed') { $title.Text='Préparation terminée';$note.Text='Rapport : C:\IQ_\Rapports\Rapport-Deploiement.pdf. Windows Update et Microsoft Store : à lancer manuellement.'; $timer.Stop() }
        elseif ($state.status -in @('failed','needs_attention')) { $title.Text='Préparation à vérifier'; $timer.Stop() }
    } catch { $message.Text='En attente de la prochaine étape...' }
})
$timer.Start()
try { [void]$form.ShowDialog() }
finally { $timer.Dispose();$form.Dispose();$mutex.ReleaseMutex();$mutex.Dispose() }
