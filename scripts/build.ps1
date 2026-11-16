#Requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    dotnet.exe publish (Join-Path $root 'src\RustBxl.Processes\RustBxl.Processes.csproj') -c Release -o (Join-Path $root 'artifacts\processes') --no-self-contained
    Copy-Item -LiteralPath (Join-Path $root 'artifacts\processes\RustBxl.Processes.exe') -Destination (Join-Path $root 'artifacts\processes\LinkerRecorder.exe') -Force
} finally { Pop-Location }