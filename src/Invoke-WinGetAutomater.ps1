<#
.SYNOPSIS
    WinGet-Automater – builds PSADT v4 packages from WinGet manifests and registers them in Intune.

.DESCRIPTION
    Queries the WinGet community repository on GitHub, builds a PSADT v4 deployment package,
    packages it as a .intunewin file, and registers it as a Win32 LOB app in Microsoft Intune.

.PARAMETER PackageId
    Single WinGet package ID to process, e.g. "VideoLAN.VLC".

.PARAMETER AppsFile
    Path to a JSON file listing multiple packages (batch mode). See config/apps.example.json.

.PARAMETER ConfigFile
    Path to the JSON configuration file. Defaults to ..\config\config.json relative to this script.

.PARAMETER OutputPath
    Override the output directory for built packages (overrides config.build.outputPath).

.PARAMETER SkipUpload
    Build the package only; skip the Intune upload step.

.PARAMETER Review
    Pause after building the PSADT package and wait for confirmation before packaging and upload.
    Opens the package folder (Explorer on Windows) so you can inspect and edit Deploy-Application.ps1.

.PARAMETER CustomizationsPath
    Path to the customizations folder. Each subdirectory named after a PackageId can contain
    PreInstall.ps1, PostInstall.ps1, PreUninstall.ps1, PostUninstall.ps1 and package.json.
    Defaults to "customizations" relative to the project root.

.PARAMETER Force
    Re-build even if the package folder already exists (overwrites).

.EXAMPLE
    .\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC"

.EXAMPLE
    .\Invoke-WinGetAutomater.ps1 -AppsFile "config\apps.json" -Verbose

.EXAMPLE
    .\Invoke-WinGetAutomater.ps1 -PackageId "Mozilla.Firefox" -SkipUpload -OutputPath "C:\Packages"

.EXAMPLE
    .\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -Review
    # Pauses after the PSADT package is built, opens the folder in Explorer,
    # and waits for confirmation before packaging (.intunewin) and Intune upload.
#>
#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'SinglePackage')]
param(
    [Parameter(ParameterSetName = 'SinglePackage', Mandatory, Position = 0)]
    [string]$PackageId,

    [Parameter(ParameterSetName = 'BatchMode', Mandatory)]
    [string]$AppsFile,

    [string]$ConfigFile         = (Join-Path $PSScriptRoot '..\config\config.json'),
    [string]$OutputPath,
    [string]$CustomizationsPath = (Join-Path $PSScriptRoot '..\customizations'),
    [switch]$SkipUpload,
    [switch]$Review,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Helper: resolve path relative to script root ────────────────────────────

function Resolve-RelativePath {
    param([string]$Path, [string]$Base = (Split-Path $PSScriptRoot -Parent))
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $Base $Path
}

# ─── Load modules ─────────────────────────────────────────────────────────────

$modulesPath = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modulesPath 'WinGetHelper.psm1')    -Force
Import-Module (Join-Path $modulesPath 'PSADTBuilder.psm1')    -Force
Import-Module (Join-Path $modulesPath 'IntuneUploader.psm1')  -Force

# ─── Load & validate config ───────────────────────────────────────────────────

$configPath = Resolve-RelativePath $ConfigFile
if (-not (Test-Path $configPath)) {
    throw "Config file not found: $configPath`nCopy config\config.example.json to config\config.json and fill in your credentials."
}
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

if (-not $SkipUpload) {
    foreach ($field in @('tenantId','clientId','clientSecret')) {
        if ([string]::IsNullOrWhiteSpace($cfg.auth.$field) -or $cfg.auth.$field -like '*<*') {
            throw "config.json: auth.$field is not configured."
        }
    }
}

$scriptRoot  = Split-Path $PSScriptRoot -Parent
$toolsPath   = Resolve-RelativePath ($cfg.build.intuneWinToolPath ?? 'tools\IntuneWinAppUtil.exe')
$templatePath = Join-Path $scriptRoot 'templates\Deploy-Application.ps1.template'

$resolvedOut = if ($OutputPath) { $OutputPath } else {
    Resolve-RelativePath ($cfg.build.outputPath ?? 'output')
}

# ─── Collect package list ─────────────────────────────────────────────────────

$packages = if ($PSCmdlet.ParameterSetName -eq 'SinglePackage') {
    @([PSCustomObject]@{ PackageId = $PackageId; Version = $null })
} else {
    if (-not (Test-Path $AppsFile)) { throw "Apps file not found: $AppsFile" }
    (Get-Content $AppsFile -Raw | ConvertFrom-Json).packages
}

# ─── Authenticate ─────────────────────────────────────────────────────────────

$token = $null
if (-not $SkipUpload) {
    Write-Host "`nAuthenticating with Microsoft Graph..." -ForegroundColor Cyan
    $token = Get-GraphToken -TenantId     $cfg.auth.tenantId `
                            -ClientId     $cfg.auth.clientId `
                            -ClientSecret $cfg.auth.clientSecret
    Write-Host "Authentication successful." -ForegroundColor Green
}

# ─── Process each package ─────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($pkg in $packages) {
    $pkgId = $pkg.PackageId
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host " $pkgId" -ForegroundColor White
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    try {
        # 1 – Fetch WinGet manifest
        Write-Host "[1/4] Fetching WinGet manifest..."
        $ghToken     = if ($cfg.github.token -and $cfg.github.token -notlike '*<*') { $cfg.github.token } else { $null }
        $packageInfo = Get-WinGetManifest -PackageId $pkgId `
            -Version ($pkg.Version ?? $null) -GitHubToken $ghToken

        # 2 – Build PSADT package
        $packageFolder = Join-Path $resolvedOut $pkgId $packageInfo.Version

        if ((Test-Path $packageFolder) -and -not $Force) {
            Write-Host "[2/4] Package folder already exists, skipping build (use -Force to rebuild)." -ForegroundColor Yellow
        } else {
            Write-Host "[2/4] Building PSADT v4 package..."
            $packageFolder = New-PSADTPackage -PackageInfo $packageInfo `
                -OutputPath $resolvedOut -TemplatePath $templatePath `
                -PSADTVersion ($cfg.build.psadtVersion ?? '4.0.4') `
                -CustomizationsPath $CustomizationsPath
        }

        # 2b – Review pause
        if ($Review) {
            $deployScript = Join-Path $packageFolder 'Deploy-Application.ps1'
            Write-Host ""
            Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
            Write-Host "  │  REVIEW MODE – Inspect and edit before packaging        │" -ForegroundColor Yellow
            Write-Host "  ├─────────────────────────────────────────────────────────┤" -ForegroundColor Yellow
            Write-Host "  │  Package folder:                                        │" -ForegroundColor Yellow
            Write-Host "  │  $packageFolder" -ForegroundColor Cyan
            Write-Host "  │                                                         │" -ForegroundColor Yellow
            Write-Host "  │  Main script:                                           │" -ForegroundColor Yellow
            Write-Host "  │  $deployScript" -ForegroundColor Cyan
            Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
            Write-Host ""

            # Try to open the package folder for easy editing
            if ($IsWindows) {
                Start-Process explorer.exe $packageFolder -ErrorAction SilentlyContinue
            } elseif ($IsMacOS) {
                Start-Process open $packageFolder -ErrorAction SilentlyContinue
            }

            $response = ''
            while ($response -notin @('', 's', 'skip', 'a', 'abort')) {
                $response = (Read-Host "  Press [Enter] to continue, [S] to skip this package, [A] to abort all").Trim().ToLower()
            }

            if ($response -in @('a', 'abort')) {
                Write-Host "Aborted by user." -ForegroundColor Red
                break
            }
            if ($response -in @('s', 'skip')) {
                Write-Host "Skipped: $pkgId" -ForegroundColor Yellow
                $results.Add([PSCustomObject]@{
                    PackageId = $pkgId; Version = $packageInfo.Version
                    Status    = 'Skipped'
                })
                continue
            }
        }

        # 3 – Create .intunewin
        Write-Host "[3/4] Packaging with IntuneWinAppUtil..."
        $intuneWinDir  = Join-Path (Split-Path $packageFolder -Parent) 'intunewin'
        $intuneWinPath = Invoke-IntuneWinPackaging -PackagePath $packageFolder `
            -ToolPath $toolsPath -OutputPath $intuneWinDir

        if ($SkipUpload) {
            Write-Host "SkipUpload: done. Package at: $intuneWinPath" -ForegroundColor Yellow
            $results.Add([PSCustomObject]@{
                PackageId    = $pkgId
                Version      = $packageInfo.Version
                Status       = 'Built'
                IntuneWinPath = $intuneWinPath
            })
            continue
        }

        # 4 – Upload to Intune
        Write-Host "[4/4] Uploading to Intune..."

        # Version policy: skip or update existing
        $existingApps = Find-ExistingIntuneApp -Token $token -DisplayName $packageInfo.Name
        $existingAppId = $null

        if ($existingApps.Count -gt 0) {
            $latest = $existingApps | Sort-Object displayVersion -Descending | Select-Object -First 1
            $cmp    = Compare-AppVersion -NewVersion $packageInfo.Version -ExistingVersion ($latest.displayVersion ?? '0.0')

            if ($cmp -eq 0) {
                Write-Host "Version $($packageInfo.Version) already exists in Intune. Skipping upload." -ForegroundColor Yellow
                $results.Add([PSCustomObject]@{
                    PackageId = $pkgId; Version = $packageInfo.Version
                    Status = 'AlreadyExists'; AppId = $latest.id
                })
                continue
            }
            if ($cmp -lt 0) {
                Write-Host "Newer version already in Intune ($($latest.displayVersion)). Skipping." -ForegroundColor Yellow
                $results.Add([PSCustomObject]@{
                    PackageId = $pkgId; Version = $packageInfo.Version
                    Status = 'NewerExists'; AppId = $latest.id
                })
                continue
            }

            Write-Host "Updating $($latest.displayVersion) → $($packageInfo.Version)"
            $existingAppId = $latest.id
        }

        $uploadResult = Publish-IntuneWin32App -Token $token `
            -PackageInfo $packageInfo -IntuneWinPath $intuneWinPath `
            -DefaultPublisher ($cfg.intune.defaultPublisher ?? 'WinGet-Automater') `
            -ExistingAppId $existingAppId

        # Optional group assignment
        if ($cfg.intune.assignmentGroupId -and $cfg.intune.assignmentGroupId -notlike '*<*') {
            Add-IntuneAppGroupAssignment -Token $token -AppId $uploadResult.AppId `
                -GroupId $cfg.intune.assignmentGroupId `
                -Intent ($cfg.intune.assignmentIntent ?? 'available')
        }

        $results.Add([PSCustomObject]@{
            PackageId = $pkgId; Version = $packageInfo.Version
            Status    = if ($existingAppId) { 'Updated' } else { 'Uploaded' }
            AppId     = $uploadResult.AppId
        })

        Write-Host "Done: $pkgId $($packageInfo.Version)" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to process '$pkgId': $_"
        $results.Add([PSCustomObject]@{
            PackageId = $pkgId
            Status    = 'Error'
            Error     = $_.ToString()
        })
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────

$ok    = ($results | Where-Object Status -in 'Uploaded','Updated','Built').Count
$skip  = ($results | Where-Object Status -in 'AlreadyExists','NewerExists','Skipped').Count
$fail  = ($results | Where-Object Status -eq 'Error').Count

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Summary  ✓ $ok  ─ $skip skipped  ✗ $fail errors" -ForegroundColor White
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
$results | Format-Table PackageId, Version, Status, AppId -AutoSize

return $results
