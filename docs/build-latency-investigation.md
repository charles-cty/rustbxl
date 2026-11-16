# Build latency investigation

Date: 2026-11-16. Baseline: `90941c7`. Windows experiment:
`F:\Temp\rustbxl-large-20261116`. This follows the
[four-worktree experiment](large-worktree-experiment.md).

The current adapter adds avoidable work before a small edit reaches rustc.
The largest measured causes are a slow Cargo-file scan and repeated cache
checking through an inflated dependency graph. Biome entry-point edit latency
fell from 21.73 seconds to 13.74 seconds with a faster scan and BuildXL incremental
scheduling. An alternating comparison measured 13.49 seconds for this configuration
and 11.21 seconds for Cargo incremental builds. A graph-trimming experiment reached
13.29 seconds when combined with those changes.

All measurements below ran in the temporary `driver-perf` checkout. The faster
contract scan and replay incremental scheduling have since been integrated into
the maintained CLI. The generator and dependency declarations remain unchanged;
graph trimming remains deferred. The evidence contains the experimental scripts
and instrumented driver files. Compression was not used.

## Measured changes

Each timed edit changed one executable entry point to emit a new marker.
Every sample executed exactly two process pips: the final compiler and linker.
The harness checked the executable marker after the timed process exited.
BuildXL used three compilation slots, a shared local cache service, and a fresh
engine process (`/server-`). Sandbox dependency checks remained enabled.

| Biome condition | Samples | Median, seconds |
| --- | ---: | ---: |
| Original scan, original graph, incremental scheduling disabled | 4 | 21.73 |
| Faster scan | 3 | 18.82 |
| Faster scan + incremental scheduling | 3 | 13.74 |
| Faster scan + trimmed graph, incremental scheduling disabled | 3 | 14.45 |
| Faster scan + trimmed graph + incremental scheduling | 3 | 13.29 |
| Alternating comparison: faster scan + incremental scheduling | 3 | 13.49 |
| Alternating comparison: native Cargo incremental | 3 | 11.21 |

The scan and scheduling changes reduced the grouped baseline median by 36.8%.
The combined trimmed condition reduced it by 38.8%. The paired BuildXL condition
remained 20.4% slower than Cargo. It used the original graph to isolate changes
that do not remove declared dependencies.

The first run of each scheduler/graph condition was excluded to establish its
state. The trimmed graph's prime took 170.82 seconds and executed 437 process pips;
changed input declarations change cache fingerprints. The first paired Cargo run
also needed warming and took 23.23 seconds. Later samples took 11.17–11.28 seconds.
`baseline-edit-2` overlapped a scan microbenchmark and is excluded. Baseline samples
1, 3, 4, and 5 ranged from 20.28 to 24.13 seconds. Grouped trials have ordering
effects; the separate paired trials alternate Cargo/BuildXL order. These small
samples do not establish confidence intervals.

## Where one original build spends its time

The representative `baseline-edit-3` took 22.098 seconds end to end. The table
uses nonoverlapping intervals. Nested contract stages are not added twice.

| Phase | Seconds | Evidence |
| --- | ---: | --- |
| CLI startup, MSVC initialization, contract checks, and bindmount entry preparation | 6.26 | Start of child CLI to `MappedBuildXL` |
| BuildXL startup to first scheduled pip | 2.29 | `TimeToFirstPipMs` |
| Scheduling/cache traversal until first `ExecuteProcess` step | 5.39 | `TimeToFirstPipExecutedMs` minus `TimeToFirstPipMs` |
| Final compiler and linker execution steps, including output processing | 7.60 | 1.225 + 6.379 seconds in XLG analyzer |
| Other engine, publication, and exit work | 0.56 | Remaining wall time |

`TimeToFirstPipExecutedMs` marks entry to BuildXL's `ExecuteProcess` step. It is
not an operating-system process creation timestamp. The packaged XLG analyzer's
formatted start/stop fields have whole-second precision; duration fields retain
fractional milliseconds. The table therefore uses scheduler step boundaries for
waiting time and reports the residual explicitly.

Within the 6.26-second CLI interval, MSVC initialization took 1.647 seconds and
contract validation took 3.721 seconds. The contract's Cargo-file scan alone took
3.486 seconds. Shell startup and remaining script work account for the balance.

Within the 7.60-second execution interval, the actual rustc process tree took
0.949 seconds and link.exe took 5.124 seconds. Output-cache insertion took 95 and
943 milliseconds respectively. The remaining time covers sandbox setup, output
validation, and other execution-step work. These subintervals are included in the
7.60 seconds, not added to it.

The link pip reported about 618 MiB of writes, with a 4,340 MiB peak working set.
It produced a dev executable and PDB. Capturing these outputs has a measured cost
even when their eventual worktree names use hardlinks. The MSVC response includes
`/DEBUG` and `/OPT:REF,NOICF`. This investigation did not change debug information
or linker settings.

## Cargo contract scanning

`lib/Contract.ps1:Get-CargoFiles` walks every source subdirectory through the
PowerShell filesystem provider. It does so on every replay, including builds
where manifests have not changed. Biome has many test directories.

The experimental function uses .NET `DirectoryInfo.EnumerateFileSystemInfos()`.
It keeps the same traversal exclusions, reads the same Cargo/toolchain files,
and checks the same ancestor and Cargo-home configuration files. It still detects
new manifests by traversal. It does not bypass the capture contract.

| Project | Directories | Items | Cargo/toolchain files | Original median, ms | .NET median, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| rust-analyzer | 246 | 2,499 | 50 | 358.43 | 28.49 |
| Biome | 2,021 | 18,823 | 99 | 2,595.42 | 143.76 |
| Typst | 99 | 2,240 | 21 | 118.70 | 12.85 |

All nine comparisons produced identical serialized contract dictionaries.
In separate fresh CLI builds the faster Biome scan took about 0.22–0.24 seconds;
the original scan took about 3.12–3.49 seconds. The isolated scan benchmark and
fresh CLI include different JIT/runspace startup conditions, so their absolute
times should not be interchanged.

## Dependency graph inflation

The generated graphs contain far more dependency declarations and copy nodes
than process nodes. The counts below refer to explicit JSON inputs, before the
frontend adds BuildXL directory seals and other internal nodes.

| Project | Process pips | Copy pips | Explicit inputs to processes | Publication-file inputs | Directory inputs |
| --- | ---: | ---: | ---: | ---: | ---: |
| rust-analyzer | 365 | 7,950 | 116,596 | 64,708 | 41,978 |
| Biome | 493 | 13,626 | 224,369 | 123,032 | 83,547 |
| Typst | 478 | 9,261 | 197,128 | 114,506 | 70,602 |

There are two confirmed sources of inflation in `GraphGenerator`:

1. The access mask `(1 | 4 | 8 | 16)` merges content reads, probes, directory
   enumeration, and enumeration probes into `Node.Reads`. If a listed file has
   a producer, that producer becomes a process dependency.
2. The generator recursively expands all predecessors, declares their output
   directories, and also adds their publication files. Dependency views already
   declare the required Rust libraries, so many of these inputs duplicate that
   information and carry unrelated dependencies into every downstream process.

The captured `unicode_width-69cf98482d5e2dbf` compiler has no `--extern` arguments
and needs no Rust dependency view. It nevertheless has 288 explicit inputs and
129 transitive process dependencies, including Biome libraries. The original
trace contains 129 accesses to other producers' outputs for that compiler; all
are `FindNextFile`, requested access 16, error 0. BuildXL defines 16 as
`EnumerationProbe`, a metadata probe caused by directory enumeration. These
records establish which names existed, not content reads of all those libraries.

The final Biome compiler has 1,771 explicit inputs. The original replay's reported
critical path reaches index 315, with hundreds of cached processes ahead of the
two executed processes. A high cache-hit ratio still pays for this traversal.
Graph reuse itself was already working: the representative graph reload took
415 milliseconds. Warm builds were not regenerating the whole graph.

The trimming experiment removes compiler/linker publication-file inputs and
private compiler/linker directory inputs. The linker retains its own compiler's
staged inputs. Dependency-view files, response files, build-script output and
configuration inputs, and other inputs remain declared. It changes compiler/linker
explicit inputs from 218,266 to 32,128, an 85.3% reduction. The complete graph's
explicit process inputs fall from 224,369 to 38,231. All 13,626 copy pips remain.

After a full prime, the trimmed graph passed three new edits at a 14.45-second
median. Its critical path reached index 85. First execution started at 4.535
seconds instead of 7.676 seconds in the representative original sample. This
supports the redundant-dependency diagnosis. Link execution also varied between
samples, so the entire end-to-end improvement cannot be assigned to edge removal.

The experiment does not establish that all removed declarations are unnecessary
for arbitrary build-script or dependency changes. A maintained fix must model
enumeration membership and actual generated inputs explicitly, then rerun dynamic
input and dependency-edit integration cases. Dropping every probe or enumeration
record would lose valid invalidation information.

## Incremental scheduling and fixed startup cost

The CLI explicitly passes `/incrementalScheduling-`. It therefore checks all
493 processes again for this entry-point edit, despite 491 cached results.
With incremental scheduling enabled and primed, BuildXL skips those 491 unchanged
processes. Its journal scan detects one changed dynamic input and marks seven
internal graph pips transitively dirty. First execution starts at 2.794 seconds
instead of 7.676 seconds in the selected original sample.

The fast scan plus scheduler condition has a 13.74-second median. Adding the
trimmed graph gives 13.29 seconds, rather than the sum of both independent gains.
Both changes remove much of the same repeated graph work.

Every call still starts PowerShell, initializes MSVC, and starts BuildXL with
`/server-`. The MSVC stage takes about 1.6 seconds and the engine takes about
2.2 seconds to reach its first scheduled pip. Native Cargo's comparison also
includes PowerShell/MSVC setup. A persistent development session can remove
some setup cost, but engine reuse needs to preserve each instance's bindmount
namespace and lifecycle. Server mode was not tested here.

One `/logProcesses-` trial took 22.12 seconds, within baseline variation.
It gives no evidence that process logging explains the large gap. Lazy output
materialization was not tested. Shared-cache pips still use
`CARGO_INCREMENTAL=0`; this investigation does not restore rustc query incremental
state. The measured compiler step is small for these executable entry-point edits.
Large library edits can have a different balance and remain unmeasured.

## Four-worktree check, cache history, and final state

The trimmed graph with fast scans and incremental scheduling built four divergent
Biome worktrees concurrently. All four intervals overlap. Each executed two
process pips, emitted its own `PERF-FOUR-A` through `PERF-FOUR-D` marker, and
formatted JavaScript with `return 42;`. Completion times ranged from 23.46 to
32.14 seconds. These runs include graph/scheduler priming in B/C/D and shared
machine contention; they are correctness checks, not a concurrency speed comparison.

All four sources and outputs were then returned to `SHARED-A` with the original
graph and original scheduler/scan flags. The first return executed two processes
in A and one in each B/C/D. The latter logs say `MissForProcessMetadata` for the
linker. The cache service's shutdown statistics report 1,454 evicted items and
22,014,590,976 evicted bytes, about 20.5 GiB, during this session. The configured
CAS quota is 16,384 MiB. The experiment accumulated many new executable/PDB
versions, so retaining every historical cache entry was no longer possible.

A subsequent original-graph replay in A hit all 493 processes and executed zero.
Old-version restoration therefore depends on history retention as well as correct
fingerprints. Evicted cache names also do not reclaim data still linked from
instance targets. The earlier storage report is a snapshot from before these
additional latency trials; it is not a new measurement of the current directory.

After all clients exited, the cache service stopped normally with exit code 0.
The final System/Application Popup query at 18:36:12 local time found zero new
matching events since 14:47:05, and zero active rustc/helper/BuildXL/cache processes.
The prior two 14-case integration result files were checked; those suites were
not rerun for the graph-trimming experiment. No active sandbox tree was killed.
This run avoided the previous teardown trigger; the exact DLL cause of the
earlier 0xc0000142 failures remains unproven.

The next implementation priorities are the faster contract scan, per-instance
incremental scheduling with invalidation tests, and correction of enumeration
dependency inference. After those, profile linker/output-cache cost and validate
isolated mutable rustc incremental state. The current evidence does not establish
Cargo-equivalent latency for all edits or steady storage use across long histories.

## Retained evidence

- [Summary and all sample records](build-latency-evidence/summary.json).
- [Raw selected cases](build-latency-evidence/cases/baseline-edit-3/BuildXL.log),
  with corresponding statistics, configurations, stage timers, and XLG-derived
  executed-pip records in the same evidence tree.
- [Spurious enumeration inputs](build-latency-evidence/spurious-inputs.json) and
  [graph inflation examples](build-latency-evidence/inflation-examples.json).
- [Experimental scripts](build-latency-evidence/scripts/Run-PerfCase.ps1) and
  [instrumented driver](build-latency-evidence/driver-perf/lib/Common.ps1).
- [Final startup check](build-latency-evidence/startup-follow-up.json) and
  [issues encountered](build-latency-evidence/issues.md).

Full XLG logs, serialized BuildXL graphs, graph JSON variants, targets, and caches
remain under the Windows experiment directory. To reproduce a case, use a new
label and marker, run the cache service first, and run timing cases serially.
`Run-PerfCase.ps1` refuses an existing archive label. Changed graph/scheduling
conditions need a prime before collecting warm samples.
