<#
.SYNOPSIS
    Downloads the Microsoft Win32 Content Prep Tool (IntuneWinAppUtil.exe) from the official GitHub repository.
.DESCRIPTION
    The tool is required to package PSADT deployments as .intunewin files for Intune.
    Run this script once before using Invoke-WinGetAutomater.ps1.
.EXAMPLE
    .\tools\Get-IntuneWinAppUtil.ps1
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$DestinationPath = (Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe')
)

$downloadUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'

if (Test-Path $DestinationPath) {
    Write-Host "IntuneWinAppUtil.exe already exists at: $DestinationPath" -ForegroundColor Yellow
    $overwrite = Read-Host "Overwrite? (y/N)"
    if ($overwrite -ne 'y') { exit 0 }
}

Write-Host "Downloading IntuneWinAppUtil.exe..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $downloadUrl -OutFile $DestinationPath -UseBasicParsing

$hash = (Get-FileHash $DestinationPath -Algorithm SHA256).Hash
Write-Host "Downloaded to: $DestinationPath" -ForegroundColor Green
Write-Host "SHA256: $hash"
Write-Host "`nReady. You can now run Invoke-WinGetAutomater.ps1." -ForegroundColor Green
