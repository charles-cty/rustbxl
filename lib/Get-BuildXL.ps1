[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Assert-BuildXLPackage([string]$Directory) {
    foreach ($file in @('bxl.exe', 'ContentStoreApp.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $file) -PathType Leaf)) {
            throw "BuildXL package is missing $file in $Directory."
        }
    }
}

$name = 'microsoft.buildxl.win-x64'
$version = '0.1.0-20260814.1'
$feedUrl = 'https://pkgs.dev.azure.com/mseng/PipelineTools/_packaging/BuildXL.External/nuget/v3/index.json'
$bootstrap = Join-Path $StateRoot 'bootstrap'
$destination = Join-Path $bootstrap "$name.$version"

if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
    $feed = Invoke-RestMethod -Uri $feedUrl
    $base = $feed.resources | Where-Object { $_.'@type' -match '^PackageBaseAddress' } |
        Select-Object -First 1 -ExpandProperty '@id'
    if (-not $base) { throw 'BuildXL feed has no PackageBaseAddress resource.' }
    $uri = "$($base.TrimEnd('/'))/$name/$version/$name.$version.nupkg"
    $staging = Join-Path $bootstrap ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        $package = Join-Path $staging 'buildxl.nupkg'
        $extracted = Join-Path $staging 'package'
        Write-Host "Downloading BuildXL $name $version"
        Invoke-WebRequest -Uri $uri -OutFile $package
        [System.IO.Compression.ZipFile]::ExtractToDirectory($package, $extracted)
        Assert-BuildXLPackage $extracted

        # Publish the complete directory even if multiple clients bootstrap at once.
        try { [IO.Directory]::Move($extracted, $destination) }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw }
        }
    } finally { Remove-Item -LiteralPath $staging -Recurse -Force }
}

Assert-BuildXLPackage $destination
Join-Path $destination 'bxl.exe'
