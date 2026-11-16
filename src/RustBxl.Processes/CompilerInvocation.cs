namespace RustBxl.Processes;

internal static class CompilerInvocation
{
    public static bool IsBuildScriptProbe(IReadOnlyList<string> arguments, string workingDirectory)
    {
        var output = Environment.GetEnvironmentVariable("OUT_DIR");
        if (output is null) return false;
        var index = arguments.ToList().IndexOf("--out-dir");
        var directory = index >= 0 ? arguments[index + 1]
            : arguments.FirstOrDefault(argument => argument.StartsWith("--out-dir=", StringComparison.Ordinal))?[10..];
        var path = Path.GetFullPath(directory ?? workingDirectory, workingDirectory).TrimEnd('\\');
        var root = Path.GetFullPath(output, workingDirectory).TrimEnd('\\');
        return path.Equals(root, StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
    }
}
