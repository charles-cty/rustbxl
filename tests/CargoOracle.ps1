#Requires -Version 7.4
param([Parameter(Mandatory)][string]$Request)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$data = Get-Content -LiteralPath $Request -Raw | ConvertFrom-Json -AsHashtable
Set-Location -LiteralPath $data.workingDirectory
$arguments = [string[]]$data.arguments
& $data.executable @arguments
