# Four-worktree BuildXL shared-cache experiment

Date: 2026-11-16. Repository baseline: `90941c7`.
Retained experiment: `F:\Temp\rustbxl-large-20261116`.

The experimental adapter built rust-analyzer, Biome, and Typst in four real Git
worktrees each. All three passed concurrent shared-cache materialization,
concurrent divergent edits, cached restoration, and functional checks. These
runs used BuildXL shared CAS and NTFS hardlinks. Compression was disabled.

The complete requested combination is not achieved. Storage and concurrent
isolation passed, but measured edit latency exceeded Cargo incremental builds.
rustc query incremental compilation remains disabled in the prototype. The
original implementation in this checkout is unchanged; the experimental source
patch and graph transformations are retained for review.

## Physical storage

Every independent Cargo target exceeded 2 GiB. Both conditions used normal dev
builds, default features, the Windows MSVC target, and three build jobs per client.
Cargo retained its incremental state. The shared condition retained its CAS,
including successful outputs from earlier failed replay attempts and all measured
edit versions. No history was purged before the final measurement.

| Project, four worktrees | Independent Cargo targets, GiB | Shared targets + all CAS, GiB | Saved | Entire shared state, GiB |
| --- | ---: | ---: | ---: | ---: |
| rust-analyzer | 12.45 | 6.68 | 46.4% | 6.98 |
| Biome | 40.14 | 10.42 | 74.0% | 10.87 |
| Typst | 16.32 | 5.91 | 63.8% | 6.26 |
| Total | 68.91 | 23.01 | 66.6% | 24.10 |

The entire state adds captures, engine data, configuration, and logs. It excludes
junction targets that supply dependency sources and the shared BuildXL bootstrap.
Source worktrees, dependency stores, and installed tools are outside both target
comparisons. Filesystem metadata is excluded.

With equal sources, before divergent edits and timing runs, targets plus CAS used
1.98, 4.75, and 2.93 GiB respectively. That 9.66 GiB total saved about 86% against
the native targets. The final table includes the subsequent cache history:
13 entry-point source versions for rust-analyzer, and nine each for Biome and
Typst. rust-analyzer also received the extra incremental-scheduling trial.
The configured CAS quota was 16,384 MiB per project. These results do not establish
a steady-state history-retention policy or a bound on instance outputs and logs.

`Measure-Storage.ps1` independently counts each NTFS volume/file identity once
across all supplied roots. It reads allocation size for ordinary files and uses
the compressed-size API for compressed or sparse files. The probe skips directory
reparse points and uses extended Windows paths for long object-file names.
It first passed a 4,097-byte/two-hardlink boundary check, which counted one file
and 8,192 allocated bytes. An independent file-compression query agreed on samples.

Both final conditions contained zero compressed files. The largest published
rlib in each shared project had hardlink names in all four targets and the CAS.
For example, rust-analyzer's `libhir_ty` had 49 names with one file identity.
Dependency-view names therefore increase logical directory sizes without
allocating a separate data copy for every name. The table uses unique allocation,
not sums of apparent file lengths.

## Concurrent execution and correctness

Each project ran these three phases. All four clients were launched before the
harness joined them. Recorded start/exit intervals establish four-way overlap.

| Project | Process pips | Equal-source hits in each new B/C/D target | Executed per divergent worktree | Executed per restored worktree |
| --- | ---: | ---: | ---: | ---: |
| rust-analyzer | 365 | 364 / 365 | 2 | 0 |
| Biome | 493 | 493 / 493 | 2 | 0 |
| Typst | 478 | 477 / 478 | 2 | 0 |

Equal-source A was already populated; B, C, and D had empty shared targets.
Divergent builds changed a real entry-point statement to emit `FOUR-A` through
`FOUR-D`. Each client compiled and linked its own executable. Restoration returned
all sources to `SHARED-A` and used cached outputs without executing a process pip.
Every phase checked each executable's marker.

All twelve executables also passed a functional operation in every phase:
rust-analyzer parsed a Rust function, Biome formatted JavaScript containing
`return 42;`, and Typst evaluated a metadata query to `42`. Output text agreed
between worktrees while their divergent markers remained distinct.

The source generator that implements dependency views passed the full 14-case
integration suite in `integration-dependency-views`, including six concurrent
fixture worktrees, dynamic inputs, transitive proc macros, restoration, and
feature recapture. The helper also passed 505 Win32 argument checks and the
frontend passed 22 actual argument-array executions. Large-project runs used
stable v2 helper binaries and transformed graph data. The v3 source generator
was validated by the fixture suite; a fresh large capture from that generator
was not run.

## Edit latency

After concurrent runs finished, each project received four serial rounds of the
same small entry-point edit. Cargo and BuildXL ran separately, with their order
alternating between rounds. The first round warmed each condition; the table
reports medians of the next three rounds. Each marker was new to both conditions,
so every BuildXL sample executed the compiler and linker. Program verification
was outside the timed interval. Times include PowerShell/toolchain setup and CLI
startup for both conditions.

| Project | Cargo incremental edit, s | BuildXL edit, s | Ratio |
| --- | ---: | ---: | ---: |
| rust-analyzer | 6.63 | 15.38 | 2.32x |
| Biome | 11.32 | 21.93 | 1.94x |
| Typst | 7.42 | 19.42 | 2.62x |

The main comparison disabled BuildXL server mode and incremental scheduling,
matching the current CLI. A separate rust-analyzer trial enabled BuildXL
incremental scheduling, primed its state, and repeated the alternating comparison
with new markers. Its medians were 12.26 seconds for BuildXL and 7.08 seconds for
Cargo. Cached restoration took 6.63 and 7.05 seconds respectively. The flag and
statistics are retained in `scheduling-final.configuration.json` and
`scheduling-final.stats`. The temporary scheduling change was then reverted.

The scheduler option reduced graph work but did not close the edit-latency gap.
The current graph has thousands of dependency-copy pips and starts a fresh engine
for each CLI call. A cache miss also recompiles the crate without rustc's query
incremental state. A production design still needs efficient graph reuse and
isolated mutable compiler state for each worktree, with immutable products in CAS.
That design and large-library edit performance remain unvalidated. These timings
cover entry-point edits, not arbitrary library or dependency changes, and three
samples do not establish confidence intervals.

The [follow-up latency investigation](build-latency-investigation.md) traces
redundant dependencies to compiler directory enumeration and measures faster
contract scanning and incremental scheduling. Its additional cache history
postdates the storage snapshot above.

## Adapter changes and experimental limits

Large captures exposed wrapped compiler/version queries, expected-failure compiler
capability probes, distinct host/target build-script executions, executable aliases,
old-form metadata, and native Git/MSVC/assembler children. The experimental adapter
models those cases. It still rejects Cargo `DEP_` metadata consumers.

Compiler and linker pips own separate output directories. Declared publication
copy pips expose Cargo-compatible output names. Per-compiler dependency views
collect the required Rust libraries into one search directory through declared
BuildXL copy pips. UTF-8 response files preserve complete rustc arguments and
avoid Windows command-line length limits. Temporary linker objects, definition
files, and NatVis files are staged before rustc removes them.

The private-directory trial initially failed with E0463. A minimal explicit
`extern crate` probe exposed the hidden `LoadLibraryExW` error 8 while loading a
transitive proc macro. Physical paths and a short namespace search list passed.
Dependency views then allowed all three complete replays to pass. This supports
the long-search-list diagnosis; a Windows loader internals analysis was not done.

MSVC also launched `vctip.exe` inside a linker tree. Its surviving process and
certificate reads made BuildXL reject the pip. The experiment held one telemetry
process outside sandbox trees during replay. Its lifecycle needs integration into
the maintained CLI. Sandbox dependency and double-write checks remained enabled.

`shared-source-v3.patch` applies to the repository baseline and contains the source
generator and fixture changes. The large-run transformations are
`Patch-PrivateResponses.ps1`, `Use-HelperV2.ps1`, and `Patch-DependencyViews.ps1`.
They are one-time transformations, and they were applied before the measured
four-worktree runs. These artifacts are experimental review material.

## Startup error 0xc0000142

Four System/Application Popup events, records 651084 through 651087, occurred
at 14:47:04.582 through 14:47:04.781 local time: one named
`RustBxl.Processes.exe`, and three named `rustc.exe`. The code is
`STATUS_DLL_INIT_FAILED`.

These events coincide with an earlier temporary stop script calling
`Process.Kill(true)` on three active sandbox driver trees. This is strong evidence
of a teardown trigger. The exact failing DLL and instruction were not captured.
The experiment now requires clients to exit before cache shutdown; its integration
harness retains timed-out clients for diagnosis and waits for active clients.
No machine-wide dialog suppression or debugger registry settings were used.

Eighty earlier compiler/helper launches passed. Both the original and updated
14-case integration suites passed. The final event query at 17:31:38 local time
found zero new matching popups after 14:47:05 and zero remaining compiler, helper,
BuildXL, or cache processes. Cache services exited normally. The separately owned
telemetry process was stopped after all build/cache clients had exited.
The tested lifecycle avoids the observed trigger; a DLL-level root-cause fix
remains unproven.

## Inputs and evidence

| Project | Revision | Selected package |
| --- | --- | --- |
| rust-analyzer, `2026-02-09` | `c75729db6845c73605115b18d819917dbf6a8972` | `rust-analyzer` |
| Biome, `@biomejs/biome@2.3.8` | `2a229e46bdb1781dc50700d332341c935b5087ef` | `biome_cli` |
| Typst, `v0.13.1` | `8ace67d942a4b8c6b9d95b73b3a39f5d0259c7b2` | `typst-cli` |

The host had 12 logical CPUs, 32 GB RAM, and NTFS on F:. Native work used Windows
paths, PowerShell 7.6.4, Rust/Cargo 1.93.1 stable, .NET 9.0.318, Visual Studio
2022 17.14.41, and MSVC 14.44. BuildXL was `0.1.0-20260814.1`, with bindmount.
Native builds used `cargo build --locked --offline --target
x86_64-pc-windows-msvc -p <package>`. Their cold timings overlapped preparation
work and are not a performance comparison.

The retained experiment has `runs/<project>/a` through `d`, native targets
`cargo-a` through `cargo-d`, and shared states `shared-<project>`. The previous
compression trial remains outside this report's results.

[summary.json](large-worktree-evidence/summary.json) retains the independently
audited measurements, all four-client intervals, functional outputs, warm timing
samples, integration results, and final startup check.
[issues.md](large-worktree-evidence/issues.md) records intermediate errors,
their original diagnostic commands, workarounds, and instruction inconsistencies.
The evidence directory also retains the experimental source patch and the scripts
that create views, run four clients, measure storage, and audit the result.

To replay a retained project, start `Start-LinkTelemetry.ps1` and that project's
`Shared-Benchmark.ps1 -Command cache-start` in separate Windows terminals. Run
`Four-Shared.ps1` with phases `equal`, `edit`, and `restore`, with matching
`Verify-SharedPrograms.ps1` checks. Stop the cache after clients exit. These phases
reuse previously recorded source versions on repetition. For fresh timing samples,
give `Compare-WarmEdits.ps1` a new `-MarkerPrefix` and a separate `-ResultName`.
`Measure-NativeFinal.ps1`, `Measure-Shared.ps1`, and `Audit-SharedEvidence.ps1`
produce the final storage and consistency records. The audit uses this run's fixed
marker names and requires the matching saved measurements.

The implementation in the original checkout was not replaced, and no commit was
created. This report, its evidence, and the README link are the repository changes.
