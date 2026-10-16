#requires -Version 5.1
param([string]$OutputDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'

function Get-AtelierWarrantyMonths {
    param([datetime]$Start,[datetime]$End)
    if ($End -le $Start) { return 0 }
    $months=($End.Year-$Start.Year)*12+$End.Month-$Start.Month
    if ($Start.AddMonths($months) -gt $End) { $months-- }
    return [math]::Max(0,$months)
}

function Save-AtelierWarranty {
    param($Report,[string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Directory 'Garantie.json') -Encoding UTF8
    @('VERIFICATION DE GARANTIE',('Poste : ' + $Report.ordinateur),('Constructeur : ' + $Report.constructeur),('Modele : ' + $Report.modele),('Numero de serie : ' + $Report.numero_serie),('Produit / SKU : ' + $Report.produit),('Source : ' + $Report.source_url),('Etat : ' + $Report.statut),('Date de verification : ' + $Report.verifie_le),('Debut : ' + $Report.debut),('Fin : ' + $Report.fin),('Mois complets de couverture : ' + $Report.mois_couverture),('Mois complets restants : ' + $Report.mois_restants),('Jours restants : ' + $Report.jours_restants),('Observation : ' + $Report.observation),'Les dates sont confirmees par l operateur depuis le portail constructeur. Une page ouverte seule ne verifie pas la garantie.') | Set-Content (Join-Path $Directory 'Garantie.txt') -Encoding UTF8
}

# Loading just the functions is supported for date calculation tests.
if ($MyInvocation.InvocationName -eq '.') { return }
$computer=Get-CimInstance Win32_ComputerSystem
$bios=Get-CimInstance Win32_BIOS
$serial=[string]$bios.SerialNumber
$url=switch -Regex ([string]$computer.Manufacturer) {
    '(^HP\b|Hewlett[- ]Packard)' { 'https://support.hp.com/fr-fr/check-warranty';break }
    '^LENOVO\b' { 'https://pcsupport.lenovo.com/fr/fr/warranty-lookup';break }
    '^Dell\b' { 'https://www.dell.com/support/home/fr-fr?app=warranty';break }
    default { '' }
}
$report=[ordered]@{ordinateur=$env:COMPUTERNAME;constructeur=[string]$computer.Manufacturer;modele=[string]$computer.Model;produit=[string]$computer.SystemSKUNumber;numero_serie=$serial;source_url=$url;statut='non_verifie';verifie_le='';debut='';fin='';mois_couverture=$null;mois_restants=$null;jours_restants=$null;observation='Dates non confirmees sur le site constructeur.'}
$previous=$null
if (Test-Path (Join-Path $OutputDirectory 'Garantie.json')) {
    try { $previous=Get-Content (Join-Path $OutputDirectory 'Garantie.json') -Raw | ConvertFrom-Json } catch { }
}
if (-not $previous -or $previous.numero_serie -ne $serial) { Save-AtelierWarranty $report $OutputDirectory }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'Theme.ps1')
$form=New-Object Windows.Forms.Form
$form.Text='IQ | Garantie constructeur';$form.ClientSize=New-Object Drawing.Size(660,420);$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$label=New-Object Windows.Forms.Label
$logo=New-AtelierLogo;$logo.Location=New-Object Drawing.Point(10,10)
$label.Location=New-Object Drawing.Point(90,15);$label.Size=New-Object Drawing.Size(550,85)
$label.Text=$report.constructeur + ' ' + $report.modele + "`r`nSN : " + $serial + ' | Produit : ' + $report.produit + "`r`nConfirmer les dates sur le site officiel, puis les saisir ci-dessous."
$open=New-Object Windows.Forms.Button;$open.Text='Site constructeur';$open.Location=New-Object Drawing.Point(20,105);$open.Size=New-Object Drawing.Size(180,32);$open.Enabled=[bool]$url
$open.Add_Click({Start-Process $url})
$copy=New-Object Windows.Forms.Button;$copy.Text='Copier le SN';$copy.Location=New-Object Drawing.Point(220,105);$copy.Size=New-Object Drawing.Size(150,32)
$copy.Add_Click({[Windows.Forms.Clipboard]::SetText($serial)})
$inputs=@{}
$y=160
foreach ($item in @(@('debut','Debut (AAAA-MM-JJ)'),@('fin','Fin (AAAA-MM-JJ)'),@('observation','Couverture / observation'))) {
    $caption=New-Object Windows.Forms.Label;$caption.Text=$item[1];$caption.Location=New-Object Drawing.Point(20,$y);$caption.Size=New-Object Drawing.Size(230,28)
    $input=New-Object Windows.Forms.TextBox;$input.Location=New-Object Drawing.Point(260,$y);$input.Size=New-Object Drawing.Size(370,28);$input.MaxLength=400
    $inputs[$item[0]]=$input;$form.Controls.AddRange(@($caption,$input));$y+=45
}
$save=New-Object Windows.Forms.Button;$save.Text='Confirmer et enregistrer';$save.Location=New-Object Drawing.Point(20,305);$save.Size=New-Object Drawing.Size(230,36)
if ($previous -and $previous.numero_serie -eq $serial) {
    $inputs.debut.Text=[string]$previous.debut;$inputs.fin.Text=[string]$previous.fin;$inputs.observation.Text=[string]$previous.observation
}
$notice=New-Object Windows.Forms.Label;$notice.Location=New-Object Drawing.Point(20,355);$notice.Size=New-Object Drawing.Size(620,50)
$save.Add_Click({
    try {
        if (-not $url) { throw 'Constructeur non pris en charge : verifier manuellement la source officielle.' }
        $culture=[Globalization.CultureInfo]::InvariantCulture
        $start=[datetime]::ParseExact($inputs.debut.Text,'yyyy-MM-dd',$culture)
        $end=[datetime]::ParseExact($inputs.fin.Text,'yyyy-MM-dd',$culture)
        if ($end -lt $start) { throw 'La fin doit etre posterieure au debut.' }
        if ($start -gt (Get-Date).Date) { throw 'Le debut est dans le futur : verifier les dates.' }
        $report.debut=$start.ToString('yyyy-MM-dd');$report.fin=$end.ToString('yyyy-MM-dd')
        $report.mois_couverture=Get-AtelierWarrantyMonths $start $end
        $report.mois_restants=Get-AtelierWarrantyMonths (Get-Date).Date $end
        $report.jours_restants=[math]::Max(0,($end-(Get-Date).Date).Days)
        $report.statut=if ($end -lt (Get-Date).Date) { 'expiree_confirmee_operateur' } else { 'active_confirmee_operateur' }
        $report.verifie_le=[DateTime]::UtcNow.ToString('o');$report.observation=$inputs.observation.Text
        Save-AtelierWarranty $report $OutputDirectory
        $notice.Text='Garantie.txt et Garantie.json enregistres. Relancer Generer-Rapport.cmd pour actualiser le PDF.'
    } catch { $notice.Text='Dates AAAA-MM-JJ attendues. ' + $_.Exception.Message }
})
$form.Controls.AddRange(@($logo,$label,$open,$copy,$save,$notice))
try { if ($url) { Start-Process $url };Set-AtelierFormTheme $form
[void]$form.ShowDialog() } finally { $form.Dispose() }
