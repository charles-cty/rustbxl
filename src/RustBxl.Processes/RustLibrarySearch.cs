using System.Text.RegularExpressions;

namespace RustBxl.Processes;

internal static class RustLibrarySearch
{
    private static readonly Regex CargoLibrary = new(@"^(?<stem>[a-z0-9_]+)-[0-9a-f]{16}\.(?<extension>rlib|rmeta|dll)$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex CrateName = new(@"^[a-z0-9_]+$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static IEnumerable<string> Options(string[] arguments, string name)
    {
        for (var index = 0; index < arguments.Length; index++)
        {
            var argument = arguments[index];
            if (argument == name) yield return arguments[++index];
            else if (argument.StartsWith(name + "=", StringComparison.Ordinal)) yield return argument[(name.Length + 1)..];
            else if (name == "-L" && argument.StartsWith(name, StringComparison.Ordinal)) yield return argument[name.Length..];
        }
    }

    public static HashSet<string> CargoDirectories(Invocation invocation, string target)
    {
        var paths = Options(invocation.Arguments, "-L").Select(value =>
        {
            var parts = value.Split('=', 2);
            var kind = parts.Length == 2 && parts[0] is "all" or "native" or "crate" or "dependency" or "framework"
                ? parts[0] : null;
            var path = kind is null ? value : parts[1];
            return (Kind: kind, Path: Path.TrimEndingDirectorySeparator(Path.GetFullPath(path, invocation.WorkingDirectory)));
        }).ToLookup(path => path.Path, StringComparer.OrdinalIgnoreCase);
        return paths.Where(group => group.All(path => path.Kind == "dependency")
                && group.Key.StartsWith(target + "\\", StringComparison.OrdinalIgnoreCase)
                && Path.GetFileName(group.Key).Equals("deps", StringComparison.OrdinalIgnoreCase))
            .Select(group => group.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    public static string[]? CandidateNames(Invocation invocation, IEnumerable<string> observedPaths)
    {
        // Use the layout of the supported MSVC target. Custom targets and
        // unstable rustc options can use different crate search rules.
        if (Options(invocation.Arguments, "--target").Any(target => target != "x86_64-pc-windows-msvc")
            || invocation.Arguments.Any(argument => argument.StartsWith("-Z", StringComparison.Ordinal))) return null;

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "std", "core", "alloc", "test", "proc_macro", "compiler_builtins", "profiler_builtins", "panic_abort", "panic_unwind"
        };
        foreach (var external in Options(invocation.Arguments, "--extern"))
        {
            var name = external.Split('=', 2)[0].Split(':')[^1];
            if (!CrateName.IsMatch(name)) return null;
            names.Add(name);
        }
        foreach (var path in observedPaths)
        {
            var extension = Path.GetExtension(path).ToLowerInvariant();
            if (extension is not (".rlib" or ".rmeta" or ".dll")) continue;
            var file = Path.GetFileName(path);
            var artifact = CargoLibrary.Match(file);
            // Nonstandard library paths can carry a crate whose name cannot be
            // inferred from its filename. Keep the full listing in that case.
            if (!artifact.Success)
            {
                if (extension == ".dll") continue;
                return null;
            }
            var stem = artifact.Groups["stem"].Value;
            if (extension == ".dll") names.Add(stem);
            else if (stem.StartsWith("lib", StringComparison.OrdinalIgnoreCase)) names.Add(stem[3..]);
            else return null;
        }
        return names.Order(StringComparer.Ordinal).ToArray();
    }

    public static bool IsCandidate(string file, string[]? names)
    {
        if (names is null) return true;
        // These are the Windows crate locator's candidate formats. Match the
        // prefix even if the file has an unexpected or missing Cargo hash.
        var extension = Path.GetExtension(file).ToLowerInvariant();
        if (extension is ".dll" or ".lib")
            return names.Any(name => file.StartsWith(name, StringComparison.OrdinalIgnoreCase));
        if (extension is ".rlib" or ".rmeta" or ".rs" && file.StartsWith("lib", StringComparison.OrdinalIgnoreCase))
            return names.Any(name => file.AsSpan(3).StartsWith(name, StringComparison.OrdinalIgnoreCase));
        return false;
    }
}
