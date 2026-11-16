using System.Text.Json;
using System.Text.Json.Serialization;

namespace RustBxl.Processes;

// The wire format contains data only. The fixed BuildXL frontend owns pip creation.
internal sealed record ProcessGraph(int Version, IReadOnlyList<GraphNode> Nodes)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, JsonOptions));
}

internal sealed record GraphInput(string Kind, string Path, string? Producer = null, string? Directory = null);
internal sealed record GraphEnvironment(string Name, string Value, string[]? Paths = null);

internal sealed record GraphNode(string Id, string Kind)
{
    public GraphInput? Tool { get; init; }
    public string[] Arguments { get; init; } = [];
    public string? WorkingDirectory { get; init; }
    public string? TempDirectory { get; init; }
    public GraphEnvironment[] Environment { get; init; } = [];
    public GraphInput[] Dependencies { get; init; } = [];
    public string[] OutputDirectories { get; init; } = [];
    public string[] UntrackedFiles { get; init; } = [];
    public string? ConsoleOutput { get; init; }
    public string? TraceFile { get; init; }
    public bool DisableCacheLookup { get; init; }
    public GraphInput? Source { get; init; }
    public string? Destination { get; init; }
}
