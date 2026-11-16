# Replay optimization integration issues

The maintained implementation received .NET Cargo-file enumeration and replay
incremental scheduling. Discovery keeps incremental scheduling disabled. The
generator, frontend, and dependency declarations were unchanged. No temporary
performance switches, graph trimming, or experimental large-project adapter
changes were copied into the implementation.

The helper built successfully. All 18 integration cases, 505 Win32 argument
checks, 22 actual BuildXL argument arrays, and the three large-worktree scanner
content comparisons passed. The cache service exited normally. No active sandbox
tree was terminated. There were no new matching startup popup events.

Two intermediate diagnostic reads needed correction:

- `jq -r '.[] | [.case, (.details.processExecuted // "-")] | @tsv' /mnt/f/Temp/rustbxl-merge-20261116/integration/results.json`
  assumed all detail records were objects; some are counts or arrays. A type
  check corrected the diagnostic. Integration result data was unchanged.
- `rg -n 'ProcessesSkippedByIncrementalScheduling=|TimeToFirstPip' '/mnt/f/Temp/rustbxl-merge-20261116/integration/sidecar state/instances/beta/run/logs/BuildXL.stats' | head -8`
  ran while the next client was creating its log directory. The final statistics
  file had not yet been written. The completed run supplied the counters.

A diagnostic `rg -n 'Failed|error|error:' .../parallel-*.log --max-count 2`
returned exit code 1 because there were no matches. This is the expected search
status. No PowerShell, dependency, or network errors required a workaround.

The earlier 0xc0000142 investigation linked the popups to termination of active
sandbox trees. The integration harness previously called
`Process.Kill(true)` on timeout and failure cleanup. It now retains timed-out
clients, waits for them to exit, and then stops the cache. This preserves the
lifecycle used in the successful follow-up experiments.
