using System.Text.Json;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Text;

namespace RustBxl.Processes;

internal static class GraphGenerator
{
    private sealed record ObservedProcess(uint Id, string Executable, uint Parent);
    private sealed record Access(uint Process, string Path, int Requested, int Error, string Operation);
    private sealed record ProcessSnapshot(uint ProcessId, Invocation Invocation);
    private sealed class Node(string name, Invocation invocation)
    {
        public string Name { get; } = name;
        public Invocation Invocation { get; } = invocation;
        public HashSet<uint> Processes { get; } = [];
        public HashSet<string> Outputs { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Reads { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<Node> Dependencies { get; } = [];
        public string? Staging { get; set; }
        public bool IsBuildScript => Name.StartsWith("run-", StringComparison.Ordinal);
    }

    public static void Generate(string worktree, string state, string workspace, string physicalTarget, string logicalTarget)
    {
        var actualRoot = Path.GetFullPath(worktree).TrimEnd('\\');
        workspace = Path.GetFullPath(workspace).TrimEnd('\\');
        physicalTarget = Path.GetFullPath(physicalTarget).TrimEnd('\\');
        logicalTarget = Path.GetFullPath(logicalTarget).TrimEnd('\\');
        static string ReplaceRoot(string value, string root, string replacement) =>
            Regex.Replace(value, Regex.Escape(root) + @"(?=$|[\\/;=\s""])", _ => replacement, RegexOptions.IgnoreCase);
        string Normalize(string value) => ReplaceRoot(ReplaceRoot(value, physicalTarget, logicalTarget), actualRoot, workspace);
        bool Under(string value, string root) => value.Equals(root, StringComparison.OrdinalIgnoreCase)
            || value.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
        string Physical(string value) => Under(value, workspace)
            ? Path.Combine(actualRoot, value[workspace.Length..].TrimStart('\\'))
            : Under(value, logicalTarget)
                ? Path.Combine(physicalTarget, value[logicalTarget.Length..].TrimStart('\\')) : value;
        Invocation NormalizeInvocation(Invocation invocation) => new(Normalize(invocation.Executable),
            invocation.Arguments.Select(Normalize).ToArray(), Normalize(invocation.WorkingDirectory),
            invocation.Environment.ToDictionary(pair => pair.Key, pair => Normalize(pair.Value), StringComparer.OrdinalIgnoreCase));
        var snapshots = File.ReadLines(Path.Combine(state, "capture", "processes.jsonl"))
            .Select(line => JsonSerializer.Deserialize<ProcessSnapshot>(line)!).ToArray();
        var (processes, accesses) = ReadTrace(Path.Combine(state, "capture-trace.txt"));
        accesses = accesses.Select(access => access with { Path = Normalize(access.Path) }).ToList();
        var nodes = new List<Node>();
        var compilerByPid = new Dictionary<uint, Node>();
        var scripts = new Dictionary<uint, Node>();
        foreach (var snapshot in snapshots.Where(snapshot => Path.GetFileName(snapshot.Invocation.Executable)
            .StartsWith("build-script-", StringComparison.OrdinalIgnoreCase)))
        {
            var invocation = NormalizeInvocation(snapshot.Invocation);
            var identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(invocation.Environment["OUT_DIR"])))[..12];
            var node = new Node("run-" + Path.GetFileName(Path.GetDirectoryName(invocation.Executable)) + "-" + identity, invocation);
            node.Processes.Add(snapshot.ProcessId);
            scripts.Add(snapshot.ProcessId, node);
            nodes.Add(node);
        }
        Node? ScriptOwner(uint processId)
        {
            while (processes.TryGetValue(processId, out var process))
            {
                if (scripts.TryGetValue(processId, out var script)) return script;
                processId = process.Parent;
            }
            return null;
        }
        foreach (var process in processes.Values)
            ScriptOwner(process.Id)?.Processes.Add(process.Id);
        foreach (var file in Directory.GetFiles(Path.Combine(state, "capture", "units"), "rustc.json", SearchOption.AllDirectories).Order())
        {
            var invocation = NormalizeInvocation(JsonSerializer.Deserialize<Invocation>(File.ReadAllText(file))!);
            var unit = Path.GetFileName(Path.GetDirectoryName(file))!;
            var snapshot = snapshots.Single(snapshot => Path.GetFileName(snapshot.Invocation.Executable) == "rustc.exe"
                && Unit(snapshot.Invocation.Arguments) == unit);
            if (ScriptOwner(snapshot.ProcessId) is not null) continue;
            var node = new Node(unit, invocation);
            node.Processes.Add(snapshot.ProcessId);
            compilerByPid.Add(snapshot.ProcessId, node);
            nodes.Add(node);
        }
        foreach (var process in processes.Values.Where(process => Path.GetFileName(process.Executable) == "LinkerRecorder.exe"))
        {
            if (ScriptOwner(process.Id) is not null) continue;
            var compiler = compilerByPid[process.Parent];
            compiler.Processes.Add(process.Id);
            var linker = processes.Values.Single(child => child.Parent == process.Id && Path.GetFileName(child.Executable) == "link.exe");
            var output = compiler.Invocation.Arguments[Array.IndexOf(compiler.Invocation.Arguments, "--out-dir") + 1];
            var linkRecord = Path.Combine(Physical(output), ".sidecar", compiler.Name, "link.json");
            var invocation = NormalizeInvocation(JsonSerializer.Deserialize<Invocation>(File.ReadAllText(linkRecord))!);
            var node = new Node(compiler.Name + "-link", invocation);
            node.Processes.Add(linker.Id);
            node.Dependencies.Add(compiler);
            compiler.Staging = invocation.Arguments.Select(value => value.StartsWith("/DEF:", StringComparison.OrdinalIgnoreCase) ? value[5..] : value)
                .Where(value => value.Contains("\\.sidecar\\", StringComparison.OrdinalIgnoreCase)).Select(Path.GetDirectoryName).First()!;
            nodes.Add(node);
        }
        var metadata = new CargoMetadata(Path.Combine(state, "capture", "cargo-metadata.json"), Normalize, Physical, logicalTarget);
        var metadataDependencies = scripts.Values.ToDictionary(script => script,
            script => metadata.Dependencies(script.Invocation, scripts.Values.Select(value => value.Invocation).ToArray()));
        foreach (var script in scripts.Values)
            foreach (var input in metadataDependencies[script])
                script.Dependencies.Add(scripts.Values.Single(candidate => candidate.Invocation == input.Producer));
        var owners = nodes.SelectMany(node => node.Processes.Select(pid => (pid, node))).ToDictionary(pair => pair.pid, pair => pair.node);
        foreach (var compiler in compilerByPid.Values)
        {
            if (!compiler.Invocation.Environment.TryGetValue("OUT_DIR", out var outputDirectory)) continue;
            var buildScript = nodes.Single(node => node.Name.StartsWith("run-", StringComparison.Ordinal)
                && node.Invocation.Environment.GetValueOrDefault("OUT_DIR") == outputDirectory);
            compiler.Dependencies.Add(buildScript);
        }
        foreach (var process in processes.Values)
        {
            if (owners.ContainsKey(process.Id)) continue;
            if (owners.ContainsKey(process.Parent))
                throw new InvalidOperationException($"Unmodeled child {process.Executable}; capture requires a process adapter.");
        }
        foreach (var access in accesses)
        {
            if (!owners.TryGetValue(access.Process, out var owner)) continue;
            if ((access.Requested & 2) != 0 && access.Error == 0 && Under(access.Path, logicalTarget)
                && File.Exists(Physical(access.Path)) && !access.Path.EndsWith("link.json", StringComparison.OrdinalIgnoreCase))
                owner.Outputs.Add(access.Path);
            if ((access.Requested & (1 | 4 | 8 | 16)) != 0) owner.Reads.Add(access.Path);
        }
        // Cargo creates executable aliases with hard links. Preserve their names with
        // BuildXL copy pips, after independently checking their file contents.
        foreach (var linker in nodes.Where(node => node.Name.EndsWith("-link", StringComparison.Ordinal)))
        {
            var compiler = linker.Dependencies.Single();
            compiler.Outputs.ExceptWith(linker.Outputs);
            compiler.Reads.ExceptWith(linker.Outputs);
        }
        foreach (var compiler in compilerByPid.Values)
        {
            compiler.Outputs.RemoveWhere(path => Path.GetExtension(path) == ".d");
            compiler.Reads.RemoveWhere(path => Path.GetExtension(path) == ".d");
        }
        var producers = new Dictionary<string, Node>(StringComparer.OrdinalIgnoreCase);
        foreach (var node in nodes)
        {
            foreach (var output in node.Outputs)
            {
                if (!producers.TryAdd(output, node))
                {
                    var detail = string.Join("; ", accesses.Where(access => access.Path.Equals(output, StringComparison.OrdinalIgnoreCase) && (access.Requested & 2) != 0)
                        .Select(access => $"{access.Process}/{access.Operation}/{access.Requested}/{access.Error}"));
                    throw new InvalidOperationException($"Multiple writers: {output} ({producers[output].Name}, {node.Name}); {detail}");
                }
            }
        }
        var aliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var node in nodes.Where(node => node.Name.StartsWith("run-", StringComparison.Ordinal)))
        {
            var alias = node.Invocation.Executable;
            if (producers.ContainsKey(alias)) continue;
            if (aliases.TryGetValue(alias, out var existing)) { node.Reads.Add(existing); continue; }
            var bytes = File.ReadAllBytes(Physical(alias));
            var original = producers.Keys.Single(path => path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                && Path.GetDirectoryName(path) == Path.GetDirectoryName(alias)
                && File.ReadAllBytes(Physical(path)).AsSpan().SequenceEqual(bytes));
            aliases.Add(alias, original);
            node.Reads.Add(original);
        }
        foreach (var node in nodes)
        {
            foreach (var read in node.Reads.Append(node.Invocation.Executable))
            {
                var path = aliases.GetValueOrDefault(read, read);
                if (producers.TryGetValue(path, out var producer) && producer != node) node.Dependencies.Add(producer);
                else if (Under(path, logicalTarget) && File.Exists(Physical(path))
                    && !node.Outputs.Contains(path) && !path.EndsWith("link.json", StringComparison.OrdinalIgnoreCase)
                    && !Directory.Exists(Physical(path)))
                    throw new InvalidOperationException($"Missing producer for {path}, read by {node.Name}. Recapture is required.");
            }
        }
        var ordered = new List<Node>();
        var pending = nodes.ToHashSet();
        while (pending.Count > 0)
        {
            var ready = pending.Where(node => node.Dependencies.All(ordered.Contains)).OrderBy(node => node.Name).ToArray();
            if (ready.Length == 0) throw new InvalidOperationException("Observed graph contains a dependency cycle.");
            ordered.AddRange(ready);
            pending.ExceptWith(ready);
        }
        var directory = Path.Combine(state, "replay");
        Directory.CreateDirectory(directory);
        var compilerDirectories = compilerByPid.Values.ToDictionary(node => node,
            node => Path.Combine(logicalTarget, ".sidecar", "compile", node.Name));
        var outputDirectories = nodes.ToDictionary(node => node, node => compilerDirectories.GetValueOrDefault(node,
            node.Name.StartsWith("run-", StringComparison.Ordinal) ? node.Invocation.Environment["OUT_DIR"]
                : Path.Combine(logicalTarget, ".sidecar", "link", node.Name)));
        var relocatedFiles = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var compiler in compilerDirectories.Keys)
        {
            var originalDirectory = compiler.Invocation.Arguments[Array.IndexOf(compiler.Invocation.Arguments, "--out-dir") + 1];
            foreach (var output in compiler.Outputs)
                relocatedFiles.Add(output, Path.Combine(compilerDirectories[compiler], Path.GetRelativePath(originalDirectory, output)));
            if (compiler.Staging is not null)
                relocatedFiles[compiler.Staging] = Path.Combine(compilerDirectories[compiler], Path.GetRelativePath(originalDirectory, compiler.Staging));
        }
        foreach (var node in nodes.Where(node => !compilerDirectories.ContainsKey(node)))
        {
            foreach (var output in node.Outputs)
                if (!node.Name.StartsWith("run-", StringComparison.Ordinal))
                    relocatedFiles.Add(output, Path.Combine(outputDirectories[node], Path.GetFileName(output)));
        }
        string Relocate(string value)
        {
            foreach (var pair in relocatedFiles.OrderByDescending(pair => pair.Key.Length))
                value = Regex.Replace(value, Regex.Escape(pair.Key) + @"(?=$|[\\;=\s])", _ => pair.Value, RegexOptions.IgnoreCase);
            return value;
        }
        var graph = new List<GraphNode>();
        GraphInput FileReference(Node node, string path) => new("file", Relocate(path), node.Name, outputDirectories[node]);
        GraphInput DependencyReference(Node node) => new("directory", outputDirectories[node], node.Name);
        var emittedAliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var configurationPips = new Dictionary<Node, string>();
        var configurationDirectories = new Dictionary<Node, string>();
        foreach (var node in ordered)
        {
            if (aliases.TryGetValue(node.Invocation.Executable, out var original) && !emittedAliases.ContainsKey(node.Invocation.Executable))
            {
                var aliasName = "alias" + emittedAliases.Count;
                graph.Add(new GraphNode(aliasName, "copy")
                {
                    Source = FileReference(producers[original], original),
                    Destination = node.Invocation.Executable
                });
                emittedAliases.Add(node.Invocation.Executable, aliasName);
            }
            var invocation = node.Invocation;
            var arguments = invocation.Arguments.Select(Relocate).ToList();
            var environment = new Dictionary<string, string>(invocation.Environment, StringComparer.OrdinalIgnoreCase);
            var transitive = new HashSet<Node>();
            void Visit(Node dependency)
            {
                if (!transitive.Add(dependency)) return;
                foreach (var predecessor in dependency.Dependencies) Visit(predecessor);
            }
            foreach (var dependency in node.Dependencies) Visit(dependency);
            var extraDependencies = new List<GraphInput>();
            string? compilerTool = null;
            if (compilerDirectories.TryGetValue(node, out var compilerDirectory))
            {
                for (var index = 0; index < arguments.Count; index++)
                    if (arguments[index].StartsWith("--emit="))
                        arguments[index] = "--emit=" + string.Join(",", arguments[index][7..].Split(',').Where(value => value != "dep-info"));
                arguments[arguments.IndexOf("--out-dir") + 1] = compilerDirectory;
                foreach (var dependency in transitive.Where(compilerDirectories.ContainsKey).OrderBy(dependency => dependency.Name))
                    arguments.AddRange(["-L", "dependency=" + compilerDirectories[dependency]]);
                if (invocation.Environment.TryGetValue("OUT_DIR", out var outputDirectory))
                {
                    var buildScript = node.Dependencies.Single(dependency => dependency.Name.StartsWith("run-", StringComparison.Ordinal)
                        && dependency.Invocation.Environment.GetValueOrDefault("OUT_DIR") == outputDirectory);
                    var crateType = invocation.Arguments[Array.IndexOf(invocation.Arguments, "--crate-type") + 1];
                    var packageHasLibrary = compilerDirectories.Keys.Any(candidate =>
                        candidate.Invocation.Environment.GetValueOrDefault("CARGO_MANIFEST_DIR") == invocation.Environment["CARGO_MANIFEST_DIR"]
                        && candidate.Invocation.Arguments[Array.IndexOf(candidate.Invocation.Arguments, "--crate-type") + 1] != "bin");
                    var target = new BuildScriptOutput.Target(invocation.Environment.GetValueOrDefault("CARGO_BIN_NAME",
                        invocation.Environment["CARGO_CRATE_NAME"]), crateType == "bin", crateType != "bin", crateType == "cdylib", packageHasLibrary);
                    var stdout = Path.Combine(Path.GetDirectoryName(Physical(outputDirectory))!, "output");
                    var captured = BuildScriptOutput.Read(stdout).Select(directive => directive with { Value = Normalize(directive.Value) }).ToArray();
                    BuildScriptOutput.RemoveCapturedArguments(arguments, BuildScriptOutput.Arguments(captured, target).Select(Relocate).ToArray());
                    foreach (var key in BuildScriptOutput.EnvironmentValues(captured).Keys)
                    {
                        environment.Remove(key);
                        if (buildScript.Invocation.Environment.TryGetValue(key, out var fallback)) environment[key] = fallback;
                    }
                    var plans = Path.Combine(state, "compiler-plans");
                    Directory.CreateDirectory(plans);
                    var plan = Path.Combine(plans, node.Name + ".json");
                    File.WriteAllText(plan, JsonSerializer.Serialize(target));
                    extraDependencies.Add(new("file", plan));
                    extraDependencies.Add(new("file", invocation.Executable));
                    arguments.InsertRange(0, ["replay-rustc", plan,
                        Path.Combine(configurationDirectories[buildScript], "config.json"), invocation.Executable]);
                    compilerTool = Path.Combine(AppContext.BaseDirectory, "RustBxl.Processes.exe");
                }
            }
            if (compilerByPid.Values.Contains(node) && node.Staging is not null)
            {
                var linker = nodes.Single(candidate => candidate.Name == node.Name + "-link");
                arguments.AddRange(["-C", "linker=" + Path.Combine(AppContext.BaseDirectory, "LinkerRecorder.exe")]);
                environment["SIDECAR_SKIP_LINK"] = "1";
                environment["SIDECAR_STAGING"] = Relocate(node.Staging);
                environment["SIDECAR_LINKER"] = "deferred-to-independent-pip";
                environment["SIDECAR_LINK_OUTPUT"] = outputDirectories[linker];
                environment["SIDECAR_LINK_RESPONSE"] = Path.Combine(compilerDirectories[node], "link.rsp");
            }
            if (node.Name.EndsWith("-link", StringComparison.Ordinal))
            {
                var compiler = compilerDirectories.Keys.Single(candidate => candidate.Name + "-link" == node.Name);
                arguments = ["@" + Path.Combine(compilerDirectories[compiler], "link.rsp")];
            }
            if (node.IsBuildScript)
            {
                var inputs = metadataDependencies[node].Select(input =>
                {
                    var producer = scripts.Values.Single(candidate => candidate.Invocation == input.Producer);
                    return new BuildScriptRunner.MetadataInput(input.Prefix,
                        Path.Combine(configurationDirectories[producer], "config.json"));
                }).ToArray();
                var plans = Path.Combine(state, "build-script-plans");
                Directory.CreateDirectory(plans);
                var plan = Path.Combine(plans, node.Name + ".json");
                File.WriteAllText(plan, JsonSerializer.Serialize(new BuildScriptRunner.Plan(
                    Relocate(invocation.Executable), arguments.ToArray(), inputs)));
                extraDependencies.Add(new("file", plan));
                extraDependencies.Add(emittedAliases.TryGetValue(invocation.Executable, out var executableAlias)
                    ? new("file", invocation.Executable, executableAlias)
                    : FileReference(producers[invocation.Executable], invocation.Executable));
                compilerTool = Path.Combine(AppContext.BaseDirectory, "RustBxl.Processes.exe");
                arguments = ["run-build-script", plan];
                foreach (var key in environment.Keys.Where(key => key.StartsWith("DEP_", StringComparison.Ordinal)).ToArray())
                    environment.Remove(key);
            }
            var dependencies = transitive.Select(DependencyReference).ToList();
            foreach (var dependency in transitive.Where(configurationPips.ContainsKey))
                dependencies.Add(new("directory", configurationDirectories[dependency], configurationPips[dependency]));
            dependencies.AddRange(extraDependencies);
            var executable = compilerTool ?? invocation.Executable;
            GraphInput tool;
            if (compilerTool is not null) tool = new("file", executable);
            else if (emittedAliases.TryGetValue(invocation.Executable, out var aliasId))
                tool = new("file", executable, aliasId);
            else if (producers.TryGetValue(invocation.Executable, out var toolProducer))
                tool = FileReference(toolProducer, invocation.Executable);
            else tool = new("file", executable);

            var transcript = Path.Combine(logicalTarget, ".sidecar", "build-script-stdout", node.Name, "stdout.txt");
            graph.Add(new GraphNode(node.Name, "process")
            {
                Tool = tool,
                Arguments = arguments.ToArray(),
                WorkingDirectory = invocation.WorkingDirectory,
                TempDirectory = Path.Combine(logicalTarget, ".sidecar", "temp", node.Name),
                Environment = environment.OrderBy(pair => pair.Key).Select(pair =>
                    new GraphEnvironment(pair.Key, pair.Value,
                        new[] { "PATH", "LIB", "INCLUDE", "LIBPATH" }.Contains(pair.Key, StringComparer.OrdinalIgnoreCase)
                            ? pair.Value.Split(';', StringSplitOptions.RemoveEmptyEntries) : null)).ToArray(),
                Dependencies = dependencies.ToArray(),
                OutputDirectories = [outputDirectories[node]],
                ConsoleOutput = node.IsBuildScript ? transcript : null
            });
            if (node.Name.StartsWith("run-", StringComparison.Ordinal))
            {
                var configuration = "prepare-" + node.Name;
                var configurationDirectory = Path.Combine(logicalTarget, ".sidecar", "build-script-config", node.Name);
                configurationPips.Add(node, configuration);
                configurationDirectories.Add(node, configurationDirectory);
                graph.Add(new GraphNode(configuration, "process")
                {
                    Tool = new("file", Path.Combine(AppContext.BaseDirectory, "RustBxl.Processes.exe")),
                    WorkingDirectory = workspace,
                    Arguments = ["prepare-build-script", transcript, Path.Combine(configurationDirectory, "config.json")],
                    Dependencies = [new("file", transcript, node.Name)],
                    OutputDirectories = [configurationDirectory],
                    Environment = [new("SystemRoot", Environment.GetEnvironmentVariable("SystemRoot")!)],
                    TempDirectory = Path.Combine(logicalTarget, ".sidecar", "temp", configuration)
                });
            }
        }
        var binaryIndex = 0;
        foreach (var line in File.ReadLines(Path.Combine(state, "capture", "cargo-messages.jsonl")))
        {
            using var message = JsonDocument.Parse(line);
            var root = message.RootElement;
            if (!root.TryGetProperty("reason", out var reason) || reason.GetString() != "compiler-artifact"
                || !root.TryGetProperty("executable", out var executable) || executable.ValueKind == JsonValueKind.Null) continue;
            var destination = Normalize(executable.GetString()!);
            var binary = File.ReadAllBytes(Physical(destination));
            var source = producers.Keys.Single(path => path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                && File.ReadAllBytes(Physical(path)).AsSpan().SequenceEqual(binary));
            if (!source.Equals(destination, StringComparison.OrdinalIgnoreCase))
                graph.Add(new GraphNode("executable" + binaryIndex++, "copy")
                {
                    Source = FileReference(producers[source], source), Destination = destination
                });
        }
        new ProcessGraph(1, graph).Save(Path.Combine(directory, "graph.json"));
        IEnumerable<string> GraphDependencies(Node node)
        {
            var predecessors = new HashSet<Node>();
            void Visit(Node dependency)
            {
                if (!predecessors.Add(dependency)) return;
                foreach (var parent in dependency.Dependencies) Visit(parent);
            }
            foreach (var dependency in node.Dependencies) Visit(dependency);
            return predecessors.Select(dependency => dependency.Name)
                .Concat(predecessors.Where(configurationPips.ContainsKey).Select(dependency => "prepare-" + dependency.Name)).Order();
        }
        var graphRecords = ordered.Select(node => new
        {
            node.Name, node.Invocation.Executable, node.Outputs,
            Dependencies = GraphDependencies(node),
            ObservedReads = node.Reads.Count
        }).Cast<object>().Concat(configurationPips.Keys.Select(node => (object)new
        {
            Name = "prepare-" + node.Name, Executable = Path.Combine(AppContext.BaseDirectory, "RustBxl.Processes.exe"),
            Outputs = new[] { Path.Combine(configurationDirectories[node], "config.json") },
            Dependencies = new[] { node.Name }, ObservedReads = 0
        }));
        File.WriteAllText(Path.Combine(state, "generated-graph.json"), JsonSerializer.Serialize(graphRecords, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"GRAPH\t{directory}\t{graph.Count(node => node.Kind == "process")} process pips\t{graph.Count(node => node.Kind == "copy")} copy pips");
    }

    private static string? Unit(string[] arguments)
    {
        var index = Array.IndexOf(arguments, "--crate-name");
        if (index < 0 || !arguments.Contains("--out-dir")) return null;
        return arguments[index + 1] + (arguments.FirstOrDefault(value => value.StartsWith("extra-filename="))?[15..] ?? "");
    }

    private static (Dictionary<uint, ObservedProcess>, List<Access>) ReadTrace(string file)
    {
        var lines = File.ReadAllLines(file);
        var index = 0;
        var version = int.Parse(lines[index++]);
        if (version != 3) throw new InvalidOperationException($"Unsupported BuildXL trace version {version}; update the trace adapter.");
        Dictionary<long, string> Mapping()
        {
            var count = int.Parse(lines[index++]);
            var result = new Dictionary<long, string>();
            for (var entry = 0; entry < count; entry++)
            {
                var line = lines[index++].Split('=', 2);
                result.Add(long.Parse(line[0]), line[1]);
            }
            return result;
        }
        var operations = Mapping();
        _ = Mapping();
        var processCount = int.Parse(lines[index++]);
        var processes = new Dictionary<uint, ObservedProcess>();
        for (var entry = 0; entry < processCount; entry++)
        {
            var match = Regex.Match(lines[index++], "^(\\d+),\"(.+)\",(\\d+),");
            if (!match.Success) throw new InvalidOperationException("Malformed process trace record.");
            var pid = uint.Parse(match.Groups[1].Value);
            if (!processes.TryAdd(pid, new ObservedProcess(pid, match.Groups[2].Value, uint.Parse(match.Groups[3].Value))))
                throw new InvalidOperationException($"Reused PID {pid} makes trace attribution ambiguous. Recapture is required with retained process handles.");
            index++; // The debugger snapshot contains the parsed command line.
        }
        var manifestPaths = Mapping();
        var paths = Mapping();
        var accessCount = int.Parse(lines[index++]);
        var accesses = new List<Access>();
        for (var entry = 0; entry < accessCount; entry++)
        {
            var fields = lines[index++].Split(',');
            var path = fields[2].Length > 0 ? manifestPaths[long.Parse(fields[2])] : paths[long.Parse(fields[3])];
            accesses.Add(new Access(uint.Parse(fields[1]), path, int.Parse(fields[5]), int.Parse(fields[6]), operations[long.Parse(fields[4])]));
        }
        return (processes, accesses);
    }
}
