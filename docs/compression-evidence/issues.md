# Artifact compression implementation issues

All compression writes used disposable states under
`F:\Temp\rustbxl-compression-20261116`. Existing large-project cache states were
not compressed. The dependency graph and its declared inputs were unchanged.

- The diagnostic command
  `cat src/RustBxl.Processes/ArgumentChecks.cs | head -35` ran from the external
  experiment directory. A read from the repository directory resolved the path.
- The first `scripts\build.ps1` run failed CA1416 because ACL APIs require
  Windows. The compression class now declares its Windows platform and its
  entry point checks the operating system. Later builds passed with warnings
  treated as errors.
- `& compact.exe /C /I /Q $file` returned zero for a disposable file with
  BuildXL's write-deny ACL, but its compressed attribute remained absent. The
  helper uses `FSCTL_SET_COMPRESSION` and tests the resulting state, content,
  and ACL instead of using the compact exit code as evidence.
- The initial real-file test failed `Compression changed the immutable ACL.`
  A `FileSecurity` read from disk had no modified access section, so writing
  that same object did not restore the removed deny rule. The helper now loads
  the saved descriptor into a new object with the Access section selected.
  It restores through a handle that prevents file replacement, before it
  compresses data. Both successful compression and an exclusive-open failure
  preserve the original SDDL in the final integration tests. The failed test
  state was disposable; no existing cache ACL was changed.
- Independent allocation probes found that `GetCompressedFileSizeW` returns
  logical length for an uncompressed file, without cluster rounding. Reporting
  now uses `FileStandardInfo.AllocationSize`. The boundary test includes a
  65,537-byte file and requires its allocation to exceed its logical length.
- An inline PowerShell allocation probe failed because Bash consumed the
  single quotes in a PowerShell here-string. The original command was:

  ```bash
  pwsh.exe -WorkingDirectory 'F:\Temp\rustbxl-compression-20261116' -CommandWithArgs 'Set-StrictMode -Version 3.0; $ErrorActionPreference="Stop"; $code = @'
  using System;
  using System.Runtime.InteropServices;
  using Microsoft.Win32.SafeHandles;
  public static class AllocationProbe {
   [StructLayout(LayoutKind.Sequential)] public struct Standard { public long Allocation, Length; public uint Links; public byte Delete, Directory; }
   [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int kind, out Standard s, uint size);
   [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetCompressedFileSizeW(string p, out uint high);
   public static string Measure(string p) {
    using var h = System.IO.File.OpenHandle(p);
    if (!GetFileInformationByHandleEx(h, 1, out var s, 24)) throw new System.ComponentModel.Win32Exception();
    var low=GetCompressedFileSizeW(p,out var high);
    return $"{s.Length}\t{s.Allocation}\t{((long)high<<32)|low}\t{p}";
   }
  }
  '@; Add-Type -TypeDefinition $code; $files = @(Get-ChildItem -LiteralPath "F:\Temp\rustbxl-compression-20261116\final\state\cache\CompressionTest\Shared\VSO0\ABC" -File | Select-Object -First 5); $files += @(Get-ChildItem -LiteralPath "F:\Temp\rustbxl-compression-20261116\integration\sidecar state\cache" -Filter *.blob -Recurse -File | Select-Object -First 6); foreach ($file in $files) { [AllocationProbe]::Measure($file.FullName) }'
  ```

  PowerShell reported `Unrecognized token in source text`; Bash then reported
  `using: command not found` and a syntax error near `LayoutKind.Sequential`.
  The probe ran successfully after it was saved as `Probe-Allocation.ps1` and
  invoked with `-File`. No repository file or test fixture was changed by the
  failed invocation.

No active sandbox tree was terminated. Cache services were stopped through
`cache-stop` after clients exited. No dependency installation, proxy change,
network workaround, or instruction exception was required for this feature.
