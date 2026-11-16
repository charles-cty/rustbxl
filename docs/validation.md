# Validation

The Windows integration suite runs with PowerShell 7, stable Rust, MSVC x64,
the BuildXL package selected by the configured checkout, and bindmount. Each
run has its own dependency store, engine download, local cache, repository,
and six Git worktrees. It uses the tools supplied on the command line.

The suite builds the .NET helper from source. It checks 505 Win32 argument
round trips and 22 argument arrays through the actual JSON frontend and
BuildXL process execution. It compares replay results with clean offline
Cargo builds and checks that existing Cargo targets and dependency sources
retain their contents.

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
- Integration cleanup now terminates test-owned pending clients before it
  stops the cache service after a failure.
- BuildXL's default output root created a temporary shared log junction beside
  the frontend. An explicit per-instance storage root now keeps this junction
  and other engine defaults inside the sidecar. Transient logs were removed
  from the Git index before the initial commit.
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
```

The first expression selected an unsuitable character overload. That source
rewrite workflow was removed. The second command resolved to the `cli` alias
for `Clear-Item`; the test helper is now `Invoke-Cli`. The third expression
formed multiple array elements; parentheses now group the newline expression.
The last probe assumed a hashed unit name; enumerating the captured unit
directories found the correct file.

An initial `rg` pattern, `AddProcess\\(`, had an unclosed group. Literal
searches now use `rg -F`. The command
`git diff --check --no-index -- /dev/null frontend\graph.dsc` returned the
normal nonzero status for a new file. Staging followed by `git diff --cached
--check` checks the project correctly.

The local cache service reports a missing certificate name while it starts
its local unencrypted gRPC endpoint. This is the selected local service mode.
No proxy or network workaround was required.
