# Registry-Key vor Installation setzen (z.B. vorhandene Konfiguration sichern)
$regPath = 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'
if (-not (Test-Path $regPath)) {
    New-Item $regPath -Force | Out-Null
}
Set-ItemProperty -Path $regPath -Name 'bUpdater'       -Value 0 -Type DWord -Force
Set-ItemProperty -Path $regPath -Name 'bUsageMeasurement' -Value 0 -Type DWord -Force
Write-ADTLogEntry -Message 'Adobe Reader policy keys set.'
