#Requires -Version 7.0
#Requires -Modules Pester

<#
  Unit tests for PSADTBuilder.psm1.
  All external calls (PSADT download, installer download, SHA256) are mocked.
  The template file at templates/Deploy-Application.ps1.template is read from disk.
#>

BeforeDiscovery {
    # Module must be loaded during discovery so InModuleScope blocks are resolvable.
    Import-Module (Join-Path $PSScriptRoot '../src/modules/PSADTBuilder.psm1') -Force
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/modules/PSADTBuilder.psm1') -Force
    $script:TemplatePath = Join-Path $PSScriptRoot '../templates/Deploy-Application.ps1.template'

    # Fake PSADT framework folder reused by all New-PSADTPackage tests.
    # Get-PSADTFramework is mocked per-Describe to return this path, so no network call is made.
    $script:FakePSADTPath = Join-Path $TestDrive 'FakePSADT'
    $adtDir = Join-Path $script:FakePSADTPath 'AppDeployToolkit'
    New-Item -ItemType Directory -Path $adtDir -Force | Out-Null
    Set-Content -Path (Join-Path $adtDir 'AppDeployToolkitConfig.xml') -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<AppDeployToolkit_Config>
  <Toolkit_Options>
    <Toolkit_CompanyName>PS App Deploy Toolkit</Toolkit_CompanyName>
  </Toolkit_Options>
</AppDeployToolkit_Config>
'@
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

        Mock -ModuleName PSADTBuilder Get-PSADTFramework { return $script:FakePSADTPath }

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

        Mock -ModuleName PSADTBuilder Get-PSADTFramework { return $script:FakePSADTPath }

        Mock -ModuleName PSADTBuilder Invoke-WebRequest {
            $null = New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](0x4D, 0x5A))
        } -ParameterFilter { $Uri -like 'https://example.com/*' }

        # Get-FileHash is NOT mocked: real hash of the 2-byte MZ stub won't match 'BBBB...' → triggers mismatch
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

# ─── Get-PackageCustomization ─────────────────────────────────────────────────

Describe 'Get-PackageCustomization' {
    BeforeAll {
        $script:CustomizationsRoot = Join-Path $env:TEMP "Customizations_$(New-Guid)"
        $script:PkgDir = Join-Path $script:CustomizationsRoot 'Test.Package'
        New-Item -ItemType Directory -Path $script:PkgDir -Force | Out-Null

        Set-Content (Join-Path $script:PkgDir 'PreInstall.ps1')    'Write-Host "pre-install"'  -Encoding UTF8
        Set-Content (Join-Path $script:PkgDir 'PostInstall.ps1')   'Write-Host "post-install"' -Encoding UTF8
        Set-Content (Join-Path $script:PkgDir 'PostUninstall.ps1') 'Write-Host "post-uninstall"' -Encoding UTF8
        Set-Content (Join-Path $script:PkgDir 'package.json') '{"closeApps":"myapp","installSwitches":"/S /CUSTOM"}' -Encoding UTF8
    }

    AfterAll {
        Remove-Item $script:CustomizationsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Loads PreInstall snippet' {
        $c = Get-PackageCustomization -PackageId 'Test.Package' -CustomizationsPath $script:CustomizationsRoot
        $c.PreInstall | Should -Match 'pre-install'
    }
    It 'Loads PostInstall snippet' {
        $c = Get-PackageCustomization -PackageId 'Test.Package' -CustomizationsPath $script:CustomizationsRoot
        $c.PostInstall | Should -Match 'post-install'
    }
    It 'Returns empty string for missing hook (PreUninstall not created)' {
        $c = Get-PackageCustomization -PackageId 'Test.Package' -CustomizationsPath $script:CustomizationsRoot
        $c.PreUninstall | Should -BeNullOrEmpty
    }
    It 'Loads PostUninstall snippet' {
        $c = Get-PackageCustomization -PackageId 'Test.Package' -CustomizationsPath $script:CustomizationsRoot
        $c.PostUninstall | Should -Match 'post-uninstall'
    }
    It 'Parses closeApps from package.json' {
        $c = Get-PackageCustomization -PackageId 'Test.Package' -CustomizationsPath $script:CustomizationsRoot
        $c.Overrides.closeApps | Should -Be 'myapp'
    }
    It 'Parses installSwitches from package.json' {
        $c = Get-PackageCustomization -PackageId 'Test.Package' -CustomizationsPath $script:CustomizationsRoot
        $c.Overrides.installSwitches | Should -Be '/S /CUSTOM'
    }
    It 'Returns empty result for unknown PackageId' {
        $c = Get-PackageCustomization -PackageId 'Does.Not.Exist' -CustomizationsPath $script:CustomizationsRoot
        $c.PreInstall    | Should -BeNullOrEmpty
        $c.PostInstall   | Should -BeNullOrEmpty
        $c.Overrides     | Should -BeNullOrEmpty
    }
}

# ─── New-PSADTPackage – customization injection ───────────────────────────────

Describe 'New-PSADTPackage – customization snippets are injected' {
    BeforeAll {
        $script:TempOut3  = Join-Path $env:TEMP "PSADTTest_$(New-Guid)"
        $script:CustomDir = Join-Path $env:TEMP "Customizations_$(New-Guid)"
        $pkgCustomDir     = Join-Path $script:CustomDir 'Test.Package'
        New-Item -ItemType Directory -Path $pkgCustomDir -Force | Out-Null

        Set-Content (Join-Path $pkgCustomDir 'PostInstall.ps1') 'Remove-Item "C:\Public\Desktop\App.lnk" -Force' -Encoding UTF8
        Set-Content (Join-Path $pkgCustomDir 'package.json')    '{"closeApps":"testapp"}' -Encoding UTF8

        $script:PackageInfo3 = [ordered]@{
            PackageId         = 'Test.Package'
            Version           = '9.9.9'
            Name              = 'Custom Test App'
            Publisher         = 'Pub'
            Description       = $null
            License           = $null
            InformationUrl    = $null
            PrivacyUrl        = $null
            InstallerUrl      = 'https://example.com/setup.exe'
            InstallerSha256   = 'A' * 64
            InstallerType     = 'exe'
            InstallerSwitches = '/S'
            ProductCode       = $null
            Architecture      = 'x64'
        }

        Mock -ModuleName PSADTBuilder Get-PSADTFramework { return $script:FakePSADTPath }

        Mock -ModuleName PSADTBuilder Invoke-WebRequest {
            $null = New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](0x4D, 0x5A))
        } -ParameterFilter { $Uri -like 'https://example.com/*' }

        Mock -ModuleName PSADTBuilder Get-FileHash {
            return [PSCustomObject]@{ Hash = 'A' * 64 }
        }

        $script:Result3 = New-PSADTPackage `
            -PackageInfo        $script:PackageInfo3 `
            -OutputPath         $script:TempOut3 `
            -TemplatePath       $script:TemplatePath `
            -PSADTVersion       '4.0.4' `
            -CustomizationsPath $script:CustomDir
    }

    AfterAll {
        Remove-Item $script:TempOut3  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:CustomDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'PostInstall snippet is injected into Deploy-Application.ps1' {
        $content = Get-Content (Join-Path $script:Result3 'Deploy-Application.ps1') -Raw
        $content | Should -Match 'Remove-Item.*Desktop.*App\.lnk'
    }
    It 'closeApps override from package.json is applied' {
        $content = Get-Content (Join-Path $script:Result3 'Deploy-Application.ps1') -Raw
        $content | Should -Match 'testapp'
    }
    It 'No unresolved placeholders remain in the generated script' {
        $content = Get-Content (Join-Path $script:Result3 'Deploy-Application.ps1') -Raw
        $content | Should -Not -Match '\{\{[A-Z_]+\}\}'
    }
}

Describe 'New-PSADTPackage – extra files are injected from customizations\Files\' {
    BeforeAll {
        $script:TempOut4  = Join-Path $env:TEMP "PSADTTest_$(New-Guid)"
        $script:CustomDir4 = Join-Path $env:TEMP "Customizations_$(New-Guid)"
        $pkgCustomDir4     = Join-Path $script:CustomDir4 'Test.Package'
        $filesDir4         = Join-Path $pkgCustomDir4 'Files'
        $supportDir4       = Join-Path $pkgCustomDir4 'SupportFiles'
        New-Item -ItemType Directory -Path $filesDir4   -Force | Out-Null
        New-Item -ItemType Directory -Path $supportDir4 -Force | Out-Null

        Set-Content (Join-Path $filesDir4   'license.xml')  '<License/>'       -Encoding UTF8
        Set-Content (Join-Path $filesDir4   'transform.mst') 'dummy transform'  -Encoding UTF8
        Set-Content (Join-Path $supportDir4 'helper.ps1')   'Write-Host "hi"'  -Encoding UTF8

        $script:PackageInfo4 = [ordered]@{
            PackageId = 'Test.Package'; Version = '1.0.0'; Name = 'Test'; Publisher = 'P'
            Description = $null; License = $null; InformationUrl = $null; PrivacyUrl = $null
            InstallerUrl = 'https://example.com/setup.exe'; InstallerSha256 = 'A' * 64
            InstallerType = 'exe'; InstallerSwitches = '/S'; ProductCode = $null; Architecture = 'x64'
        }

        Mock -ModuleName PSADTBuilder Get-PSADTFramework { return $script:FakePSADTPath }

        Mock -ModuleName PSADTBuilder Invoke-WebRequest {
            $null = New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](0x4D, 0x5A))
        } -ParameterFilter { $Uri -like 'https://example.com/*' }

        Mock -ModuleName PSADTBuilder Get-FileHash {
            return [PSCustomObject]@{ Hash = 'A' * 64 }
        }

        $script:Result4 = New-PSADTPackage `
            -PackageInfo        $script:PackageInfo4 `
            -OutputPath         $script:TempOut4 `
            -TemplatePath       $script:TemplatePath `
            -PSADTVersion       '4.0.4' `
            -CustomizationsPath $script:CustomDir4
    }

    AfterAll {
        Remove-Item $script:TempOut4   -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:CustomDir4 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'license.xml from customizations\Files\ is present in package Files\' {
        Test-Path (Join-Path $script:Result4 'Files\license.xml') | Should -BeTrue
    }
    It 'transform.mst from customizations\Files\ is present in package Files\' {
        Test-Path (Join-Path $script:Result4 'Files\transform.mst') | Should -BeTrue
    }
    It 'helper.ps1 from customizations\SupportFiles\ is present in package SupportFiles\' {
        Test-Path (Join-Path $script:Result4 'SupportFiles\helper.ps1') | Should -BeTrue
    }
    It 'Injected file content is preserved' {
        Get-Content (Join-Path $script:Result4 'Files\license.xml') | Should -Match '<License'
    }
}

# ─── Set-PSADTBranding ────────────────────────────────────────────────────────

Describe 'Set-PSADTBranding' {

    BeforeAll {
        # Build a minimal fake AppDeployToolkit folder with a stub config XML
        $script:BrandTestDir = Join-Path $TestDrive 'BrandPkg'
        $adtDir = Join-Path $script:BrandTestDir 'AppDeployToolkit'
        New-Item -ItemType Directory -Path $adtDir -Force | Out-Null

        $script:ConfigXml = Join-Path $adtDir 'AppDeployToolkitConfig.xml'
        Set-Content $script:ConfigXml -Value @'
<?xml version="1.0" encoding="utf-8"?>
<AppDeployToolkit_Config>
  <Toolkit_Options>
    <Toolkit_CompanyName>PS App Deploy Toolkit</Toolkit_CompanyName>
  </Toolkit_Options>
</AppDeployToolkit_Config>
'@ -Encoding UTF8
    }

    Context 'Company name patching' {
        BeforeAll {
            $branding = [PSCustomObject]@{ companyName = 'Contoso GmbH'; bannerImagePath = ''; iconPath = '' }
            Set-PSADTBranding -PackagePath $script:BrandTestDir -Branding $branding
        }

        It 'Sets Toolkit_CompanyName in the config XML' {
            [xml]$xml = Get-Content $script:ConfigXml -Encoding UTF8
            $xml.SelectSingleNode('//Toolkit_CompanyName').InnerText | Should -Be 'Contoso GmbH'
        }
    }

    Context 'Banner image replacement' {
        BeforeAll {
            # Create a fake source banner
            $script:FakeBanner = Join-Path $TestDrive 'mybanner.png'
            Set-Content $script:FakeBanner -Value 'PNG_FAKE' -Encoding UTF8

            $branding = [PSCustomObject]@{ companyName = ''; bannerImagePath = $script:FakeBanner; iconPath = '' }
            Set-PSADTBranding -PackagePath $script:BrandTestDir -Branding $branding
        }

        It 'Copies the banner to AppDeployToolkit\AppDeployToolkitBanner.png' {
            $dest = Join-Path $script:BrandTestDir 'AppDeployToolkit' 'AppDeployToolkitBanner.png'
            Test-Path $dest | Should -BeTrue
        }
        It 'Banner content matches the source file' {
            $dest = Join-Path $script:BrandTestDir 'AppDeployToolkit' 'AppDeployToolkitBanner.png'
            Get-Content $dest | Should -Be 'PNG_FAKE'
        }
    }

    Context 'Icon replacement' {
        BeforeAll {
            $script:FakeIcon = Join-Path $TestDrive 'myicon.ico'
            Set-Content $script:FakeIcon -Value 'ICO_FAKE' -Encoding UTF8

            $branding = [PSCustomObject]@{ companyName = ''; bannerImagePath = ''; iconPath = $script:FakeIcon }
            Set-PSADTBranding -PackagePath $script:BrandTestDir -Branding $branding
        }

        It 'Copies the icon to AppDeployToolkit\AppDeployToolkitIcon.ico' {
            $dest = Join-Path $script:BrandTestDir 'AppDeployToolkit' 'AppDeployToolkitIcon.ico'
            Test-Path $dest | Should -BeTrue
        }
    }

    Context 'Missing source files are skipped without error' {
        It 'Does not throw when bannerImagePath does not exist' {
            $branding = [PSCustomObject]@{ companyName = ''; bannerImagePath = 'C:\DoesNotExist\banner.png'; iconPath = '' }
            { Set-PSADTBranding -PackagePath $script:BrandTestDir -Branding $branding } | Should -Not -Throw
        }
        It 'Does not throw when iconPath does not exist' {
            $branding = [PSCustomObject]@{ companyName = ''; bannerImagePath = ''; iconPath = 'C:\DoesNotExist\icon.ico' }
            { Set-PSADTBranding -PackagePath $script:BrandTestDir -Branding $branding } | Should -Not -Throw
        }
    }
}
