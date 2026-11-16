# Experiment issues

## Windows and network setup

- GitHub direct access stalled on `git.exe ls-remote --tags https://github.com/rust-lang/rust-analyzer.git 2026-02-09`. A per-command Windows proxy completed the requests. No project proxy configuration was changed.
- The initial Biome reference `cli/v2.3.8` did not exist. The published tag is `@biomejs/biome@2.3.8`.
- BuildXL was absent from PATH. Its installed public bootstrap was found in the previous experiment and copied into this experiment's tools directory. bindmount was found in its own project distribution directory.
- Free space initially limited retained outputs. The user freed space before measurement completed.
- BuildXL's local cache logged missing encrypted gRPC credentials. Its configured local channel still started.

## Temporary PowerShell and shell mistakes

- `Get-CimInstance Win32_Process -Filter "Name = ''git.exe''"` and the same expression for `RustBxl.Processes.exe` used incorrect quoting inside a Bash single-quoted command. A script file or a filtered process inventory fixed the queries.
- `[Diagnostics.Process]::GetProcessById($item.ProcessId).Kill($true)` raced with child processes that had already exited after their parent was stopped. The one-time cleanup was removed after the parent stopped.
- `Start-ThreadJob ... git.exe clone ...` plus `Receive-Job -ErrorAction Stop` treated Git progress on stderr as a terminating error. The completed checkouts were inspected, and later Git operations used separate native processes.
- `& rustbxl.ps1 @initArguments` passed a string array to a PowerShell script as positional arguments. The corrected invocation starts `pwsh.exe -File` as a native process, which parses those CLI arguments.
- An initial `Get-Helper generate ...` experiment used a previous helper version and failed. Later helpers used separate versioned directories so active processes retained their original binaries.
- A temporary `RustcQueries.Query(...)` edit had one excess closing parenthesis and produced CS1002/CS1513. The expression was corrected before further tests.
- `ls -l Edit-Probe.ps1 && git status --short` ran in the temporary driver checkout; the script is in its parent directory. The scoped directory check was corrected.
- `@('-L', 'dependency=' + $dependency.path)` split the expression into extra array elements. A temporary graph patch used an explicit string list and grouped strings. Production code already uses typed C# arrays.
- Starting capture during an active replay correctly failed on `dependencies.lock`. Subsequent dependent operations were separated.
- Restarting a replay before its stopped cache had restarted produced DX11281/DX7136. The cache was restarted.
- Re-running the temporary `Regenerate.ps1` after a successful run failed because the successful run had removed discovery outputs. Fresh captures are required after that boundary.
- A status probe read `capture-a-final-cli.log` before the driver had finished creating it. Later status used the active BuildXL log.
- One integration rerun changed helper binaries during the suite and lost restoration cache hits. A stable helper build passed subsequent suites.
- `Process.Kill(true)` in the initial Stop-BuildXL-Trials.ps1 abruptly stopped three active sandbox trees and coincided with four 0xc0000142 popup events at 14:47:04. The script now refuses active clients. See startup-failure/analysis.md for evidence and follow-up validation.
- A BuildXL source search used `runs/biome/...` while its current directory was the BuildXL checkout. The scoped log search was moved back to the experiment directory.
- The temporary verification command `typst.exe eval sample.typ '(20 + 22)'` used a subcommand absent from Typst 0.13.1. The supported `typst.exe query sample.typ '<probe>' --field value --one --ignore-system-fonts` command verified evaluation of metadata to 42 in both worktrees.
- An inline follow-up probe used `Get-Content -LiteralPath 'F:\Temp\rustbxl-large-20261116\integration-startup-lifecycle\summary.json' -ErrorAction SilentlyContinue`. The suite writes `results.json`. The named Review-Startup.ps1 script now reads that file, saves the event query and all 14 passing cases, and returns an explicit exit code.
- `rg -n 'ERROR|error |LNK1104|32767|too long|character|Win32Exception' runs/rust-analyzer/replay*.log runs/biome/replay*.log runs/typst/replay*.log` assumed log names that did not exist. Scoped `rg --files` located `build-a-fixed-paths.log`, which contains the retained command-length and linker failures.

## Large project boundaries found in rustbxl

- Build-script compiler version queries through RUSTC_WRAPPER were unmodeled.
- Compiler capability probes from autocfg, proc-macro2, and other packages were unmodeled, including probes that are expected to fail.
- The same build-script executable can execute for both host and target; executable aliases and graph names need distinct execution identities.
- Repeated compiler version queries created duplicate graph nodes.
- prettyplease emits old-form Cargo links metadata (`cargo:VERSION`). This requires metadata consumer handling.
- Typst invokes Git, MSVC C tools, and the x64 assembler from build scripts.
- Transitive process-macro DLL search paths were missing after output relocation.
- Adding per-crate dependency directories exceeded the Windows 32767-character process command limit on rust-analyzer.
- Biome replay reached an LNK1104 missing staged rlib error.

Experimental changes and test evidence remain under this directory. The original
rustbxl checkout was restored after the trials. The experiment does not claim
that these prototypes are a complete production implementation.

## Shared-cache follow-up issues

- The first shared-output frontend used `Artifact.sharedOpaqueOutput` in `Transformer.execute.outputs`. The selected SDK accepts `{directory, kind: "shared"}` there. Capture stopped during type checking (DX11231), before sandbox compilation started; the frontend now uses the SDK's DirectoryOutput type.
- An unnecessary parenthesis edit caused CS1026 in the temporary driver. The original four closing parentheses were correct and were restored before further builds.
- `rg -n 'type Output|interface.*Output|sharedOpaque' Public/Sdk/Public/Transformers/Transformer.Execute.dsc Public/Sdk/Public/Prelude/Prelude.Transformer.Arguments.dsc Public/Sdk/Public/Transformers/Transformer.Arguments.dsc` referenced a missing third file. Scoped discovery found `Transformer.Dependencies.dsc` and the SDK's current shared-directory examples.
- `pwsh.exe -WorkingDirectory 'F:\Temp\rustbxl-large-20261116' -File 'F:\Temp\rustbxl-large-20261116\Inspect-Processes.ps1'` was a capture-trace inspection script that needs a project name, not a live-process inventory. It emitted missing-path errors and changed no state. Live inventory now uses Get-CimInstance Win32_Process directly.
- The shared-output experiment rejected rustc/linker double writes to final DLLs. It was replaced by separate owned compiler/linker directories and declared publication copy pips. Sandbox double-write checks remain enabled.
- `tail -n 10 integration-published-outputs/cold-alpha.log` ran before that case had created its log. Subsequent progress uses the active session output.
- The first large shared-cache configuration placed `CARGO_BUILD_JOBS` in the user environment map. Configuration validation correctly rejected this reserved variable. The temporary driver now sets its experiment limit internally, and the unsupported user-map entry was removed before capture.
- `tail -n 8 shared-biome/captures/main/discovery-run/logs/BuildXL.log` was queried after that configuration rejection, before discovery had started. The captured CLI log identified the configuration error; a fresh capture then succeeded.
- The original Review-Startup.ps1 emitted complete active compiler command lines and made a follow-up response too large. It now retains only process IDs and names and prints a compact count.

## Instruction inconsistencies

- The PowerShell skill includes direct UNC script examples, while the supplied
  project instructions require Windows-local execution and boundary copies.
  All build work used local Windows paths.
- The supplied instructions mention proxy port 2080 in the keyword list and
  10808 in the explicit network recovery procedure. The explicit procedure was
  used for the one-time commands.

## Four-worktree shared-cache follow-up

- The private-directory response-file trial failed with E0463 in all three large projects. A minimal explicit `extern crate smallvec` probe exposed the underlying `LoadLibraryExW` error 8 while loading a transitive proc macro. The same inputs loaded successfully through physical paths, and a minimal short search list also passed through the namespace. Per-compiler dependency views replaced the long list of private library directories. All three large replays then passed. Each view file is a declared BuildXL copy pip; sandbox dependency checks remain enabled.
- rust-analyzer linking required a temporary NatVis input which rustc deletes after the linker returns. LinkCapture now stages `/NATVIS:` inputs. Its temporary-file rule now uses the actual temporary directory, instead of matching any directory beginning with `rustc`, which also matched the crate `rustc_hash`.
- A replay launched MSVC's `vctip.exe`, which outlived its linker and accessed certificate files under an unhashable AppData mount. BuildXL rejected it with DX0041/DX3601. The experiment now holds one external telemetry process for the replay lifetime, as discovery already does. No sandbox check or certificate tracking exception was added. This external service is part of the experimental setup, and still needs lifecycle integration in the maintained CLI.
- The inline response-file probe `[IO.File]::WriteAllLines($path,@("--print=cfg","--cfg",''probe="a b"''),...)` was embedded in a Bash single-quoted `-CommandWithArgs` string and caused a PowerShell parser error. The standalone `Probe-RustcResponse.ps1` passed and preserves spaces and embedded quotes.
- `cat shared-biome/config.json && ...` used an assumed filename. The configuration is `shared-biome/rustbxl.json`; scoped file discovery located it.
- `tail -10 shared-biome/probe-...-physical.log; head -10 shared-biome/probe-....log; git diff --stat` ran from `driver-shared` instead of the experiment root. Later reads use the experiment root. The accidental trailing `cat CXX-does-not-exist 2>/dev/null` in another temporary read had no side effects.
- Two diagnostic `Probe-ReplayNode.ps1` variants were started concurrently and competed for the same output log. PowerShell reported a sharing violation. These probes now run sequentially; the production four-worktree harness uses separate instance targets and logs.
- `Patch-DependencyViews.ps1 -Name biome` initially assumed every `--extern` has a file path and failed on the valid sysroot argument `--extern proc_macro`. Bare extern entries are now retained. The failed pass wrote no graph or response files. A scalar response-file selection was also changed to an explicit array before use.
- `Measure-Shared.ps1 -Name rust-analyzer -Label equal` initially failed when `CreateFileW` opened an object-file path longer than MAX_PATH. The probe now uses the extended Windows path prefix for native size and identity queries. The complete measurement then passed.
- An SDK source search included the absent path `Public/Src/FrontEnd/Script/UnitTests`. The other scoped searches returned normally; no production source was changed by the search.
- A later source probe `sed -n '1,130p' driver-shared/src/RustBxl.Processes/RustcQueries.cs` ran from the original checkout and used the wrong relative root. The source stayed unchanged. `rg 'processes' .gitignore` also ran at the experiment root, which has no `.gitignore`.
- The configuration source search included the absent `Public/Src/Utilities/Configuration/CommandLineConfiguration.cs`; `Public/Src/App/Bxl/Args.cs` contained the incremental scheduling switch.
- An `apply_patch` call combined Delete File and Add File operations for `docs/large-worktree-experiment.md`. Patch validation rejected the duplicate target before changing the file. Separate sequential operations installed the final report.

## Final status

All three projects passed four concurrent equal, divergent, and restored builds,
plus all corresponding functional checks. The updated source generator passed
14 integration cases. The experiment retained every CAS history version; final
storage is therefore larger than the equal-source measurement. Three serial
warm samples per condition showed slower BuildXL edits. An additional
rust-analyzer incremental-scheduling trial reduced, but did not close, that gap.
The temporary scheduling switch was reverted after measurement.

The final follow-up found no new matching 0xc0000142 popup events and no remaining
compiler, helper, BuildXL, or cache processes. The three cache services exited
normally. The separately owned vctip process was stopped only after all clients
and caches had exited. The original implementation remains unchanged.
