namespace RustBxl.Processes;

public sealed record Invocation(string Executable, string[] Arguments, string WorkingDirectory,
    Dictionary<string, string> Environment);

internal static class CaptureEnvironment
{
    // Discovery starts with an explicit environment in BuildXL. Keep arbitrary
    // build-script rustc-env keys; exclude process-local sandbox and job handles.
    public static bool IsRelevant(string name) => !name.StartsWith("BUILDXL", StringComparison.OrdinalIgnoreCase)
        && !name.StartsWith("DETOURS", StringComparison.OrdinalIgnoreCase)
        && !name.StartsWith("DOMINO", StringComparison.OrdinalIgnoreCase)
        && !name.StartsWith("SIDECAR_", StringComparison.OrdinalIgnoreCase)
        && !new[] { "TEMP", "TMP", "TMPDIR", "RUSTC_WRAPPER", "CARGO_MAKEFLAGS", "MAKEFLAGS", "MFLAGS" }
            .Contains(name, StringComparer.OrdinalIgnoreCase);

    public static Dictionary<string, string> Read() => System.Environment.GetEnvironmentVariables()
        .Cast<System.Collections.DictionaryEntry>()
        .Where(entry => IsRelevant((string)entry.Key))
        .ToDictionary(entry => (string)entry.Key, entry => (string)entry.Value!, StringComparer.OrdinalIgnoreCase);
}
