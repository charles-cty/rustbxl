#Requires -Version 7.4
[CmdletBinding()]
param([string]$RunRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test\compression'))
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Common.ps1')
$RunRoot = Assert-LocalPath $RunRoot
if (Test-Path -LiteralPath $RunRoot) { throw 'Use an empty compression test directory.' }
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$project = Join-Path $RunRoot 'project'
$state = Join-Path $RunRoot 'state'
New-Item -ItemType Directory -Path $project | Out-Null
[IO.File]::WriteAllText((Join-Path $project 'Cargo.toml'), '[workspace]')
[IO.File]::WriteAllText((Join-Path $project 'Cargo.lock'), 'version = 4')
$records = [Collections.Generic.List[object]]::new()
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Cli([string]$Label, [string[]]$Arguments, [int]$ExpectedExit = 0) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-File',(Join-Path $root 'rustbxl.ps1')) + $Arguments + @('-State',$state)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $RunRoot "$Label.log"),$output)
    Assert ($process.ExitCode -eq $ExpectedExit) "Unexpected exit code for $Label. See its log."
    $process.Dispose()
    return $output
}
function Add-File([string]$Relative, [double]$AgeDays = 8, [int]$Bytes = 256KB) {
    $path = Join-Path $state $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllBytes($path, [byte[]]::new($Bytes))
    [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-$AgeDays))
    return $path
}
function Link([string]$Relative, [string]$Target) {
    $path = Join-Path $state $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    New-Item -ItemType HardLink -Path $path -Target $Target | Out-Null
    return $path
}
function Is-Compressed([string]$Path) {
    return ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::Compressed) -ne 0
}
function Record([string]$Name, $Details) {
    $records.Add(@{Case=$Name;Passed=$true;Details=$Details})
    $records.ToArray() | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $RunRoot 'results.json') -Encoding utf8NoBOM
    "PASS $Name"
}

& (Join-Path $root 'scripts\build.ps1') | Out-Host
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$null = Invoke-Cli init @('init','-Project',$project,'-Port',"$port",'-CacheScenario','CompressionTest')
$empty = Invoke-Cli empty-preview @('compress') | ConvertFrom-Json -AsHashtable
Assert (@($empty.ActiveInstances).Count -eq 0 -and $empty.CandidateFiles -eq 0) 'Empty state did not produce an empty selection.'
$blobRoot = 'cache\CompressionTest\Shared\VSO0\ABC'
$hot = Add-File 'instances\hot\target\current.rlib'
$hotBlob = Link "$blobRoot\hot.blob" $hot
$hotColdAlias = Link 'instances\cold\target\hot-alias.rlib' $hot
$cold = Add-File 'instances\cold\target\old.rlib'
$coldBlob = Link "$blobRoot\cold.blob" $cold
$excluded = Add-File 'instances\cold\target\excluded.pdb'
$excludedBlob = Link "$blobRoot\excluded.blob" $excluded
$recent = Add-File "$blobRoot\recent.blob" 6.99
$old = Add-File "$blobRoot\old.blob" 7.01
$incremental = Add-File 'instances\cold\target\debug\incremental\query-cache.bin'
$engine = Add-File 'instances\cold\run\engine\state.bin'
$database = Add-File 'cache\CompressionTest\RocksDbMemoizationStore\database.sst'
$log = Add-File 'instances\cold\run\logs\old.log'
$external = Add-File "$blobRoot\external.blob"
$outsideAlias = Join-Path $RunRoot 'outside.bin'
New-Item -ItemType HardLink -Path $outsideAlias -Target $external | Out-Null
$junctionTarget = Join-Path $RunRoot 'junction-target'
New-Item -ItemType Directory -Path $junctionTarget | Out-Null
$junctionFile = Join-Path $junctionTarget 'not-managed.bin'
[IO.File]::WriteAllBytes($junctionFile,[byte[]]::new(256KB))
New-Item -ItemType Junction -Path (Join-Path $state 'instances\cold\target\linked') -Target $junctionTarget | Out-Null
$unknownAlias = Add-File "$blobRoot\unknown.blob"
$unknownLink = Link 'maintenance\unknown-alias.bin' $unknownAlias
$acl = Get-Acl -LiteralPath $cold
$rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
    [Security.AccessControl.FileSystemRights]'WriteData,AppendData', [Security.AccessControl.AccessControlType]::Deny)
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $cold -AclObject $acl
$originalAcl = (Get-Acl -LiteralPath $cold).Sddl
$hash = (Get-FileHash -LiteralPath $cold -Algorithm SHA256).Hash
$fileId = @(& fsutil.exe file queryfileid $cold) -join [char]10
$writeTime = [IO.File]::GetLastWriteTimeUtc($cold)

$defaults = Invoke-Cli default-preview @('compress') | ConvertFrom-Json -AsHashtable
Assert ($defaults.Mode -eq 'preview') 'Compression must default to preview.'
Assert (@($defaults.ActiveInstances).Count -eq 2) 'Default did not protect all instances.'
Assert (-not (Is-Compressed $cold)) 'Preview modified an artifact.'
$arguments = @('compress','-ActiveInstances','hot','-ExcludePath','instances\cold\target\excluded.pdb')
$preview = Invoke-Cli selected-preview $arguments | ConvertFrom-Json -AsHashtable
Assert ($preview.CandidateFiles -eq 3) 'Preview did not select exactly cold content, old CAS content, and an old log.'
Assert (-not (Is-Compressed $coldBlob) -and -not (Is-Compressed $old)) 'Preview changed compression state.'
Assert ((Get-Acl -LiteralPath $cold).Sddl -ceq $originalAcl) 'Preview changed permissions.'
Record 'preview-and-hardlink-policy' $preview

$maintenance = [IO.File]::Open((Join-Path $state 'locks\maintenance.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
try { $null = Invoke-Cli reject-active-client $arguments 1 } finally { $maintenance.Dispose() }
$dependencies = [IO.File]::Open((Join-Path $state 'locks\dependencies.lock'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try { $null = Invoke-Cli reject-old-client $arguments 1 } finally { $dependencies.Dispose() }
$endpoint = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
$endpoint.Start()
try {
    $errorText = Invoke-Cli reject-cache-service $arguments 1
    Assert ($errorText.Contains('Stop the cache service')) 'Running cache was not rejected.'
} finally { $endpoint.Stop() }
Record 'maintenance-exclusion' $true

$applied = Invoke-Cli apply ($arguments + '-Apply') | ConvertFrom-Json -AsHashtable
Assert ($applied.CompressedFiles -eq 3 -and $applied.SavedBytes -gt 0) 'Cold artifact compression did not save space.'
Assert ((Is-Compressed $cold) -and (Is-Compressed $coldBlob) -and (Is-Compressed $old) -and (Is-Compressed $log)) 'Cold hardlink compression was incomplete.'
foreach ($path in @($hot,$hotBlob,$hotColdAlias,$excluded,$excludedBlob,$recent,$incremental,$engine,$database,$external,$outsideAlias,$junctionFile,$unknownAlias,$unknownLink)) {
    Assert (-not (Is-Compressed $path)) "Protected artifact was compressed: $path"
}
Assert ((Get-FileHash -LiteralPath $cold -Algorithm SHA256).Hash -ceq $hash) 'Compression changed file contents.'
Assert ((Get-Acl -LiteralPath $cold).Sddl -ceq $originalAcl) 'Compression changed the immutable ACL.'
Assert ((@(& fsutil.exe file queryfileid $cold) -join [char]10) -ceq $fileId) 'Compression replaced the file identity.'
Assert ([IO.File]::GetLastWriteTimeUtc($cold) -eq $writeTime) 'Compression changed LastWriteTime.'
Record 'compression-preserves-content-acl-and-identity' $applied
$again = Invoke-Cli idempotent ($arguments + '-Apply') | ConvertFrom-Json -AsHashtable
Assert ($again.CompressedFiles -eq 0 -and $again.CandidateFiles -eq 0) 'Compression was not idempotent.'
Record 'idempotent' $again

# A denied file held by another reader must keep its ACL when reopening fails.
$busy = Add-File "$blobRoot\busy.blob"
Set-Acl -LiteralPath $busy -AclObject $acl
$busyAcl = (Get-Acl -LiteralPath $busy).Sddl
$reader = [IO.File]::Open($busy,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
try {
    $blocked = Invoke-Cli held-reader ($arguments + '-Apply') | ConvertFrom-Json -AsHashtable
    Assert ($blocked.CandidateFiles -eq 1 -and $blocked.CompressedFiles -eq 0) 'An in-use artifact was compressed.'
    Assert ($blocked.Skipped['access-denied-or-in-use'] -eq 1) 'An in-use artifact was not reported.'
    Assert ((Get-Acl -LiteralPath $busy).Sddl -ceq $busyAcl) 'Failed reopen changed the immutable ACL.'
    Assert (-not (Is-Compressed $busy)) 'An in-use artifact changed compression state.'
} finally { $reader.Dispose() }
$released = Invoke-Cli released-reader ($arguments + '-Apply') | ConvertFrom-Json -AsHashtable
Assert ($released.CompressedFiles -eq 1 -and (Is-Compressed $busy)) 'A released artifact could not be compressed.'
Assert ((Get-Acl -LiteralPath $busy).Sddl -ceq $busyAcl) 'Released artifact lost its immutable ACL.'
Record 'held-file-restores-acl' $blocked

$small = Add-File "$blobRoot\size-below.blob" 8 (64KB - 1)
$threshold = Add-File "$blobRoot\size-equal.blob" 8 64KB
$above = Add-File "$blobRoot\size-above.blob" 8 (64KB + 1)
$readOnly = Add-File "$blobRoot\read-only.blob"
[IO.File]::SetAttributes($readOnly,[IO.FileAttributes]::ReadOnly)
$customDeny = Add-File "$blobRoot\custom-deny.blob"
$customAcl = Get-Acl -LiteralPath $customDeny
$customRule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
    [Security.AccessControl.FileSystemRights]::WriteData,[Security.AccessControl.AccessControlType]::Deny)
$customAcl.AddAccessRule($customRule)
Set-Acl -LiteralPath $customDeny -AclObject $customAcl
$customSddl = (Get-Acl -LiteralPath $customDeny).Sddl
$sizePreview = Invoke-Cli size-preview $arguments | ConvertFrom-Json -AsHashtable
$abovePreview = @($sizePreview.Files | Where-Object Path -EQ $above)
Assert ($abovePreview.Count -eq 1 -and $abovePreview[0].AllocatedBefore -gt (64KB + 1)) 'Allocation omitted the last partial disk cluster.'
$boundaries = Invoke-Cli size-and-access-boundaries ($arguments + '-Apply') | ConvertFrom-Json -AsHashtable
Assert ($boundaries.CompressedFiles -eq 2 -and (Is-Compressed $threshold) -and (Is-Compressed $above)) 'Files at or above the size threshold were not eligible.'
Assert (-not (Is-Compressed $small)) 'A file below the size threshold was compressed.'
Assert (-not (Is-Compressed $readOnly) -and -not (Is-Compressed $customDeny)) 'An unsupported access restriction was bypassed.'
Assert ((Get-Acl -LiteralPath $customDeny).Sddl -ceq $customSddl) 'A non-BuildXL deny rule was changed.'
Record 'size-and-access-boundaries' $boundaries

$savedInstances = Join-Path $state 'instances-saved'
$instancesRoot = Join-Path $state 'instances'
Move-Item -LiteralPath $instancesRoot -Destination $savedInstances
try {
    New-Item -ItemType Junction -Path $instancesRoot -Target $savedInstances | Out-Null
    $errorText = Invoke-Cli reject-reparse-root $arguments 1
    Assert ($errorText.Contains('reparse point')) 'A redirected compression root was accepted.'
} finally {
    if (Test-Path -LiteralPath $instancesRoot) { Remove-Item -LiteralPath $instancesRoot }
    Move-Item -LiteralPath $savedInstances -Destination $instancesRoot
}
Record 'reparse-root-rejected' $true
'COMPRESSION_PASS '+$records.Count+' cases. Evidence: '+$RunRoot
