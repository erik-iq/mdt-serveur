#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][psobject]$Config)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'Unattend.ps1')
. (Join-Path $PSScriptRoot 'WinPE-Session.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:session = $null
$script:page = 0
$script:running = $false
$script:engine = $null
$script:invocation = $null
$script:informationIndex = 0
$script:drive = $null
$script:settings = $null
$script:selectedProfile = $null
$script:targetName = ''
$script:controls = @{}
$script:operatorKeyboard = if ($env:ATELIER_WINPE_KEYBOARD) { $env:ATELIER_WINPE_KEYBOARD } elseif ($Config.winpe_keyboard_layout) { $Config.winpe_keyboard_layout } else { '040c:0000040c' }
$script:steps = @('Connexion','Windows','Poste & region','Bundle & bureau','Recapitulatif','Installation')
$computer = Get-CimInstance Win32_ComputerSystem
$script:manufacturer = [string]$computer.Manufacturer
$script:macs = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress } | ForEach-Object { $_.MACAddress.Replace('-',':').ToUpperInvariant() } | Select-Object -Unique)
$script:root = $Config.server_url.TrimEnd('/')
$script:share = if ($Config.image_share) { $Config.image_share } else { '\\' + ([Uri]$script:root).Host + '\AtelierImages' }
$accent = [Drawing.ColorTranslator]::FromHtml('#487868')
$ink = [Drawing.ColorTranslator]::FromHtml('#18312A')
$paper = [Drawing.ColorTranslator]::FromHtml('#F5F8F6')
$muted = [Drawing.ColorTranslator]::FromHtml('#65776F')

function New-Text([string]$Text, [int]$Size = 10, [bool]$Bold = $false) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text; $label.AutoSize = $true
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font('Segoe UI', $Size, $style)
    $label.ForeColor = $ink; $label.Margin = New-Object Windows.Forms.Padding(0,7,0,7)
    return $label
}
function New-Button([string]$Text, [bool]$Primary = $false) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Width = 150; $button.Height = 40
    $button.FlatStyle = 'Flat'; $button.FlatAppearance.BorderSize = 0
    $button.Font = New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
    $button.BackColor = if ($Primary) { $accent } else { [Drawing.ColorTranslator]::FromHtml('#E6EFEA') }
    $button.ForeColor = if ($Primary) { [Drawing.Color]::White } else { $ink }
    $button.Margin = New-Object Windows.Forms.Padding(8,0,0,0)
    return $button
}
function Add-Text([string]$Text, [int]$Size = 10, [bool]$Bold = $false) {
    $label = New-Text $Text $Size $Bold
    $label.MaximumSize = New-Object Drawing.Size(($script:body.ClientSize.Width - 26),0)
    $script:body.Controls.Add($label)
    return $label
}
function Add-Input([string]$Key, [string]$Label, [string]$Value = '', [bool]$Secret = $false) {
    Add-Text $Label 10 $true | Out-Null
    $input = New-Object Windows.Forms.TextBox
    $input.Text = $Value; $input.UseSystemPasswordChar = $Secret
    $input.Font = New-Object Drawing.Font('Segoe UI',11)
    $input.Width = $script:body.ClientSize.Width - 28
    $input.Margin = New-Object Windows.Forms.Padding(0,0,0,12)
    $script:controls[$Key] = $input; $script:body.Controls.Add($input)
    return $input
}
function Add-Choice([string]$Key, [string]$Label, [object[]]$Items, [string]$Value = '') {
    Add-Text $Label 10 $true | Out-Null
    $choice = New-Object Windows.Forms.ComboBox
    $choice.DropDownStyle = 'DropDownList'; $choice.Font = New-Object Drawing.Font('Segoe UI',11)
    $choice.Width = $script:body.ClientSize.Width - 28
    $choice.Tag = @($Items)
    foreach ($item in $Items) { $choice.Items.Add([string]$item.name) | Out-Null }
    $choice.Margin = New-Object Windows.Forms.Padding(0,0,0,12)
    $script:controls[$Key] = $choice; $script:body.Controls.Add($choice)
    $choice.SelectedIndex = 0
    for ($i=0; $i -lt $Items.Count; $i++) { if ([string]$Items[$i].id -eq $Value) { $choice.SelectedIndex = $i; break } }
    return $choice
}
function Choice-Value([string]$Key) {
    $choice = $script:controls[$Key]
    if ($choice.SelectedIndex -lt 0) { throw 'Une selection est requise.' }
    return [string]$choice.Tag[$choice.SelectedIndex].id
}
function Add-Check([string]$Key, [string]$Text, [bool]$Checked, [bool]$Enabled = $true) {
    $check = New-Object Windows.Forms.CheckBox
    $check.Text = $Text; $check.Checked = $Checked; $check.Enabled = $Enabled
    $check.AutoSize = $false; $check.Width = $script:body.ClientSize.Width - 28; $check.Height = 30
    $check.Font = New-Object Drawing.Font('Segoe UI',10); $check.Margin = New-Object Windows.Forms.Padding(0,3,0,3)
    $script:controls[$Key] = $check; $script:body.Controls.Add($check)
}
function Send-Json([string]$Path, [psobject]$Body, [bool]$Authenticated = $true) {
    $headers = @{}
    if ($Authenticated) { $headers.Authorization = 'Bearer ' + $script:session.agent_token }
    $json = $Body | ConvertTo-Json -Depth 14 -Compress
    return Invoke-RestMethod -Uri ($script:root + $Path) -Method Post -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}
function Set-Profile([string]$Id) {
    $profile = $script:session.catalog.profiles | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $profile) { throw 'Profil absent de cette autorisation.' }
    $script:selectedProfile = $profile
    $script:settings = $profile.settings | ConvertTo-Json -Depth 8 | ConvertFrom-Json
}
function Save-Page {
    switch ($script:page) {
        1 { $id = Choice-Value 'profile'; if ($id -ne $script:selectedProfile.id) { Set-Profile $id } }
        2 {
            $name = $script:controls.hostname.Text.Trim()
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9-]{0,14}$') { throw 'Nom du PC : 1 a 15 caracteres, lettres, chiffres et tirets.' }
            $script:targetName = $name
            $script:settings.keyboard = Choice-Value 'keyboard'
            $script:settings.timezone = Choice-Value 'timezone'
            $script:settings.user_locale = Choice-Value 'user_locale'
            $script:settings.registered_owner = $script:controls.owner.Text.Trim()
            $script:settings.organization = $script:controls.organization.Text.Trim()
        }
        3 {
            $script:settings.theme = Choice-Value 'theme'
            $wallpaper = Choice-Value 'wallpaper'
            $script:settings.wallpaper_asset_id = if ($wallpaper) { $wallpaper } else { $null }
            $script:settings.bundle_ids = @($script:session.catalog.bundles | Where-Object { $script:controls[('bundle-' + $_.id)].Checked } | ForEach-Object { $_.id })
            $script:settings.application_ids = @($script:session.catalog.applications | Where-Object { $script:controls[('app-' + $_.id)].Checked } | ForEach-Object { $_.id })
        }
    }
}
function Selected-Applications {
    $ids = @($script:settings.application_ids)
    foreach ($bundle in @($script:session.catalog.bundles | Where-Object { $_.id -in @($script:settings.bundle_ids) })) { $ids += @($bundle.application_ids) }
    return @($script:session.catalog.applications | Where-Object { $_.id -in $ids -and (Test-AtelierManufacturer $_.manufacturer $script:manufacturer) })
}
function Show-Page {
    $script:body.SuspendLayout()
    foreach ($control in @($script:body.Controls)) { $control.Dispose() }
    $script:body.Controls.Clear(); $script:controls = @{}
    $script:title.Text = $script:steps[$script:page]
    $script:description.Text = @('Autorisez ce poste et connectez le partage des images.','Choisissez Windows dans le catalogue du serveur.','Preparez le nom, le clavier et le fuseau horaire.','Choisissez votre bundle et votre personnalisation.','Verifiez la cible avant de confirmer l installation.','Application de Windows et preparation du premier demarrage.')[$script:page]
    $script:back.Enabled = $script:page -gt 1 -and -not $script:running
    $script:next.Enabled = -not $script:running
    $script:next.Text = if ($script:page -eq 0) { 'Connexion' } elseif ($script:page -eq 4) { 'Installer Windows' } else { 'Continuer' }
    for ($i=0; $i -lt $script:nav.Count; $i++) {
        $script:nav[$i].ForeColor = if ($i -eq $script:page) { [Drawing.Color]::White } else { [Drawing.ColorTranslator]::FromHtml('#AEC5BA') }
        $script:nav[$i].Text = ('{0:00}  {1}' -f ($i+1), $script:steps[$i])
    }
    switch ($script:page) {
        0 {
            Add-Text ($script:manufacturer + ' / ' + $computer.Model) 12 $true | Out-Null
            Add-Text ('MAC Ethernet : ' + ($script:macs -join ' / ')) | Out-Null
            $keyboard = Add-Choice 'operator_keyboard' 'Clavier de cet assistant' @(
                [pscustomobject]@{id='040c:0000040c';name='Francais - AZERTY'},
                [pscustomobject]@{id='100c:0000100c';name='Suisse romand - QWERTZ'},
                [pscustomobject]@{id='0409:00000409';name='Anglais US - QWERTY'}
            ) $script:operatorKeyboard
            $keyboard.Add_SelectedIndexChanged({
                try {
                    $operatorLayout = Choice-Value 'operator_keyboard'
                    Set-AtelierOperatorKeyboard -Layout $operatorLayout
                    $script:operatorKeyboard = $operatorLayout
                    $script:status.Text = 'Clavier applique. Verifiez la saisie dans le champ de test.'
                } catch {
                    [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Clavier WinPE','OK','Warning')
                }
            })
            Add-Input 'keyboard_test' 'Test clavier (sans mot de passe) : essayez azerty et 123' | Out-Null
            Add-Text 'Enregistrez cette MAC dans la console, puis creez une autorisation avec assistant PXE. Saisissez le code affiche par la console.' | Out-Null
            Add-Input 'code' 'Code d installation' '' $true | Out-Null
            Add-Text ('Partage des images : ' + $script:share) | Out-Null
            Add-Input 'username' 'Compte de lecture du partage' ([string]$Config.share_account) | Out-Null
            Add-Input 'password' 'Mot de passe du partage' '' $true | Out-Null
            Add-Text 'Le mot de passe reste dans la session WinPE ; il ne sera pas copie dans Windows.' | Out-Null
        }
        1 {
            $items = @($script:session.catalog.profiles | ForEach-Object { [pscustomobject]@{id=$_.id; name=($_.name + ' | ' + $_.windows_version + ' ' + $_.edition + ' | ' + $_.locale)} })
            Add-Choice 'profile' 'Windows a installer' $items $script:selectedProfile.id | Out-Null
            Add-Text 'Les versions proposees correspondent aux images enregistrees sur votre serveur. La langue de Windows est celle de l image selectionnee.' | Out-Null
            Add-Text ('Profil initial : ' + $script:session.plan.profile_name) | Out-Null
        }
        2 {
            $name = Add-Input 'hostname' 'Nom du PC' $script:targetName
            $name.MaxLength = 15
            Add-Choice 'keyboard' 'Clavier' @($script:session.catalog.options.keyboards) $script:settings.keyboard | Out-Null
            Add-Choice 'timezone' 'Fuseau horaire' @($script:session.catalog.options.timezones) $script:settings.timezone | Out-Null
            Add-Choice 'user_locale' 'Region / formats' @($script:session.catalog.options.regions) $script:settings.user_locale | Out-Null
            Add-Input 'owner' 'Proprietaire enregistre (facultatif)' $script:settings.registered_owner | Out-Null
            Add-Input 'organization' 'Organisation (facultatif)' $script:settings.organization | Out-Null
        }
        3 {
            Add-Text 'Bundles' 12 $true | Out-Null
            foreach ($bundle in @($script:session.catalog.bundles)) { Add-Check ('bundle-' + $bundle.id) $bundle.name ($bundle.id -in @($script:settings.bundle_ids)) }
            Add-Text 'Logiciels supplementaires' 12 $true | Out-Null
            foreach ($application in @($script:session.catalog.applications)) {
                $compatible = Test-AtelierManufacturer $application.manufacturer $script:manufacturer
                $label = $application.name + ' ' + $application.version
                if (-not $compatible) { $label += ' (autre constructeur)' }
                Add-Check ('app-' + $application.id) $label ($compatible -and $application.id -in @($script:settings.application_ids)) $compatible
            }
            Add-Choice 'theme' 'Theme du bureau' @($script:session.catalog.options.themes) $script:settings.theme | Out-Null
            $wallpapers = @([pscustomobject]@{id=''; name='Conserver le fond d ecran Windows'}) + @($script:session.catalog.wallpapers | ForEach-Object { [pscustomobject]@{id=$_.id;name=$_.filename} })
            Add-Choice 'wallpaper' 'Fond d ecran' $wallpapers ([string]$script:settings.wallpaper_asset_id) | Out-Null
            Add-Text 'Les logiciels sont prepares depuis le partage, puis installes au premier demarrage avec le premier compte administrateur. Les outils portables ne lancent aucune mise a jour du BIOS.' | Out-Null
        }
        4 {
            $disk = Get-Disk -Number $script:session.plan.disk_number
            Add-Text ($script:selectedProfile.name + ' -> ' + $script:targetName) 16 $true | Out-Null
            Add-Text ('Clavier : ' + $script:settings.keyboard + ' | Fuseau : ' + $script:settings.timezone) | Out-Null
            Add-Text ('Disque ' + $disk.Number + ' : ' + $disk.FriendlyName + ' | ' + [math]::Round($disk.Size/1GB) + ' Go | Serie ' + $disk.SerialNumber) 11 $true | Out-Null
            $apps = @(Selected-Applications | ForEach-Object { $_.name })
            Add-Text ('Logiciels de ce poste : ' + ($apps -join ', ')) | Out-Null
            Add-Text 'Toutes les partitions du disque indique seront supprimees. Les controles MAC, UEFI, image et disque seront executes avant cet effacement.' | Out-Null
            $expected = 'EFFACER ' + $script:targetName + ' DISQUE ' + $disk.Number
            Add-Input 'confirmation' ('Tapez exactement : ' + $expected) | Out-Null
        }
        5 {
            $script:stage = Add-Text 'Controle des prerequis...' 13 $true
            $script:progress = New-Object Windows.Forms.ProgressBar
            $script:progress.Width = $script:body.ClientSize.Width - 28; $script:progress.Height = 22
            $script:body.Controls.Add($script:progress)
            $script:logs = New-Object Windows.Forms.TextBox
            $script:logs.Multiline = $true; $script:logs.ReadOnly = $true; $script:logs.ScrollBars = 'Vertical'
            $script:logs.Width = $script:body.ClientSize.Width - 28; $script:logs.Height = 250
            $script:logs.Font = New-Object Drawing.Font('Consolas',9)
            $script:body.Controls.Add($script:logs)
            Add-Text 'Image appliquee signifie que Windows est prepare. Le premier demarrage, les logiciels et le bureau seront verifies apres redemarrage.' | Out-Null
        }
    }
    $script:body.ResumeLayout()
}
function Connect-Post {
    $code = $script:controls.code.Text.Trim()
    if (-not $script:macs.Count) { throw 'Aucune MAC detectee : verifier le pilote Ethernet WinPE.' }
    if (-not $script:controls.username.Text.Trim() -or -not $script:controls.password.Text) { throw 'Indiquez le compte et le mot de passe du partage.' }
    $script:status.Text = 'Connexion securisee au serveur...'; $form.Refresh()
    $connected = Send-Json '/api/boot/connect' @{code=$code;macs=$script:macs} $false
    $secure = ConvertTo-SecureString $script:controls.password.Text -AsPlainText -Force
    $credential = New-Object PSCredential($script:controls.username.Text.Trim(), $secure)
    try {
        $letter = @('Y','Z','V','U','T') | Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
        if (-not $letter) { throw 'Aucune lettre libre pour le partage des images.' }
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $script:share -Credential $credential -Persist -Scope Global | Out-Null
        $script:drive = $letter
    } finally {
        $script:controls.password.Clear(); $credential = $null
        if ($secure) { $secure.Dispose() }
    }
    $script:session = $connected
    $script:targetName = $connected.plan.hostname
    Set-Profile $connected.plan.profile_id
    $script:page = 1; $script:status.Text = 'Poste autorise. Les choix restent modifiables avant installation.'
    Show-Page
}
function Begin-Deployment {
    $expected = 'EFFACER ' + $script:targetName + ' DISQUE ' + $script:session.plan.disk_number
    if ($script:controls.confirmation.Text -cne $expected) { throw 'Confirmation exacte requise avant installation.' }
    $plan = Send-Json ('/api/agent/' + $script:session.id + '/configure') @{profile_id=$script:selectedProfile.id;hostname=$script:targetName;settings=$script:settings}
    $image = Join-Path $script:share $plan.image_filename
    $script:running = $true; $script:page = 5
    Show-Page; $script:next.Enabled = $false; $script:back.Enabled = $false
    $script:engine = [PowerShell]::Create()
    $script:engine.AddCommand((Join-Path $PSScriptRoot 'Deploy.ps1')).AddParameter('ServerUrl',$script:root).AddParameter('DeploymentId',$script:session.id).AddParameter('Token',$script:session.agent_token).AddParameter('ImagePath',$image).AddParameter('LocalConfirmation',$expected) | Out-Null
    if ($Config.allow_http_for_lab) { $script:engine.AddParameter('AllowHttpForLab',$true) | Out-Null }
    $script:invocation = $script:engine.BeginInvoke()
    $script:timer.Start()
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Atelier PXE | Assistant Windows | ' + $Config.boot_release
$form.StartPosition = 'CenterScreen'; $form.BackColor = $paper; $form.AutoScaleMode = 'None'
$bounds = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.ClientSize = New-Object Drawing.Size(([math]::Min(980,$bounds.Width-30)),([math]::Min(690,$bounds.Height-50)))
$form.MinimumSize = New-Object Drawing.Size(760,560)
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 2; $layout.RowCount = 1
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,190))) | Out-Null
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
$form.Controls.Add($layout)
$sidebar = New-Object Windows.Forms.FlowLayoutPanel
$sidebar.Dock = 'Fill'; $sidebar.FlowDirection = 'TopDown'; $sidebar.WrapContents = $false
$sidebar.BackColor = $ink; $sidebar.Padding = New-Object Windows.Forms.Padding(18,26,8,0)
$brand = New-Text 'atelier / PXE' 19 $true; $brand.ForeColor = [Drawing.Color]::White; $sidebar.Controls.Add($brand)
$tag = New-Text 'ASSISTANT WINDOWS' 8; $tag.ForeColor = [Drawing.ColorTranslator]::FromHtml('#AEC5BA'); $tag.Margin = New-Object Windows.Forms.Padding(0,0,0,30); $sidebar.Controls.Add($tag)
$script:nav = @()
foreach ($name in $script:steps) { $item=New-Text $name 10; $item.Margin=New-Object Windows.Forms.Padding(0,12,0,12); $sidebar.Controls.Add($item); $script:nav += $item }
$layout.Controls.Add($sidebar,0,0)
$main = New-Object Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'; $main.RowCount = 4; $main.ColumnCount = 1; $main.Padding = New-Object Windows.Forms.Padding(24,20,24,14)
$main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,90))) | Out-Null
$main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
$main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,32))) | Out-Null
$main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,44))) | Out-Null
$layout.Controls.Add($main,1,0)
$header = New-Object Windows.Forms.FlowLayoutPanel
$header.Dock='Fill';$header.FlowDirection='TopDown';$header.WrapContents=$false
$script:title = New-Text 'Connexion' 25 $true; $header.Controls.Add($script:title)
$script:description = New-Text '' 9; $script:description.ForeColor=$muted; $header.Controls.Add($script:description)
$main.Controls.Add($header,0,0)
$script:body = New-Object Windows.Forms.FlowLayoutPanel
$script:body.Dock='Fill';$script:body.FlowDirection='TopDown';$script:body.WrapContents=$false;$script:body.AutoScroll=$true
$main.Controls.Add($script:body,0,1)
$script:status = New-Text 'Ethernet / UEFI x64 / installation supervisee' 9
$script:status.Dock='Fill';$script:status.AutoSize=$false;$main.Controls.Add($script:status,0,2)
$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft'
$script:next=New-Button 'Connexion' $true;$script:back=New-Button 'Retour'
$buttons.Controls.Add($script:next);$buttons.Controls.Add($script:back);$main.Controls.Add($buttons,0,3)
$script:back.Add_Click({ try { Save-Page; $script:page--; Show-Page } catch { $script:status.Text=$_.Exception.Message } })
$script:next.Add_Click({
    try {
        $script:next.Enabled=$false
        if ($script:page -eq 0) { Connect-Post }
        elseif ($script:page -eq 4) { Begin-Deployment }
        elseif ($script:page -eq 5) { $form.Close() }
        else { Save-Page; $script:page++; Show-Page }
    } catch { $script:status.Text=$_.Exception.Message; $script:next.Enabled=$true }
})
$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval=400
$script:timer.Add_Tick({
    while ($script:informationIndex -lt $script:engine.Streams.Information.Count) {
        $message=[string]$script:engine.Streams.Information[$script:informationIndex].MessageData
        $script:informationIndex++
        if ($message -match '^ATELIER\|(\d+)\|(.*)$') {
            $script:progress.Value=[math]::Min(100,[int]$Matches[1]);$script:stage.Text=$Matches[2]
            $script:logs.AppendText($Matches[2] + "`r`n")
        }
    }
    if ($script:invocation.IsCompleted) {
        $script:timer.Stop()
        try {
            $output=$script:engine.EndInvoke($script:invocation)
            foreach($line in $output){$script:logs.AppendText([string]$line + "`r`n")}
            if ($script:engine.HadErrors) {
                $script:stage.Text='Installation interrompue : consulter le journal.'
                foreach($errorRecord in $script:engine.Streams.Error){$script:logs.AppendText($errorRecord.ToString() + "`r`n")}
            } else {
                $script:stage.Text='Image appliquee. Premier demarrage Windows a verifier.'
                $script:progress.Value=100
                $script:logs.AppendText("Eteignez WinPE avec wpeutil shutdown, puis demarrez Windows depuis le disque. Verifiez ensuite C:\ProgramData\AtelierPXE\result.json.`r`n")
            }
        } catch { $script:stage.Text='Echec du deploiement.';$script:logs.AppendText($_.Exception.Message) }
        finally { $script:running=$false;$script:engine.Dispose();$script:next.Text='Fermer';$script:next.Enabled=$true }
    }
})
$form.Add_FormClosing({ param($sender,$eventArgs) if($script:running){$eventArgs.Cancel=$true;$script:status.Text='Installation active : la fenetre reste ouverte pendant les operations disque.'} })
$script:startupFailure = $null
$form.Add_Shown({
    try { Show-Page } catch {
        # Return startup errors to Launch.ps1 instead of leaving a blank form.
        $script:startupFailure = $_
        $form.Close()
    }
})
try { [void]$form.ShowDialog() }
finally {
    $script:timer.Dispose();$form.Dispose()
    if($script:drive){Remove-PSDrive -Name $script:drive -Force -ErrorAction SilentlyContinue}
    $script:session=$null
}
if ($script:startupFailure) { throw $script:startupFailure }
