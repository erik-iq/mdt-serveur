# Functions only: safe to load for XML validation without executing Windows setup.
function New-AtelierUnattend {
    param([Parameter(Mandatory)][psobject]$Plan)
    $settings = $Plan.settings
    if (-not $settings) {
        $settings = [pscustomobject]@{keyboard='040c:0000040c'; timezone='Romance Standard Time'; user_locale=$Plan.locale; registered_owner=''; organization=''}
    }
    $escape = { param($value) [Security.SecurityElement]::Escape([string]$value) }
    $hostname = & $escape $Plan.hostname
    $language = & $escape $Plan.locale
    $keyboard = & $escape $settings.keyboard
    $region = & $escape $settings.user_locale
    $zone = & $escape $settings.timezone
    $owner = & $escape $settings.registered_owner
    $organization = & $escape $settings.organization
    $identity = ''
    if ($owner) { $identity += "<RegisteredOwner>$owner</RegisteredOwner>" }
    if ($organization) { $identity += "<RegisteredOrganization>$organization</RegisteredOrganization>" }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
 <settings pass="specialize">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <ComputerName>$hostname</ComputerName><TimeZone>$zone</TimeZone>
   $identity
  </component>
 </settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <InputLocale>$keyboard</InputLocale><SystemLocale>$language</SystemLocale><UILanguage>$language</UILanguage><UserLocale>$region</UserLocale>
  </component>
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <FirstLogonCommands>
    <SynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add">
     <Order>1</Order><Description>Atelier PXE - logiciels et personnalisation</Description>
     <CommandLine>powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\AtelierPXE\FirstLogon.ps1"</CommandLine>
    </SynchronousCommand>
   </FirstLogonCommands>
  </component>
 </settings>
</unattend>
"@
    [xml]$validated = $xml
    return $xml
}

function Test-AtelierManufacturer {
    param([string]$Target, [string]$Actual)
    switch ($Target) {
        'all' { return $true }
        'hp' { return $Actual -match '(^HP\b|Hewlett[- ]Packard)' }
        'lenovo' { return $Actual -match '^LENOVO\b' }
        default { throw 'Constructeur cible inconnu.' }
    }
}
