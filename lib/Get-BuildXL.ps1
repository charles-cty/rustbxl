[CmdletBinding()]
param(
    [string]$BuildXLRoot = $env:BUILDXL_ROOT,
    [string]$StateRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'buildxl-state')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if (-not $BuildXLRoot) { throw 'Supply -BuildXLRoot or set BUILDXL_ROOT.' }
$repository = (Resolve-Path -LiteralPath $BuildXLRoot).Path
$versionFile = Join-Path $repository 'Shared\Scripts\BuildXLLkgVersionPublic.cmd'
$settings = @{}
foreach ($line in Get-Content -LiteralPath $versionFile) {
    if ($line -match '^set (BUILDXL_LKG_\w+)=(.+)$') { $settings[$Matches[1]] = $Matches[2].Trim() }
}
$name = $settings['BUILDXL_LKG_NAME'].ToLowerInvariant()
$version = $settings['BUILDXL_LKG_VERSION'].ToLowerInvariant()
$destination = Join-Path $StateRoot "bootstrap\$name.$version"
$executable = Join-Path $destination 'bxl.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    $feed = Invoke-RestMethod -Uri $settings['BUILDXL_LKG_FEED_1']
    $base = $feed.resources | Where-Object { $_.'@type' -match '^PackageBaseAddress' } |
        Select-Object -First 1 -ExpandProperty '@id'
    if (-not $base) { throw 'BuildXL feed has no PackageBaseAddress resource.' }
    $package = Join-Path $StateRoot "bootstrap\$name.$version.nupkg"
    New-Item -ItemType Directory -Path (Split-Path -Parent $package) -Force | Out-Null
    $uri = "$($base.TrimEnd('/'))/$name/$version/$name.$version.nupkg"
    Write-Host "Downloading repository-selected BuildXL bootstrap: $name $version"
    Invoke-WebRequest -Uri $uri -OutFile $package
    [System.IO.Compression.ZipFile]::ExtractToDirectory($package, $destination)
    Remove-Item -LiteralPath $package
}
if (-not (Test-Path -LiteralPath $executable)) { throw "BuildXL package has no bxl.exe: $destination" }
Write-Output $executable
