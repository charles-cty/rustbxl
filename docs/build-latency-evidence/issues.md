# Latency investigation issues

The implementation stayed in `F:\Temp\rustbxl-large-20261116\driver-perf`.
The maintained CLI and generator were not changed. Windows programs ran through
PowerShell 7 with Windows-local paths and working directories. No network or
dependency installation was needed during this investigation.

## Measurement and implementation issues

- The first `Summarize-GraphCost.ps1` invocation indexed `$_.arguments[-1]` on a
  query with no arguments. PowerShell raised an index error. Checking Count before
  indexing fixed the script; its subsequent graph counts passed.
- `Run-PerfCase.ps1 -Name biome -Label baseline-edit-2 -Marker PERF-BASE-2`
  overlapped `Compare-CargoScans.ps1`. That timing is retained but excluded from
  performance comparisons. Subsequent timed builds ran without independent
  CPU/disk-intensive probes.
- Four-worktree timing instrumentation initially had one shared `perf-last.json`
  destination. Before the concurrent runs, the driver was changed to use distinct
  per-instance files for B/C/D. The normal CLI's result/log paths were already
  per instance. `PerfScan` was initialized to null to preserve early failure details.
- `Summarize-Perf.ps1` initially reused `$Matches` after a second `-match`, which
  replaced the numeric captures and yielded zero engine counters. Independent
  comparison with raw `.stats` files found this error. The script now captures
  the numeric value before filtering its key. The archived summary was regenerated
  and agrees with raw files: baseline-edit-3 first execution is 7,676 ms and
  scheduling-edit-3 is 2,794 ms.
- The BuildXL `PipExecutionPerformance` analyzer's formatted start/stop strings
  have whole-second precision. Its per-child process-tree records also reported
  zero I/O and implausibly small lifetimes, despite nonzero aggregate process
  performance. The report uses aggregate process/pip durations and scheduler
  step counters. It does not infer OS launch times from those child records.
- The analyzer source has a trailing-comma risk when `resultFilter` omits records:
  its comma counter is compared with the unfiltered record count. The command
  used `/m:PipExecutionPerformance /includeProcessTree` without resultFilter,
  then filtered the parsed output. No analyzer parse failure occurred.
- Changing graph declarations invalidated compiler fingerprints. The trimmed
  prime executed 437 pips in 170.82 seconds and is excluded from warm comparisons.
  First scheduler and paired Cargo runs are also excluded as primes.
- The 16,384 MiB CAS quota evicted 1,454 items (22,014,590,976 bytes of cumulative
  eviction). The first return to old SHARED-A outputs required a small rebuild;
  B/C/D linker logs report `MissForProcessMetadata`. A repeated original-graph A
  build then hit all 493 processes. No cache history was manually deleted.

## Read-only command and edit mistakes

These commands changed no project state. Reads were corrected to their scoped
paths before conclusions were drawn.

- `rg -n 'transitive|predecessor|publications|Dependencies|DirectoryDependencies' src/RustBxl/Capture/GraphGenerator.cs`
  used an assumed source path. The file is `src/RustBxl.Processes/GraphGenerator.cs`.
- `rg --files -g '*Startup*' -g '*Telemetry*' -g '*Scan*' -g '*Perf*' -g '*Cargo*' -g '*Trimmed*'`
  at the experiment root traversed dependency sources and produced excessive
  output. Later script discovery used `rg --files --max-depth 1 -g '*.ps1'`.
- `rg --files src lib tools | head -60` included an absent `tools` directory.
  The valid source paths were returned; later searches used those roots.
- `sed -n '1,160p' Run-WarmComparison.ps1` used an assumed filename. The script is
  `Compare-WarmEdits.ps1`; it was read before writing the new paired harness.
- `cat perf-investigation/graph-cost.json` used the wrong relative location.
  The file is `graph-cost.json` at the experiment root.
- `cat Four-Shared.ps1` ran once from the original checkout, where the temporary
  harness does not exist. It was subsequently read from the experiment root.
- `cat Prepare-PerfDriver.ps1` and `cat Prepare-ValidationDriver.ps1` ran from
  driver-perf instead of its parent. The required preparation script was then
  read through its full path.
- `rg 'Cache miss.*Process will be executed' shared-biome/instances/a/run/logs/BuildXL.log shared-biome/instances/b/run/logs/BuildXL.log | head -8`
  ran from the original checkout. The later correctly scoped read found B/C/D
  linker metadata misses. A's overwritten live log was not used as historical
  evidence; archived case logs were used.
- An `apply_patch` operation to remove an unused variable from
  `Copy-PerfEvidence.ps1` included context that did not exactly match the file.
  Patch validation rejected it before any write. A smaller patch succeeded.
- `git diff --no-index -- ../driver-validated/lib/Common.ps1 lib/Common.ps1`
  returned exit code 1 because the files differ. This is Git's expected diff
  status, not an execution failure.
- `jq -n '{savedPercent:(1-13.7414622/21.72775775)*100,combinedSavedPercent:(1-13.2888143/21.72775775)*100,pairedSlowerPercent:(13.488169/11.2065311-1)*100,removedPercent:(1-32128/218266)*100,phaseSum:(6.2601083+2.290+5.386+1.2245819+6.3785436+0.5587041)}'`
  needed parentheses around each complete arithmetic object value. The corrected
  independent calculation confirmed the reported percentages and phase sum.

## Lifecycle and instruction checks

No active sandbox tree was killed. All four clients were joined before cache
shutdown. The cache service exited with code 0. The final popup query found zero
new matching 0xc0000142 events and zero rustc/helper/BuildXL/cache processes.
The exact DLL-level cause of the earlier failures is still unproven.

No subagents were spawned. The prior instruction inconsistencies about UNC
examples and proxy port numbers are recorded in
[the earlier issues file](../large-worktree-evidence/issues.md). This work used
Windows-local execution and did not need a proxy.
