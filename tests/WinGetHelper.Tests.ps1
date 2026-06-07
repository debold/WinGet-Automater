#Requires -Version 7.0
#Requires -Modules Pester

<#
  Integration tests for WinGetHelper.psm1.
  These tests call the live github.com/microsoft/winget-pkgs repository.
  No mocking – real package metadata is validated.

  Set $env:GITHUB_TOKEN to avoid the 60 req/h unauthenticated rate limit.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/modules/WinGetHelper.psm1') -Force
    $script:GhToken = $env:GITHUB_TOKEN
}

# ─── Get-WinGetManifest ───────────────────────────────────────────────────────

Describe 'Get-WinGetManifest – VideoLAN.VLC (EXE, well-known)' {
    BeforeAll {
        $script:vlc = Get-WinGetManifest -PackageId 'VideoLAN.VLC' -GitHubToken $script:GhToken
    }

    It 'Returns PackageId unchanged' {
        $script:vlc.PackageId | Should -Be 'VideoLAN.VLC'
    }
    It 'Resolves a non-empty Version' {
        $script:vlc.Version | Should -Not -BeNullOrEmpty
    }
    It 'Returns a Name' {
        $script:vlc.Name | Should -Not -BeNullOrEmpty
    }
    It 'Returns a Publisher' {
        $script:vlc.Publisher | Should -Not -BeNullOrEmpty
    }
    It 'InstallerUrl is an HTTPS URL' {
        $script:vlc.InstallerUrl | Should -Match '^https://'
    }
    It 'InstallerSha256 is a 64-char hex string' {
        $script:vlc.InstallerSha256 | Should -Match '^[0-9a-fA-F]{64}$'
    }
    It 'InstallerType is populated' {
        $script:vlc.InstallerType | Should -Not -BeNullOrEmpty
    }
    It 'Architecture is a known value' {
        $script:vlc.Architecture | Should -BeIn @('x64', 'x86', 'arm64', 'neutral')
    }
    It 'Result is an OrderedDictionary' {
        $script:vlc | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
    }
}

Describe 'Get-WinGetManifest – 7zip.7zip (MSI with ProductCode)' {
    BeforeAll {
        $script:zip = Get-WinGetManifest -PackageId '7zip.7zip' -GitHubToken $script:GhToken
    }

    It 'InstallerType is msi' {
        $script:zip.InstallerType | Should -Be 'msi'
    }
    It 'ProductCode is a valid GUID' {
        $script:zip.ProductCode | Should -Match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'
    }
}

Describe 'Get-WinGetManifest – specific version' {
    It 'Returns the requested version exactly' {
        $result = Get-WinGetManifest -PackageId 'VideoLAN.VLC' -Version '3.0.20' -GitHubToken $script:GhToken
        $result.Version | Should -Be '3.0.20'
    }
    It 'InstallerUrl for the pinned version is non-empty' {
        $result = Get-WinGetManifest -PackageId 'VideoLAN.VLC' -Version '3.0.20' -GitHubToken $script:GhToken
        $result.InstallerUrl | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-WinGetManifest – error handling' {
    It 'Throws for an unknown PackageId' {
        { Get-WinGetManifest -PackageId 'DoesNotExist.NotAPackage' -GitHubToken $script:GhToken } |
            Should -Throw
    }
    It 'Throws for a valid package but non-existent version' {
        { Get-WinGetManifest -PackageId 'VideoLAN.VLC' -Version '0.0.0.0.1' -GitHubToken $script:GhToken } |
            Should -Throw
    }
}

# ─── Get-WinGetInstallerFileName ─────────────────────────────────────────────

Describe 'Get-WinGetInstallerFileName' {
    It 'Returns the filename directly from a clean URL' {
        $info = [ordered]@{
            InstallerType = 'exe'
            InstallerUrl  = 'https://example.com/downloads/setup_vlc_3.0.exe'
            Name          = 'VLC'
        }
        Get-WinGetInstallerFileName -PackageInfo $info | Should -Be 'setup_vlc_3.0.exe'
    }

    It 'Falls back to a generated .msi name when URL has query params only' {
        $info = [ordered]@{
            InstallerType = 'msi'
            InstallerUrl  = 'https://example.com/download?id=123&token=abc'
            Name          = 'My App'
        }
        $result = Get-WinGetInstallerFileName -PackageInfo $info
        $result | Should -Match '\.msi$'
    }

    It 'Uses .msix extension for msix type' {
        $info = [ordered]@{
            InstallerType = 'msix'
            InstallerUrl  = 'https://example.com/get?pkg=app'
            Name          = 'SomeApp'
        }
        Get-WinGetInstallerFileName -PackageInfo $info | Should -Match '\.msix$'
    }

    It 'Uses .exe extension for nullish/unknown type' {
        $info = [ordered]@{
            InstallerType = $null
            InstallerUrl  = 'https://example.com/get?pkg=app'
            Name          = 'SomeApp'
        }
        Get-WinGetInstallerFileName -PackageInfo $info | Should -Match '\.exe$'
    }

    It 'Returns a safe filename without spaces' {
        $info = [ordered]@{
            InstallerType = 'exe'
            InstallerUrl  = 'https://example.com/get?x=1'
            Name          = 'My Cool App'
        }
        Get-WinGetInstallerFileName -PackageInfo $info | Should -Not -Match ' '
    }
}
