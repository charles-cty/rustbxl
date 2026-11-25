#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildXLRoot = $env:BUILDXL_ROOT,
    [string]$BindMount = $env:BINDMOUNT_EXE,
    [string]$RunRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test\integration')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'GraphArguments.ps1')
. (Join-Path $PSScriptRoot 'ContractFiles.ps1')
. (Join-Path $PSScriptRoot 'Environment.ps1')
. (Join-Path $PSScriptRoot 'CrossCapture.ps1')
$RunRoot = Assert-LocalPath $RunRoot
if (Test-Path -LiteralPath $RunRoot) { throw "Use an empty test directory: $RunRoot" }
New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
$state = Join-Path $RunRoot 'sidecar state'
$repository = Join-Path $RunRoot 'repository'
$names = @('alpha', 'beta', 'gamma', 'delta', 'alpha-near', 'beta-near')
$trees = @{}
$records = [Collections.Generic.List[object]]::new()
$startedDrivers = [Collections.Generic.List[object]]::new()
$service = $null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Start-Driver([string]$Label, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $root
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-File', (Join-Path $root 'rustbxl.ps1')) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $driver = @{ Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync(); Label = $Label; Completed = $false }
    $startedDrivers.Add($driver)
    $driver
}

function Complete-Driver($Driver, [int]$ExpectedExit = 0) {
    if (-not $Driver.Process.WaitForExit(180000)) { throw "Timeout: $($Driver.Label). The client is retained for diagnosis." }
    $output = $Driver.Output.GetAwaiter().GetResult() + $Driver.Error.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $RunRoot ($Driver.Label + '.log')), $output)
    $exitCode = $Driver.Process.ExitCode
    $Driver.Process.Dispose()
    $Driver.Completed = $true
    Assert ($exitCode -eq $ExpectedExit) "Unexpected exit $exitCode for $($Driver.Label). See its .log."
    $output
}

function Invoke-Cli([string]$Label, [string[]]$Arguments, [int]$ExpectedExit = 0) {
    Complete-Driver (Start-Driver $Label ($Arguments + @('-State', $state))) $ExpectedExit
}

function Replay([string]$Label, [string]$Name) {
    $null = Invoke-Cli $Label @('build', '-Project', $trees[$Name], '-Instance', $Name)
    $result = Get-Content -LiteralPath (Join-Path $state "instances\$Name\run\result.json") -Raw | ConvertFrom-Json -AsHashtable
    $result
}

function Program-Output([string]$Name) {
    $exe = Join-Path $state "instances\$Name\target\x86_64-pc-windows-msvc\debug\rustbxl-fixture.exe"
    @(& $exe) -join [char]10
}

function Cargo-Oracle([string]$Label, [string]$Name) {
    $layout = Get-Layout $state $Name 'main' $config
    $oracle = Join-Path $RunRoot "oracle\$Label"
    $layout.PhysicalTarget = $oracle
    $environment = Get-BuildEnvironment $config $state $layout
    $environment.RUSTC_WRAPPER = Get-Helper
    Invoke-WithEnvironment $environment {
        $parameters = @(Get-CargoArguments $config)
        $cargo = (Get-Command cargo.exe).Source
        # Invoke Cargo with a Windows-local mapped working directory.
        $request = Join-Path $RunRoot "$Label-cargo-request.json"
        Write-Json @{workingDirectory=$layout.Source; executable=$cargo; arguments=$parameters} $request
        $arguments = @('-WorkingDirectory', $layout.Source, '-File', (Join-Path $PSScriptRoot 'CargoOracle.ps1'), '-Request', $request)
        $log = @(Invoke-MappedProcess (Get-Command pwsh.exe).Source $arguments $trees[$Name] $layout $config "oracle-$Name" 2>&1)
        [IO.File]::WriteAllText((Join-Path $RunRoot "$Label-cargo.log"), ($log -join [char]10))
    }
    $output = @(& (Join-Path $oracle 'x86_64-pc-windows-msvc\debug\rustbxl-fixture.exe')) -join [char]10
    Remove-Item -LiteralPath $oracle -Recurse -Force
    $output
}

function Start-TestCache([string]$Label) {
    $driver = Start-Driver $Label @('cache-start', '-State', $state)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($driver.Process.HasExited) { $null = Complete-Driver $driver; throw 'Cache service exited.' }
        $client = [Net.Sockets.TcpClient]::new()
        try { $client.Connect('127.0.0.1', $port); return $driver }
        catch [Net.Sockets.SocketException] {
            if ($timer.Elapsed.TotalSeconds -gt 30) { throw 'Cache startup timeout.' }
            Start-Sleep -Milliseconds 100
        } finally { $client.Dispose() }
    }
}

function Record([string]$Name, $Details) {
    $records.Add(@{ case = $Name; details = $Details; passed = $true })
    Write-Json @($records.ToArray()) (Join-Path $RunRoot 'results.json')
    "PASS $Name"
}

try {
    Record 'scoped-process-environment' (Test-ScopedEnvironment)
    $contractFiles = Test-ContractFiles $RunRoot
    Record 'contract-file-boundaries' $contractFiles
    & (Join-Path $root 'scripts\build.ps1') | Out-Host
    & (Get-Helper) check-arguments | Out-Host
    Initialize-Msvc
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'fixture\*') -Destination $repository -Recurse -Force
    # Explicit copy includes dotfiles on hosts with different wildcard settings.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\.gitignore') -Destination $repository
    git.exe -C $repository init --initial-branch=main | Out-Host
    git.exe -C $repository config core.autocrlf false
    git.exe -C $repository add --all
    git.exe -C $repository -c user.name=RustBxl -c user.email=rustbxl@example.invalid commit -m 'test: add integration workspace' | Out-Host
    foreach ($name in $names) {
        $tree = Join-Path $RunRoot "worktrees\$name"
        git.exe -C $repository worktree add --detach $tree HEAD | Out-Host
        $trees[$name] = $tree
        New-Item -ItemType Directory -Path (Join-Path $tree 'target') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tree 'target\sentinel.txt'), 'existing-cargo-output')
    }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $null = Invoke-Cli 'init' @('init', '-Project', $trees.alpha, '-BuildXLRoot', $BuildXLRoot, '-BindMount', $BindMount,
        '-Port', "$port", '-CacheScenario', "RustBxlTest$PID")
    $configPath = Join-Path $state 'rustbxl.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    # Leave room for CMake compiler-check paths under each build-script OUT_DIR.
    # The target namespace must still exceed instances\alpha-near\target.
    $config.namespace.source = 'namespace\source'
    $config.namespace.target = 'namespace\build-output-for-shared-cache'
    $external = Join-Path $RunRoot 'external input.txt'
    [IO.File]::WriteAllText($external, 'external-original')
    $config.build.environment.FIXTURE_EXTERNAL_INPUT = $external
    $config.build.environment.FIXTURE_TOKEN = 'token with spaces 中文'
    Write-Json $config $configPath
    $null = Invoke-Cli 'prepare' @('prepare')
    $dependencySnapshot = @(Get-ChildItem (Join-Path $state 'cargo-home\registry\src') -Recurse -File | ForEach-Object {
        $_.FullName + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks
    }) -join [char]10
    $null = Invoke-Cli 'capture' @('capture', '-Instance', 'alpha')
    $contractPath = Join-Path $state 'captures\main\contract.json'
    $contractBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath))
    $tracePath = Join-Path $state 'captures\main\capture\processes.jsonl'
    $traceTime = (Get-Item -LiteralPath $tracePath).LastWriteTimeUtc
    $graph = @(Get-Content -LiteralPath (Join-Path $state 'captures\main\generated-graph.json') -Raw | ConvertFrom-Json)
    Assert ($graph.Count -ge 8) 'Expected separate compiler, linker, build-script, and directive pips.'
    Assert (@($graph | Where-Object { [IO.Path]::GetFileName($_.Executable) -eq 'cargo.exe' }).Count -eq 0) 'Cargo appeared as an execution pip.'
    Assert (@($graph | Where-Object Name -Like 'probe-*').Count -eq 0) 'Compiler probes escaped their build-script pip.'
    $scriptGroups = @($graph | Where-Object Name -Like 'run-*' | Group-Object Executable | Where-Object Count -GT 1)
    Assert ($scriptGroups.Count -gt 0) 'Fixture did not exercise a shared host/target build-script executable.'
    Assert (@($graph.Name | Sort-Object -Unique).Count -eq $graph.Count) 'Host/target graph identities collided.'
    Record 'build-script-execution-identities' $scriptGroups.Count

    # Capture ran in a child PowerShell. The same graph must validate when the
    # caller invokes the CLI directly from its initialized developer shell.
    $status = @(& (Join-Path $root 'rustbxl.ps1') status -State $state -Project $trees.alpha -Instance alpha)
    $status = ($status -join [char]10) | ConvertFrom-Json -AsHashtable
    Assert $status.captureValid "Capture changed across shell nesting: $($status.reason)"
    Record 'shell-session-contract' $true

    $service = Start-TestCache 'cache-service'
    $argumentCases = Test-GraphArguments $trees.alpha $state $config
    Record 'structured-graph-arguments' $argumentCases
    $cold = Replay 'cold-alpha' 'alpha'
    $oracle = Cargo-Oracle 'baseline' 'alpha'
    Assert ($oracle.Contains('cargo-config=true')) 'Cargo configuration rustflags were lost.'
    Assert ($oracle.Contains('links=initial-value:left=right with spaces:true')) 'Cargo metadata oracle did not cover both directive forms.'
    Assert ((Program-Output 'alpha') -ceq $oracle) 'Cold replay differs from Cargo.'
    $shared = Replay 'shared-beta' 'beta'
    Assert ($shared.processCacheHits -eq $graph.Count -and $shared.processExecuted -eq 0) 'Equal worktree did not share every process pip.'
    Assert ((Program-Output 'beta') -ceq $oracle) 'Shared replay differs from Cargo.'
    Record 'cold-and-shared-cache' @{ cold=$cold; shared=$shared; processPips=$graph.Count }

    $warm = Replay 'warm-beta' 'beta'
    Assert ($warm.processExecuted -eq 0) 'Unchanged replay executed a process.'
    $statsFile = Join-Path $state 'instances\beta\run\logs\BuildXL.stats'
    $skipped = Select-String -LiteralPath $statsFile -Pattern '^BuildSetCalculatorProcessStats_ProcessesSkippedByIncrementalScheduling=(\d+)$'
    Assert ($null -ne $skipped -and [int]$skipped.Matches[0].Groups[1].Value -gt 0) 'Warm replay did not skip unchanged processes through incremental scheduling.'
    Record 'incremental-no-change' $warm

    $binary = Join-Path $state 'instances\beta\target\x86_64-pc-windows-msvc\debug\rustbxl-fixture.exe'
    Remove-Item -LiteralPath $binary
    $materialized = Replay 'missing-output-beta' 'beta'
    Assert ($materialized.processExecuted -eq 0) 'Missing cached executable caused recompilation.'
    Assert ((Program-Output 'beta') -ceq $oracle) 'Missing executable was not restored from cache.'
    Record 'incremental-missing-output' $materialized

    Test-CrossCapture

    foreach ($relative in @('.hidden\Cargo.toml', 'rust-toolchain.toml', '.cargo\config.toml')) {
        $path = Join-Path $trees.beta $relative
        $saved = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        try {
            # These are configuration data. Rejection must occur before invoking Cargo or BuildXL.
            [IO.File]::WriteAllText($path, '# changed capture input')
            $label = 'reject-cargo-input-' + [IO.Path]::GetFileName($path)
            $errorText = Invoke-Cli $label @('build','-Project',$trees.beta,'-Instance','beta') 1
            Assert ($errorText.Contains('Capture input changed: files')) "Cargo input change was accepted: $relative"
        } finally {
            if ($null -eq $saved) { Remove-Item -LiteralPath $path }
            else { [IO.File]::WriteAllBytes($path, $saved) }
        }
    }
    Remove-Item -LiteralPath (Join-Path $trees.beta '.hidden')
    $afterContractRestore = Replay 'restored-cargo-inputs' 'beta'
    Assert ($afterContractRestore.processExecuted -eq 0) 'Restored Cargo inputs caused recompilation.'
    Record 'cargo-input-invalidation' $afterContractRestore

    foreach ($case in @('ordinary-source', 'new-module', 'optional-file', 'directory-member', 'external-text', 'same-directives', 'build-script', 'links-metadata', 'compiler-probe', 'source-text')) {
        $edit = $null
        $saved = $null
        $created = $null
        try {
            switch ($case) {
                'ordinary-source' {
                    $edit = Join-Path $trees.beta 'engine\src\lib.rs'
                    $saved = [IO.File]::ReadAllBytes($edit)
                    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'variants\edited-engine.rs') -Destination $edit
                }
                'new-module' {
                    $edit = Join-Path $trees.beta 'engine\src\lib.rs'
                    $saved = [IO.File]::ReadAllBytes($edit)
                    $created = Join-Path $trees.beta 'engine\src\additional.rs'
                    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'variants\additional.rs') -Destination $created
                    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'variants\module-engine.rs') -Destination $edit
                }
                'optional-file' { $created=Join-Path $trees.beta 'app\optional.txt'; [IO.File]::WriteAllText($created,'enabled') }
                'directory-member' { $created=Join-Path $trees.beta 'app\entries\new.txt'; [IO.File]::WriteAllText($created,'enabled') }
                'external-text' { [IO.File]::WriteAllText($external,'external-changed') }
                'same-directives' { [IO.File]::WriteAllText($external,'external-original   ') }
                'build-script' {
                    $edit = Join-Path $trees.beta 'app\build.rs'
                    $saved = [IO.File]::ReadAllBytes($edit)
                    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'variants\edited-build.rs') -Destination $edit
                }
                'source-text' { $edit=Join-Path $trees.beta 'app\label.txt'; $saved=[IO.File]::ReadAllBytes($edit); [IO.File]::WriteAllText($edit,'label-changed') }
                'links-metadata' { $edit=Join-Path $trees.beta 'probe-support\metadata.txt'; $saved=[IO.File]::ReadAllBytes($edit); [IO.File]::WriteAllText($edit,'changed=metadata with spaces') }
                'compiler-probe' { $edit=Join-Path $trees.beta 'probe-support\probe-mode.txt'; $saved=[IO.File]::ReadAllBytes($edit); [IO.File]::WriteAllText($edit,'failure') }
            }
            $expected = Cargo-Oracle $case 'beta'
            if ($case -eq 'links-metadata') {
                Assert ($expected.Contains('links=changed=metadata with spaces:')) 'Metadata oracle did not use the changed value.'
                Assert ($expected.Contains('added-metadata=new metadata key')) 'Metadata oracle did not add the new key.'
            }
            if ($case -eq 'compiler-probe') {
                Assert ($expected.Contains('links=initial-value:left=right with spaces:false')) 'Compiler oracle did not observe the failed capability probe.'
            }
            $result = Replay $case 'beta'
            Assert ((Program-Output 'beta') -ceq $expected) "Replay differs from Cargo: $case"
            Assert ($result.processExecuted -gt 0 -and $result.processExecuted -lt $graph.Count) "Expected partial rebuild: $case"
            Assert ($contractBytes -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath))) 'Unexpected recapture.'
            Assert ($traceTime -eq (Get-Item -LiteralPath $tracePath).LastWriteTimeUtc) 'Unexpected discovery run.'
            if ($case -eq 'source-text') {
                $historicalOutput = $expected
                $historicalHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
                $historicalLength = (Get-Item -LiteralPath $binary).Length
            }
            Record $case $result
        } finally {
            if ($edit) { [IO.File]::WriteAllBytes($edit, $saved) }
            if ($created) { Remove-Item -LiteralPath $created }
            [IO.File]::WriteAllText($external,'external-original')
        }
        $restored = Replay "restore-$case" 'beta'
        Assert ((Program-Output 'beta') -ceq $oracle) "Restore differs from Cargo: $case"
        Assert ($restored.processExecuted -eq 0) "Restore did not use cached pips: $case"
    }

    # Compress a historical executable that now exists only in the real CAS,
    # then require BuildXL to restore those exact bytes without recompilation.
    $errorText = Invoke-Cli 'reject-compression-active-cache' @('compress') 1
    Assert ($errorText.Contains('maintenance.lock')) 'Compression did not reject the running cache service.'
    Record 'compression-rejects-running-cache' $true
    $null = Invoke-Cli 'cache-stop-before-compression' @('cache-stop')
    $null = Complete-Driver $service
    $sharedRoot = Join-Path $state "cache\$($config.cache.scenario)\Shared"
    $historicalBlobs = @(Get-ChildItem -LiteralPath $sharedRoot -Filter '*.blob' -Recurse -File | Where-Object {
        $_.Length -eq $historicalLength -and (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ceq $historicalHash
    })
    Assert ($historicalBlobs.Count -eq 1) 'Historical executable is missing from the shared CAS.'
    $historicalBlob = $historicalBlobs[0].FullName
    $historicalAcl = (Get-Acl -LiteralPath $historicalBlob).Sddl
    $compressionArguments = @('compress','-MinimumAgeDays','0','-MinimumSizeKiB','1')
    $preview = Invoke-Cli 'compression-preview' $compressionArguments | ConvertFrom-Json -AsHashtable
    Assert ($historicalBlob -in @($preview.Files.Path)) 'Historical CAS output was not a compression candidate.'
    $compressed = Invoke-Cli 'compression-apply' ($compressionArguments + '-Apply') | ConvertFrom-Json -AsHashtable
    Assert ($historicalBlob -in @($compressed.Files.Path)) 'Historical CAS output was not compressed.'
    Assert ($compressed.CompressedFiles -gt 0 -and $compressed.SavedBytes -gt 0) 'Real CAS compression saved no space.'
    Assert (([IO.File]::GetAttributes($historicalBlob) -band [IO.FileAttributes]::Compressed) -ne 0) 'CAS compression attribute is absent.'
    Assert ((Get-Acl -LiteralPath $historicalBlob).Sddl -ceq $historicalAcl) 'CAS compression changed the original ACL.'
    Assert ((Get-FileHash -LiteralPath $historicalBlob -Algorithm SHA256).Hash -ceq $historicalHash) 'CAS compression changed the original content.'
    Assert (([IO.File]::GetAttributes($binary) -band [IO.FileAttributes]::Compressed) -eq 0) 'Active output was compressed.'
    $service = Start-TestCache 'cache-service-after-compression'
    $labelPath = Join-Path $trees.beta 'app\label.txt'
    $savedLabel = [IO.File]::ReadAllBytes($labelPath)
    try {
        [IO.File]::WriteAllText($labelPath,'label-changed')
        Remove-Item -LiteralPath $binary
        $restoredCompressed = Replay 'restore-compressed-cas' 'beta'
        Assert ($restoredCompressed.processExecuted -eq 0 -and $restoredCompressed.processCacheHits -gt 0) 'Compressed CAS output caused recompilation.'
        Assert ((Program-Output 'beta') -ceq $historicalOutput) 'Compressed CAS replay differs from clean Cargo.'
        Assert ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ceq $historicalHash) 'Restored executable differs from compressed CAS content.'
    } finally { [IO.File]::WriteAllBytes($labelPath,$savedLabel) }
    $null = Replay 'restore-after-compression' 'beta'
    Assert ((Program-Output 'beta') -ceq $oracle) 'Baseline replay changed after cache compression.'
    Record 'compressed-cache-restoration' @{ compression=$compressed; replay=$restoredCompressed }

    # Six separate worktrees share one compatible graph, with four development variants and two near forks.
    $expectedOutputs = @{}
    foreach ($name in $names) {
        $label = switch ($name) { 'alpha' {'planner'} 'beta' {'importer'} 'gamma' {'audit'} 'delta' {'validation'} 'alpha-near' {'planner-near'} 'beta-near' {'importer-near'} }
        $path = Join-Path $trees[$name] 'engine\src\lib.rs'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "variants\$label.rs") -Destination $path
        $expectedOutputs[$name] = Cargo-Oracle "parallel-$name" $name
    }
    $drivers = @{}
    foreach ($name in $names) { $drivers[$name] = Start-Driver "parallel-$name" @('build','-State',$state,'-Project',$trees[$name],'-Instance',$name) }
    foreach ($name in $names) {
        $null = Complete-Driver $drivers[$name]
        Assert ((Program-Output $name) -ceq $expectedOutputs[$name]) "Concurrent isolation failed: $name"
    }
    Record 'six-concurrent-worktrees' $names

    # Exercise Git and CMake as descendants of the build-script pip. A commit
    # changes Git state without changing source; a C edit changes native inputs.
    $config.build.environment.FIXTURE_GIT_QUERY = '1'
    $config.build.environment.FIXTURE_NATIVE_TOOLS = '1'
    foreach ($tool in @('cmake.exe','ninja.exe')) { Get-Command $tool -ErrorAction Stop | Out-Null }
    Write-Json $config $configPath
    $null = Invoke-Cli 'capture-native' @('capture','-Instance','alpha','-Capture','native')
    $nativeContract = Join-Path $state 'captures\native\contract.json'
    $nativeContractBytes = [IO.File]::ReadAllBytes($nativeContract)
    $null = Invoke-Cli 'build-native' @('build','-Instance','alpha','-Capture','native')
    $nativeOracle = Cargo-Oracle 'native-baseline' 'alpha'
    Assert ((Program-Output 'alpha') -ceq $nativeOracle -and $nativeOracle.Contains('native=42')) 'Native build-script subtree differs from Cargo.'
    $baselineCommit = @(git.exe -C $trees.alpha rev-parse HEAD)[0]
    Assert ($nativeOracle.Contains("git=$baselineCommit")) 'Git build input was lost.'
    $nativeSource = Join-Path $trees.alpha 'probe-support\native\probe.c'
    $nativeSaved = [IO.File]::ReadAllBytes($nativeSource)
    try {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'variants\native-probe.c') -Destination $nativeSource
        $null = Invoke-Cli 'native-source-edit' @('build','-Instance','alpha','-Capture','native')
        $nativeResult = Get-Content -LiteralPath (Join-Path $state 'instances\alpha\run\result.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($nativeResult.processExecuted -gt 0) 'Native source change did not rerun its build script.'
        Assert ((Program-Output 'alpha') -ceq (Cargo-Oracle 'native-edit' 'alpha')) 'Native source edit differs from Cargo.'
        Assert ((Program-Output 'alpha').Contains('native=43')) 'Native edit did not change the linked program result.'
        $libraries = @(Get-ChildItem -LiteralPath (Join-Path $state 'instances\alpha\target') -Filter native_probe.lib -Recurse -File)
        Assert ($libraries.Count -eq 2) 'Host and target native outputs did not remain distinct.'
    } finally { [IO.File]::WriteAllBytes($nativeSource,$nativeSaved) }
    $null = Invoke-Cli 'restore-native-source' @('build','-Instance','alpha','-Capture','native')
    $nativeRestored = Get-Content -LiteralPath (Join-Path $state 'instances\alpha\run\result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($nativeRestored.processExecuted -eq 0) 'Restored native source did not reuse cached outputs.'
    Record 'native-build-script-subtree' @{edit=$nativeResult;restored=$nativeRestored}
    try {
        git.exe -C $trees.alpha -c user.name=RustBxl -c user.email=rustbxl@example.invalid commit --allow-empty -m 'test: change build-script Git input' | Out-Host
        $newCommit = @(git.exe -C $trees.alpha rev-parse HEAD)[0]
        $null = Invoke-Cli 'git-head-change' @('build','-Instance','alpha','-Capture','native')
        $gitResult = Get-Content -LiteralPath (Join-Path $state 'instances\alpha\run\result.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($gitResult.processExecuted -gt 0) 'Git commit change did not invalidate the build script.'
        Assert ((Program-Output 'alpha').Contains("git=$newCommit")) 'Git metadata remained captured at its original value.'
        Assert ((Program-Output 'alpha') -ceq (Cargo-Oracle 'git-change' 'alpha')) 'Git commit change differs from Cargo.'
    } finally { git.exe -C $trees.alpha checkout --detach $baselineCommit | Out-Host }
    $null = Invoke-Cli 'git-head-restore' @('build','-Instance','alpha','-Capture','native')
    $gitRestored = Get-Content -LiteralPath (Join-Path $state 'instances\alpha\run\result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ((Program-Output 'alpha') -ceq $nativeOracle) 'Git restoration did not restore baseline output.'
    Assert ($gitRestored.processExecuted -eq 0) 'Git restoration did not reuse cached outputs.'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($nativeContract)) -ceq [Convert]::ToBase64String($nativeContractBytes)) 'Git/native inputs caused recapture.'
    Record 'git-state-invalidation' @{edit=$gitResult;restored=$gitRestored}
    $config.build.environment.Remove('FIXTURE_GIT_QUERY')
    $config.build.environment.Remove('FIXTURE_NATIVE_TOOLS')

    # A feature change must reject the old graph, then work after a new capture.
    $config.build.features = @('rustbxl-fixture/extra')
    Write-Json $config $configPath
    $errorText = Invoke-Cli 'reject-feature-change' @('build','-Instance','alpha') 1
    Assert ($errorText.Contains('Capture input changed: build')) 'Feature change did not invalidate the contract.'
    $null = Invoke-Cli 'capture-extra' @('capture','-Instance','alpha','-Capture','extra')
    $null = Invoke-Cli 'build-extra' @('build','-Instance','alpha','-Capture','extra')
    $expected = Cargo-Oracle 'extra' 'alpha'
    Assert ((Program-Output 'alpha') -ceq $expected) 'Feature configuration differs from Cargo.'
    Assert ($expected.Contains('features=false:true')) 'Feature selection was not effective.'
    Record 'feature-recapture' $config.build.features

    foreach ($name in $names) {
        Assert ([IO.File]::ReadAllText((Join-Path $trees[$name] 'target\sentinel.txt')) -ceq 'existing-cargo-output') 'Existing Cargo target changed.'
        Assert (@(Get-ChildItem (Join-Path $trees[$name] 'target')).Count -eq 1) 'rustbxl wrote into the project target.'
        git.exe -C $trees[$name] restore -- engine/src/lib.rs
        Assert (-not (git.exe -C $trees[$name] status --porcelain)) "Project files changed: $name"
    }
    $after = @(Get-ChildItem (Join-Path $state 'cargo-home\registry\src') -Recurse -File | ForEach-Object {
        $_.FullName + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks
    }) -join [char]10
    Assert ($after -ceq $dependencySnapshot) 'Dependency sources changed during compilation.'
    Record 'non-invasive-and-read-only-dependencies' $true
} finally {
    foreach ($driver in $startedDrivers.ToArray()) {
        if ($driver -ne $service -and -not $driver.Completed -and -not $driver.Process.HasExited) {
            Write-Host "Waiting for active sandbox client: $($driver.Label)"
            $driver.Process.WaitForExit()
        }
    }
    try {
        if ($service -and -not $service.Completed) {
            if (-not $service.Process.HasExited) { $null = Invoke-Cli 'cache-stop' @('cache-stop') }
            $null = Complete-Driver $service
        }
    } finally {
        foreach ($driver in $startedDrivers.ToArray()) {
            if (-not $driver.Completed) { $driver.Process.Dispose() }
        }
    }
}
"INTEGRATION_PASS $($records.Count) cases. Evidence: $RunRoot"
