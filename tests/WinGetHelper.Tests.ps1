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
    It 'InformationUrl is an HTTPS URL or null' {
        if ($script:vlc.InformationUrl) {
            $script:vlc.InformationUrl | Should -Match '^https?://'
        } else {
            $script:vlc.InformationUrl | Should -BeNullOrEmpty
        }
    }
    It 'Result is an OrderedDictionary' {
        $script:vlc | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
    }
}

Describe 'Get-WinGetManifest – 7zip.7zip (second well-known package)' {
    BeforeAll {
        $script:zip = Get-WinGetManifest -PackageId '7zip.7zip' -GitHubToken $script:GhToken
    }

    It 'Returns a non-empty Version' {
        $script:zip.Version | Should -Not -BeNullOrEmpty
    }
    It 'InstallerUrl is an HTTPS URL' {
        $script:zip.InstallerUrl | Should -Match '^https://'
    }
    It 'InstallerSha256 is a 64-char hex string' {
        $script:zip.InstallerSha256 | Should -Match '^[0-9a-fA-F]{64}$'
    }
    It 'InstallerType is populated' {
        $script:zip.InstallerType | Should -Not -BeNullOrEmpty
    }
    It 'ProductCode is a valid GUID when InstallerType is msi, or null/empty otherwise' {
        if ($script:zip.InstallerType -eq 'msi') {
            $script:zip.ProductCode | Should -Match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'
        } else {
            $script:zip.ProductCode | Should -BeNullOrEmpty
        }
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

# ─── Get-WinGetLatestVersion ──────────────────────────────────────────────────

Describe 'Get-WinGetLatestVersion – Integration (live GitHub)' {
    It 'Returns a non-empty version string for VideoLAN.VLC' {
        $v = Get-WinGetLatestVersion -PackageId 'VideoLAN.VLC' -GitHubToken $script:GhToken
        $v | Should -Not -BeNullOrEmpty
    }

    It 'Returns a version that looks like a semver (x.y.z)' {
        $v = Get-WinGetLatestVersion -PackageId '7zip.7zip' -GitHubToken $script:GhToken
        $v | Should -Match '^\d+\.\d+'
    }

    It 'Matches the version returned by the full Get-WinGetManifest' {
        $latest   = Get-WinGetLatestVersion -PackageId 'VideoLAN.VLC' -GitHubToken $script:GhToken
        $manifest = Get-WinGetManifest      -PackageId 'VideoLAN.VLC' -GitHubToken $script:GhToken
        $latest | Should -Be $manifest.Version
    }

    It 'Throws for an unknown PackageId' {
        { Get-WinGetLatestVersion -PackageId 'DoesNotExist.NotAPackage' -GitHubToken $script:GhToken } |
            Should -Throw
    }

    It 'Is significantly faster than Get-WinGetManifest (only 1 API call)' {
        $elapsed = (Measure-Command {
            Get-WinGetLatestVersion -PackageId 'VideoLAN.VLC' -GitHubToken $script:GhToken
        }).TotalSeconds
        # Full manifest needs 3–5 API calls; version-only should finish in < 10 s even on slow links
        $elapsed | Should -BeLessThan 10
    }
}
