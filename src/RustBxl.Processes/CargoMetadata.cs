using System.Text.Json;
using System.Text.Json.Serialization;

namespace RustBxl.Processes;

internal sealed class CargoMetadata
{
    private sealed record Package(string Id, [property: JsonPropertyName("manifest_path")] string ManifestPath, string? Links);
    private sealed record DependencyKind(string? Kind);
    private sealed record Dependency(string Pkg, [property: JsonPropertyName("dep_kinds")] DependencyKind[] Kinds);
    private sealed record ResolveNode(string Id, Dependency[] Deps);
    private sealed record Resolve(ResolveNode[] Nodes);
    private sealed record Document(Package[] Packages, Resolve Resolve);
    internal sealed record Input(string Prefix, Invocation Producer);

    private readonly Document document;
    private readonly Func<string, string> normalize;
    private readonly Func<string, string> physical;
    private readonly string logicalTarget;

    public CargoMetadata(string path, Func<string, string> normalize, Func<string, string> physical, string logicalTarget)
    {
        document = JsonSerializer.Deserialize<Document>(File.ReadAllText(path),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        this.normalize = normalize;
        this.physical = physical;
        this.logicalTarget = logicalTarget;
    }

    private Package PackageOf(Invocation invocation) => document.Packages.Single(package =>
        Path.GetDirectoryName(normalize(package.ManifestPath))!.Equals(
            invocation.Environment["CARGO_MANIFEST_DIR"], StringComparison.OrdinalIgnoreCase));

    public Input[] Dependencies(Invocation consumer, Invocation[] scripts)
    {
        var package = PackageOf(consumer);
        var resolved = document.Resolve.Nodes.Single(node => node.Id == package.Id);
        var inputs = new Dictionary<string, Input>(StringComparer.OrdinalIgnoreCase);
        foreach (var dependency in resolved.Deps)
        {
            // Cargo passes links metadata from normal dependencies to a package's
            // build script. Build dependencies are Rust libraries for the script.
            if (!dependency.Kinds.Any(kind => kind.Kind is null)) continue;
            var source = document.Packages.Single(candidate => candidate.Id == dependency.Pkg);
            if (source.Links is null) continue;
            var candidates = scripts.Where(script => PackageOf(script).Id == source.Id).ToArray();
            var expectedHost = IsHost(consumer);
            candidates = candidates.Where(script => IsHost(script) == expectedHost).ToArray();
            if (candidates.Length == 0) continue; // Dependency was not built in this capture's selected target graph.
            if (candidates.Length != 1)
                throw new NotSupportedException($"Ambiguous Cargo links producer for {source.Id}; capture needs a distinct dependency role.");
            var prefix = "DEP_" + BuildScriptOutput.MetadataName(source.Links) + "_";
            inputs.Add(prefix, new Input(prefix, candidates[0]));
        }
        var expected = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var input in inputs.Values)
        {
            var output = input.Producer.Environment["OUT_DIR"];
            var stdout = Path.Combine(Path.GetDirectoryName(output)!, "output");
            foreach (var value in BuildScriptOutput.MetadataValues(BuildScriptOutput.Read(physical(stdout))))
                expected.Add(input.Prefix + value.Key, normalize(value.Value));
        }
        var actual = consumer.Environment.Where(pair => pair.Key.StartsWith("DEP_", StringComparison.Ordinal))
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        if (expected.Count != actual.Count || expected.Any(pair => !actual.TryGetValue(pair.Key, out var value) || value != pair.Value))
            throw new NotSupportedException($"Captured Cargo links metadata does not match the resolved producers for {package.Id}.");
        return inputs.Values.OrderBy(input => input.Prefix, StringComparer.Ordinal).ToArray();
    }

    private bool IsHost(Invocation invocation)
    {
        var output = invocation.Environment["OUT_DIR"];
        var target = invocation.Environment["TARGET"];
        var relative = Path.GetRelativePath(logicalTarget, output);
        return !relative.Split(Path.DirectorySeparatorChar)[0].Equals(target, StringComparison.OrdinalIgnoreCase);
    }
}
