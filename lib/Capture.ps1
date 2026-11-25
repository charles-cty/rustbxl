function Invoke-Capture([string]$Project, [string]$StateRoot, $Config, $Layout, [string]$Instance) {
    $helper = Get-Helper
    $bxl = Get-BuildXL $Config $StateRoot
    Initialize-Msvc
    $metadata = Assert-ContainedDependencies $Project $StateRoot $Config $Layout
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
    $reuse = Join-Path $Layout.Capture 'discovery-cache'
    $reference = Join-Path $Layout.Capture 'discovery-cache.sha256'
    if (Test-Path -LiteralPath $reuse) { Remove-Item -LiteralPath $reuse -Recurse -Force }
    try {
        $keep = $null
        $generate = @('generate', $Project, $Layout.Capture, $Layout.Source, $Layout.PhysicalTarget,
            $Layout.Target, (Join-Path $StateRoot 'plans'))
        if (Test-CacheService $Config) {
            New-Item -ItemType Directory -Path $reuse | Out-Null
            $discovery.nodes[0].environment += @{name='SIDECAR_DISCOVERY_CACHE'; value=$reuse}
            $generate += $reuse
            $seed = if (Test-Path -LiteralPath $reference) { $reference } else {
                Join-Path $StateRoot 'captures\main\discovery-cache.sha256'
            }
            if (Test-Path -LiteralPath $seed) {
                $hash = (Get-Content -LiteralPath $seed -Raw).Trim()
                if ($hash -match '^[0-9A-Fa-f]{64}$') {
                    $previous = Join-Path $reuse 'previous.zip'
                    $null = Invoke-DiscoveryCacheTransfer $bxl $Config 'placeFile' $previous $hash
                    if (Test-Path -LiteralPath $previous) {
                        if ((Get-FileHash -LiteralPath $previous -Algorithm SHA256).Hash -eq $hash) {
                            $keep = $hash
                        } else {
                            Remove-Item -LiteralPath $previous
                        }
                    }
                }
            }
        }
        Write-Json $discovery (Join-Path $graph 'graph.json')
        Invoke-BuildXL $bxl $graph (Join-Path $Layout.Capture 'discovery-run') $Project $Layout $Config $StateRoot $Instance -Discovery
        Write-Json $metadata (Join-Path $capture 'cargo-metadata.json')
        & $helper @generate
        # Cargo discovery outputs must not become undeclared replay inputs.
        Remove-Item -LiteralPath $Layout.PhysicalTarget -Recurse -Force
        Write-Json (Get-CaptureContract $Project $StateRoot $Config $Layout $bxl) $contract
        $next = Join-Path $reuse 'next.zip'
        if (Test-Path -LiteralPath $next) {
            $hash = (Get-FileHash -LiteralPath $next -Algorithm SHA256).Hash
            $result = Invoke-DiscoveryCacheTransfer $bxl $Config 'putFile' $next ''
            if ($result -match "Content added with hash=\[SHA256:$hash\]") {
                $keep = $hash
            } else {
                Write-Warning "Discovery cache archive was not stored: $result"
            }
        }
        if ($keep) {
            $temporary = Join-Path $reuse 'reference'
            [IO.File]::WriteAllText($temporary, $keep)
            [IO.File]::Move($temporary, $reference, $true)
        }
    } finally {
        if (Test-Path -LiteralPath $reuse) { Remove-Item -LiteralPath $reuse -Recurse -Force }
    }
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
