#Requires -Version 7.0

$script:GraphBaseUrl = 'https://graph.microsoft.com/v1.0'

# --- Authentication ---

function Get-GraphToken {
    <#
    .SYNOPSIS
        Obtains an OAuth2 access token via client credentials (Service Principal).
    .OUTPUTS
        Bearer token string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$ClientId,
        [Parameter(Mandatory)] [string]$ClientSecret
    )

    $response = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method Post `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type    = 'client_credentials'
            scope         = 'https://graph.microsoft.com/.default'
            client_id     = $ClientId
            client_secret = $ClientSecret
        }

    return $response.access_token
}

function script:Get-GraphHeaders {
    param([string]$Token)
    return @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }
}

# --- App Discovery ---

function Find-ExistingIntuneApp {
    <#
    .SYNOPSIS
        Searches for existing Win32 apps in Intune matching the given display name.
    .OUTPUTS
        Array of matching app objects (may be empty).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$DisplayName
    )

    $encoded = [uri]::EscapeDataString($DisplayName)
    $url = "$script:GraphBaseUrl/deviceAppManagement/mobileApps" +
           "?`$filter=displayName eq '$encoded' and isof('microsoft.graph.win32LobApp')" +
           "&`$select=id,displayName,displayVersion,createdDateTime"

    $response = Invoke-RestMethod -Uri $url -Headers (Get-GraphHeaders $Token)
    return $response.value
}

function Get-AllIntuneWin32Apps {
    <#
    .SYNOPSIS
        Fetches all Win32 LOB apps from Intune in a single paginated call.
        Result includes the notes field so callers can match by WinGet-PackageId.
    .OUTPUTS
        Array of app objects with id, displayName, displayVersion, notes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token
    )

    $apps = [System.Collections.Generic.List[object]]::new()
    $url  = "$script:GraphBaseUrl/deviceAppManagement/mobileApps" +
            "?`$filter=isof('microsoft.graph.win32LobApp')" +
            "&`$select=id,displayName,displayVersion,notes,createdDateTime" +
            "&`$top=999"

    do {
        $resp = Invoke-RestMethod -Uri $url -Headers (Get-GraphHeaders $Token)
        $apps.AddRange([object[]]$resp.value)
        $url = $resp.'@odata.nextLink'
    } while ($url)

    Write-Verbose "Loaded $($apps.Count) Win32 apps from Intune."
    return $apps.ToArray()
}

function Find-IntuneAppByPackageId {
    <#
    .SYNOPSIS
        Finds a Win32 app in a pre-loaded app list by its WinGet-PackageId stored in the notes field.
        Use Get-AllIntuneWin32Apps once per run, then pass the result here for each package.
    .OUTPUTS
        Matching app object, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Apps,
        [Parameter(Mandatory)] [string]$PackageId
    )

    $pattern = "WinGet-PackageId:\s*$([regex]::Escape($PackageId))(?=[\r\n\s]|$)"
    $match   = $Apps | Where-Object { $_.notes -match $pattern }

    if (@($match).Count -gt 1) {
        Write-Warning "Multiple Intune apps found with WinGet-PackageId '$PackageId'. Using the most recently created one."
        $match = @($match) | Sort-Object createdDateTime -Descending | Select-Object -First 1
    }

    return $match | Select-Object -First 1
}

function Compare-AppVersion {
    <#
    .SYNOPSIS
        Returns 1 if $NewVersion > $ExistingVersion, 0 if equal, -1 if older.
    #>
    param([string]$NewVersion, [string]$ExistingVersion)

    try {
        $nv = [version]($NewVersion -replace '[^0-9.]')
        $ev = [version]($ExistingVersion -replace '[^0-9.]')
        return $nv.CompareTo($ev)
    } catch {
        return [string]::Compare($NewVersion, $ExistingVersion, [System.StringComparison]::OrdinalIgnoreCase)
    }
}

# --- App Object Construction ---

function script:New-Win32LobAppBody {
    param(
        [System.Collections.Specialized.OrderedDictionary]$PackageInfo,
        [string]$IntuneWinFileName,
        [string]$DefaultPublisher
    )

    $detectionRule = Get-Win32DetectionRule -PackageInfo $PackageInfo

    $archMap = @{
        x64     = 'x64'
        x86     = 'x86'
        arm64   = 'arm64'
        arm     = 'arm'
        neutral = 'neutral'
    }
    $arch = $archMap[$PackageInfo.Architecture?.ToLower()] ?? 'x64'

    return @{
        '@odata.type'           = '#microsoft.graph.win32LobApp'
        displayName             = $PackageInfo.Name
        displayVersion          = $PackageInfo.Version
        description             = $PackageInfo.Description ?? "$($PackageInfo.Name) – deployed via WinGet-Automater"
        publisher               = $PackageInfo.Publisher ?? $DefaultPublisher
        notes                   = "WinGet-PackageId: $($PackageInfo.PackageId)`nManaged by: WinGet-Automater"
        informationUrl          = $PackageInfo.InformationUrl
        privacyInformationUrl   = $PackageInfo.PrivacyUrl
        fileName                = $IntuneWinFileName
        applicableArchitectures = $arch
        installCommandLine      = 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -File Deploy-Application.ps1 -DeploymentType Install -DeployMode Silent'
        uninstallCommandLine    = 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -File Deploy-Application.ps1 -DeploymentType Uninstall -DeployMode Silent'
        installExperience       = @{
            '@odata.type'         = 'microsoft.graph.win32LobAppInstallExperience'
            runAsAccount          = 'system'
            deviceRestartBehavior = 'suppress'
        }
        returnCodes             = @(
            @{ returnCode = 0;    type = 'success'    }
            @{ returnCode = 1707; type = 'success'    }
            @{ returnCode = 3010; type = 'softReboot' }
            @{ returnCode = 1641; type = 'hardReboot' }
            @{ returnCode = 1618; type = 'retry'      }
        )
        detectionRules          = @($detectionRule)
        minimumSupportedWindowsRelease = '21H1'
        allowAvailableUninstall = $true
    }
}

function Get-Win32DetectionRule {
    <#
    .SYNOPSIS
        Builds the most appropriate detection rule from package metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$PackageInfo
    )

    if ($PackageInfo.InstallerType -eq 'msi' -and $PackageInfo.ProductCode) {
        return @{
            '@odata.type'          = '#microsoft.graph.win32LobAppProductCodeDetection'
            productCode            = $PackageInfo.ProductCode
            productVersionOperator = 'notConfigured'
            productVersion         = $null
        }
    }

    if ($PackageInfo.ProductCode) {
        return @{
            '@odata.type'        = '#microsoft.graph.win32LobAppRegistryDetection'
            check32BitOn64System = $false
            detectionType        = 'exists'
            keyPath              = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($PackageInfo.ProductCode)"
            valueName            = ''
            operator             = 'notConfigured'
            detectionValue       = $null
        }
    }

    # File-based fallback
    return @{
        '@odata.type'        = '#microsoft.graph.win32LobAppFileSystemDetection'
        path                 = "%ProgramFiles%\$($PackageInfo.Publisher)"
        fileOrFolderName     = $PackageInfo.Name
        check32BitOn64System = $false
        detectionType        = 'exists'
        operator             = 'notConfigured'
        detectionValue       = $null
    }
}

# --- .intunewin archive helpers ---

function script:Read-IntuneWinDetectionXml {
    param([string]$IntuneWinPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'Metadata/Detection.xml' } | Select-Object -First 1
        if (-not $entry) { throw "Detection.xml not found inside '$IntuneWinPath'" }
        $reader  = New-Object System.IO.StreamReader($entry.Open())
        $xmlText = $reader.ReadToEnd()
        $reader.Dispose()
        return [xml]$xmlText
    } finally {
        $zip.Dispose()
    }
}

function script:Expand-IntuneWinContent {
    param([string]$IntuneWinPath, [string]$ExtractPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null

    $zip = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinPath)
    try {
        $contentEntry = $zip.Entries | Where-Object { $_.FullName -like 'Contents/*' -and $_.Name } | Select-Object -First 1
        if (-not $contentEntry) { throw "Content entry not found inside '$IntuneWinPath'" }
        $destFile = Join-Path $ExtractPath $contentEntry.Name
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($contentEntry, $destFile, $true)
        return $destFile
    } finally {
        $zip.Dispose()
    }
}

# --- Azure Blob upload ---

function script:Send-AzureBlobChunked {
    param([string]$SasUrl, [string]$FilePath)

    $chunkSize = 4 * 1024 * 1024   # 4 MB
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $totalSize = $fileBytes.Length
    $blockIds  = [System.Collections.Generic.List[string]]::new()
    $chunks    = [Math]::Ceiling($totalSize / $chunkSize)

    Write-Verbose "Uploading $totalSize bytes in $chunks chunks..."

    for ($i = 0; $i -lt $chunks; $i++) {
        $offset  = $i * $chunkSize
        $length  = [Math]::Min($chunkSize, $totalSize - $offset)
        $chunk   = $fileBytes[$offset..($offset + $length - 1)]
        $blockId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($i.ToString('D6')))
        $blockIds.Add($blockId)

        $blockUrl = "${SasUrl}&comp=block&blockid=$([uri]::EscapeDataString($blockId))"
        Invoke-WebRequest -Uri $blockUrl -Method Put -Body $chunk `
            -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -UseBasicParsing | Out-Null

        $pct = [Math]::Round(($i + 1) / $chunks * 100)
        Write-Progress -Activity "Uploading to Azure Blob Storage" -Status "$pct%" -PercentComplete $pct
    }

    # Commit block list
    $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>' +
        (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    Invoke-WebRequest -Uri "${SasUrl}&comp=blocklist" -Method Put `
        -Body $blockListXml -ContentType 'text/xml' -UseBasicParsing | Out-Null

    Write-Progress -Activity "Uploading to Azure Blob Storage" -Completed
    Write-Verbose "Azure Blob upload complete."
}

# --- Upload state polling ---

function script:Wait-IntuneFileState {
    param(
        [string]$Token,
        [string]$AppId,
        [string]$VersionId,
        [string]$FileId,
        [string]$ExpectedState,
        [int]$TimeoutSeconds = 300
    )

    $url      = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/contentVersions/$VersionId/files/$FileId"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $file = Invoke-RestMethod -Uri $url -Headers (Get-GraphHeaders $Token)
        Write-Verbose "File state: $($file.uploadState)"
        if ($file.uploadState -eq $ExpectedState)      { return $file }
        if ($file.uploadState -like '*Fail*' -or
            $file.uploadState -like '*Error*') {
            throw "Upload failed – state: $($file.uploadState)"
        }
    }
    throw "Timeout after ${TimeoutSeconds}s waiting for state '$ExpectedState' (last: '$($file.uploadState)')"
}

# --- Main upload flow ---

function Publish-IntuneWin32App {
    <#
    .SYNOPSIS
        Full Graph API flow: creates or updates the app, uploads the .intunewin, and commits.
    .OUTPUTS
        [PSCustomObject] with AppId and VersionId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$PackageInfo,
        [Parameter(Mandatory)] [string]$IntuneWinPath,
        [string]$DefaultPublisher = 'WinGet-Automater',
        [string]$ExistingAppId
    )

    $iwFileName = [System.IO.Path]::GetFileName($IntuneWinPath)

    # Step 1 – Create or update app object
    $appBody = New-Win32LobAppBody -PackageInfo $PackageInfo `
        -IntuneWinFileName $iwFileName -DefaultPublisher $DefaultPublisher
    $appJson = ConvertTo-Json $appBody -Depth 10

    if ($ExistingAppId) {
        Write-Host "Updating existing Intune app: $ExistingAppId"
        Invoke-RestMethod -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$ExistingAppId" `
            -Method Patch -Headers (Get-GraphHeaders $Token) -Body $appJson | Out-Null
        $appId = $ExistingAppId
    } else {
        Write-Host "Creating new Intune app..."
        $app   = Invoke-RestMethod -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps" `
            -Method Post -Headers (Get-GraphHeaders $Token) -Body $appJson
        $appId = $app.id
        Write-Host "App created: $appId"
    }

    # Step 2 – Create content version
    $cv        = Invoke-RestMethod `
        -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$appId/contentVersions" `
        -Method Post -Headers (Get-GraphHeaders $Token) -Body '{}'
    $versionId = $cv.id
    Write-Verbose "Content version: $versionId"

    # Step 3 – Read .intunewin metadata
    $xml         = Read-IntuneWinDetectionXml -IntuneWinPath $IntuneWinPath
    $appInfoNode = $xml.ApplicationInfo
    $encNode     = $appInfoNode.EncryptionInfo

    $tempDir       = Join-Path $env:TEMP "IntuneUpload_$(New-Guid)"
    $innerFile     = Expand-IntuneWinContent -IntuneWinPath $IntuneWinPath -ExtractPath $tempDir
    $encryptedSize = (Get-Item $innerFile).Length
    $origSize      = [int64]$appInfoNode.UnencryptedContentSize

    # Step 4 – Create file entry and get Azure Blob SAS URI
    $fileBody = @{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'
        name          = $iwFileName
        size          = $origSize
        sizeEncrypted = $encryptedSize
        isDependency  = $false
    } | ConvertTo-Json

    $fileEntry = Invoke-RestMethod `
        -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$appId/contentVersions/$versionId/files" `
        -Method Post -Headers (Get-GraphHeaders $Token) -Body $fileBody
    $fileId = $fileEntry.id
    Write-Verbose "File entry: $fileId"

    # Step 5 – Wait for Azure Storage URI
    Write-Host "Waiting for Azure Storage URI..."
    $fileEntry = Wait-IntuneFileState -Token $Token -AppId $appId -VersionId $versionId `
        -FileId $fileId -ExpectedState 'azureStorageUriRequestSuccess'

    # Step 6 – Upload encrypted content to Azure Blob
    Write-Host "Uploading .intunewin content to Azure Blob Storage..."
    Send-AzureBlobChunked -SasUrl $fileEntry.azureStorageUri -FilePath $innerFile

    # Step 7 – Commit file with encryption metadata
    $commitBody = @{
        fileEncryptionInfo = @{
            encryptionKey        = $encNode.EncryptionKey
            macKey               = $encNode.MacKey
            initializationVector = $encNode.InitializationVector
            mac                  = $encNode.Mac
            profileIdentifier    = $encNode.ProfileIdentifier
            fileDigest           = $encNode.FileDigest
            fileDigestAlgorithm  = $encNode.FileDigestAlgorithm
        }
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$appId/contentVersions/$versionId/files/$fileId/commit" `
        -Method Post -Headers (Get-GraphHeaders $Token) -Body $commitBody | Out-Null

    Write-Host "Waiting for commit confirmation..."
    Wait-IntuneFileState -Token $Token -AppId $appId -VersionId $versionId `
        -FileId $fileId -ExpectedState 'commitFileSuccess' | Out-Null

    # Step 8 – Set committed content version on the app
    $patchBody = @{
        '@odata.type'           = '#microsoft.graph.win32LobApp'
        committedContentVersion = $versionId
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$appId" `
        -Method Patch -Headers (Get-GraphHeaders $Token) -Body $patchBody | Out-Null

    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "App published: $appId  (version: $($PackageInfo.Version))" -ForegroundColor Green
    return [PSCustomObject]@{ AppId = $appId; VersionId = $versionId }
}

function Add-IntuneAppGroupAssignment {
    <#
    .SYNOPSIS
        Assigns an Intune Win32 app to an Azure AD group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$AppId,
        [Parameter(Mandatory)] [string]$GroupId,
        [ValidateSet('available', 'required', 'uninstall')]
        [string]$Intent = 'available'
    )

    $body = @{
        mobileAppAssignments = @(
            @{
                '@odata.type' = '#microsoft.graph.mobileAppAssignment'
                intent        = $Intent
                target        = @{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    groupId       = $GroupId
                }
                settings      = @{
                    '@odata.type'                = '#microsoft.graph.win32LobAppAssignmentSettings'
                    notifications                = 'showAll'
                    installTimeSettings          = $null
                    restartSettings              = $null
                    deliveryOptimizationPriority = 'notConfigured'
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod `
        -Uri "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/assign" `
        -Method Post -Headers (Get-GraphHeaders $Token) -Body $body | Out-Null

    Write-Host "Assigned app '$AppId' to group '$GroupId' (intent: $Intent)" -ForegroundColor Green
}

Export-ModuleMember -Function Get-GraphToken, Find-ExistingIntuneApp, `
    Get-AllIntuneWin32Apps, Find-IntuneAppByPackageId, Compare-AppVersion, `
    Get-Win32DetectionRule, Publish-IntuneWin32App, Add-IntuneAppGroupAssignment
