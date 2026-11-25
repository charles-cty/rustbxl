using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace RustBxl.Processes;

internal static class DiscoveryCache
{
    internal sealed record Access(uint Process, string Path, int Requested, int Error, string Operation, string Filter,
        uint Attributes = uint.MaxValue);
    internal sealed record Input(string Path, string Kind, string Value, string[]? CandidateNames = null);
    internal sealed record Entry(string Key, string[] Outputs, string[] Reads, Input[] Inputs);

    public const string ArchiveName = "next.zip";
    private const string IndexName = "entry-v2.json";
    private const string StdoutName = "stdout.bin";
    private const string StderrName = "stderr.bin";

    public static bool IsLibrary(Invocation invocation)
    {
        var arguments = invocation.Arguments;
        var crateTypes = arguments.Select((argument, index) => (argument, index))
            .Where(item => item.argument == "--crate-type").Select(item => arguments[item.index + 1]).ToArray();
        return crateTypes is ["lib" or "rlib"]
            && arguments.Contains("--emit=dep-info,metadata,link")
            && !arguments.Any(argument => argument.StartsWith('@')
                || argument.StartsWith("--crate-type=", StringComparison.Ordinal)
                || argument.StartsWith("incremental=", StringComparison.Ordinal)
                || argument.Equals("target-cpu=native", StringComparison.Ordinal)
                || argument.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
    }

    private static string[] ArtifactNames(string unit) => [unit + ".d", "lib" + unit + ".rlib", "lib" + unit + ".rmeta"];

    private static string Key(Invocation invocation) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(
        invocation with { Environment = invocation.Environment.OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .ToDictionary(pair => pair.Key, pair => pair.Value) })));

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static bool Under(string path, string directory) => path.Equals(directory, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(directory.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);

    private static string Member(string name, FileAttributes attributes) =>
        $"{name}:{attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)}";

    private static string FileState(string path, bool read, DateTime? before = null)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new IOException($"Reparse point: {path}");
            if ((attributes & FileAttributes.Directory) != 0) return "directory";
            if (before is not null && File.GetLastWriteTimeUtc(path) > before)
                throw new IOException($"Input changed during discovery: {path}");
            return read ? "file:" + HashFile(path) : "file";
        }
        catch (FileNotFoundException) { return "absent"; }
        catch (DirectoryNotFoundException) { return "absent"; }
    }

    private static string DirectoryState(IEnumerable<string> entries) =>
        Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(
            entries.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray())));

    private static bool Matches(Input input) => input.Value == (input.Kind switch
    {
        "read" => FileState(input.Path, read: true),
        "probe" => FileState(input.Path, read: false),
        "enumerate" => DirectoryState(new DirectoryInfo(input.Path).EnumerateFileSystemInfos()
            .Where(item => RustLibrarySearch.IsCandidate(item.Name, input.CandidateNames))
            .Select(item => Member(item.Name, item.Attributes))),
        _ => throw new InvalidDataException($"Unknown discovery input kind: {input.Kind}")
    });

    public static Entry? Record(string unit, Invocation original, string[] outputs, string[] reads, Access[] accesses,
        string logicalTarget, string temporaryRoot, DateTime started, Func<string, string> physical)
    {
        if (!IsLibrary(original)) return null;
        var outputDirectory = original.Arguments[Array.IndexOf(original.Arguments, "--out-dir") + 1];
        var expected = ArtifactNames(unit);
        if (outputs.Length != expected.Length || expected.Any(name =>
            !outputs.Contains(Path.Combine(outputDirectory, name), StringComparer.OrdinalIgnoreCase))) return null;

        // Omit private scratch paths written by this rustc itself. Any other write outside
        // the library output directory or discovery temp area disqualifies the invocation.
        var writes = accesses.Where(access => (access.Requested & 2) != 0 && access.Error == 0)
            .Select(access => access.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (writes.Any(path => (!Under(path, outputDirectory) && !Under(path, temporaryRoot))
            || (!outputs.Contains(path, StringComparer.OrdinalIgnoreCase)
                && (File.Exists(physical(path)) || Directory.Exists(physical(path)))))) return null;
        var inputs = new List<Input>();
        var compilerRoot = Path.GetDirectoryName(Path.GetDirectoryName(original.Executable)!)!;
        var windowsRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var cargoDirectories = RustLibrarySearch.CargoDirectories(original, logicalTarget);
        var candidateNames = RustLibrarySearch.CandidateNames(original, accesses
            .Where(access => access.Error == 0 && (access.Requested & (1 | 4)) != 0 && !writes.Contains(access.Path))
            .Select(access => access.Path));
        try
        {
            // Rustc declares compile-time env!/option_env! inputs in dep-info.
            // A job-local or sandbox variable is outside the invocation key.
            const string environmentDependency = "# env-dep:";
            if (File.ReadLines(physical(Path.Combine(outputDirectory, unit + ".d")))
                .Where(line => line.StartsWith(environmentDependency, StringComparison.Ordinal))
                .Select(line => line[environmentDependency.Length..].Split('=', 2)[0])
                .Any(name => !CaptureEnvironment.IsRelevant(name))) return null;
            foreach (var group in accesses.GroupBy(access => access.Path, StringComparer.OrdinalIgnoreCase))
            {
                var path = group.Key;
                // BuildXL represents non-filesystem device probes with an invalid
                // AbsolutePath. Pure library compilers can probe console handles.
                if (path == "{Invalid}" && group.All(access =>
                    access is { Operation: "CreateFile", Requested: 4, Error: 0 })) continue;
                if (!Path.IsPathFullyQualified(path) || group.Any(access => access.Operation == "ReparsePointTarget"))
                    return null;
                if (writes.Contains(path)) continue;
                if (group.Any(access => access.Error is not (0 or 2 or 3) &&
                    !(access.Operation == "CreateDirectory" && access.Error == 183))) return null;
                if (Under(path, temporaryRoot))
                {
                    // The private temp location is different for each discovery.
                    if (group.Any(access => (access.Requested & 1) != 0)) return null;
                    continue;
                }

                var probes = group.Where(access => (access.Requested & (1 | 4)) != 0).ToArray();
                if (probes.Length > 0)
                {
                    var isDll = probes.Any(access => access.Error == 0) && path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase);
                    if (isDll && !Under(path, compilerRoot) && !Under(path, windowsRoot)) return null;
                    var read = isDll || probes.Any(access => (access.Requested & 1) != 0);
                    var state = FileState(physical(path), read, started);
                    if (probes.Any(access => (access.Error == 0) != (state != "absent"))) return null;
                    inputs.Add(new(path, read ? "read" : "probe", state));
                }
                var enumerations = group.Where(access => (access.Requested & 8) != 0).ToArray();
                if (enumerations.Length == 0) continue;
                if (enumerations.Length != 1 || enumerations[0].Filter != "*" || enumerations[0].Error != 0) return null;
                // The trace contains the actual names returned, including the entries
                // seen before concurrent Cargo tasks wrote to the shared deps directory.
                var entries = accesses.Where(access => (access.Requested & 16) != 0 && access.Error == 0
                    && string.Equals(Path.GetDirectoryName(access.Path), path, StringComparison.OrdinalIgnoreCase))
                    .ToArray();
                if (entries.Any(access => access.Attributes == uint.MaxValue)) return null;
                // For a Cargo dependency directory, fingerprint rustc crate candidates
                // separately from unrelated Cargo publications. Other listings stay complete.
                var names = cargoDirectories.Contains(path) ? candidateNames : null;
                var members = entries.Where(access => RustLibrarySearch.IsCandidate(Path.GetFileName(access.Path), names))
                    .Select(access => Member(Path.GetFileName(access.Path), (FileAttributes)access.Attributes));
                inputs.Add(new(path, "enumerate", DirectoryState(members), names));
            }
            return new(Key(original), outputs.Order(StringComparer.Ordinal).ToArray(), reads.Order(StringComparer.Ordinal).ToArray(),
                inputs.OrderBy(input => Under(input.Path, compilerRoot) || Under(input.Path, windowsRoot))
                    .ThenBy(input => input.Path, StringComparer.Ordinal).ToArray());
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static async Task<Entry?> TryRestoreAsync(string directory, string unit, string unitDirectory, Invocation invocation)
    {
        var archivePath = Path.Combine(directory, "previous.zip");
        if (!File.Exists(archivePath)) return null;
        using var archive = ZipFile.OpenRead(archivePath);
        var index = archive.GetEntry(unit + "/" + IndexName);
        if (index is null) return null;
        Entry entry;
        try
        {
            using var data = index.Open();
            entry = JsonSerializer.Deserialize<Entry>(data)!;
            if (entry.Key != Key(invocation) || !entry.Inputs.All(Matches)) return null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }

        var outputDirectory = invocation.Arguments[Array.IndexOf(invocation.Arguments, "--out-dir") + 1];
        var expected = ArtifactNames(unit);
        if (entry.Outputs.Length != expected.Length || expected.Any(name => !entry.Outputs.Contains(
            Path.Combine(outputDirectory, name), StringComparer.OrdinalIgnoreCase))) return null;
        // Stage the full result before Cargo sees any artifacts or diagnostics.
        foreach (var name in expected.Append(StdoutName).Append(StderrName))
        {
            var file = archive.GetEntry(unit + "/" + name) ?? throw new InvalidDataException($"Missing discovery artifact {name}.");
            file.ExtractToFile(Path.Combine(unitDirectory, name));
        }
        foreach (var name in expected) File.Move(Path.Combine(unitDirectory, name), Path.Combine(outputDirectory, name));
        using var stdout = File.OpenRead(Path.Combine(unitDirectory, StdoutName));
        using var stderr = File.OpenRead(Path.Combine(unitDirectory, StderrName));
        await Task.WhenAll(stdout.CopyToAsync(Console.OpenStandardOutput()), stderr.CopyToAsync(Console.OpenStandardError()));
        return entry;
    }

    public static async Task<int> RunCompilerAsync(ProcessStartInfo start, string unitDirectory)
    {
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"Cannot start {start.FileName}");
        await Task.WhenAll(
            CopyOutputAsync(process.StandardOutput.BaseStream, Console.OpenStandardOutput(), Path.Combine(unitDirectory, StdoutName)),
            CopyOutputAsync(process.StandardError.BaseStream, Console.OpenStandardError(), Path.Combine(unitDirectory, StderrName)),
            process.WaitForExitAsync());
        return process.ExitCode;
    }

    private static async Task CopyOutputAsync(Stream input, Stream output, string history)
    {
        using var file = File.Create(history);
        var buffer = new byte[8192];
        int count;
        while ((count = await input.ReadAsync(buffer)) != 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, count));
            await file.WriteAsync(buffer.AsMemory(0, count));
        }
    }

    public static void AddToArchive(ZipArchive archive, string unit, Entry entry, string streams, Func<string, string> physical)
    {
        using (var index = archive.CreateEntry(unit + "/" + IndexName).Open()) JsonSerializer.Serialize(index, entry);
        foreach (var output in entry.Outputs)
            archive.CreateEntryFromFile(physical(output), unit + "/" + Path.GetFileName(output), CompressionLevel.NoCompression);
        foreach (var stream in new[] { StdoutName, StderrName })
            archive.CreateEntryFromFile(Path.Combine(streams, stream), unit + "/" + stream, CompressionLevel.NoCompression);
    }
}
