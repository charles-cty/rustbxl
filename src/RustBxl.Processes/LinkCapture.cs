using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace RustBxl.Processes;

internal static class LinkCapture
{
    public static async Task<int> RunAsync(string[] arguments)
    {
        var staging = Environment.GetEnvironmentVariable("SIDECAR_STAGING")
            ?? throw new InvalidOperationException("SIDECAR_STAGING is required.");
        Directory.CreateDirectory(staging);
        var executable = Environment.GetEnvironmentVariable("SIDECAR_LINKER")
            ?? throw new InvalidOperationException("SIDECAR_LINKER is required.");
        var expanded = new List<string>();
        foreach (var argument in arguments)
        {
            if (argument.StartsWith('@')) expanded.AddRange(SplitResponseFile(File.ReadAllText(argument[1..])));
            else expanded.Add(argument);
        }
        for (var index = 0; index < expanded.Count; index++)
        {
            var value = expanded[index];
            var source = value.StartsWith("/DEF:", StringComparison.OrdinalIgnoreCase) ? value[5..] : value;
            var prefix = source == value ? "" : value[..5];
            if (!Path.IsPathFullyQualified(source) || !File.Exists(source)) continue;
            var parent = Path.GetFileName(Path.GetDirectoryName(source));
            var extension = Path.GetExtension(source);
            if (parent is null || !(parent.StartsWith("rustc", StringComparison.OrdinalIgnoreCase)
                || parent.StartsWith(".tmp", StringComparison.OrdinalIgnoreCase)
                || extension is ".o" or ".obj")) continue;
            // Export temporary linker inputs before rustc removes them.
            var destination = Path.Combine(staging, Path.GetFileName(source));
            File.Copy(source, destination, overwrite: true);
            expanded[index] = prefix + destination;
        }
        var invocation = new Invocation(executable, expanded.ToArray(), Environment.CurrentDirectory, CaptureEnvironment.Read());
        if (Environment.GetEnvironmentVariable("SIDECAR_SKIP_LINK") == "1")
        {
            var outputDirectory = Environment.GetEnvironmentVariable("SIDECAR_LINK_OUTPUT")
                ?? throw new InvalidOperationException("SIDECAR_LINK_OUTPUT is required.");
            var responseFile = Environment.GetEnvironmentVariable("SIDECAR_LINK_RESPONSE")
                ?? throw new InvalidOperationException("SIDECAR_LINK_RESPONSE is required.");
            for (var index = 0; index < expanded.Count; index++)
            {
                foreach (var prefix in new[] { "/OUT:", "/PDB:", "/IMPLIB:" })
                    if (expanded[index].StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                        expanded[index] = prefix + Path.Combine(outputDirectory, Path.GetFileName(expanded[index][prefix.Length..]));
            }
            // link.exe consumes this compiler output in a separate process pip.
            // UTF-16 with BOM preserves Unicode paths in MSVC response files.
            await File.WriteAllTextAsync(responseFile, string.Join("\r\n", expanded.Select(DebugCapture.Quote)), new UnicodeEncoding(false, true));
            return 0;
        }
        await File.WriteAllTextAsync(Path.Combine(staging, "link.json"), JsonSerializer.Serialize(invocation));
        var captureResponse = Path.Combine(staging, "captured-link.rsp");
        await File.WriteAllTextAsync(captureResponse, string.Join("\r\n", expanded.Select(DebugCapture.Quote)), new UnicodeEncoding(false, true));
        var startInfo = new ProcessStartInfo(executable) { UseShellExecute = false };
        startInfo.ArgumentList.Add("@" + captureResponse);
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Cannot start the linker.");
        await process.WaitForExitAsync();
        return process.ExitCode;
    }

    private static string[] SplitResponseFile(string content)
    {
        // CommandLineToArgvW recognizes spaces and tabs. MSVC response files
        // also use line breaks between arguments. Preserve quoted characters.
        var line = new StringBuilder();
        var quoted = false;
        var slashes = 0;
        foreach (var character in content)
        {
            if (character == '"' && slashes % 2 == 0) quoted = !quoted;
            line.Append(!quoted && character is '\r' or '\n' ? ' ' : character);
            slashes = character == '\\' ? slashes + 1 : 0;
        }
        return DebugCapture.SplitCommandLine("link " + line)[1..];
    }
}
