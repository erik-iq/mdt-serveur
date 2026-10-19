# One palette for WinPE and the interactive Windows tools.
$script:AtelierTheme=Get-Content (Join-Path $PSScriptRoot 'theme.json') -Encoding UTF8 -Raw | ConvertFrom-Json
function Get-AtelierColor([string]$Name) { return [Drawing.ColorTranslator]::FromHtml($script:AtelierTheme.$Name) }
function New-AtelierFont {
    param([single]$Size=10,[bool]$Bold=$false,[string]$Family='Segoe UI')
    $style=if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    # Four explicitly typed arguments avoid the Font(Font, FontStyle) overload.
    return (New-Object Drawing.Font -ArgumentList @($Family,[single]$Size,$style,[Drawing.GraphicsUnit]::Point))
}
function New-AtelierLogo {
    $picture=New-Object Windows.Forms.PictureBox
    $picture.Size=New-Object Drawing.Size(40,40)
    $picture.Anchor='Top,Right'
    $picture.SizeMode='Zoom';$picture.BackColor=[Drawing.Color]::Transparent
    $picture.Image=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'brand-logo.png'))
    $picture.Add_Disposed({ if ($this.Image) { $this.Image.Dispose() } })
    return $picture
}
function Set-AtelierFormTheme($Control) {
    $Control.ForeColor=Get-AtelierColor 'ink'
    $Control.BackColor=Get-AtelierColor 'paper'
    if ($Control -is [Windows.Forms.Button]) {
        $Control.FlatStyle='Flat';$Control.FlatAppearance.BorderColor=Get-AtelierColor 'line'
        $Control.BackColor=Get-AtelierColor 'surface'
        if ($Control.Tag -eq 'primary') { $Control.BackColor=Get-AtelierColor 'accent';$Control.ForeColor=[Drawing.Color]::White }
    } elseif ($Control -is [Windows.Forms.TextBox] -or $Control -is [Windows.Forms.ComboBox]) { $Control.BackColor=Get-AtelierColor 'surface' }
    foreach ($child in $Control.Controls) { Set-AtelierFormTheme $child }
}
function Set-AtelierGradient($Panel) {
    $Panel.BackColor=Get-AtelierColor 'blue'
    $Panel.Add_Paint({
        $bounds=$this.ClientRectangle
        if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return }
        $brush=New-Object Drawing.Drawing2D.LinearGradientBrush($bounds,(Get-AtelierColor 'blue'),(Get-AtelierColor 'lilac'),[single]0)
        try { $_.Graphics.FillRectangle($brush,$bounds) } finally { $brush.Dispose() }
    })
}
function Set-AtelierProgressTheme($Bar) {
    if (-not ('IQProgressTheme' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class IQProgressTheme { [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id); }'
    }
    [void][IQProgressTheme]::SetWindowTheme($Bar.Handle,'','')
    $Bar.ForeColor=Get-AtelierColor 'accent'
}
