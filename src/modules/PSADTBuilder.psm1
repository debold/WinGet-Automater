#Requires -Version 7.0

function Get-PSADTFramework {
    <#
    .SYNOPSIS
        Downloads PSADT v4 from GitHub releases and caches it locally.
    .OUTPUTS
        Path to the cached PSADT root directory (contains AppDeployToolkit\ subfolder).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Version  = '4.1.8',
        [string]$CachePath = (Join-Path $env:TEMP 'PSADT-Cache')
    )

    $psadtPath   = Join-Path $CachePath "PSADT-$Version"
    $markerFile  = Join-Path $psadtPath '.ready'
    $moduleCheck = Join-Path $psadtPath 'PSAppDeployToolkit'

    if ((Test-Path $markerFile) -and (Test-Path $moduleCheck)) {
        Write-Verbose "Using cached PSADT $Version from $psadtPath"
        return $psadtPath
    }

    if (Test-Path $psadtPath) {
        Write-Host "Refreshing PSADT cache..." -ForegroundColor Yellow
        Remove-Item $psadtPath -Recurse -Force
    }

    Write-Host "Downloading PSADT v$Version from GitHub..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $psadtPath -Force | Out-Null

    $zipPath = "$psadtPath.zip"
    $zipUrl  = "https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/download/$Version/PSAppDeployToolkit_Template_v4.zip"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Remove-Item $psadtPath -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to download PSADT v$Version from $zipUrl.`nError: $_`nPlease download manually from https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases"
    }

    $extractPath = "$psadtPath-extract"
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    Remove-Item $zipPath

    # Copy all top-level contents from the zip's root folder to the cache path.
    # PSADT v4 Template has everything at root: PSAppDeployToolkit\, Config\, Assets\, etc.
    $topLevel = Get-ChildItem $extractPath -Directory | Select-Object -First 1
    $srcRoot  = if ($topLevel) { $topLevel.FullName } else { $extractPath }
    Get-ChildItem $srcRoot | Copy-Item -Destination $psadtPath -Recurse -Force
    Remove-Item $extractPath -Recurse -Force

    if (-not (Test-Path $moduleCheck)) {
        throw "PSADT extraction failed: 'PSAppDeployToolkit' module folder not found after unzipping."
    }

    New-Item -ItemType File -Path $markerFile -Force | Out-Null
    Write-Host "PSADT v$Version cached at $psadtPath" -ForegroundColor Green
    return $psadtPath
}

function Get-PackageCustomization {
    <#
    .SYNOPSIS
        Loads per-package customization snippets and overrides from the customizations folder.
    .PARAMETER PackageId
        WinGet package identifier, e.g. Adobe.Acrobat.Reader.
    .PARAMETER CustomizationsPath
        Root folder that contains per-package subdirectories.
    .OUTPUTS
        Hashtable with keys: PreInstall, PostInstall, PreUninstall, PostUninstall, Overrides.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$PackageId,
        [Parameter(Mandatory)] [string]$CustomizationsPath
    )

    $result = @{
        PreInstall    = ''
        PostInstall   = ''
        PreUninstall  = ''
        PostUninstall = ''
        Overrides     = $null
    }

    $pkgDir = Join-Path $CustomizationsPath $PackageId
    if (-not (Test-Path $pkgDir)) {
        Write-Verbose "No customizations found for $PackageId"
        return $result
    }

    Write-Host "Loading customizations from: $pkgDir" -ForegroundColor Cyan
    foreach ($hook in @('PreInstall', 'PostInstall', 'PreUninstall', 'PostUninstall')) {
        $file = Join-Path $pkgDir "$hook.ps1"
        if (Test-Path $file) {
            $result[$hook] = Get-Content $file -Raw
            Write-Verbose "  Loaded: $hook.ps1"
        }
    }

    $configFile = Join-Path $pkgDir 'package.json'
    if (Test-Path $configFile) {
        $result.Overrides = Get-Content $configFile -Raw | ConvertFrom-Json
        Write-Verbose "  Loaded: package.json"
    }

    return $result
}

function Set-PSADTBranding {
    <#
    .SYNOPSIS
        Applies global company branding to a PSADT package folder (company name, banner, icon).
        Must be called after the AppDeployToolkit\ folder has been copied into the package.
    .PARAMETER PackagePath
        Root of the built package folder (contains AppDeployToolkit\).
    .PARAMETER Branding
        PSCustomObject with optional fields: companyName, bannerImagePath, iconPath.
        Fields that are empty or missing are silently skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PackagePath,
        [Parameter(Mandatory)] [PSCustomObject]$Branding
    )

    # PSADT v4 layout: Config\ holds the XML, Assets\ holds banner and icon
    $configFolder = Join-Path $PackagePath 'Config'
    $assetsFolder = Join-Path $PackagePath 'Assets'
    $configFile   = Join-Path $configFolder 'AppDeployToolkitConfig.xml'

    # ── Company name → Config\AppDeployToolkitConfig.xml ─────────────────────
    if (-not [string]::IsNullOrWhiteSpace($Branding.companyName) -and (Test-Path $configFile)) {
        [xml]$xml = Get-Content $configFile -Encoding UTF8
        $node = $xml.SelectSingleNode('//Toolkit_CompanyName')
        if ($node) {
            $node.InnerText = $Branding.companyName
            $xml.Save($configFile)
            Write-Verbose "Branding: companyName = '$($Branding.companyName)'"
        } else {
            Write-Warning "Branding: <Toolkit_CompanyName> node not found in Config\AppDeployToolkitConfig.xml — skipping."
        }
    }

    # ── Banner image → Assets\ ────────────────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($Branding.bannerImagePath)) {
        $src = $Branding.bannerImagePath
        if (Test-Path $src) {
            $ext  = [System.IO.Path]::GetExtension($src)
            $dest = Join-Path $assetsFolder "AppDeployToolkitBanner$ext"
            New-Item -ItemType Directory -Path $assetsFolder -Force | Out-Null
            Copy-Item $src -Destination $dest -Force
            Write-Verbose "Branding: banner → $dest"
        } else {
            Write-Warning "Branding: bannerImagePath '$src' not found — skipping."
        }
    }

    # ── Icon file → Assets\ ───────────────────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($Branding.iconPath)) {
        $src = $Branding.iconPath
        if (Test-Path $src) {
            $dest = Join-Path $assetsFolder 'AppDeployToolkitIcon.ico'
            New-Item -ItemType Directory -Path $assetsFolder -Force | Out-Null
            Copy-Item $src -Destination $dest -Force
            Write-Verbose "Branding: icon → $dest"
        } else {
            Write-Warning "Branding: iconPath '$src' not found — skipping."
        }
    }
}

function New-PSADTPackage {
    <#
    .SYNOPSIS
        Builds a PSADT v4 deployment package from WinGet package information.
    .PARAMETER PackageInfo
        Package metadata hashtable from Get-WinGetManifest.
    .PARAMETER OutputPath
        Base output directory. Each package lands in {OutputPath}\{PackageId}\{Version}.
    .PARAMETER TemplatePath
        Path to Deploy-Application.ps1.template.
    .PARAMETER PSADTVersion
        PSADT v4 version to download/use. Must match a GitHub release tag.
    .PARAMETER PSADTCachePath
        Where to cache the PSADT download. Defaults to %TEMP%\PSADT-Cache.
    .PARAMETER CustomizationsPath
        Root folder with per-package customization subdirectories.
        If a subfolder matching the PackageId exists, its snippets and overrides are applied.
    .OUTPUTS
        Full path to the built package folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$PackageInfo,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [string]$PSADTVersion        = '4.1.8',
        [string]$PSADTCachePath      = (Join-Path $env:TEMP 'PSADT-Cache'),
        [string]$CustomizationsPath  = '',
        [PSCustomObject]$Branding    = $null
    )

    $packageFolder = Join-Path $OutputPath $PackageInfo.PackageId $PackageInfo.Version
    Write-Host "Building package: $packageFolder"

    # Create folder structure
    New-Item -ItemType Directory -Path (Join-Path $packageFolder 'Files')        -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $packageFolder 'SupportFiles') -Force | Out-Null

    # Copy PSADT framework to package root (v4 layout: PSAppDeployToolkit\, Config\, Assets\, etc.)
    # Files\ and SupportFiles\ are managed by this script — skip them from the PSADT source.
    $psadtSource = Get-PSADTFramework -Version $PSADTVersion -CachePath $PSADTCachePath
    Write-Verbose "Copying PSADT framework to $packageFolder..."
    Get-ChildItem $psadtSource |
        Where-Object { $_.Name -notin @('Files', 'SupportFiles') } |
        ForEach-Object {
            $dest = Join-Path $packageFolder $_.Name
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Copy-Item $_.FullName -Destination $dest -Recurse -Force
        }

    # Apply global branding (company name, banner, icon)
    if ($Branding) {
        Set-PSADTBranding -PackagePath $packageFolder -Branding $Branding
    }

    # Download installer
    $installerFileName = Get-WinGetInstallerFileName -PackageInfo $PackageInfo
    $installerDest     = Join-Path $packageFolder 'Files' $installerFileName
    Write-Host "Downloading installer: $($PackageInfo.InstallerUrl)"
    Invoke-WebRequest -Uri $PackageInfo.InstallerUrl -OutFile $installerDest -UseBasicParsing

    # Verify SHA256
    if ($PackageInfo.InstallerSha256) {
        $hash = (Get-FileHash -Path $installerDest -Algorithm SHA256).Hash
        if ($hash -ne $PackageInfo.InstallerSha256.ToUpper()) {
            throw "SHA256 mismatch!`n  Expected: $($PackageInfo.InstallerSha256.ToUpper())`n  Got:      $hash"
        }
        Write-Verbose "SHA256 verified: $hash"
    }

    # Load per-package customizations
    $customization = if ($CustomizationsPath -and (Test-Path $CustomizationsPath)) {
        Get-PackageCustomization -PackageId $PackageInfo.PackageId -CustomizationsPath $CustomizationsPath
    } else {
        @{ PreInstall = ''; PostInstall = ''; PreUninstall = ''; PostUninstall = ''; Overrides = $null }
    }

    # Inject extra files from customizations\<PackageId>\Files\ and SupportFiles\
    if ($CustomizationsPath) {
        foreach ($subFolder in @('Files', 'SupportFiles')) {
            $srcDir  = Join-Path (Join-Path $CustomizationsPath $PackageInfo.PackageId) $subFolder
            $destDir = Join-Path $packageFolder $subFolder
            if (Test-Path $srcDir) {
                $items = Get-ChildItem $srcDir -Recurse -File
                foreach ($item in $items) {
                    $rel  = [System.IO.Path]::GetRelativePath($srcDir, $item.FullName)
                    $dest = Join-Path $destDir $rel
                    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                    Copy-Item $item.FullName -Destination $dest -Force
                    Write-Host "  + $subFolder\$rel" -ForegroundColor DarkCyan
                }
                Write-Verbose "Injected $($items.Count) file(s) into $subFolder\"
            }
        }
    }

    # Apply overrides from package.json (closeApps, installSwitches)
    if ($customization.Overrides) {
        if ($customization.Overrides.PSObject.Properties['installSwitches']) {
            $PackageInfo.InstallerSwitches = $customization.Overrides.installSwitches
            Write-Verbose "Override: installSwitches = $($customization.Overrides.installSwitches)"
        }
    }

    # Generate Deploy-Application.ps1
    $installBlock, $uninstallBlock, $repairBlock = Get-PSADTInstallBlocks -PackageInfo $PackageInfo -InstallerFileName $installerFileName

    $closeApps = if ($customization.Overrides?.closeApps) {
        $customization.Overrides.closeApps
    } else {
        ($PackageInfo.Name -replace '[^a-zA-Z0-9_]', '').ToLower()
    }

    $script = Get-Content $TemplatePath -Raw
    $script = $script -replace '{{PACKAGE_ID}}',        $PackageInfo.PackageId
    $script = $script -replace '{{PUBLISHER}}',         ($PackageInfo.Publisher  -replace "'", "''")
    $script = $script -replace '{{APP_NAME}}',          ($PackageInfo.Name       -replace "'", "''")
    $script = $script -replace '{{VERSION}}',           $PackageInfo.Version
    $script = $script -replace '{{ARCHITECTURE}}',      $PackageInfo.Architecture
    $script = $script -replace '{{SETUP_FILE}}',        $installerFileName
    $script = $script -replace '{{CLOSE_APPS}}',        $closeApps
    $script = $script -replace '{{INSTALL_BLOCK}}',     $installBlock
    $script = $script -replace '{{UNINSTALL_BLOCK}}',   $uninstallBlock
    $script = $script -replace '{{REPAIR_BLOCK}}',      $repairBlock
    $script = $script -replace '{{PRE_INSTALL_BLOCK}}',    $customization.PreInstall
    $script = $script -replace '{{POST_INSTALL_BLOCK}}',   $customization.PostInstall
    $script = $script -replace '{{PRE_UNINSTALL_BLOCK}}',  $customization.PreUninstall
    $script = $script -replace '{{POST_UNINSTALL_BLOCK}}', $customization.PostUninstall

    Set-Content -Path (Join-Path $packageFolder 'Deploy-Application.ps1') -Value $script -Encoding UTF8

    Write-Host "Package ready: $packageFolder" -ForegroundColor Green
    return $packageFolder
}

function Get-PSADTInstallBlocks {
    param(
        [System.Collections.Specialized.OrderedDictionary]$PackageInfo,
        [string]$InstallerFileName
    )

    $silentArgs  = $PackageInfo.InstallerSwitches
    $productCode = $PackageInfo.ProductCode
    $type        = $PackageInfo.InstallerType?.ToLower()

    switch -Regex ($type) {
        '^msi$' {
            $msiArgs   = if ($silentArgs) { $silentArgs } else { 'ALLUSERS=1 REBOOT=ReallySuppress' }
            $install   = "Invoke-ADTMsiexec -Action Install -FilePath `"`$dirFiles\$InstallerFileName`" -ArgumentList '$msiArgs'"
            $uninstall = if ($productCode) {
                "Invoke-ADTMsiexec -Action Uninstall -ProductCode '$productCode'"
            } else {
                "Invoke-ADTMsiexec -Action Uninstall -FilePath `"`$dirFiles\$InstallerFileName`""
            }
            $repair    = "Invoke-ADTMsiexec -Action Repair -FilePath `"`$dirFiles\$InstallerFileName`" -ArgumentList '$msiArgs'"
        }
        '^(msix|appx|msixbundle|appxbundle)$' {
            $install   = "Add-AppxPackage -Path `"`$dirFiles\$InstallerFileName`" -ErrorAction Stop"
            $safeName  = $PackageInfo.Name -replace '[^a-zA-Z0-9.*]', ''
            $uninstall = "Get-AppxPackage -Name '*$safeName*' | Remove-AppxPackage -ErrorAction SilentlyContinue"
            $repair    = $install
        }
        default {
            $installArgs = if ($silentArgs) { $silentArgs } else { '/S' }
            $install     = "Start-ADTProcess -FilePath `"`$dirFiles\$InstallerFileName`" -ArgumentList '$installArgs' -WaitForMsiExec"
            $uninstall   = if ($productCode) {
                "Start-ADTProcess -FilePath 'msiexec.exe' -ArgumentList '/x $productCode /qn /norestart'"
            } else {
                "# TODO: Configure uninstall command for $($PackageInfo.Name)`n            # Example: Start-ADTProcess -FilePath 'C:\Program Files\...\uninstall.exe' -ArgumentList '/S'"
            }
            $repair      = "Start-ADTProcess -FilePath `"`$dirFiles\$InstallerFileName`" -ArgumentList '$installArgs' -WaitForMsiExec"
        }
    }

    return $install, $uninstall, $repair
}

function Invoke-IntuneWinPackaging {
    <#
    .SYNOPSIS
        Wraps IntuneWinAppUtil.exe to create a .intunewin file from a PSADT package folder.
    .OUTPUTS
        Full path to the created .intunewin file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$ToolPath,

        [string]$OutputPath
    )

    if (-not (Test-Path $ToolPath)) {
        Write-Host ""
        Write-Host "IntuneWinAppUtil.exe not found at '$ToolPath'." -ForegroundColor Yellow
        $answer = Read-Host "Download it now? [Y/n]"
        if ($answer -eq '' -or $answer -match '^[Yy]') {
            Write-Host "Downloading IntuneWinAppUtil.exe..." -ForegroundColor Cyan
            New-Item -ItemType Directory -Path (Split-Path $ToolPath -Parent) -Force | Out-Null
            Invoke-WebRequest `
                -Uri 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe' `
                -OutFile $ToolPath `
                -UseBasicParsing
            Write-Host "Downloaded to: $ToolPath" -ForegroundColor Green
        } else {
            throw "IntuneWinAppUtil.exe not found at '$ToolPath'. Run: .\tools\Get-IntuneWinAppUtil.ps1"
        }
    }

    if (-not $OutputPath) {
        $OutputPath = Join-Path (Split-Path $PackagePath -Parent) 'intunewin'
    }
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

    # Clean previous output for this package
    Get-ChildItem $OutputPath -Filter '*.intunewin' | Remove-Item -Force

    Write-Verbose "Packaging with IntuneWinAppUtil..."
    $null = & $ToolPath -c $PackagePath -s 'Deploy-Application.ps1' -o $OutputPath -q 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "IntuneWinAppUtil.exe exited with code $LASTEXITCODE"
    }

    $result = Get-ChildItem $OutputPath -Filter '*.intunewin' | Select-Object -First 1
    if (-not $result) {
        throw "No .intunewin file found in '$OutputPath' after packaging."
    }

    Write-Host "Created: $($result.FullName)" -ForegroundColor Green
    return $result.FullName
}

Export-ModuleMember -Function Get-PSADTFramework, New-PSADTPackage, Invoke-IntuneWinPackaging, Get-PackageCustomization, Set-PSADTBranding
