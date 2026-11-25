# Validation

The Windows integration suite runs with PowerShell 7, stable Rust, MSVC x64,
the pinned BuildXL package, and bindmount. Each run has its own dependency
store, engine download, local cache, repository, and six Git worktrees.

The suite builds the .NET helper from source. It checks 505 Win32 argument
round trips and 22 argument arrays through the actual JSON frontend and
BuildXL process execution. It compares replay results with clean offline
Cargo builds and checks that existing Cargo targets and dependency sources
retain their contents.

## Verified results

The cross-capture fingerprint change passed all 30 Windows integration cases
under `F:\Temp\rbc1116c`. The run included the 505 Win32 argument checks, 22
BuildXL argument arrays, and six concurrent worktrees.

| Replay scenario | Process cache hits | Processes executed |
| --- | ---: | ---: |
| Identical sources with a separate capture on a fresh instance | 26 | 0 |
| Added local dependency with a build script and `links` metadata | 20 | 11 |
| Original and dependency captures built concurrently | 26 and 31 | 0 and 0 |
| Original capture after restoring the dependency edit | 26 | 0 |

All 20 unchanged process definitions retained their BuildXL weak fingerprints
and hit the shared cache. The new metadata consumer used a different plan and
executed. Replay output matched clean Cargo, and existing shared plans retained
their contents and last-write times. Both cache service lifetimes ended
normally. The Windows System log contained zero matching startup popup events
during the test window.

See the [cross-capture results](cross-capture-evidence/validation.json) and
[implementation issues](cross-capture-evidence/issues.md).

The build-script modeling implementation passed all 26 Windows integration
cases on 2026-11-16. The suite retained 505 Win32 argument checks, 22 actual
BuildXL argument arrays, six concurrent worktrees, compressed CAS restoration,
and comparisons with clean offline Cargo builds. The expanded fixture has 26
process pips. An equal second worktree reused all 26 without execution.

The new cases cover shared host/target script executables, current `links`
metadata, newly added metadata keys, normal versus build dependencies, repeated
direct/wrapped compiler version requests, and successful or expected-failure
capability probes. CMake and Ninja build a real MSVC C library and executable.
Changing the C result from 42 to 43 or changing only Git HEAD executed 11 pips
and reused 15. Both restorations reused all 26 with zero process execution and
without recapture. The CMake fixture uses embedded debug information (`/Z7`)
and short logical paths; external PDB services remain unsupported by this trial.

Evidence: [build-script validation](build-script-modeling-evidence/validation.json).
Full logs remain under `F:\Temp\rbm1116b`. The final event query found no new
matching compiler/helper startup popup events or active build/cache processes.
The cache stopped normally. Intermediate capture cleanup, PDB-service, shell,
and path-length issues are recorded in
[modeling issues](build-script-modeling-issues.md).
Environment checks also cover absent, empty, and existing values, nested scopes,
explicit removal, ambient Cargo overrides, and restoration after an exception.
These tests cover the fixture; the earlier large-project storage and latency
measurements have not been repeated with the new model. The dependency graph
was not trimmed, and experimental patches stayed outside the baseline commit.

The optional artifact-compression implementation passed 20 complete Windows
integration cases and 7 separate NTFS policy cases on 2026-11-16. The complete
suite retained the 505 Win32 argument checks, 22 actual BuildXL argument arrays,
and six concurrent worktrees. Source edits and restorations still matched clean
Cargo builds. The dependency graph was unchanged.

The real shared CAS test compressed 38 historical content files while protecting
all active instance files. Unique allocated space for those selected files changed
from 14,540,800 to 7,032,832 bytes: 7,507,968 bytes saved (51.63%). The cache then
restarted and restored the historical executable with 10 process cache hits and
zero executed processes. Its SHA-256, output, and original CAS ACL matched the
values recorded before compression. These fixture results establish cache
correctness and selected-file savings; they do not measure large-project edit
latency or total-state compression ratios.

NTFS policy cases cover default preview, empty state, explicit exclusions,
active aliases through CAS and another instance, unknown external hardlinks,
7-day age boundaries, 64-KiB size boundaries, partial-cluster allocation,
incremental/engine/database exclusions, junctions, maintenance locks, an occupied
cache endpoint, retained ACLs on success and failed exclusive open, read-only
files, other deny rules, file identity, last-write time, and repeated apply.

Evidence: [compression validation](compression-evidence/validation.json).
Full logs remain under `F:\Temp\rustbxl-compression-20261116\integration-final`
and `allocation-verified`. Intermediate issues and their resolutions are recorded
in [compression issues](compression-evidence/issues.md).
The final event query found zero new matching startup popup events and zero
active compiler, helper, engine, or cache processes. Both cache lifetimes ended
through the normal stop command.

The replay optimization integration passed all 18 cases on 2026-11-16 using the
maintained CLI. Replay enabled BuildXL incremental scheduling; discovery kept it
disabled. The generator, frontend, and declared graph dependencies were unchanged.
The run retained the same 505 Win32 and 22 actual BuildXL argument checks.

The four added cases cover filesystem scan boundaries, unchanged incremental
replay, cache materialization after deleting the executable, and rejection of new
hidden manifests or changed Cargo/toolchain configuration. Scanner checks include
zero, one, and several manifests; hidden directories; nested `target` exclusions;
directory junctions; Git worktree metadata; file addition/edit/removal; and ancestor
and Cargo-home configuration.

All eight existing source/dynamic-input edits still matched clean Cargo builds.
Their restorations executed zero processes. Six worktree variants built
concurrently and matched their independent Cargo outputs. Feature recapture and
preservation of project targets and dependency sources also passed.

The maintained scanner produced identical serialized contract dictionaries to
the original scanner on the retained rust-analyzer, Biome, and Typst worktrees.
This is a content-equivalence check; the prior latency measurements remain in the
[latency investigation](build-latency-investigation.md).
The source-level integration did not apply the experimental large-project adapter
patch or graph trimming. Those remain separate review material.

Evidence: [validation.json](replay-optimization-evidence/validation.json).
Full logs remain in `F:\Temp\rustbxl-merge-20261116\integration`.
The cache exited normally, with zero active compiler/helper/engine/cache processes
and no new matching startup popup events at the final check. Intermediate
diagnostic read issues are recorded in
[issues.md](replay-optimization-evidence/issues.md).

On 2026-11-16, a clean Git clone passed all 14 integration cases. The clone
had no build artifacts or test state. It built its own helper, downloaded its
own BuildXL package, and fetched the locked crates.io dependency into its own
Cargo home. The external BuildXL checkout and bindmount executable were supplied
as command arguments. No files from the earlier experiment were used.

The host used PowerShell 7.6.4, .NET SDK 9.0.318, Rust 1.93.1 stable, Visual
Studio 2022 17.14.41 with MSVC 14.44, and BuildXL 0.1.0-20260814.1.
All 505 Win32 argument cases and 22 BuildXL argument-array cases passed.

The fixture has 10 process pips, plus copy pips for executable aliases:

| Build or edit | Executed process pips | Process cache hits |
| --- | ---: | ---: |
| Cold replay | 10 | 0 |
| Equal second worktree | 0 | 10 |
| Ordinary library source | 3 | 7 |
| Newly read Rust module | 3 | 7 |
| Previously absent file appears | 4 | 6 |
| Directory member added | 4 | 6 |
| External text changes | 4 | 6 |
| Input changes with equal resulting directives | 1 | 9 |
| Build-script source changes | 6 | 4 |
| Included source text changes | 2 | 8 |

Each restored source case executed zero process pips. The capture contract
and process trace remained unchanged through ordinary and dynamic input edits.
Six worktree variants built concurrently and matched their separate clean
Cargo outputs. Feature changes rejected the old capture and passed after a new
capture. Existing project targets and dependency sources stayed unchanged.

Additional CLI checks passed from a fresh, uninitialized PowerShell session:
the current capture validated, and a changed tool search path rejected it.
The frontend directory kept only its three committed source files. Git stayed
clean in the clone. Disposable test states and clones were removed after these
results were recorded. These checks establish correctness and isolation; they
do not measure build time or disk savings.

## Resolved implementation issues

- Source rewriting and a string-based DScript renderer made data escaping and
  source maintenance fragile. Typed graph records now serialize to JSON. A
  fixed frontend owns pip construction. Test variants and the Cargo oracle
  are complete, committed source files.
- BuildXL SDK assumptions failed during the first frontend runs: a config
  file permits one `config(...)` call, JSON uses `module.config.dsc`, paths
  use typed path expressions, and Map uses `containsKey`. The frontend now
  uses the packaged SDK API. A contract check runs inside a function.
- `Cmd.concat` used unescaped argument fragments. `Cmd.argument` also omits
  empty strings. The frontend passes each complete nonempty argument to
  `Cmd.argument` and represents an empty argument with `Cmd.rawArgument("\"\"")`.
- An explicit discovery temp path did not exist. Discovery now uses BuildXL's
  prepared default temp directory.
- Cargo discovery files in the first instance changed absent-file probes and
  reduced sharing with an empty instance. Capture now removes its own sidecar
  target after graph extraction. Replay populates it with declared outputs.
- Per-instance MSVC telemetry cleanup raced with concurrent linkers. The
  foreground cache service now owns one telemetry process for its lifetime.
  Discovery owns a temporary process. Cleanup acts on the owned process handle.
- Argument normalization used temporary drive tokens and changed remap-root
  boundaries. It now maps actual roots directly to the common logical roots.
- A new test expected `/` after the remapped Rust target prefix. Windows
  `file!()` retained `\` separators. The test now compares path components.
- Integration cleanup waits for test-owned pending clients before it stops the
  cache service after a failure. A timeout retains the active sandbox client for
  diagnosis; it does not terminate the process tree.
- BuildXL's default output root created a temporary shared log junction beside
  the frontend. An explicit per-instance storage root now keeps this junction
  and other engine defaults inside the sidecar. Transient logs were removed
  from the Git index before the initial commit.
- A status check from another shell found an avoidable capture rejection.
  A child PowerShell prepends its runtime directory to PATH; Visual Studio
  initialization can place that entry after the compiler directories. The
  compile environment now puts this one runtime directory at a stable first
  position. It preserves the order of other search paths. A direct-call versus
  child-session integration check covers this boundary.
- A partial migration retained a removed `DiskUsage` call and caused CS0103.
  The stale call was removed. Initial source/API searches also used incorrect
  paths and an overescaped regex; scoped file discovery and literal searches
  resolved those errors.
- Tool orchestration had JavaScript template and helper-serialization errors.
  Those calls changed no project files; source edits used explicit patches.

## Resolved PowerShell issues

The original failing expressions were:

```powershell
$text.Replace([char]13+[char]10,[char]10)
Cli 'init' ...
@(..., 'line1' + [char]10 + 'line2')
Get-Content '.\.test\current\sidecar state\captures\main\capture\units\rustbxl_fixture-*\rustc.json'
Get-Item .\frontend\Out\BuildXLCurrentLog -Force | Select-Object FullName,Attributes,LinkType,Target
```

The first expression selected an unsuitable character overload. That source
rewrite workflow was removed. The second command resolved to the `cli` alias
for `Clear-Item`; the test helper is now `Invoke-Cli`. The third expression
formed multiple array elements; parentheses now group the newline expression.
The captured-unit probe assumed a hashed unit name; enumerating the captured unit
directories found the correct file.
The last command queried a temporary junction after BuildXL had removed it.
The retained engine configuration supplied its location. The per-instance
storage-root change then moved this junction into the sidecar.

An initial `rg` pattern, `AddProcess\\(`, had an unclosed group. Literal
searches now use `rg -F`. The command
`git diff --check --no-index -- /dev/null frontend\graph.dsc` returned the
normal nonzero status for a new file. Staging followed by `git diff --cached
--check` checks the project correctly.

The local cache service reports a missing certificate name while it starts
its local unencrypted gRPC endpoint. This is the selected local service mode.
No proxy or network workaround was required.
