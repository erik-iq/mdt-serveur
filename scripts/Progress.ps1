#requires -Version 5.1
param([string]$DataPath = 'C:\ProgramData\AtelierPXE')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$mutex = New-Object Threading.Mutex($false,'Local\AtelierPXE-Progress')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return }
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'Atelier PXE | Preparation de Windows'
$form.ClientSize = New-Object Drawing.Size(720,390)
$form.StartPosition='CenterScreen'; $form.BackColor=[Drawing.ColorTranslator]::FromHtml('#F5F8F6')
$form.Font = New-Object Drawing.Font('Segoe UI',11)
$title=New-Object Windows.Forms.Label
$title.Text='Preparation de votre poste'; $title.Location=New-Object Drawing.Point(24,22); $title.Size=New-Object Drawing.Size(610,36)
$title.Font=New-Object Drawing.Font('Segoe UI',20,[Drawing.FontStyle]::Bold)
$message=New-Object Windows.Forms.Label
$message.Text='Chargement de la progression...';$message.Location=New-Object Drawing.Point(25,80);$message.Size=New-Object Drawing.Size(670,90)
$bar=New-Object Windows.Forms.ProgressBar
$bar.Location=New-Object Drawing.Point(25,174);$bar.Size=New-Object Drawing.Size(670,24);$bar.Maximum=100
$note=New-Object Windows.Forms.Label
$note.Text='Logiciels, bureau et mises a jour. Des redemarrages automatiques peuvent suivre.'
$note.Location=New-Object Drawing.Point(25,210);$note.Size=New-Object Drawing.Size(670,45);$note.Font=New-Object Drawing.Font('Segoe UI',9)
$details=New-Object Windows.Forms.TextBox
$details.Location=New-Object Drawing.Point(25,263);$details.Size=New-Object Drawing.Size(670,95)
$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical'
$form.Controls.AddRange(@($title,$message,$bar,$note,$details))
$script:lastMessage=''
$script:lastRead=[DateTime]::MinValue
$started=Get-Date
$timer=New-Object Windows.Forms.Timer
$timer.Interval=1000
$timer.Add_Tick({
    try {
        $state=Get-Content (Join-Path $DataPath 'progress.json') -Raw | ConvertFrom-Json
        $message.Text=$state.message
        $elapsed=(Get-Date)-$started
        $note.Text='Session : ' + $elapsed.ToString('hh\:mm\:ss') + ' | Des redemarrages automatiques peuvent suivre.'
        if ($state.detail -and $state.status -eq 'running') {
            if ($state.detail.percent -lt 0) { $bar.Style='Marquee';$note.Text += ' Recherche : duree variable.' }
            else { $bar.Style='Continuous';$bar.Value=[math]::Max(0,[math]::Min(100,[int]$state.detail.percent));$note.Text += ' Avancement de cette etape : ' + $state.detail.percent + ' %.' }
        } else { $bar.Style='Continuous';$bar.Value=[math]::Max(0,[math]::Min(100,[int]$state.progress)) }
        if ($state.message -ne $script:lastMessage) { $details.AppendText((Get-Date -Format 'HH:mm:ss') + ' ' + $state.message + "`r`n");$script:lastMessage=$state.message }
        if ($state.status -eq 'completed') { $title.Text='Preparation terminee';$note.Text='Rapport : C:\IQ_\Rapport-Deploiement.pdf. HP Image Assistant va s ouvrir sur les HP equipes.'; $timer.Stop() }
        elseif ($state.status -in @('failed','needs_attention')) { $title.Text='Preparation a verifier'; $timer.Stop() }
    } catch { $message.Text='En attente de la prochaine etape...' }
})
$timer.Start()
try { [void]$form.ShowDialog() }
finally { $timer.Dispose();$form.Dispose();$mutex.ReleaseMutex();$mutex.Dispose() }
