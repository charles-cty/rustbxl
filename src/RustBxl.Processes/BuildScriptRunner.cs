using System.Diagnostics;
using System.Text.Json;

namespace RustBxl.Processes;

internal static class BuildScriptRunner
{
    internal sealed record MetadataInput(string Prefix, string Configuration);
    internal sealed record Plan(string Executable, string[] Arguments, MetadataInput[] Metadata);

    public static async Task<int> RunAsync(string planFile)
    {
        var plan = JsonSerializer.Deserialize<Plan>(File.ReadAllText(planFile))!;
        var start = new ProcessStartInfo(plan.Executable) { UseShellExecute = false };
        foreach (var argument in plan.Arguments) start.ArgumentList.Add(argument);
        foreach (var key in start.Environment.Keys.Where(key => key.StartsWith("DEP_", StringComparison.Ordinal)).ToArray())
            start.Environment.Remove(key);
        foreach (var input in plan.Metadata)
        {
            var directives = JsonSerializer.Deserialize<BuildScriptOutput.Directive[]>(File.ReadAllText(input.Configuration))!;
            foreach (var pair in BuildScriptOutput.MetadataValues(directives))
                start.Environment[input.Prefix + pair.Key] = pair.Value;
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start build script.");
        await process.WaitForExitAsync();
        return process.ExitCode;
    }
}
