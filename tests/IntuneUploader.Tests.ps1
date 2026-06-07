#Requires -Version 7.0
#Requires -Modules Pester

<#
  Unit tests for IntuneUploader.psm1.
  All Graph API and Azure Blob calls are mocked – no Intune tenant required.
#>

BeforeDiscovery {
    # Module must be loaded during discovery so InModuleScope blocks are resolvable.
    Import-Module (Join-Path $PSScriptRoot '../src/modules/IntuneUploader.psm1') -Force
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/modules/IntuneUploader.psm1') -Force
}

# ─── Compare-AppVersion (pure, no mocks needed) ───────────────────────────────

Describe 'Compare-AppVersion' {
    It 'Returns 1 when new version is higher (major)' {
        Compare-AppVersion -NewVersion '2.0.0' -ExistingVersion '1.9.9' | Should -Be 1
    }
    It 'Returns 1 when new version is higher (minor)' {
        Compare-AppVersion -NewVersion '1.10.0' -ExistingVersion '1.9.9' | Should -Be 1
    }
    It 'Returns 1 when new version is higher (patch)' {
        Compare-AppVersion -NewVersion '1.0.1' -ExistingVersion '1.0.0' | Should -Be 1
    }
    It 'Returns 0 when versions are equal' {
        Compare-AppVersion -NewVersion '3.0.20' -ExistingVersion '3.0.20' | Should -Be 0
    }
    It 'Returns -1 when new version is lower' {
        Compare-AppVersion -NewVersion '1.0.0' -ExistingVersion '2.0.0' | Should -Be -1
    }
    It 'Strips non-numeric suffix (e.g. 2.0.0-beta → 2.0.0)' {
        Compare-AppVersion -NewVersion '2.0.0-rc1' -ExistingVersion '1.9.9' | Should -Be 1
    }
    It 'Does not throw for non-semver strings' {
        { Compare-AppVersion -NewVersion 'nightly' -ExistingVersion 'stable' } | Should -Not -Throw
    }
}

# ─── Get-Win32DetectionRule (pure, no mocks needed) ──────────────────────────

Describe 'Get-Win32DetectionRule' {

    Context 'MSI with ProductCode → MSI ProductCode detection' {
        BeforeAll {
            $script:msiInfo = [ordered]@{
                InstallerType = 'msi'
                ProductCode   = '{12345678-1234-1234-1234-123456789012}'
                Publisher     = 'TestPub'
                Name          = 'TestApp'
            }
            $script:rule = Get-Win32DetectionRule -PackageInfo $script:msiInfo
        }

        It 'OData type is ProductCodeDetection' {
            $script:rule.'@odata.type' | Should -Match 'ProductCodeDetection'
        }
        It 'ProductCode matches input' {
            $script:rule.productCode | Should -Be '{12345678-1234-1234-1234-123456789012}'
        }
        It 'productVersionOperator is notConfigured' {
            $script:rule.productVersionOperator | Should -Be 'notConfigured'
        }
    }

    Context 'EXE with ProductCode → Registry detection' {
        BeforeAll {
            $script:exeWithPc = [ordered]@{
                InstallerType = 'exe'
                ProductCode   = '{ABCDEF12-ABCD-ABCD-ABCD-ABCDEF123456}'
                Publisher     = 'TestPub'
                Name          = 'TestApp'
            }
            $script:rule = Get-Win32DetectionRule -PackageInfo $script:exeWithPc
        }

        It 'OData type is RegistryDetection' {
            $script:rule.'@odata.type' | Should -Match 'RegistryDetection'
        }
        It 'keyPath references HKEY_LOCAL_MACHINE uninstall path' {
            $script:rule.keyPath | Should -Match 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
        }
        It 'keyPath includes the ProductCode' {
            $script:rule.keyPath | Should -Match 'ABCDEF12-ABCD-ABCD-ABCD-ABCDEF123456'
        }
        It 'detectionType is exists' {
            $script:rule.detectionType | Should -Be 'exists'
        }
    }

    Context 'EXE without ProductCode → File system detection' {
        BeforeAll {
            $script:exeNoPc = [ordered]@{
                InstallerType = 'exe'
                ProductCode   = $null
                Publisher     = 'Acme Corp'
                Name          = 'Acme Tool'
            }
            $script:rule = Get-Win32DetectionRule -PackageInfo $script:exeNoPc
        }

        It 'OData type is FileSystemDetection' {
            $script:rule.'@odata.type' | Should -Match 'FileSystemDetection'
        }
        It 'path references %ProgramFiles%' {
            $script:rule.path | Should -Match '%ProgramFiles%'
        }
        It 'path includes the Publisher name' {
            $script:rule.path | Should -Match 'Acme Corp'
        }
        It 'fileOrFolderName matches the app name' {
            $script:rule.fileOrFolderName | Should -Be 'Acme Tool'
        }
    }
}

# ─── Get-GraphToken ──────────────────────────────────────────────────────────

Describe 'Get-GraphToken' {

    Context 'Successful response' {
        BeforeAll {
            Mock -ModuleName IntuneUploader Invoke-RestMethod {
                return [PSCustomObject]@{ access_token = 'mock-bearer-token-xyz' }
            }
        }

        It 'Returns the access_token value' {
            $token = Get-GraphToken -TenantId 'my-tenant' -ClientId 'my-client' -ClientSecret 'my-secret'
            $token | Should -Be 'mock-bearer-token-xyz'
        }
        It 'Calls the tenant-specific token endpoint' {
            Get-GraphToken -TenantId 'my-tenant' -ClientId 'my-client' -ClientSecret 'my-secret'
            Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*my-tenant*oauth2/v2.0/token*'
            }
        }
        It 'Requests the Graph default scope' {
            Get-GraphToken -TenantId 'my-tenant' -ClientId 'my-client' -ClientSecret 'my-secret'
            Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
                $Body.scope -eq 'https://graph.microsoft.com/.default'
            }
        }
    }

    Context 'Auth failure' {
        BeforeAll {
            Mock -ModuleName IntuneUploader Invoke-RestMethod { throw 'Unauthorized' }
        }

        It 'Propagates the error' {
            { Get-GraphToken -TenantId 't' -ClientId 'c' -ClientSecret 's' } | Should -Throw
        }
    }
}

# ─── Find-ExistingIntuneApp ───────────────────────────────────────────────────

Describe 'Find-ExistingIntuneApp' {

    Context 'App found' {
        BeforeAll {
            Mock -ModuleName IntuneUploader Invoke-RestMethod {
                return [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ id = 'app-001'; displayName = 'VLC media player'; displayVersion = '3.0.20' }
                    )
                }
            }
        }

        It 'Returns one result' {
            $r = Find-ExistingIntuneApp -Token 'tok' -DisplayName 'VLC media player'
            $r.Count | Should -Be 1
        }
        It 'Result has the expected id' {
            $r = Find-ExistingIntuneApp -Token 'tok' -DisplayName 'VLC media player'
            $r[0].id | Should -Be 'app-001'
        }
    }

    Context 'No app found' {
        BeforeAll {
            Mock -ModuleName IntuneUploader Invoke-RestMethod {
                return [PSCustomObject]@{ value = @() }
            }
        }

        It 'Returns an empty result' {
            $r = Find-ExistingIntuneApp -Token 'tok' -DisplayName 'Non-existent App'
            $r.Count | Should -Be 0
        }
    }
}

# ─── New-Win32LobAppBody (internal via InModuleScope) ─────────────────────────

Describe 'New-Win32LobAppBody – app object structure' {
    InModuleScope IntuneUploader {

        BeforeAll {
            $script:info = [ordered]@{
                PackageId         = 'Test.App'
                Version           = '2.0.0'
                Name              = 'Test App'
                Publisher         = 'Test Publisher'
                Description       = 'A test'
                License           = 'MIT'
                InformationUrl    = 'https://example.com/info'
                PrivacyUrl        = 'https://example.com/privacy'
                InstallerUrl      = 'https://example.com/setup.exe'
                InstallerSha256   = 'A' * 64
                InstallerType     = 'exe'
                InstallerSwitches = '/S'
                ProductCode       = $null
                Architecture      = 'x64'
            }
            $script:body = New-Win32LobAppBody -PackageInfo $script:info `
                -IntuneWinFileName 'Test.App.intunewin' -DefaultPublisher 'WinGet-Automater'
        }

        It 'OData type is win32LobApp' {
            $script:body.'@odata.type' | Should -Be '#microsoft.graph.win32LobApp'
        }
        It 'displayName matches PackageInfo.Name' {
            $script:body.displayName | Should -Be 'Test App'
        }
        It 'displayVersion matches PackageInfo.Version' {
            $script:body.displayVersion | Should -Be '2.0.0'
        }
        It 'publisher is populated' {
            $script:body.publisher | Should -Not -BeNullOrEmpty
        }
        It 'fileName is set' {
            $script:body.fileName | Should -Be 'Test.App.intunewin'
        }
        It 'installCommandLine uses Deploy-Application.ps1' {
            $script:body.installCommandLine | Should -Match 'Deploy-Application\.ps1'
        }
        It 'uninstallCommandLine uses Deploy-Application.ps1' {
            $script:body.uninstallCommandLine | Should -Match 'Deploy-Application\.ps1'
        }
        It 'installExperience runAsAccount is system' {
            $script:body.installExperience.runAsAccount | Should -Be 'system'
        }
        It 'returnCodes contains success code 0' {
            $rc = $script:body.returnCodes | Where-Object { $_.returnCode -eq 0 }
            $rc.type | Should -Be 'success'
        }
        It 'returnCodes contains softReboot for 3010' {
            $rc = $script:body.returnCodes | Where-Object { $_.returnCode -eq 3010 }
            $rc.type | Should -Be 'softReboot'
        }
        It 'detectionRules is a non-empty array' {
            $script:body.detectionRules | Should -Not -BeNullOrEmpty
            $script:body.detectionRules.Count | Should -BeGreaterThan 0
        }
        It 'informationUrl is mapped from PackageInfo.InformationUrl' {
            $script:body.informationUrl | Should -Be 'https://example.com/info'
        }
        It 'privacyInformationUrl is mapped from PackageInfo.PrivacyUrl' {
            $script:body.privacyInformationUrl | Should -Be 'https://example.com/privacy'
        }
        It 'applicableArchitectures reflects the installer architecture' {
            $script:body.applicableArchitectures | Should -Be 'x64'
        }
    }
}

Describe 'New-Win32LobAppBody – architecture mapping' {
    InModuleScope IntuneUploader {
        It 'Maps x86 installer to x86' {
            $info = [ordered]@{ Name = 'A'; Version = '1'; Publisher = 'P'; Description = $null
                                InformationUrl = $null; PrivacyUrl = $null; Architecture = 'x86'
                                InstallerType = 'exe'; ProductCode = $null }
            $body = New-Win32LobAppBody -PackageInfo $info -IntuneWinFileName 'a.intunewin' -DefaultPublisher 'P'
            $body.applicableArchitectures | Should -Be 'x86'
        }
        It 'Maps arm64 installer to arm64' {
            $info = [ordered]@{ Name = 'A'; Version = '1'; Publisher = 'P'; Description = $null
                                InformationUrl = $null; PrivacyUrl = $null; Architecture = 'arm64'
                                InstallerType = 'exe'; ProductCode = $null }
            $body = New-Win32LobAppBody -PackageInfo $info -IntuneWinFileName 'a.intunewin' -DefaultPublisher 'P'
            $body.applicableArchitectures | Should -Be 'arm64'
        }
        It 'Falls back to x64 for unknown architecture' {
            $info = [ordered]@{ Name = 'A'; Version = '1'; Publisher = 'P'; Description = $null
                                InformationUrl = $null; PrivacyUrl = $null; Architecture = $null
                                InstallerType = 'exe'; ProductCode = $null }
            $body = New-Win32LobAppBody -PackageInfo $info -IntuneWinFileName 'a.intunewin' -DefaultPublisher 'P'
            $body.applicableArchitectures | Should -Be 'x64'
        }
    }
}

# ─── Get-AllIntuneWin32Apps ───────────────────────────────────────────────────

Describe 'Get-AllIntuneWin32Apps' {

    Context 'Single page of results' {
        BeforeAll {
            Mock -ModuleName IntuneUploader Invoke-RestMethod {
                return [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ id = 'app-001'; displayName = 'VLC media player'; notes = 'WinGet-PackageId: VideoLAN.VLC' }
                        [PSCustomObject]@{ id = 'app-002'; displayName = '7-Zip 24.08';       notes = 'WinGet-PackageId: 7zip.7zip' }
                    )
                }
            }
            $script:apps = Get-AllIntuneWin32Apps -Token 'test-token'
        }

        It 'Returns all apps from the page' {
            $script:apps.Count | Should -Be 2
        }
        It 'Queries the win32LobApp endpoint' {
            Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*win32LobApp*'
            }
        }
        It 'Requests the notes field' {
            Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -match '\$select=.*notes'
            }
        }
    }

    Context 'Paginated results (@odata.nextLink)' {
        BeforeAll {
            $script:callCount = 0
            Mock -ModuleName IntuneUploader Invoke-RestMethod {
                $script:callCount++
                if ($script:callCount -eq 1) {
                    return [PSCustomObject]@{
                        value              = @([PSCustomObject]@{ id = 'app-001'; displayName = 'App1'; notes = '' })
                        '@odata.nextLink'  = 'https://graph.microsoft.com/next-page'
                    }
                } else {
                    return [PSCustomObject]@{
                        value = @([PSCustomObject]@{ id = 'app-002'; displayName = 'App2'; notes = '' })
                    }
                }
            }
            $script:apps = Get-AllIntuneWin32Apps -Token 'test-token'
        }

        It 'Follows nextLink and returns all apps from both pages' {
            $script:apps.Count | Should -Be 2
        }
        It 'Made exactly two API calls' {
            $script:callCount | Should -Be 2
        }
    }
}

# ─── Find-IntuneAppByPackageId ────────────────────────────────────────────────

Describe 'Find-IntuneAppByPackageId' {

    BeforeAll {
        $script:appList = @(
            [PSCustomObject]@{ id = 'app-001'; displayName = 'VLC media player'; displayVersion = '3.0.20'; notes = "WinGet-PackageId: VideoLAN.VLC`nManaged by: WinGet-Automater" }
            [PSCustomObject]@{ id = 'app-002'; displayName = '7-Zip 24.08';       displayVersion = '24.8.0'; notes = "WinGet-PackageId: 7zip.7zip`nManaged by: WinGet-Automater" }
            [PSCustomObject]@{ id = 'app-003'; displayName = 'Firefox';            displayVersion = '126.0';  notes = $null }
            [PSCustomObject]@{ id = 'app-004'; displayName = 'Adobe Acrobat';      displayVersion = '24.1.0'; notes = 'WinGet-PackageId: Adobe.Acrobat.Reader' }
        )
    }

    It 'Finds an app by exact PackageId match in notes' {
        $result = Find-IntuneAppByPackageId -Apps $script:appList -PackageId 'VideoLAN.VLC'
        $result.id | Should -Be 'app-001'
    }

    It 'Finds a second distinct app by its PackageId' {
        $result = Find-IntuneAppByPackageId -Apps $script:appList -PackageId '7zip.7zip'
        $result.id | Should -Be 'app-002'
    }

    It 'Returns null for an unknown PackageId' {
        $result = Find-IntuneAppByPackageId -Apps $script:appList -PackageId 'Does.NotExist'
        $result | Should -BeNullOrEmpty
    }

    It 'Returns null for an app with null notes' {
        $result = Find-IntuneAppByPackageId -Apps $script:appList -PackageId 'Mozilla.Firefox'
        $result | Should -BeNullOrEmpty
    }

    It 'Returns the correct displayVersion for matched app' {
        $result = Find-IntuneAppByPackageId -Apps $script:appList -PackageId 'Adobe.Acrobat.Reader'
        $result.displayVersion | Should -Be '24.1.0'
    }

    It 'Does not return a partial match (VideoLAN should not match VideoLAN.VLCx)' {
        $extendedList = $script:appList + [PSCustomObject]@{
            id = 'app-005'; displayName = 'VLC Extended'; displayVersion = '4.0.0'
            notes = 'WinGet-PackageId: VideoLAN.VLCx'
        }
        $result = Find-IntuneAppByPackageId -Apps $extendedList -PackageId 'VideoLAN.VLC'
        $result.id | Should -Be 'app-001'
    }
}

# ─── Add-IntuneAppGroupAssignment ─────────────────────────────────────────────

Describe 'Add-IntuneAppGroupAssignment' {

    BeforeAll {
        Mock -ModuleName IntuneUploader Invoke-RestMethod { return $null }
    }

    It 'Posts to the /assign endpoint' {
        Add-IntuneAppGroupAssignment -Token 'tok' -AppId 'app-123' -GroupId 'grp-456'
        Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -like '*/mobileApps/app-123/assign*'
        }
    }
    It 'Default intent is available' {
        Add-IntuneAppGroupAssignment -Token 'tok' -AppId 'app-123' -GroupId 'grp-456'
        Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
            ($Body | ConvertFrom-Json -Depth 10).mobileAppAssignments[0].intent -eq 'available'
        }
    }
    It 'Accepts required intent' {
        Add-IntuneAppGroupAssignment -Token 'tok' -AppId 'app-123' -GroupId 'grp-456' -Intent 'required'
        Should -Invoke -ModuleName IntuneUploader Invoke-RestMethod -Times 1 -ParameterFilter {
            ($Body | ConvertFrom-Json -Depth 10).mobileAppAssignments[0].intent -eq 'required'
        }
    }
}
