#Requires -Version 7.0

function Get-WinGetManifest {
    <#
    .SYNOPSIS
        Retrieves package metadata from the WinGet community repository on GitHub.
    .PARAMETER PackageId
        WinGet package identifier, e.g. VideoLAN.VLC
    .PARAMETER Version
        Specific version to fetch. If omitted, the latest available version is used.
    .PARAMETER GitHubToken
        Optional GitHub token to avoid API rate limiting (60 req/h unauthenticated, 5000 authenticated).
    .OUTPUTS
        [ordered] hashtable with package metadata.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][\w.-]+\.[A-Za-z0-9][\w.-]+$')]
        [string]$PackageId,

        [string]$Version,

        [string]$GitHubToken
    )

    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Write-Host "Installing required module: powershell-yaml..." -ForegroundColor Yellow
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module powershell-yaml -Force

    $headers = @{ 'User-Agent' = 'WinGet-Automater/1.0' }
    if ($GitHubToken) { $headers['Authorization'] = "token $GitHubToken" }

    $idParts     = $PackageId -split '\.'
    $firstLetter = $idParts[0][0].ToString().ToLower()
    $manifestBase = "manifests/$firstLetter/$($idParts -join '/')"
    $repoBase     = 'https://api.github.com/repos/microsoft/winget-pkgs/contents'
    $rawBase      = 'https://raw.githubusercontent.com/microsoft/winget-pkgs/master'

    if (-not $Version) {
        Write-Verbose "Resolving latest version for $PackageId..."
        try {
            $versionsResp = Invoke-RestMethod -Uri "$repoBase/$manifestBase" -Headers $headers -ErrorAction Stop
        } catch {
            throw "Package '$PackageId' not found in the WinGet repository. Error: $_"
        }
        $dirs = $versionsResp | Where-Object { $_.type -eq 'dir' }
        $Version = $dirs |
            Sort-Object {
                try { [version]($_.name -replace '[^0-9.]') } catch { [version]'0.0' }
            } -Descending |
            Select-Object -First 1 -ExpandProperty name

        if (-not $Version) {
            throw "No versions found for '$PackageId' in the WinGet repository."
        }
        Write-Verbose "Resolved version: $Version"
    }

    $versionPath   = "$manifestBase/$Version"
    Write-Verbose "Fetching manifest files from $versionPath..."
    $manifestFiles = Invoke-RestMethod -Uri "$repoBase/$versionPath" -Headers $headers

    $result = [ordered]@{
        PackageId         = $PackageId
        Version           = $Version
        Name              = $null
        Publisher         = $null
        Description       = $null
        License           = $null
        InstallerUrl      = $null
        InstallerSha256   = $null
        InstallerType     = $null
        InstallerSwitches = $null
        ProductCode       = $null
        Architecture      = 'x64'
    }

    foreach ($file in $manifestFiles | Where-Object { $_.type -eq 'file' -and $_.name -like '*.yaml' }) {
        $rawUrl  = "$rawBase/$versionPath/$($file.name)"
        Write-Verbose "Reading: $($file.name)"
        $content = (Invoke-WebRequest -Uri $rawUrl -Headers $headers -UseBasicParsing).Content

        if ($file.name -match '\.installer\.yaml$') {
            $data = ConvertFrom-Yaml $content
            $result.InstallerType = $data.InstallerType

            $installer = $data.Installers | Where-Object { $_.Architecture -eq 'x64' } | Select-Object -First 1
            if (-not $installer) { $installer = $data.Installers | Where-Object { $_.Architecture -eq 'x86' } | Select-Object -First 1 }
            if (-not $installer) { $installer = $data.Installers | Select-Object -First 1 }

            if ($installer) {
                $result.InstallerUrl    = $installer.InstallerUrl
                $result.InstallerSha256 = $installer.InstallerSha256
                $result.Architecture    = $installer.Architecture ?? 'x64'
                $result.ProductCode     = $installer.ProductCode ?? $data.ProductCode
                if ($installer.InstallerType) { $result.InstallerType = $installer.InstallerType }
                $switches = $installer.InstallerSwitches ?? $data.InstallerSwitches
                if ($switches) { $result.InstallerSwitches = $switches.Silent ?? $switches.SilentWithProgress }
            }
        }
        elseif ($file.name -match '\.locale\.en-US\.yaml$') {
            $data = ConvertFrom-Yaml $content
            $result.Name        = $data.PackageName
            $result.Publisher   = $data.Publisher
            $result.Description = $data.ShortDescription
            $result.License     = $data.License
        }
        elseif ($file.name -notmatch '\.(installer|locale)\.') {
            $data = ConvertFrom-Yaml $content
            if (-not $result.Name      -and $data.PackageName) { $result.Name = $data.PackageName }
            if (-not $result.Publisher -and $data.Publisher)   { $result.Publisher = $data.Publisher }
        }
    }

    if (-not $result.Name)      { $result.Name = $idParts[-1] }
    if (-not $result.Publisher) { $result.Publisher = $idParts[0] }
    if (-not $result.InstallerUrl) {
        throw "Could not determine installer URL for '$PackageId' version '$Version'."
    }

    Write-Verbose "Resolved: $($result.Name) $($result.Version) [$($result.InstallerType)] $($result.Architecture)"
    return $result
}

function Get-WinGetInstallerFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$PackageInfo
    )

    $ext = switch ($PackageInfo.InstallerType?.ToLower()) {
        'msi'          { '.msi' }
        'msix'         { '.msix' }
        'appx'         { '.appx' }
        'msixbundle'   { '.msixbundle' }
        'appxbundle'   { '.appxbundle' }
        default        { '.exe' }
    }

    $urlPath = ($PackageInfo.InstallerUrl -split '\?')[0]
    $urlFile = [System.IO.Path]::GetFileName($urlPath)
    if ($urlFile -match '\.' -and $urlFile.Length -lt 100) { return $urlFile }

    $safeName = $PackageInfo.Name -replace '[^a-zA-Z0-9_-]', ''
    return "setup_$safeName$ext"
}

Export-ModuleMember -Function Get-WinGetManifest, Get-WinGetInstallerFileName
