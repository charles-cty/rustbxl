$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Json($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Assert-LocalPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:\\.+') { throw "Use a Windows-local path in a subdirectory: $Path" }
    $full
}

function Test-Within([string]$Path, [string]$Directory) {
    $Path.Equals($Directory, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Directory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-Msvc {
    if ($env:VSCMD_ARG_HOST_ARCH -eq 'x64' -and $env:VSCMD_ARG_TGT_ARCH -eq 'x64') {
        Get-Command link.exe -ErrorAction Stop | Out-Null
        return
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'Visual Studio x64 C++ tools are required.' }
    $location = (Get-Location).Path
    try {
        & (Join-Path $installation 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Host
    } finally { Set-Location -LiteralPath $location }
    Get-Command link.exe -ErrorAction Stop | Out-Null
}

function Get-Layout([string]$StateRoot, [string]$Instance, [string]$CaptureName, $Config) {
    @{
        Source = Join-Path $StateRoot $Config.namespace.source
        Target = Join-Path $StateRoot $Config.namespace.target
        PhysicalTarget = Join-Path $StateRoot "instances\$Instance\target"
        Run = Join-Path $StateRoot "instances\$Instance\run"
        Capture = Join-Path $StateRoot "captures\$CaptureName"
    }
}

function Get-BindMount($Config) {
    $path = if ($Config.tools.bindmount) { $Config.tools.bindmount } else { $env:BINDMOUNT_EXE }
    if ($path) { return (Resolve-Path -LiteralPath $path).Path }
    (Get-Command bindmount.exe -ErrorAction Stop).Source
}

function Get-BuildXL($Config, [string]$StateRoot) {
    $checkout = if ($Config.tools.buildxlRoot) { $Config.tools.buildxlRoot } else { $env:BUILDXL_ROOT }
    & (Join-Path $PSScriptRoot 'Get-BuildXL.ps1') -BuildXLRoot $checkout -StateRoot $StateRoot
}

function Get-Helper {
    $helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\processes\RustBxl.Processes.exe'
    if (-not (Test-Path -LiteralPath $helper)) { throw 'Process helper is missing. Run scripts\build.ps1 from the rustbxl checkout.' }
    $helper
}

function Invoke-MappedProcess([string]$Executable, [string[]]$Arguments, [string]$Project, $Layout, $Config, [string]$Instance) {
    foreach ($path in @($Layout.Source, $Layout.Target, $Layout.PhysicalTarget)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $bindings = @('--link', "$($Layout.Source)=$Project", '--link', "$($Layout.Target)=$($Layout.PhysicalTarget)")
    & (Get-BindMount $Config) exec --no-ui-restrictions @bindings "RustBxl-$Instance-$PID" -- $Executable @Arguments
}

function Invoke-BuildXL([string]$Bxl, [string]$Graph, [string]$Run, [string]$Project, $Layout, $Config, [string]$StateRoot, [string]$Instance, [switch]$Discovery, [switch]$Diagnostics) {
    if ($Layout.Target.Length -lt $Layout.PhysicalTarget.Length) {
        throw 'The target namespace is too short for cache RPC placement. Use a shorter instance name.'
    }
    New-Item -ItemType Directory -Path $Run -Force | Out-Null
    $arguments = @(
        "/c:$(Join-Path (Split-Path -Parent $PSScriptRoot) 'frontend\config.dsc')",
        "/substSource:$($Layout.PhysicalTarget)", "/substTarget:$($Layout.Target)",
        "/translateDirectory:$($Project)::$($Layout.Source)",
        "/cacheDirectory:$(Join-Path $StateRoot 'cache')",
        "/storageRoot:$Run",
        "/engineCacheDirectory:$(Join-Path $Run 'engine')",
        "/logsDirectory:$(Join-Path $Run 'logs')", "/objectDirectory:$(Join-Path $Run 'obj')",
        '/server-', '/incrementalScheduling-', '/logProcesses+', '/enableLazyOutputs-', '/processRetries:0'
    )
    if ($Discovery -or $Diagnostics) {
        $arguments += @('/logObservedFileAccesses+', '/storeFingerprints+')
    } else {
        $arguments += @('/logObservedFileAccesses-', '/storeFingerprints-')
    }
    if ($Discovery) {
        $arguments += @('/storeOutputsToCache-', "/cacheDirectory:$(Join-Path $Run 'discovery-cache')")
    } else {
        $client = Join-Path $StateRoot 'cache-service\client.json'
        if (-not (Test-Path -LiteralPath $client)) { throw 'Cache service is not configured. Run cache-start first.' }
        $arguments += "/cacheConfigFilePath:$client"
    }
    $telemetry = if ($Discovery) { Start-MsvcTelemetry } else { $null }
    try {
        $frontendEnvironment = @{
            RUSTBXL_SDK = Join-Path (Split-Path $Bxl) 'Sdk'
            RUSTBXL_STATE = $StateRoot
            RUSTBXL_SOURCE = $Layout.Source
            RUSTBXL_TARGET = $Layout.Target
            RUSTBXL_GRAPH = Join-Path $Graph 'graph.json'
        }
        Invoke-WithEnvironment $frontendEnvironment {
            Invoke-MappedProcess $Bxl $arguments $Project $Layout $Config $Instance
        }
    } finally {
        if ($telemetry) { Stop-MsvcTelemetry $telemetry }
    }
}

function Start-MsvcTelemetry {
    # Keep one service outside observed process trees while clients link.
    $telemetryStart = [Diagnostics.ProcessStartInfo]::new((Get-Command VCTIP.EXE -ErrorAction Stop).Source)
    $telemetryStart.UseShellExecute = $false
    $telemetryStart.ArgumentList.Add('-upload:skip')
    $telemetryStart.ArgumentList.Add('-timeout:0')
    [Diagnostics.Process]::Start($telemetryStart)
}

function Stop-MsvcTelemetry([Diagnostics.Process]$Process) {
    if (-not $Process.HasExited) { $Process.Kill($true); $Process.WaitForExit() }
    $Process.Dispose()
}

function Get-CargoArguments($Config, [switch]$Fetch) {
    $arguments = if ($Fetch) { @('fetch', '--locked', '--target', $Config.build.target) } else {
        @('build', '--locked', '--offline', '--target', $Config.build.target, '--profile', $Config.build.profile, '--message-format=json')
    }
    if (-not $Fetch) {
        if ($Config.build.packages.Count) {
            foreach ($package in $Config.build.packages) { $arguments += @('--package', $package) }
        } else { $arguments += '--workspace' }
        if (-not $Config.build.defaultFeatures) { $arguments += '--no-default-features' }
        if ($Config.build.features.Count) { $arguments += @('--features', ($Config.build.features -join ',')) }
    }
    $arguments
}

function Get-BuildEnvironment($Config, [string]$StateRoot, $Layout) {
    $environment = [ordered]@{}
    foreach ($key in @('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'SystemRoot', 'USERPROFILE', 'RUSTUP_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($key)
        if ($null -ne $value) { $environment[$key] = $value }
    }
    # PowerShell prepends its runtime directory in child sessions. Keep that
    # directory at one stable position across normal and developer shells.
    $searchPaths = @($env:PATH -split ';' | Where-Object {
        -not $_.TrimEnd('\').Equals($PSHOME.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    })
    $environment.PATH = (@($PSHOME) + $searchPaths) -join ';'
    foreach ($key in $Config.build.environment.Keys) { $environment[$key] = $Config.build.environment[$key] }
    $environment.CARGO_HOME = Join-Path $StateRoot 'cargo-home'
    $environment.CARGO_INCREMENTAL = '0'
    $environment.RUSTUP_TOOLCHAIN = $Config.build.toolchain
    $environment.CARGO_TARGET_DIR = $Layout.Target
    $flags = @("--remap-path-prefix=$($Layout.Source)=/_/workspace", "--remap-path-prefix=$($Layout.Target)=/_/target") + @($Config.build.rustFlags)
    $environment.SIDECAR_RUSTFLAGS = ConvertTo-Json -InputObject $flags -Compress
    $environment._NO_DEBUG_HEAP = '1'
    $environment
}

function Invoke-WithEnvironment($Environment, [scriptblock]$Action) {
    $saved = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ($entry.Key -match '^(CARGO|RUST|SIDECAR)' -and $entry.Key -ne 'RUSTUP_HOME') {
            $saved[$entry.Key] = $entry.Value
            [Environment]::SetEnvironmentVariable($entry.Key, $null)
        }
    }
    foreach ($key in $Environment.Keys) {
        if (-not $saved.ContainsKey($key)) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
        [Environment]::SetEnvironmentVariable($key, $Environment[$key])
    }
    try { & $Action } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
}

function Assert-Project([string]$Project, [string]$StateRoot) {
    if (-not (Test-Path -LiteralPath (Join-Path $Project 'Cargo.toml'))) { throw "Cargo.toml is missing: $Project" }
    if (-not (Test-Path -LiteralPath (Join-Path $Project 'Cargo.lock'))) { throw 'Commit or generate Cargo.lock with Cargo before init. rustbxl uses --locked.' }
    if ((Test-Within $StateRoot $Project) -or (Test-Within $Project $StateRoot)) {
        throw 'Keep the sidecar state and project in separate directory trees.'
    }
}

function Assert-Config($Config) {
    if ($Config.version -ne 1) { throw 'Unsupported rustbxl config version.' }
    if ($Config.build.target -ne 'x86_64-pc-windows-msvc') { throw 'This release supports the x86_64-pc-windows-msvc target.' }
    if ($Config.build.toolchain -notmatch '^(stable|1\.\d+\.\d+)(-x86_64-pc-windows-msvc)?$') { throw 'Use stable Rust or a stable release number.' }
    if ($Config.build.profile -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid Cargo profile name.' }
    $reserved = @('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'SYSTEMROOT', 'USERPROFILE', 'RUSTUP_HOME', '_NO_DEBUG_HEAP')
    foreach ($key in $Config.build.environment.Keys) {
        if ($key -match '^(CARGO|RUST|SIDECAR|BUILDXL|DETOURS|DOMINO|TEMP|TMP)' -or $key.ToUpperInvariant() -in $reserved) {
            throw "Reserved environment variable: $key. Use build options for Cargo and Rust settings."
        }
    }
}
