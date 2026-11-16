# Build-script modeling implementation issues

The baseline workspace was committed as `7ea4cf4` before the modeling changes.
Experimental patches, temporary drivers, one-time scripts, and raw experiment
logs remained outside that commit. No experimental patch was applied.

## Commit checks

The initial `git.exe diff --cached --check` found trailing whitespace in retained
BuildXL logs. Those raw logs were removed from the index. Maintained code,
integration tests, reports, and structured validation evidence passed the check.
Git also reported CRLF-to-LF normalization for JSON evidence, as required by the
existing `.gitattributes` rule. The evidence content was unchanged.

## Capture output cleanup

The first modeling run failed because the helper could not find
`capture\cargo-metadata.json`. The discovery pip owns that output directory and
BuildXL cleans it before execution. Cargo metadata is now written after discovery
exits and before graph generation. The failed run is retained under
`F:\Temp\rustbxl-modeling-20261116\first`.

The next run passed all 23 cases, including changed metadata, compiler capability
probes, host/target script identities, compressed CAS restoration, and six
concurrent worktrees. The later suite adds native and Git cases.

## Cargo metadata boundaries

The captured Cargo environment confirmed that a script receives links metadata
from normal dependencies. A build dependency supplies a Rust library to compile
the script and does not inject its own `DEP_*` values. The implementation and
fixture now check that distinction. Capture also compares all reconstructed
metadata keys and values with Cargo's actual environment before it saves a graph.

The parser distinguishes modern `cargo::metadata=key=value` from the old
single-colon metadata syntax. In particular, `cargo:metadata=literal=value` names
the old metadata key `metadata`; it does not name a key `literal`. The fixture
checks this against clean Cargo execution.

## MSVC PDB service

The first CMake test used default Debug `/Zi`. CMake's compiler checks failed
C1041 on their PDB paths. An idle `mspdbsrv.exe -start -spawn` descendant then kept
the debug capture alive until the test timeout. The harness waited for the client
and retained its sandbox. It did not call `Process.Kill(true)`.

The fixture now sets CMake policy `CMP0141 NEW` and
`CMAKE_MSVC_DEBUG_INFORMATION_FORMAT Embedded`, which uses `/Z7`. This keeps debug
information in the object file and avoids a separate PDB writer for compilation.
The trial does not establish the exact contribution of path length versus silo
visibility to C1041. General external PDB-service support remains a separate task.
The failed run and CMake configure logs are under
`F:\Temp\rustbxl-modeling-20261116\native`.

The service diagnosis had these failed commands:

```powershell
Get-CimInstance Win32_Process -Filter "Name = ''mspdbsrv.exe''"
& $server.ExecutablePath -shutdown
& $server.ExecutablePath -?
```

The first expression was inside a Bash single-quoted `-CommandWithArgs` argument;
Bash removed its inner quotes and WMI reported an invalid query. A complete
process inventory filtered by `Name` corrected the query. The next two commands
reported invalid switches. Inspection of the installed executable's option
strings identified `-stop`. After confirming that no compiler clients remained,
`& $server.ExecutablePath -stop` was requested. It returned exit code 1 without a
diagnostic; the server and retained capture then exited. No process tree was
terminated.

## CMake compiler-check path length

The next native trial used `/Z7` and exited normally, but CMake's nested
`CMakeScratch/TryCompile-*` object directory reached 281 characters. CMake warned
that its maximum safe object path was 250 characters. MSVC then reported C1083
with an invalid file argument. The logs remain under
`F:\Temp\rustbxl-modeling-20261116\verified`.

The integration configuration now uses shorter logical source and target roots,
and the final run uses the shorter Windows-local root `F:\Temp\rbm1116b`. The
logical target still exceeds the longest physical instance target, as required
by cache RPC placement. The fixture keeps native outputs inside `OUT_DIR` and
retains normal CMake compiler checks. Production defaults are unchanged; native
projects with deep generated paths need a short state root and suitable logical
namespaces before capture.

## Absent environment variables became empty values

The short-path run passed the native and Git invalidation cases, but its final
feature comparison failed. The Cargo oracle still enabled Git and CMake after
their configuration flags were removed. On the tested PowerShell 7.6.4/.NET 9
runtime, these calls bind a PowerShell null as an empty string:

```powershell
[Environment]::SetEnvironmentVariable($entry.Key, $null)
[Environment]::SetEnvironmentVariable($key, $saved[$key])
```

The first call left the variable present. The second did the same when a saved
value was null. Rust's `var_os` therefore returned `Some("")` for flags that should
have been absent. This was a process-environment restoration defect, rather than
a stale BuildXL result. Capture in a fresh CLI process had the correct absent
flags; the long-lived Cargo oracle process had leaked empty flags.

`Invoke-WithEnvironment` now supplies `[NullString]::Value` for a missing value,
which passes a CLR null to the API. A retained integration check covers absent,
empty, and existing values, explicit removal, nested calls, ambient Cargo
overrides, and exception cleanup. The final suite passed all 26 cases from an
empty state, including the feature comparison that exposed this defect.
The failed comparison is retained under `F:\Temp\rbm1116`.

## Documentation patch

One documentation patch expected `build scripts.` where the file contained
`scripts.`. Patch validation rejected it before changing files. A scoped read
supplied the correct context, and the next patch applied.

No dependency installation, proxy change, source generation, or instruction
exception was required for these changes. All builds ran through Windows-local
paths with native Windows tools. The dependency graph was not trimmed.
