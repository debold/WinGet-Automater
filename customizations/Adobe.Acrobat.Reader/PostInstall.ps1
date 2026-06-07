# Shortcut auf dem Public Desktop entfernen
$desktopLink = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Adobe Acrobat.lnk'
if (Test-Path $desktopLink) {
    Remove-Item $desktopLink -Force
    Write-ADTLogEntry -Message 'Public Desktop shortcut removed.'
}

# Adobe Updater-Dienst deaktivieren
$svc = Get-Service -Name 'AdobeARMservice' -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service  $svc.Name -Force -ErrorAction SilentlyContinue
    Set-Service   $svc.Name -StartupType Disabled
    Write-ADTLogEntry -Message 'AdobeARMservice disabled.'
}
