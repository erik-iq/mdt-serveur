# Windows Update engine; injectable COM factories allow testing without changing Windows.
function Invoke-AtelierWindowsUpdates {
    param(
        [scriptblock]$SessionFactory = { New-Object -ComObject Microsoft.Update.Session },
        [scriptblock]$CollectionFactory = { ,(New-Object -ComObject Microsoft.Update.UpdateColl) }
    )
    $session = & $SessionFactory
    $session.ClientApplicationID = 'Atelier PXE'
    $searcher = $session.CreateUpdateSearcher()
    # Respect the configured update service/WSUS. Exclude optional and driver updates.
    $search = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0")
    if ([int]$search.ResultCode -ne 2) { throw 'Recherche Windows Update incomplete.' }
    $updates = & $CollectionFactory
    $titles = @()
    foreach ($update in $search.Updates) {
        if ($update.InstallationBehavior.CanRequestUserInput) { throw 'Une mise a jour exige une intervention utilisateur.' }
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        $updates.Add($update) | Out-Null
        $titles += [string]$update.Title
    }
    if ($updates.Count -eq 0) { return [pscustomobject]@{status='up_to_date';count=0;reboot_required=$false;titles=@()} }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    $download = $downloader.Download()
    if ([int]$download.ResultCode -ne 2) { throw 'Telechargement Windows Update incomplet.' }
    $installer = $session.CreateUpdateInstaller()
    if ($installer.RebootRequiredBeforeInstallation) {
        return [pscustomobject]@{status='reboot_required';count=0;reboot_required=$true;titles=@()}
    }
    $installer.Updates = $updates
    $installer.AllowSourcePrompts = $false
    $installer.ForceQuiet = $true
    $result = $installer.Install()
    if ([int]$result.ResultCode -ne 2) { throw 'Installation Windows Update incomplete.' }
    for ($index=0; $index -lt $updates.Count; $index++) {
        if ([int]$result.GetUpdateResult($index).ResultCode -ne 2) { throw 'Une mise a jour Windows a echoue.' }
    }
    return [pscustomobject]@{status='installed';count=$updates.Count;reboot_required=[bool]$result.RebootRequired;titles=@($titles)}
}

function Request-AtelierStoreUpdates {
    # The MDM bridge method requires SYSTEM. It requests a scan; it does not
    # expose a trustworthy aggregate completion result for Store installations.
    $manager = @(Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01')
    if ($manager.Count -ne 1) { throw 'Service de mise a jour Microsoft Store indisponible.' }
    $result = Invoke-CimMethod -InputObject $manager[0] -MethodName 'UpdateScanMethod'
    if ([int]$result.ReturnValue -ne 0) { throw 'La demande de mise a jour Microsoft Store a echoue.' }
    return [pscustomobject]@{status='requested';completion_verified=$false;message='Actualisation Microsoft Store demandee ; son achevement reste gere par Windows.'}
}

function Disable-AtelierAutoLogon {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $path -Name AutoAdminLogon -Value '0'
    foreach ($name in @('DefaultPassword','AutoLogonCount')) { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }
}
