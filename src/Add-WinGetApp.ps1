<#
.SYNOPSIS
    Searches WinGet packages (full text) and adds selected ones to the apps.json batch list.

.DESCRIPTION
    Performs a full-text search against the WinGet repository (via the local WinGet client,
    or the winget.run API as fallback), displays the results as a numbered list, and appends
    the packages you select to the apps.json file used by Invoke-WinGetAutomater.ps1 -AppsFile.

    The apps file is created automatically if it does not exist yet.
    Packages already present in the list are skipped (no duplicates).

.PARAMETER Query
    Full-text search term, e.g. "vlc", "pdf reader", "7zip".

.PARAMETER AppsFile
    Path to the apps JSON file. Defaults to config\apps.json relative to the project root.

.PARAMETER MaxResults
    Maximum number of search results to display. Default: 20.

.EXAMPLE
    .\src\Add-WinGetApp.ps1 vlc

.EXAMPLE
    .\src\Add-WinGetApp.ps1 -Query "pdf reader" -MaxResults 30

.EXAMPLE
    .\src\Add-WinGetApp.ps1 firefox -AppsFile "C:\my\apps.json"
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Query,

    [string]$AppsFile = (Join-Path $PSScriptRoot '..\config\apps.json'),

    [ValidateRange(1, 100)]
    [int]$MaxResults = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules\WinGetHelper.psm1') -Force

# ─── Search ───────────────────────────────────────────────────────────────────

Write-Host "`nSearching WinGet packages for: '$Query'..." -ForegroundColor Cyan
$found = @(Search-WinGetPackage -Query $Query -MaxResults $MaxResults)

if ($found.Count -eq 0) {
    Write-Host "No packages found for '$Query'." -ForegroundColor Yellow
    return
}

# ─── Load (or initialize) apps.json ───────────────────────────────────────────

$appsPath = [System.IO.Path]::GetFullPath($AppsFile)
$apps = if (Test-Path $appsPath) {
    Get-Content $appsPath -Raw | ConvertFrom-Json
} else {
    [PSCustomObject]@{
        _comment = 'Batch mode package list. Pass this file via -AppsFile parameter.'
        packages = @()
    }
}
$existingIds = @($apps.packages | ForEach-Object PackageId)

# ─── Display results ──────────────────────────────────────────────────────────

Write-Host ""
$idWidth   = [Math]::Max(9,  ($found.PackageId | Measure-Object -Maximum -Property Length).Maximum)
$nameWidth = [Math]::Max(4,  ($found.Name      | Measure-Object -Maximum -Property Length).Maximum)

Write-Host ("  {0,4}  {1,-$idWidth}  {2,-$nameWidth}  {3}" -f '#', 'PackageId', 'Name', 'Version') -ForegroundColor White
Write-Host ("  {0}" -f ('─' * (10 + $idWidth + $nameWidth + 12))) -ForegroundColor DarkGray

for ($n = 0; $n -lt $found.Count; $n++) {
    $p = $found[$n]
    $marker = if ($p.PackageId -in $existingIds) { ' (already in list)' } else { '' }
    $color  = if ($marker) { 'DarkGray' } else { 'Gray' }
    Write-Host ("  [{0,2}]  {1,-$idWidth}  {2,-$nameWidth}  {3}{4}" -f ($n + 1), $p.PackageId, $p.Name, $p.Version, $marker) -ForegroundColor $color
}

# ─── Selection ────────────────────────────────────────────────────────────────

Write-Host ""
$answer = Read-Host "Select package(s) to add — e.g. 1 or 1,3,5 or 'a' for all  [Enter = cancel]"
if ([string]::IsNullOrWhiteSpace($answer)) {
    Write-Host "Cancelled — nothing added." -ForegroundColor Yellow
    return
}

$selected = if ($answer.Trim() -match '^[Aa](ll)?$') {
    $found
} else {
    $indices = $answer -split '[,;\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $invalid = @($indices | Where-Object { $_ -lt 1 -or $_ -gt $found.Count })
    if ($invalid) {
        throw "Invalid selection: $($invalid -join ', '). Valid range: 1-$($found.Count)."
    }
    @($indices | Sort-Object -Unique | ForEach-Object { $found[$_ - 1] })
}

if (-not $selected -or @($selected).Count -eq 0) {
    Write-Host "No valid selection — nothing added." -ForegroundColor Yellow
    return
}

# ─── Append to apps.json (skip duplicates) ────────────────────────────────────

$added   = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$pkgList = [System.Collections.Generic.List[PSCustomObject]]::new()
$apps.packages | ForEach-Object { $pkgList.Add($_) }

foreach ($pkg in $selected) {
    if ($pkg.PackageId -in $existingIds) {
        $skipped.Add($pkg.PackageId)
        continue
    }
    $pkgList.Add([PSCustomObject]@{
        PackageId = $pkg.PackageId
        Version   = $null      # null = always use latest version
    })
    $existingIds += $pkg.PackageId
    $added.Add($pkg.PackageId)
}

if ($added.Count -gt 0) {
    $apps.packages = $pkgList.ToArray()
    New-Item -ItemType Directory -Path (Split-Path $appsPath -Parent) -Force | Out-Null
    $apps | ConvertTo-Json -Depth 5 | Set-Content -Path $appsPath -Encoding UTF8
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
foreach ($id in $added)   { Write-Host "  + $id" -ForegroundColor Green }
foreach ($id in $skipped) { Write-Host "  = $id (already in list, skipped)" -ForegroundColor DarkGray }
Write-Host ""
Write-Host "$($added.Count) package(s) added to: $appsPath" -ForegroundColor $(if ($added.Count) { 'Green' } else { 'Yellow' })
if ($added.Count -gt 0) {
    Write-Host "Build them with:  .\src\Invoke-WinGetAutomater.ps1 -AppsFile `"$appsPath`"" -ForegroundColor Cyan
}
