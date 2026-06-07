#Requires -Version 7.0
<#
.SYNOPSIS
    Standalone Intune upload test using a pre-built .intunewin for Evernote.
    Skips all WinGet manifest fetching and PSADT building.
    Edit the $packageInfo hashtable below to test different parameters.
#>

[CmdletBinding()]
param(
    [switch]$DeleteExisting    # Delete any existing Evernote app from Intune before testing
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Config ───────────────────────────────────────────────────────────────────
$configPath    = Join-Path $PSScriptRoot 'config\config.json'
$intuneWinPath = Join-Path $PSScriptRoot 'output\Evernote.Evernote\intunewin\11.19.4\Deploy-Application.intunewin'

$config = Get-Content $configPath | ConvertFrom-Json

# ── Hardcoded Evernote package info ──────────────────────────────────────────
$packageInfo = [ordered]@{
    PackageId         = 'Evernote.Evernote'
    Version           = '11.19.4'
    Name              = 'Evernote'
    Publisher         = 'Evernote Corporation'
    Description       = 'Evernote - note taking app'
    InformationUrl    = 'https://evernote.com'
    PrivacyUrl        = 'https://evernote.com/privacy'
    InstallerType     = 'nullsoft'
    ProductCode       = 'e4251011-875e-51f3-a464-121adaff5aaa'
    Architecture      = 'x64'
}

# ── Load module ───────────────────────────────────────────────────────────────
Import-Module (Join-Path $PSScriptRoot 'src\modules\IntuneUploader.psm1') -Force

# ── Auth ──────────────────────────────────────────────────────────────────────
Write-Host "Authenticating..." -ForegroundColor Cyan
$token = Get-GraphToken -TenantId $config.auth.tenantId `
                        -ClientId $config.auth.clientId `
                        -ClientSecret $config.auth.clientSecret
Write-Host "  Token obtained." -ForegroundColor Green

# ── Optional: delete existing app ────────────────────────────────────────────
if ($DeleteExisting) {
    Write-Host "Looking for existing Evernote apps to delete..." -ForegroundColor Yellow
    $allApps = Get-AllIntuneWin32Apps -Token $token
    $pattern = "WinGet-PackageId:\s*$([regex]::Escape($packageInfo.PackageId))(?=[\r\n\s]|$)"
    $found  = @($allApps | Where-Object { $_.notes -match $pattern })
    if ($found.Count -gt 0) {
        $delHeaders = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
        foreach ($app in $found) {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)" `
                -Method Delete -Headers $delHeaders
            Write-Host "  Deleted app: $($app.id)  ($($app.displayName))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No existing apps found." -ForegroundColor Gray
    }
}

# ── Show what we're about to send ────────────────────────────────────────────
Write-Host ""
Write-Host "Package : $($packageInfo.PackageId) v$($packageInfo.Version)"
Write-Host "Installer: $($packageInfo.InstallerType)  ProductCode: $($packageInfo.ProductCode)"
Write-Host "IntuneWin: $intuneWinPath  ($([Math]::Round((Get-Item $intuneWinPath).Length/1MB,1)) MB)"
Write-Host ""

# ── Upload ────────────────────────────────────────────────────────────────────
Write-Host "Starting Intune upload..." -ForegroundColor Cyan
try {
    $result = Publish-IntuneWin32App `
        -Token            $token `
        -PackageInfo      $packageInfo `
        -IntuneWinPath    $intuneWinPath `
        -DefaultPublisher $config.intune.defaultPublisher

    Write-Host ""
    Write-Host "SUCCESS" -ForegroundColor Green
    Write-Host "  AppId    : $($result.AppId)"
    Write-Host "  VersionId: $($result.VersionId)"
} catch {
    Write-Host ""
    Write-Host "FAILED: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
