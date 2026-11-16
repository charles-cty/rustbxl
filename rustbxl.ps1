#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('help', 'init', 'prepare', 'capture', 'build', 'status', 'cache-start', 'cache-stop', 'compress')]
    [string]$Command = 'help',
    [string]$State,
    [string]$Project,
    [ValidatePattern('^[A-Za-z0-9-]{1,40}$')][string]$Instance = 'main',
    [ValidatePattern('^[A-Za-z0-9-]{1,40}$')][string]$Capture = 'main',
    [string]$BuildXLRoot,
    [string]$BindMount,
    [string]$Toolchain = 'stable',
    [string]$Profile = 'dev',
    [string[]]$Features = @(),
    [string[]]$Packages = @(),
    [switch]$DefaultFeatures,
    [ValidateRange(1024,65535)][int]$Port = 7089,
    [ValidateRange(64,1048576)][int]$CacheSizeMiB = 4096,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$CacheScenario = 'RustBxl',
    [switch]$Diagnostics,
    [ValidatePattern('^[A-Za-z0-9-]{1,40}$')][string[]]$ActiveInstances = @(),
    [string[]]$ExcludePath = @(),
    [ValidateRange(0,36500)][int]$MinimumAgeDays = 7,
    [ValidateRange(1,1048576)][int]$MinimumSizeKiB = 64,
    [switch]$Apply
)

if ($Command -eq 'help') {
    @'
rustbxl: stable Rust process graphs on Windows x64

pwsh.exe -File rustbxl.ps1 <command> -State <sidecar-directory> [options]

init        -Project <workspace> [-BuildXLRoot <checkout>] [-BindMount <exe>]
            [-Toolchain stable] [-Profile dev] [-Packages a,b] [-Features a,b]
            [-DefaultFeatures] [-Port 7089] [-CacheSizeMiB 4096] [-CacheScenario RustBxl]
prepare     Download Cargo dependencies into the separate Cargo home.
capture     Discover processes and generate pips. Compilation is offline.
build       Replay the captured graph. Cargo is not an execution pip.
status      Print configuration, capture state, and output paths as JSON.
cache-start Run the shared local cache service in the foreground.
cache-stop  Stop the configured cache service.
compress    Preview cold artifact compression after clients and cache exit.
            [-ActiveInstances main,branch-a] [-ExcludePath <state-relative-path>]
            [-MinimumAgeDays 7] [-MinimumSizeKiB 64] [-Apply]

capture/build/status accept -Project <other-worktree> -Instance <name> -Capture <name>.
Use a distinct instance for each worktree. Compatible worktrees can share a capture.
Use a distinct capture after manifests, configuration, or dependencies diverge.
build accepts -Diagnostics to retain observed-access and fingerprint diagnostics.
compress protects all existing instances unless -ActiveInstances selects them.
It preserves all hard links to protected files. -Apply performs the compression.
Run scripts/build.ps1 once before capture. Tools can also use BUILDXL_ROOT and BINDMOUNT_EXE.
'@
    exit 0
}

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Contract.ps1')
. (Join-Path $PSScriptRoot 'lib\Capture.ps1')
. (Join-Path $PSScriptRoot 'lib\Cache.ps1')
. (Join-Path $PSScriptRoot 'lib\Compression.ps1')
$handles = [Collections.Generic.List[IO.FileStream]]::new()

try {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell on Windows.' }
    if (-not $State) { throw 'Supply -State with an external sidecar directory.' }
    $State = Assert-LocalPath $State
    $configPath = Join-Path $State 'rustbxl.json'
    if ($Command -eq 'init') {
        if (Test-Path -LiteralPath $configPath) { throw "Configuration already exists: $configPath" }
        if (-not $Project) { throw 'init requires -Project.' }
        $Project = Assert-LocalPath $Project
        Assert-Project $Project $State
        $config = [ordered]@{
            version = 1
            project = $Project
            tools = @{ buildxlRoot = $BuildXLRoot; bindmount = $BindMount }
            build = [ordered]@{
                toolchain = $Toolchain; target = 'x86_64-pc-windows-msvc'; profile = $Profile
                packages = @($Packages); features = @($Features); defaultFeatures = $DefaultFeatures.IsPresent
                rustFlags = @(); environment = @{}
            }
            namespace = @{
                source = 'namespace\workspace-source-root-for-concurrent-rust-builds'
                target = 'namespace\workspace-output-root-for-concurrent-rust-builds-with-shared-cache'
            }
            cache = @{ port = $Port; scenario = $CacheScenario; maxSizeMiB = $CacheSizeMiB }
        }
        Assert-Config $config
        New-Item -ItemType Directory -Path $State, (Join-Path $State 'locks') -Force | Out-Null
        Write-Json $config $configPath
        [IO.File]::WriteAllText((Join-Path $State 'locks\dependencies.lock'), '')
        "INITIALIZED $configPath"
        exit 0
    }
    if (-not (Test-Path -LiteralPath $configPath)) { throw 'Configuration is missing. Run init first.' }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Config $config
    $maintenanceShare = if ($Command -eq 'compress') { [IO.FileShare]::None } else { [IO.FileShare]::ReadWrite }
    $handles.Add([IO.File]::Open((Join-Path $State 'locks\maintenance.lock'), [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, $maintenanceShare))
    if ($Command -eq 'compress') {
        $handles.Add([IO.File]::Open((Join-Path $State 'locks\dependencies.lock'), [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
        Invoke-ArtifactCompression $State $config $ActiveInstances $ExcludePath $MinimumAgeDays ([long]$MinimumSizeKiB * 1024) -Apply:$Apply
        exit 0
    }
    if (-not $Project) { $Project = $config.project }
    $Project = Assert-LocalPath $Project
    Assert-Project $Project $State
    $layout = Get-Layout $State $Instance $Capture $config

    if ($Command -eq 'status') {
        $contract = Join-Path $layout.Capture 'contract.json'
        $reason = 'Capture is missing.'
        $valid = $false
        if (Test-Path -LiteralPath $contract) {
            try {
                Initialize-Msvc
                $bxl = Get-BuildXL $config $State
                Assert-CaptureContract $Project $State $config $layout $bxl
                $valid = $true
                $reason = 'Capture matches the current configuration and Cargo inputs.'
            } catch { $reason = $_.Exception.Message }
        }
        [ordered]@{
            config = $configPath; project = $Project; instance = $Instance; capture = $Capture
            captureValid = $valid; reason = $reason; targetDirectory = $layout.PhysicalTarget
            build = $config.build; cache = $config.cache
        } | ConvertTo-Json -Depth 8
        exit 0
    }
    if ($Command -eq 'cache-start') { Invoke-CacheService $State $config; exit 0 }
    if ($Command -eq 'cache-stop') { Invoke-CacheService $State $config -Stop; exit 0 }

    # OS file handles release these locks on success, failure, and process termination.
    $dependencyShare = if ($Command -eq 'build') { [IO.FileShare]::Read } else { [IO.FileShare]::None }
    $dependencyAccess = if ($Command -eq 'build') { [IO.FileAccess]::Read } else { [IO.FileAccess]::ReadWrite }
    $handles.Add([IO.File]::Open((Join-Path $State 'locks\dependencies.lock'), [IO.FileMode]::Open, $dependencyAccess, $dependencyShare))
    if ($Command -eq 'prepare') {
        $environment = Get-BuildEnvironment $config $State $layout
        $environment.CARGO_TARGET_DIR = $layout.PhysicalTarget
        Invoke-WithEnvironment $environment {
            Push-Location $Project
            try { $arguments = @(Get-CargoArguments $config -Fetch); cargo.exe @arguments }
            finally { Pop-Location }
        }
        "DEPENDENCIES_READY $(Join-Path $State 'cargo-home')"
        exit 0
    }

    $handles.Add([IO.File]::Open((Join-Path $State "locks\instance-$Instance.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
    $captureLock = Join-Path $State "locks\capture-$Capture.lock"
    if ($Command -eq 'capture') {
        $handles.Add([IO.File]::Open($captureLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
        Invoke-Capture $Project $State $config $layout $Instance
    } else {
        if (-not (Test-Path -LiteralPath $captureLock)) { throw 'Capture is missing. Run capture first.' }
        $handles.Add([IO.File]::Open($captureLock, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        Invoke-Replay $Project $State $config $layout $Instance -Diagnostics:$Diagnostics
    }
} catch {
    [Console]::Error.WriteLine('rustbxl: ' + $_.Exception.Message)
    exit 1
} finally {
    foreach ($handle in $handles) { $handle.Dispose() }
}
