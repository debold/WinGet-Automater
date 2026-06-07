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
        [string]$Version  = '4.0.4',
        [string]$CachePath = (Join-Path $env:TEMP 'PSADT-Cache')
    )

    $psadtPath  = Join-Path $CachePath "PSADT-$Version"
    $markerFile = Join-Path $psadtPath '.ready'
    $adtFolder  = Join-Path $psadtPath 'AppDeployToolkit'

    if ((Test-Path $markerFile) -and (Test-Path $adtFolder)) {
        Write-Verbose "Using cached PSADT $Version from $psadtPath"
        return $psadtPath
    }

    Write-Host "Downloading PSADT v$Version from GitHub..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $psadtPath -Force | Out-Null

    $zipPath = "$psadtPath.zip"
    $zipUrl  = "https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/download/$Version/PSAppDeployToolkit_$Version.zip"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Remove-Item $psadtPath -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to download PSADT v$Version from $zipUrl.`nError: $_`nPlease download manually from https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases"
    }

    $extractPath = "$psadtPath-extract"
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    Remove-Item $zipPath

    # Locate the AppDeployToolkit folder anywhere in the extracted archive
    $found = Get-ChildItem $extractPath -Recurse -Directory -Filter 'AppDeployToolkit' | Select-Object -First 1
    if ($found) {
        Copy-Item $found.FullName -Destination $psadtPath -Recurse -Force
    } else {
        # Fallback: copy everything from the first top-level directory
        $topLevel = Get-ChildItem $extractPath -Directory | Select-Object -First 1
        if ($topLevel) {
            Get-ChildItem $topLevel.FullName | Copy-Item -Destination $psadtPath -Recurse -Force
        }
    }
    Remove-Item $extractPath -Recurse -Force

    if (-not (Test-Path $adtFolder)) {
        throw "PSADT extraction failed: 'AppDeployToolkit' folder not found after unzipping."
    }

    New-Item -ItemType File -Path $markerFile -Force | Out-Null
    Write-Host "PSADT v$Version cached at $psadtPath" -ForegroundColor Green
    return $psadtPath
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

        [string]$PSADTVersion   = '4.0.4',
        [string]$PSADTCachePath = (Join-Path $env:TEMP 'PSADT-Cache')
    )

    $packageFolder = Join-Path $OutputPath $PackageInfo.PackageId $PackageInfo.Version
    Write-Host "Building package: $packageFolder"

    # Create folder structure
    New-Item -ItemType Directory -Path (Join-Path $packageFolder 'Files')        -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $packageFolder 'SupportFiles') -Force | Out-Null

    # Copy PSADT framework
    $psadtSource = Get-PSADTFramework -Version $PSADTVersion -CachePath $PSADTCachePath
    $adtDest     = Join-Path $packageFolder 'AppDeployToolkit'
    Write-Verbose "Copying PSADT framework to $adtDest..."
    Copy-Item -Path (Join-Path $psadtSource 'AppDeployToolkit') -Destination $adtDest -Recurse -Force

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

    # Generate Deploy-Application.ps1
    $installBlock, $uninstallBlock, $repairBlock = Get-PSADTInstallBlocks -PackageInfo $PackageInfo -InstallerFileName $installerFileName
    $closeApps = ($PackageInfo.Name -replace '[^a-zA-Z0-9_]', '').ToLower()

    $script = Get-Content $TemplatePath -Raw
    $script = $script -replace '{{PACKAGE_ID}}',   $PackageInfo.PackageId
    $script = $script -replace '{{PUBLISHER}}',    ($PackageInfo.Publisher  -replace "'", "''")
    $script = $script -replace '{{APP_NAME}}',     ($PackageInfo.Name       -replace "'", "''")
    $script = $script -replace '{{VERSION}}',      $PackageInfo.Version
    $script = $script -replace '{{ARCHITECTURE}}', $PackageInfo.Architecture
    $script = $script -replace '{{SETUP_FILE}}',   $installerFileName
    $script = $script -replace '{{CLOSE_APPS}}',   $closeApps
    $script = $script -replace '{{INSTALL_BLOCK}}',   $installBlock
    $script = $script -replace '{{UNINSTALL_BLOCK}}', $uninstallBlock
    $script = $script -replace '{{REPAIR_BLOCK}}',    $repairBlock

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
        throw "IntuneWinAppUtil.exe not found at '$ToolPath'.`nRun: .\tools\Get-IntuneWinAppUtil.ps1"
    }

    if (-not $OutputPath) {
        $OutputPath = Join-Path (Split-Path $PackagePath -Parent) 'intunewin'
    }
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

    # Clean previous output for this package
    Get-ChildItem $OutputPath -Filter '*.intunewin' | Remove-Item -Force

    Write-Host "Packaging with IntuneWinAppUtil..."
    $proc = Start-Process -FilePath $ToolPath `
        -ArgumentList "-c `"$PackagePath`" -s `"Deploy-Application.ps1`" -o `"$OutputPath`" -q" `
        -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0) {
        throw "IntuneWinAppUtil.exe exited with code $($proc.ExitCode)"
    }

    $result = Get-ChildItem $OutputPath -Filter '*.intunewin' | Select-Object -First 1
    if (-not $result) {
        throw "No .intunewin file found in '$OutputPath' after packaging."
    }

    Write-Host "Created: $($result.FullName)" -ForegroundColor Green
    return $result.FullName
}

Export-ModuleMember -Function Get-PSADTFramework, New-PSADTPackage, Invoke-IntuneWinPackaging
