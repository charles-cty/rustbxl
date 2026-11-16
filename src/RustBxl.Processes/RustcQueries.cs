using System.Text.Json;

namespace RustBxl.Processes;

internal static class RustcQueries
{
    internal sealed record Query(string[] Arguments, string Output);

    public static bool IsVersionQuery(Invocation invocation) =>
        Path.GetFileName(invocation.Executable).Equals("rustc.exe", StringComparison.OrdinalIgnoreCase)
        && invocation.Arguments is [var argument]
        && argument is "--version" or "-V" or "-vV";

    public static int Replay(string[] arguments, string map)
    {
        var queries = JsonSerializer.Deserialize<Query[]>(File.ReadAllText(map))!;
        var query = queries.SingleOrDefault(query => query.Arguments.SequenceEqual(arguments))
            ?? throw new InvalidOperationException(
                $"Uncaptured rustc query: {string.Join(" ", arguments)}. Capture the changed process graph.");
        using var stdout = Console.OpenStandardOutput();
        stdout.Write(File.ReadAllBytes(query.Output));
        return 0;
    }
}
