# Process startup error investigation

The four Application Popup events (System event 26, records 651084 through
651087) occurred at 2026-11-16 14:47:04.582 through 14:47:04.781, local time.
They name RustBxl.Processes.exe once and rustc.exe three times, with status
0xc0000142 (STATUS_DLL_INIT_FAILED).

The experiment's Stop-BuildXL-Trials.ps1 used Process.Kill(true) to terminate
three active sandbox driver trees at this time. The final discovery log writes
for those drivers are 14:47:02.795 (rust-analyzer) and 14:47:04.743 (Biome).
This is strong evidence that abrupt sandbox teardown triggered the startup
failures. The exact failing DLL and instruction have not been captured.

BuildXL's DetoursServices.cpp documents that a failed sandbox DLL attach returns
false from DllMain and prevents the injected process from loading. This supplies
a plausible mechanism, but the event alone cannot establish which DLL failed.
The .NET application exceptions from 14:32 and earlier use 0xe0434352 and have
separate graph-generation explanations. They are distinct from these popups.

The temporary stop script now rejects active clients. Normal build clients
must finish before cache services stop. No machine-wide dialog suppression,
registry debugger flags, or toolchain changes were applied.

Check-StartupStability.ps1 completed 80 compiler/helper launches, in batches of
eight concurrent processes, with zero nonzero exits and zero new Application
Popup events. Its detailed evidence is stability.json. The original rustbxl
integration suite passed all 14 cases through normal sandbox startup and shutdown,
including six concurrent worktrees, cache sharing, input invalidation, and feature
recapture. Final follow-up inspection at 15:20:02 local time found zero new matching
popup events and no remaining compiler, helper, BuildXL, or cache processes.
See follow-up.json and ../integration-startup-lifecycle/results.json.

The process startup symptom has been avoided with the corrected lifecycle.
This experiment does not claim an upstream BuildXL DLL initialization fix.

The four-worktree follow-up finished at 17:31 local time. All three large projects
passed equal-source, divergent, and restored concurrent builds. The updated
dependency-view generator also passed 14 integration cases. The event query at
17:31:38 found no new matching popups and no remaining compiler, helper, BuildXL,
or cache processes. All cache services exited normally before the independently
owned telemetry process was stopped. The final record is follow-up.json in the
retained experiment and startup-follow-up.json in the repository evidence copy.
