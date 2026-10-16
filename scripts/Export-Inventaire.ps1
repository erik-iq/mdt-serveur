#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$OutputDirectory='C:\IQ_')
$ErrorActionPreference='Stop'
$collected=[DateTime]::UtcNow.ToString('o')
$computer=[string]$env:COMPUTERNAME
$sections=New-Object 'Collections.Generic.List[object]'
$rows=New-Object 'Collections.Generic.List[object]'

function Convert-InventoryValue($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('o',[Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [IFormattable]) { return $Value.ToString($null,[Globalization.CultureInfo]::InvariantCulture) }
    # XML 1.0 forbids some control characters returned by device firmware.
    return ([string]$Value -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}

function Add-InventoryProperty([string]$Category,[int]$Index,[string]$Path,$Value,[int]$Depth=0) {
    if ($Depth -lt 5 -and $Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys | Sort-Object) { Add-InventoryProperty $Category $Index ($Path + '.' + $key) $Value[$key] ($Depth+1) }
    } elseif ($Depth -lt 5 -and $Value -is [Array]) {
        if ($Value.Count -eq 0) { Add-InventoryProperty $Category $Index $Path '' 5 }
        for ($i=0;$i -lt $Value.Count;$i++) { Add-InventoryProperty $Category $Index ($Path + '[' + $i + ']') $Value[$i] ($Depth+1) }
    } elseif ($Depth -lt 5 -and $Value -and $Value.PSObject.Properties['CimInstanceProperties']) {
        foreach ($property in $Value.CimInstanceProperties | Sort-Object Name) { Add-InventoryProperty $Category $Index ($Path + '.' + $property.Name) $property.Value ($Depth+1) }
    } else {
        $rows.Add([pscustomobject][ordered]@{Ordinateur=$computer;CollecteUTC=$collected;Categorie=$Category;Element=$Index;Propriete=$Path;Valeur=(Convert-InventoryValue $Value);Type=$(if($null -eq $Value){'null'}else{$Value.GetType().Name});Etat='ok';Erreur=''})
    }
}

function Add-InventorySection {
    param([string]$Name,[scriptblock]$Query,[string[]]$Properties)
    try {
        $items=@(& $Query)
        $state=if ($items.Count) { 'ok' } else { 'vide' }
        $sections.Add([pscustomobject]@{Nom=$Name;Etat=$state;Elements=$items.Count;Erreur=''})
        if (-not $items.Count) { $rows.Add([pscustomobject][ordered]@{Ordinateur=$computer;CollecteUTC=$collected;Categorie=$Name;Element=0;Propriete='';Valeur='';Type='';Etat='vide';Erreur=''}) }
        $index=0
        foreach ($item in $items) {
            $index++
            if ($Properties) {
                foreach ($property in $Properties) { Add-InventoryProperty $Name $index $property $item.$property }
            } elseif ($item.PSObject.Properties['CimInstanceProperties']) {
                foreach ($property in $item.CimInstanceProperties | Sort-Object Name) { Add-InventoryProperty $Name $index $property.Name $property.Value }
            } else {
                foreach ($property in $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^(PS|Cim)' } | Sort-Object Name) { Add-InventoryProperty $Name $index $property.Name $property.Value }
            }
            if ($Name -eq 'Ordinateur' -and $item.TotalPhysicalMemory) { Add-InventoryProperty $Name $index 'RAM_Totale_GiB' ([math]::Round($item.TotalPhysicalMemory/1GB,2)) }
            if ($Name -eq 'BarrettesRAM' -and $item.Capacity) { Add-InventoryProperty $Name $index 'Capacite_GiB' ([math]::Round($item.Capacity/1GB,2)) }
            if ($Name -in @('Disques','DisquesPhysiques_SSD_HDD','VolumesLogiques','VolumesStockage') -and $item.Size) { Add-InventoryProperty $Name $index 'Capacite_GiB' ([math]::Round($item.Size/1GB,2)) }
            if ($Name -eq 'VolumesStockage' -and $null -ne $item.SizeRemaining) { Add-InventoryProperty $Name $index 'Libre_GiB' ([math]::Round($item.SizeRemaining/1GB,2)) }
        }
    } catch {
        $errorType=$_.Exception.GetType().Name
        $sections.Add([pscustomobject]@{Nom=$Name;Etat='indisponible';Elements=0;Erreur=$errorType})
        $rows.Add([pscustomobject][ordered]@{Ordinateur=$computer;CollecteUTC=$collected;Categorie=$Name;Element=0;Propriete='';Valeur='';Type='';Etat='indisponible';Erreur=$errorType})
    }
}

$classes=[ordered]@{
    Ordinateur='Win32_ComputerSystem';Identite='Win32_ComputerSystemProduct';BIOS='Win32_BIOS';CarteMere='Win32_BaseBoard';Boitier='Win32_SystemEnclosure';Windows='Win32_OperatingSystem';Processeurs='Win32_Processor';CachesCPU='Win32_CacheMemory';BarrettesRAM='Win32_PhysicalMemory';EmplacementsRAM='Win32_PhysicalMemoryArray';Disques='Win32_DiskDrive';Partitions='Win32_DiskPartition';VolumesLogiques='Win32_LogicalDisk';Graphique='Win32_VideoController';Ecrans='Win32_DesktopMonitor';ReseauCartes='Win32_NetworkAdapter';ReseauConfiguration='Win32_NetworkAdapterConfiguration';Son='Win32_SoundDevice';Claviers='Win32_Keyboard';Souris='Win32_PointingDevice';Batteries='Win32_Battery';ControleursUSB='Win32_USBController';ControleursStockage='Win32_SCSIController';Peripheriques='Win32_PnPEntity';PilotesSignes='Win32_PnPSignedDriver';CorrectifsWindows='Win32_QuickFixEngineering';Imprimantes='Win32_Printer'
}
foreach ($entry in $classes.GetEnumerator()) {
    $class=$entry.Value
    Add-InventorySection $entry.Key { Get-CimInstance -ClassName $class -OperationTimeoutSec 15 -ErrorAction Stop }
}
foreach ($class in @('WmiMonitorID','WmiMonitorBasicDisplayParams','BatteryStaticData','BatteryFullChargedCapacity','BatteryStatus')) {
    Add-InventorySection ('Materiel_' + $class) { Get-CimInstance -Namespace 'root\wmi' -ClassName $class -OperationTimeoutSec 10 -ErrorAction Stop }
}
Add-InventorySection 'DisquesPhysiques_SSD_HDD' { Get-PhysicalDisk -ErrorAction Stop } @('FriendlyName','Manufacturer','Model','SerialNumber','FirmwareVersion','MediaType','BusType','Size','AllocatedSize','LogicalSectorSize','PhysicalSectorSize','HealthStatus','OperationalStatus','Usage','DeviceId')
Add-InventorySection 'SanteStockage' { Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop } @('DeviceId','Temperature','TemperatureMax','PowerOnHours','Wear','ReadErrorsTotal','ReadErrorsUncorrected','WriteErrorsTotal','WriteErrorsUncorrected','ReadLatencyMax','WriteLatencyMax','FlushLatencyMax','StartStopCycleCount','LoadUnloadCycleCount')
Add-InventorySection 'VolumesStockage' { Get-Volume -ErrorAction Stop } @('DriveLetter','FileSystemLabel','FileSystemType','DriveType','HealthStatus','OperationalStatus','Size','SizeRemaining','AllocationUnitSize','Path','UniqueId')
Add-InventorySection 'TPM' { Get-Tpm -ErrorAction Stop } @('TpmPresent','TpmReady','TpmEnabled','TpmActivated','TpmOwned','ManufacturerId','ManufacturerIdTxt','ManufacturerVersion','ManagedAuthLevel','OwnerClearDisabled','AutoProvisioning','LockedOut','LockoutCount','LockoutMax')
Add-InventorySection 'SecureBoot' { [pscustomobject]@{Active=(Confirm-SecureBootUEFI -ErrorAction Stop)} }
Add-InventorySection 'BitLocker' { Get-BitLockerVolume -ErrorAction Stop } @('MountPoint','VolumeType','CapacityGB','VolumeStatus','EncryptionPercentage','EncryptionMethod','ProtectionStatus','LockStatus','AutoUnlockEnabled')
# Never export OA3xOriginalProductKey, registry DigitalProductId, OwnerAuth or BitLocker key protectors.
Add-InventorySection 'LicencesWindows' {
    Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -OperationTimeoutSec 15 -ErrorAction Stop | Where-Object { $_.Name -like 'Windows*' -and -not $_.LicenseIsAddon }
} @('ID','ApplicationID','Name','Description','LicenseStatus','LicenseStatusReason','GracePeriodRemaining','EvaluationEndDate','ProductKeyChannel','LicenseFamily','LicenseIsAddon','VLActivationTypeEnabled','VLActivationInterval','VLRenewalInterval','KeyManagementServiceMachine','KeyManagementServicePort')
Add-InventorySection 'ServiceLicence' { Get-CimInstance -ClassName SoftwareLicensingService -OperationTimeoutSec 15 -ErrorAction Stop } @('Version','ClientMachineID','RemainingWindowsReArmCount','KeyManagementServiceMachine','KeyManagementServicePort','VLActivationInterval','VLRenewalInterval')
Add-InventorySection 'LicencesOfficeSiExposees' { Get-CimInstance -ClassName OfficeSoftwareProtectionProduct -OperationTimeoutSec 10 -ErrorAction Stop } @('Name','Description','LicenseStatus','GracePeriodRemaining','LicenseFamily')
Add-InventorySection 'VersionWindows' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } @('ProductName','EditionID','DisplayVersion','CurrentBuild','UBR','BuildLabEx','InstallationType','InstallDate','ProductId')
Add-InventorySection 'DemarrageRapide' { Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop } @('HiberbootEnabled')
Add-InventorySection 'FuseauHoraire' { Get-TimeZone -ErrorAction Stop } @('Id','DisplayName','StandardName','DaylightName','BaseUtcOffset','SupportsDaylightSavingTime')
Add-InventorySection 'RoutesReseau' { Get-NetRoute -ErrorAction Stop } @('InterfaceIndex','DestinationPrefix','NextHop','RouteMetric','Protocol','State','AddressFamily')
Add-InventorySection 'ServicesWindows' { Get-CimInstance -ClassName Win32_Service -OperationTimeoutSec 15 -ErrorAction Stop } @('Name','DisplayName','State','StartMode','StartName','ExitCode')
# Win32_Product is deliberately not queried: enumerating it can repair/reconfigure MSI applications.
foreach ($view in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $category=if ($view.StartsWith('HKCU')) {'LogicielsUtilisateur'} elseif ($view -match 'WOW6432Node') {'Logiciels32bits'} else {'Logiciels64bits'}
    Add-InventorySection $category { Get-ItemProperty -Path $view -ErrorAction Stop | Where-Object { $_.DisplayName } | Sort-Object DisplayName,DisplayVersion } @('DisplayName','DisplayVersion','Publisher','InstallDate','EstimatedSize','InstallLocation','SystemComponent','ReleaseType')
}
Add-InventorySection 'ApplicationsStore' { Get-AppxPackage -AllUsers -ErrorAction Stop | Sort-Object Name,Version } @('Name','PackageFullName','Version','Architecture','Publisher','SignatureKind','Status')

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$xmlPath=Join-Path $OutputDirectory 'Inventaire-Technique.xml'
$csvPath=Join-Path $OutputDirectory 'Inventaire-Technique.csv'
$xmlTemp=$xmlPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
$csvTemp=$csvPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
try {
    $settings=New-Object Xml.XmlWriterSettings
    $settings.Indent=$true;$settings.Encoding=New-Object Text.UTF8Encoding($true)
    $writer=[Xml.XmlWriter]::Create($xmlTemp,$settings)
    try {
        $writer.WriteStartDocument();$writer.WriteStartElement('InventaireOrdinateur')
        $writer.WriteAttributeString('schemaVersion','1');$writer.WriteAttributeString('ordinateur',$computer);$writer.WriteAttributeString('collecteUTC',$collected)
        $writer.WriteStartElement('Collecte')
        $writer.WriteElementString('Portee','Inventaire technique accessible a Windows. Les absences et erreurs de fournisseur sont explicites. Aucune cle de produit, mot de passe, cle TPM ou cle BitLocker.')
        foreach ($section in $sections) {
            $writer.WriteStartElement('Section');$writer.WriteAttributeString('nom',$section.Nom);$writer.WriteAttributeString('etat',$section.Etat);$writer.WriteAttributeString('elements',[string]$section.Elements)
            if ($section.Erreur) { $writer.WriteElementString('Erreur',$section.Erreur) }
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement();$writer.WriteStartElement('Proprietes')
        foreach ($row in $rows) {
            $writer.WriteStartElement('Propriete');$writer.WriteAttributeString('categorie',$row.Categorie);$writer.WriteAttributeString('element',[string]$row.Element);$writer.WriteAttributeString('nom',$row.Propriete);$writer.WriteAttributeString('type',$row.Type);$writer.WriteAttributeString('etat',$row.Etat)
            $writer.WriteString($row.Valeur);$writer.WriteEndElement()
        }
        $writer.WriteEndElement();$writer.WriteEndElement();$writer.WriteEndDocument()
    } finally { $writer.Dispose() }
    # Semicolon + UTF-8 BOM for Excel. Prefix formula-looking strings only in CSV.
    $csvEncoding=if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $rows | ForEach-Object {
        $csvRow=$_.PSObject.Copy()
        foreach ($property in $csvRow.PSObject.Properties) {
            if ($property.Value -is [string] -and $property.Value -match '^[\s]*[=+@-]') { $property.Value="'" + $property.Value }
        }
        $csvRow
    } | Export-Csv -LiteralPath $csvTemp -Delimiter ';' -Encoding $csvEncoding -NoTypeInformation
    foreach ($pair in @(@($xmlTemp,$xmlPath),@($csvTemp,$csvPath))) {
        if ([IO.File]::Exists($pair[1])) {
            $backup=$pair[1] + '.previous-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Replace($pair[0],$pair[1],$backup)
            [IO.File]::Delete($backup)
        } else { [IO.File]::Move($pair[0],$pair[1]) }
    }
} finally {
    foreach ($path in @($xmlTemp,$csvTemp)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
[pscustomobject]@{XmlPath=$xmlPath;CsvPath=$csvPath;Sections=$sections.Count;Proprietes=$rows.Count;SectionsIndisponibles=@($sections | Where-Object { $_.Etat -eq 'indisponible' }).Count;CollecteUTC=$collected}
