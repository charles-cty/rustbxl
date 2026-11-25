function Get-ProcessCacheHits([string]$Instance) {
    $hits = @{}
    $log = Join-Path $state "instances\$Instance\run\logs\BuildXL.log"
    foreach ($line in Get-Content -LiteralPath $log) {
        if ($line -match "\|\| (.+?)\] Cache hit \(weak fingerprint '([0-9A-F]+)'") {
            $hits[$Matches[1]] = $Matches[2]
        }
    }
    return $hits
}

function Test-CrossCapture {
    $baseline = Get-Content -LiteralPath (Join-Path $state 'captures\main\replay\graph.json') -Raw | ConvertFrom-Json -AsHashtable
    $baselineNodes = @($baseline.nodes | Where-Object kind -EQ process)
    $plans = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $state 'plans') -Filter '*.json' -File) {
        $plans[$file.FullName] = @{hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;time=$file.LastWriteTimeUtc.Ticks}
    }

    # A fresh instance cannot satisfy this check through incremental scheduling.
    $null = Invoke-Cli 'capture-identical' @('capture','-Project',$trees.gamma,'-Instance','gamma','-Capture','identical')
    $null = Invoke-Cli 'build-identical' @('build','-Project',$trees.gamma,'-Instance','gamma','-Capture','identical')
    $identical = Get-Content -LiteralPath (Join-Path $state 'instances\gamma\run\result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($identical.processExecuted -eq 0 -and $identical.processCacheHits -eq $baselineNodes.Count) 'Renaming a capture changed process cache fingerprints.'
    Assert ((Program-Output 'gamma') -ceq $oracle) 'Renamed capture differs from clean Cargo.'
    $hits = Get-ProcessCacheHits 'gamma'
    Assert ($hits.Count -eq $baselineNodes.Count) 'BuildXL did not report each cross-capture cache hit.'
    Record 'identical-named-captures' $identical

    $tree = $trees.gamma
    $variant = Join-Path $PSScriptRoot 'variants\dependency-added'
    $savedFiles = @{}
    foreach ($relative in @('Cargo.toml','Cargo.lock','app\Cargo.toml','app\src\main.rs')) {
        $savedFiles[$relative] = [IO.File]::ReadAllBytes((Join-Path $tree $relative))
    }
    try {
        foreach ($relative in @('Cargo.toml','app\Cargo.toml','app\src\main.rs')) {
            Copy-Item -LiteralPath (Join-Path $variant $relative) -Destination (Join-Path $tree $relative)
        }
        Copy-Item -LiteralPath (Join-Path $variant 'added-support') -Destination $tree -Recurse
        $environment = Get-BuildEnvironment $config $state (Get-Layout $state 'gamma' 'added' $config)
        Invoke-WithEnvironment $environment {
            Push-Location $tree
            try { cargo.exe generate-lockfile --offline | Out-Host }
            finally { Pop-Location }
        }
        $rejected = Invoke-Cli 'reject-added-dependency' @('build','-Project',$tree,'-Instance','gamma') 1
        Assert ($rejected.Contains('Capture input changed: files')) 'Added dependency was accepted by the old capture.'
        $null = Invoke-Cli 'capture-added' @('capture','-Project',$tree,'-Instance','gamma','-Capture','added')
        $null = Invoke-Cli 'build-added' @('build','-Project',$tree,'-Instance','gamma','-Capture','added')
        $added = Get-Content -LiteralPath (Join-Path $state 'instances\gamma\run\result.json') -Raw | ConvertFrom-Json -AsHashtable
        $expected = Cargo-Oracle 'dependency-added' 'gamma'
        Assert ($expected.Contains('new-dependency=added-dependency')) 'Cargo did not exercise the new dependency.'
        Assert ((Program-Output 'gamma') -ceq $expected) 'Dependency addition differs from clean Cargo.'

        $newGraph = Get-Content -LiteralPath (Join-Path $state 'captures\added\replay\graph.json') -Raw | ConvertFrom-Json -AsHashtable
        $newNodes = @{}
        foreach ($node in $newGraph.nodes | Where-Object kind -EQ process) { $newNodes[$node.id] = $node }
        Assert ($newNodes.Count -gt $baselineNodes.Count) 'Added dependency did not add process nodes.'
        $newHits = Get-ProcessCacheHits 'gamma'
        $unchanged = @($baselineNodes | Where-Object {
            $newNodes.ContainsKey($_.id) -and
                (ConvertTo-Json -InputObject $_ -Depth 12 -Compress) -ceq (ConvertTo-Json -InputObject $newNodes[$_.id] -Depth 12 -Compress)
        })
        Assert (@($unchanged | Where-Object id -Like 'run-*').Count -gt 0) 'Unchanged graph did not include build-script runners.'
        Assert (@($unchanged | Where-Object id -Like 'probe_support-*').Count -gt 0) 'Unchanged graph did not include library compilers.'
        foreach ($node in $unchanged) {
            Assert ($newHits.ContainsKey($node.id)) "Unchanged task did not hit the shared cache: $($node.id)"
            Assert ($newHits[$node.id] -ceq $hits[$node.id]) "Unchanged task changed its weak fingerprint: $($node.id)"
        }
        $oldConsumer = @($baselineNodes | Where-Object id -Like 'run-rustbxl-fixture-*')
        $newConsumer = @($newNodes.Values | Where-Object id -Like 'run-rustbxl-fixture-*')
        Assert ($oldConsumer.Count -eq 1 -and $newConsumer.Count -eq 1) 'Expected one metadata consumer in each graph.'
        Assert ($oldConsumer[0].arguments[1] -cne $newConsumer[0].arguments[1]) 'New metadata dependency did not change its consumer plan.'
        $consumerPlan = Get-Content -LiteralPath $newConsumer[0].arguments[1] -Raw | ConvertFrom-Json -AsHashtable
        Assert ('DEP_ADDED_PROBE_' -in $consumerPlan.Metadata.Prefix) 'New consumer plan omitted the added metadata producer.'
        Assert (-not $newHits.ContainsKey($newConsumer[0].id)) 'Changed metadata dependency reused the old script task.'
        Assert ($added.processExecuted -gt 0) 'New dependency incorrectly reused every cached process.'
        Record 'dependency-added-cross-capture' @{result=$added; unchanged=$unchanged.id; changedPlan=$newConsumer[0].id; processPips=$newNodes.Count}

        $oldDriver = Start-Driver 'parallel-capture-main' @('build','-State',$state,'-Project',$trees.alpha,'-Instance','alpha')
        $newDriver = Start-Driver 'parallel-capture-added' @('build','-State',$state,'-Project',$tree,'-Instance','gamma','-Capture','added')
        $null = Complete-Driver $oldDriver
        $null = Complete-Driver $newDriver
        $parallel = @{}
        foreach ($instance in @('alpha','gamma')) {
            $parallel[$instance] = Get-Content -LiteralPath (Join-Path $state "instances\$instance\run\result.json") -Raw | ConvertFrom-Json -AsHashtable
            Assert ($parallel[$instance].processExecuted -eq 0) 'Concurrent captures lost previously cached process outputs.'
        }
        Assert ((Program-Output 'alpha') -ceq $oracle) 'Concurrent original capture changed its output.'
        Assert ((Program-Output 'gamma') -ceq $expected) 'Concurrent dependency capture changed its output.'
        Record 'concurrent-distinct-captures' $parallel
    } finally {
        foreach ($relative in $savedFiles.Keys) { [IO.File]::WriteAllBytes((Join-Path $tree $relative), $savedFiles[$relative]) }
        Remove-Item -LiteralPath (Join-Path $tree 'added-support') -Recurse -Force
    }
    $restored = Replay 'restore-main-after-added' 'gamma'
    Assert ($restored.processExecuted -eq 0) 'New capture invalidated the original graph cache.'
    Assert ((Program-Output 'gamma') -ceq $oracle) 'Original capture no longer produces its Cargo output.'
    foreach ($path in $plans.Keys) {
        Assert ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $plans[$path].hash) 'A new capture overwrote an existing plan.'
        Assert ((Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks -eq $plans[$path].time) 'A new capture rewrote an existing plan.'
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $state 'plans') -Filter '*.json' -File) {
        Assert ($file.BaseName -ceq (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) 'Plan address does not match its file content.'
    }
    Record 'original-capture-and-plans-preserved' @{restored=$restored; plans=$plans.Count}
}
