using System.Diagnostics;
using System.Text.Json;

namespace RustBxl.Processes;

internal static class BuildScriptOutput
{
    internal sealed record Directive(string Name, string Value);
    internal sealed record Target(string Name, bool IsBinary, bool IsLibrary, bool IsCdylib, bool PackageHasLibrary);

    public static Directive[] Read(string path)
    {
        var result = new List<Directive>();
        foreach (var line in File.ReadLines(path))
        {
            var prefix = line.StartsWith("cargo::", StringComparison.Ordinal) ? 7
                : line.StartsWith("cargo:", StringComparison.Ordinal) ? 6 : 0;
            if (prefix == 0) continue;
            var separator = line.IndexOf('=', prefix);
            if (separator < 0) continue;
            var name = line[prefix..separator];
            var value = line[(separator + 1)..];
            if (name is "rerun-if-changed" or "rerun-if-env-changed") continue;
            if (name == "warning") { Console.Error.WriteLine("build script: " + value); continue; }
            if (name == "error") throw new InvalidOperationException("Build script error: " + value);
            if (name == "metadata" && prefix == 6)
            {
                result.Add(new Directive("metadata", "metadata=" + value));
                continue;
            }
            if (name is not ("metadata" or "rustc-env" or "rustc-cfg" or "rustc-check-cfg" or "rustc-flags"
                or "rustc-link-lib" or "rustc-link-search" or "rustc-link-arg" or "rustc-link-arg-bin"
                or "rustc-link-arg-bins" or "rustc-link-arg-cdylib" or "rustc-link-arg-tests"
                or "rustc-link-arg-examples" or "rustc-link-arg-benches"))
            {
                // Cargo interprets unknown single-colon keys as links metadata.
                if (prefix == 6) { result.Add(new Directive("metadata", name + "=" + value)); continue; }
                throw new NotSupportedException($"Unsupported Cargo build-script directive: {name}.");
            }
            result.Add(new Directive(name, value));
        }
        return result.ToArray();
    }

    public static void Prepare(string stdout, string configuration)
    {
        var directives = Read(stdout);
        Directory.CreateDirectory(Path.GetDirectoryName(configuration)!);
        File.WriteAllText(configuration, JsonSerializer.Serialize(directives));
    }

    public static Dictionary<string, string> EnvironmentValues(IEnumerable<Directive> directives)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var directive in directives.Where(directive => directive.Name == "rustc-env"))
        {
            var separator = directive.Value.IndexOf('=');
            if (separator < 1) throw new InvalidOperationException("Invalid Cargo rustc-env directive.");
            result[directive.Value[..separator]] = directive.Value[(separator + 1)..];
        }
        return result;
    }

    public static string MetadataName(string name) => name.Replace('-', '_').ToUpperInvariant();

    public static Dictionary<string, string> MetadataValues(IEnumerable<Directive> directives)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var directive in directives.Where(directive => directive.Name == "metadata"))
        {
            var separator = directive.Value.IndexOf('=');
            if (separator < 1) throw new InvalidOperationException("Invalid Cargo metadata directive.");
            result[MetadataName(directive.Value[..separator])] = directive.Value[(separator + 1)..];
        }
        return result;
    }

    public static string[] Arguments(IEnumerable<Directive> directives, Target target)
    {
        var result = new List<string>();
        void LinkArgument(string value) => result.AddRange(["-C", "link-arg=" + value]);
        foreach (var directive in directives)
        {
            var value = directive.Value;
            switch (directive.Name)
            {
                case "rustc-cfg": result.AddRange(["--cfg", value]); break;
                case "rustc-check-cfg": result.AddRange(["--check-cfg", value]); break;
                case "rustc-link-search": result.AddRange(["-L", value]); break;
                case "rustc-link-lib":
                    if (!target.PackageHasLibrary || target.IsLibrary) result.AddRange(["-l", value]);
                    break;
                case "rustc-flags":
                    var flags = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                    for (var index = 0; index < flags.Length; index++)
                    {
                        var flag = flags[index];
                        if (!flag.StartsWith("-L", StringComparison.Ordinal) && !flag.StartsWith("-l", StringComparison.Ordinal))
                            throw new InvalidOperationException("Cargo rustc-flags permits only -l and -L.");
                        var option = flag[..2];
                        var argument = flag.Length == 2 ? flags[++index] : flag[2..];
                        if (option == "-L" || !target.PackageHasLibrary || target.IsLibrary) result.AddRange([option, argument]);
                    }
                    break;
                case "rustc-link-arg": if (target.IsBinary || target.IsCdylib) LinkArgument(value); break;
                case "rustc-link-arg-bins": if (target.IsBinary) LinkArgument(value); break;
                case "rustc-link-arg-cdylib": if (target.IsCdylib) LinkArgument(value); break;
                case "rustc-link-arg-bin":
                    var separator = value.IndexOf('=');
                    if (separator < 1) throw new InvalidOperationException("Invalid Cargo rustc-link-arg-bin directive.");
                    if (target.IsBinary && value[..separator] == target.Name) LinkArgument(value[(separator + 1)..]);
                    break;
                // cargo build --workspace does not build tests, examples, or benches.
                case "rustc-link-arg-tests" or "rustc-link-arg-examples" or "rustc-link-arg-benches": break;
            }
        }
        return result.ToArray();
    }

    public static void RemoveCapturedArguments(List<string> arguments, string[] captured)
    {
        // Cargo appends build-script flags. Remove from the end to preserve an
        // equal flag supplied independently by the user's compiler configuration.
        for (var index = captured.Length - 2; index >= 0; index -= 2)
        {
            var position = arguments.Count - 2;
            while (position >= 0 && !(arguments[position] == captured[index] && arguments[position + 1] == captured[index + 1])) position--;
            if (position < 0) throw new InvalidOperationException($"Captured Cargo flag was not found: {captured[index]} {captured[index + 1]}.");
            arguments.RemoveRange(position, 2);
        }
    }

    public static async Task<int> CompileAsync(string targetFile, string configuration, string compiler, string[] arguments)
    {
        var target = JsonSerializer.Deserialize<Target>(File.ReadAllText(targetFile))!;
        var directives = JsonSerializer.Deserialize<Directive[]>(File.ReadAllText(configuration))!;
        var start = new ProcessStartInfo(compiler) { UseShellExecute = false };
        foreach (var argument in arguments.Concat(Arguments(directives, target))) start.ArgumentList.Add(argument);
        foreach (var pair in EnvironmentValues(directives)) start.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start rustc.");
        await process.WaitForExitAsync();
        return process.ExitCode;
    }
}
