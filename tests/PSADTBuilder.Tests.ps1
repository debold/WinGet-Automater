#Requires -Version 7.0
#Requires -Modules Pester

<#
  Unit tests for PSADTBuilder.psm1.
  All external calls (PSADT download, installer download, SHA256) are mocked.
  The template file at templates/Deploy-Application.ps1.template is read from disk.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/modules/PSADTBuilder.psm1') -Force
    $script:TemplatePath = Join-Path $PSScriptRoot '../templates/Deploy-Application.ps1.template'
}

# ─── Get-PSADTInstallBlocks ───────────────────────────────────────────────────

Describe 'Get-PSADTInstallBlocks – MSI' {
    InModuleScope PSADTBuilder {

        Context 'MSI with ProductCode' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'msi'
                    InstallerSwitches = $null
                    ProductCode       = '{12345678-1234-1234-1234-123456789012}'
                    Name              = 'TestApp'
                }
                $script:i, $script:u, $script:r = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.msi'
            }

            It 'Install uses Invoke-ADTMsiexec -Action Install' {
                $script:i | Should -Match 'Invoke-ADTMsiexec.*-Action Install'
            }
            It 'Uninstall uses Invoke-ADTMsiexec -Action Uninstall with ProductCode' {
                $script:u | Should -Match 'Invoke-ADTMsiexec.*-Action Uninstall'
                $script:u | Should -Match '12345678-1234-1234-1234-123456789012'
            }
            It 'Repair uses Invoke-ADTMsiexec -Action Repair' {
                $script:r | Should -Match 'Invoke-ADTMsiexec.*-Action Repair'
            }
        }

        Context 'MSI without ProductCode – uninstall falls back to file' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'msi'
                    InstallerSwitches = 'TRANSFORMS=transform.mst'
                    ProductCode       = $null
                    Name              = 'TestApp'
                }
                $_, $script:u, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.msi'
            }

            It 'Uninstall references the setup filename' {
                $script:u | Should -Match 'setup\.msi'
            }
        }

        Context 'MSI with custom silent switches' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'msi'
                    InstallerSwitches = 'ALLUSERS=2 REBOOT=ReallySuppress'
                    ProductCode       = $null
                    Name              = 'TestApp'
                }
                $script:i, $_, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.msi'
            }

            It 'Install block passes the custom switches' {
                $script:i | Should -Match 'ALLUSERS=2 REBOOT=ReallySuppress'
            }
        }
    }
}

Describe 'Get-PSADTInstallBlocks – EXE' {
    InModuleScope PSADTBuilder {

        Context 'EXE with silent switch' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'exe'
                    InstallerSwitches = '/S /NORESTART'
                    ProductCode       = $null
                    Name              = 'TestApp'
                }
                $script:i, $script:u, $script:r = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.exe'
            }

            It 'Install uses Start-ADTProcess' {
                $script:i | Should -Match 'Start-ADTProcess'
            }
            It 'Install passes the silent switch' {
                $script:i | Should -Match '/S /NORESTART'
            }
            It 'Repair reuses the install command' {
                $script:r | Should -Match 'Start-ADTProcess'
            }
        }

        Context 'EXE with ProductCode – uninstall via msiexec' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'exe'
                    InstallerSwitches = '/S'
                    ProductCode       = '{ABCDEF12-0000-0000-0000-ABCDEF000000}'
                    Name              = 'TestApp'
                }
                $_, $script:u, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.exe'
            }

            It 'Uninstall references the ProductCode' {
                $script:u | Should -Match 'ABCDEF12-0000-0000-0000-ABCDEF000000'
            }
        }

        Context 'EXE without ProductCode – uninstall TODO comment' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'exe'
                    InstallerSwitches = '/S'
                    ProductCode       = $null
                    Name              = 'TestApp'
                }
                $_, $script:u, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.exe'
            }

            It 'Uninstall block contains a TODO reminder' {
                $script:u | Should -Match '# TODO'
            }
        }

        Context 'EXE without any switches – defaults to /S' {
            BeforeAll {
                $info = [ordered]@{
                    InstallerType     = 'exe'
                    InstallerSwitches = $null
                    ProductCode       = $null
                    Name              = 'TestApp'
                }
                $script:i, $_, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'setup.exe'
            }

            It 'Install block defaults to /S switch' {
                $script:i | Should -Match "'/S'"
            }
        }
    }
}

Describe 'Get-PSADTInstallBlocks – MSIX / APPX' {
    InModuleScope PSADTBuilder {

        It 'Install uses Add-AppxPackage' {
            $info = [ordered]@{
                InstallerType     = 'msix'
                InstallerSwitches = $null
                ProductCode       = $null
                Name              = 'TestApp'
            }
            $install, $_, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'app.msix'
            $install | Should -Match 'Add-AppxPackage'
        }

        It 'Uninstall uses Remove-AppxPackage' {
            $info = [ordered]@{
                InstallerType     = 'appx'
                InstallerSwitches = $null
                ProductCode       = $null
                Name              = 'TestApp'
            }
            $_, $uninstall, $_ = Get-PSADTInstallBlocks -PackageInfo $info -InstallerFileName 'app.appx'
            $uninstall | Should -Match 'Remove-AppxPackage'
        }
    }
}

# ─── New-PSADTPackage – template substitution ─────────────────────────────────

Describe 'New-PSADTPackage – template substitution and folder structure' {
    BeforeAll {
        $script:TempOut = Join-Path $env:TEMP "PSADTTest_$(New-Guid)"

        $script:PackageInfo = [ordered]@{
            PackageId         = 'Test.Package'
            Version           = '1.2.3'
            Name              = 'Test App'
            Publisher         = 'Test Publisher'
            Description       = 'A test application'
            License           = 'MIT'
            InstallerUrl      = 'https://example.com/setup.exe'
            InstallerSha256   = 'A' * 64
            InstallerType     = 'exe'
            InstallerSwitches = '/S'
            ProductCode       = $null
            Architecture      = 'x64'
        }

        # PSADT is public on GitHub – Get-PSADTFramework downloads it for real (cached in %TEMP%).
        # Only the installer is mocked: we don't want to fetch 100 MB real app binaries in tests.
        Mock -ModuleName PSADTBuilder Invoke-WebRequest {
            $null = New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](0x4D, 0x5A))
        } -ParameterFilter { $Uri -like 'https://example.com/*' }

        Mock -ModuleName PSADTBuilder Get-FileHash {
            return [PSCustomObject]@{ Hash = 'A' * 64 }
        }

        $script:Result = New-PSADTPackage `
            -PackageInfo   $script:PackageInfo `
            -OutputPath    $script:TempOut `
            -TemplatePath  $script:TemplatePath `
            -PSADTVersion  '4.0.4'
    }

    AfterAll {
        Remove-Item $script:TempOut -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns a path string' {
        $script:Result | Should -BeOfType [string]
    }
    It 'Returned path exists on disk' {
        Test-Path $script:Result | Should -BeTrue
    }
    It 'Creates Deploy-Application.ps1' {
        Test-Path (Join-Path $script:Result 'Deploy-Application.ps1') | Should -BeTrue
    }
    It 'Creates Files sub-folder' {
        Test-Path (Join-Path $script:Result 'Files') | Should -BeTrue
    }
    It 'Creates SupportFiles sub-folder' {
        Test-Path (Join-Path $script:Result 'SupportFiles') | Should -BeTrue
    }
    It 'Deploy-Application.ps1 contains no unresolved {{PLACEHOLDERS}}' {
        $content = Get-Content (Join-Path $script:Result 'Deploy-Application.ps1') -Raw
        $content | Should -Not -Match '\{\{[A-Z_]+\}\}'
    }
    It 'Deploy-Application.ps1 contains the AppName' {
        $content = Get-Content (Join-Path $script:Result 'Deploy-Application.ps1') -Raw
        $content | Should -Match 'Test App'
    }
    It 'Deploy-Application.ps1 contains the Version' {
        $content = Get-Content (Join-Path $script:Result 'Deploy-Application.ps1') -Raw
        $content | Should -Match '1\.2\.3'
    }
    It 'Deploy-Application.ps1 contains the Publisher' {
        $content = Get-Content (Join-Path $script:Result 'Deploy-Application.ps1') -Raw
        $content | Should -Match 'Test Publisher'
    }
    It 'Deploy-Application.ps1 contains the PackageId' {
        $content = Get-Content (Join-Path $script:Result 'Deploy-Application.ps1') -Raw
        $content | Should -Match 'Test\.Package'
    }
    It 'Package path follows {OutputPath}/{PackageId}/{Version} convention' {
        $script:Result | Should -Match 'Test\.Package'
        $script:Result | Should -Match '1\.2\.3'
    }
}

Describe 'New-PSADTPackage – SHA256 mismatch is rejected' {
    BeforeAll {
        $script:TempOut2 = Join-Path $env:TEMP "PSADTTest_$(New-Guid)"

        $script:PackageInfo2 = [ordered]@{
            PackageId         = 'Bad.Hash'
            Version           = '1.0.0'
            Name              = 'Bad Hash App'
            Publisher         = 'Pub'
            Description       = $null
            License           = $null
            InstallerUrl      = 'https://example.com/setup.exe'
            InstallerSha256   = 'B' * 64   # expected hash – won't match actual file
            InstallerType     = 'exe'
            InstallerSwitches = '/S'
            ProductCode       = $null
            Architecture      = 'x64'
        }

        # PSADT downloads for real; only the installer is mocked
        Mock -ModuleName PSADTBuilder Invoke-WebRequest {
            $null = New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](0x4D, 0x5A))
        } -ParameterFilter { $Uri -like 'https://example.com/*' }

        # Real Get-FileHash – computes the actual hash of the 2-byte MZ stub,
        # which will NOT match the 'BBBB...' expected hash → triggers the mismatch error
    }

    AfterAll {
        Remove-Item $script:TempOut2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Throws when SHA256 does not match the manifest' {
        {
            New-PSADTPackage `
                -PackageInfo   $script:PackageInfo2 `
                -OutputPath    $script:TempOut2 `
                -TemplatePath  $script:TemplatePath `
                -PSADTVersion  '4.0.4'
        } | Should -Throw '*SHA256 mismatch*'
    }
}
