function Invoke-Capture([string]$Project, [string]$StateRoot, $Config, $Layout, [string]$Instance) {
    $helper = Get-Helper
    $bxl = Get-BuildXL $Config $StateRoot
    Initialize-Msvc
    Assert-ContainedDependencies $Project $StateRoot $Config $Layout
    # Invalidate the contract before replacing capture data. A failed capture cannot be replayed.
    $contract = Join-Path $Layout.Capture 'contract.json'
    if (Test-Path -LiteralPath $contract) { Remove-Item -LiteralPath $contract }
    $capture = Join-Path $Layout.Capture 'capture'
    if (Test-Path -LiteralPath $capture) { Remove-Item -LiteralPath $capture -Recurse -Force }
    if (Test-Path -LiteralPath $Layout.PhysicalTarget) { Remove-Item -LiteralPath $Layout.PhysicalTarget -Recurse -Force }
    New-Item -ItemType Directory -Path $capture, $Layout.PhysicalTarget -Force | Out-Null
    $graph = Join-Path $Layout.Capture 'discovery'
    New-Item -ItemType Directory -Path $graph -Force | Out-Null
    $environment = Get-BuildEnvironment $Config $StateRoot $Layout
    $environment.RUSTC_WRAPPER = $helper
    $environment.SIDECAR_CAPTURE = $capture
    $environment.SIDECAR_LINKER = (Get-Command link.exe).Source
    $arguments = @('capture', (Join-Path $capture 'processes.jsonl'), (Get-Command cargo.exe).Source) + @(Get-CargoArguments $Config)
    $locks = (@('.global-cache', '.global-cache-journal', '.package-cache', '.package-cache-mutate') | ForEach-Object {
        Join-Path $StateRoot "cargo-home\$_"
    })
    $discovery = @{
        version = 1
        nodes = @(@{
            id = 'discovery'; kind = 'process'; tool = @{kind='file'; path=$helper}
            arguments = @($arguments); workingDirectory = $Layout.Source
            environment = @($environment.GetEnumerator() | ForEach-Object { @{name=$_.Key; value=$_.Value} })
            dependencies = @(); outputDirectories = @($Layout.Target, $capture)
            untrackedFiles = @($locks); disableCacheLookup = $true
            traceFile = Join-Path $Layout.Capture 'capture-trace.txt'
            consoleOutput = Join-Path $capture 'cargo-messages.jsonl'
        })
    }
    Write-Json $discovery (Join-Path $graph 'graph.json')
    Invoke-BuildXL $bxl $graph (Join-Path $Layout.Capture 'discovery-run') $Project $Layout $Config $StateRoot $Instance -Discovery
    & $helper generate $Project $Layout.Capture $Layout.Source $Layout.PhysicalTarget $Layout.Target
    # Cargo discovery outputs must not become undeclared replay inputs.
    # Only BuildXL's pip outputs can populate an instance target during replay.
    Remove-Item -LiteralPath $Layout.PhysicalTarget -Recurse -Force
    Write-Json (Get-CaptureContract $Project $StateRoot $Config $Layout $bxl) $contract
    "CAPTURE_READY $($Layout.Capture)"
}

function Invoke-Replay([string]$Project, [string]$StateRoot, $Config, $Layout, [string]$Instance, [switch]$Diagnostics) {
    $bxl = Get-BuildXL $Config $StateRoot
    Initialize-Msvc
    Assert-CaptureContract $Project $StateRoot $Config $Layout $bxl
    $graph = Join-Path $Layout.Capture 'replay'
    if (-not (Test-Path -LiteralPath (Join-Path $graph 'graph.json'))) { throw 'Generated graph is missing. Run capture.' }
    Invoke-BuildXL $bxl $graph $Layout.Run $Project $Layout $Config $StateRoot $Instance -Diagnostics:$Diagnostics
    $stats = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Layout.Run 'logs\BuildXL.stats')) {
        if ($line -match '^([^=]+)=(\d+)$') { $stats[$Matches[1]] = [long]$Matches[2] }
    }
    $result = [ordered]@{
        instance = $Instance; project = $Project; targetDirectory = $Layout.PhysicalTarget
        processCacheHits = $stats['ProcessPipCacheHits']
        processExecuted = $stats['PipExecution.ProcessPipsExecutedDueToCacheMiss']
    }
    Write-Json $result (Join-Path $Layout.Run 'result.json')
    "BUILD_RESULT $($result | ConvertTo-Json -Compress)"
}
