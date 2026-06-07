#Requires -Version 7.0
<#
.SYNOPSIS
    Runs all Pester tests for WinGet-Automater.

.PARAMETER Suite
    Which test suite to run: All (default), Unit, Integration.
    Unit    – PSADTBuilder + IntuneUploader (mocked, no network required)
    Integration – WinGetHelper (live GitHub calls)

.PARAMETER OutputFormat
    Pester output format. Default: Detailed. Options: Normal, Detailed, Diagnostic.

.EXAMPLE
    .\tests\Run-Tests.ps1
    .\tests\Run-Tests.ps1 -Suite Unit
    .\tests\Run-Tests.ps1 -Suite Integration
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Unit', 'Integration')]
    [string]$Suite = 'All',

    [ValidateSet('Normal', 'Detailed', 'Diagnostic')]
    [string]$OutputFormat = 'Detailed'
)

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object Version -ge '5.0')) {
    Write-Host "Installing Pester 5..." -ForegroundColor Yellow
    Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser -AllowClobber
}
Import-Module Pester -MinimumVersion 5.0 -Force

$testsRoot = $PSScriptRoot

# Unit  = mocked, no credentials needed (IntuneUploader)
# Integration = live public APIs, no credentials needed (WinGetHelper, PSADTBuilder)
$unitFiles = @(
    Join-Path $testsRoot 'IntuneUploader.Tests.ps1'
)
$integrationFiles = @(
    Join-Path $testsRoot 'WinGetHelper.Tests.ps1'
    Join-Path $testsRoot 'PSADTBuilder.Tests.ps1'
)

$paths = switch ($Suite) {
    'Unit'        { $unitFiles }
    'Integration' { $integrationFiles }
    default       { $unitFiles + $integrationFiles }
}

$config = New-PesterConfiguration
$config.Run.Path            = $paths
$config.Output.Verbosity    = $OutputFormat
$config.TestResult.Enabled  = $true
$config.TestResult.OutputPath = Join-Path $testsRoot 'TestResults.xml'

$result = Invoke-Pester -Configuration $config

if ($result.FailedCount -gt 0) {
    Write-Host "`n$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll $($result.PassedCount) tests passed." -ForegroundColor Green
