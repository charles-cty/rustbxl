using System.Diagnostics;
using System.Text.Json;
using RustBxl.Processes;

if (args.FirstOrDefault() == "capture") return DebugCapture.Run(args[1], args[2..]);
if (args.FirstOrDefault() == "generate") { GraphGenerator.Generate(args[1], args[2], args[3], args[4], args[5], args[6], args.ElementAtOrDefault(7)); return 0; }
if (args.FirstOrDefault() == "prepare-build-script") { BuildScriptOutput.Prepare(args[1], args[2]); return 0; }
if (args.FirstOrDefault() == "replay-rustc") return await BuildScriptOutput.CompileAsync(args[1], args[2], args[3], args[4..]);
if (args.FirstOrDefault() == "run-build-script") return await BuildScriptRunner.RunAsync(args[1]);
if (args.FirstOrDefault() == "check-arguments") { ArgumentChecks.Run(); return 0; }
if (args.FirstOrDefault() == "compress-artifacts")
{
    if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Artifact compression requires Windows.");
    try { ArtifactCompression.Run(args[1]); return 0; }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
        or System.ComponentModel.Win32Exception or NotSupportedException)
    {
        Console.Error.WriteLine("Artifact compression: " + error.Message);
        return 1;
    }
}
if (args.FirstOrDefault() == "write-arguments")
{
    Directory.CreateDirectory(Path.GetDirectoryName(args[1])!);
    File.WriteAllText(args[1], JsonSerializer.Serialize(args[2..]));
    return 0;
}
if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "LinkerRecorder", StringComparison.OrdinalIgnoreCase))
    return await LinkCapture.RunAsync(args);
if (args.Length == 0) throw new ArgumentException("Expected the rustc executable.");
var executable = Path.GetFullPath(args[0]);
var arguments = args[1..].ToList();
var crateName = Option(arguments, "--crate-name");
if (crateName is null || Option(arguments, "--out-dir") is null) return await RunAsync(executable, arguments);
if (CompilerInvocation.IsBuildScriptProbe(arguments, Environment.CurrentDirectory))
    return await RunAsync(executable, arguments);
// Add path remapping after Cargo resolves its own rustflags and target configuration.
// Without SIDECAR_CAPTURE this wrapper also supports the mapped Cargo test oracle.
if (Environment.GetEnvironmentVariable("SIDECAR_RUSTFLAGS") is { } extraFlags)
    arguments.AddRange(JsonSerializer.Deserialize<string[]>(extraFlags)!);
var captureRoot = Environment.GetEnvironmentVariable("SIDECAR_CAPTURE");
if (captureRoot is null) return await RunAsync(executable, arguments);
var extraFilename = arguments.FirstOrDefault(value => value.StartsWith("extra-filename="))?[15..] ?? "";
var unit = crateName + extraFilename;
var unitDirectory = Path.Combine(captureRoot, "units", unit);
Directory.CreateDirectory(unitDirectory);
var outputDirectory = Option(arguments, "--out-dir")!;
var staging = Path.Combine(outputDirectory, ".sidecar", unit);
Directory.CreateDirectory(staging);
var invocation = new Invocation(executable, arguments.ToArray(), Environment.CurrentDirectory, CaptureEnvironment.Read());
await File.WriteAllTextAsync(Path.Combine(unitDirectory, "rustc.json"), JsonSerializer.Serialize(invocation));
var discoveryCache = Environment.GetEnvironmentVariable("SIDECAR_DISCOVERY_CACHE");
var cacheLibrary = discoveryCache is not null && DiscoveryCache.IsLibrary(invocation);
if (cacheLibrary && await DiscoveryCache.TryRestoreAsync(discoveryCache!, unit, unitDirectory, invocation) is { } restored)
{
    await File.WriteAllTextAsync(Path.Combine(unitDirectory, "restored.json"), JsonSerializer.Serialize(restored));
    return 0;
}
Environment.SetEnvironmentVariable("SIDECAR_UNIT", unit);
Environment.SetEnvironmentVariable("SIDECAR_STAGING", staging);
arguments.AddRange(["-C", "linker=" + Path.Combine(AppContext.BaseDirectory, "LinkerRecorder.exe")]);
var startInfo = StartInfo(executable, arguments);
var exitCode = cacheLibrary
    ? await DiscoveryCache.RunCompilerAsync(startInfo, unitDirectory)
    : await RunStartAsync(startInfo);
await File.WriteAllTextAsync(Path.Combine(unitDirectory, "exit-code.txt"), exitCode.ToString());
return exitCode;

static string? Option(List<string> arguments, string name)
{
    var index = arguments.IndexOf(name);
    return index < 0 ? null : arguments[index + 1];
}

static ProcessStartInfo StartInfo(string executable, IEnumerable<string> arguments)
{
    var startInfo = new ProcessStartInfo(executable) { UseShellExecute = false };
    foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
    return startInfo;
}

static Task<int> RunAsync(string executable, IEnumerable<string> arguments) => RunStartAsync(StartInfo(executable, arguments));

static async Task<int> RunStartAsync(ProcessStartInfo startInfo)
{
    using var process = Process.Start(startInfo) ?? throw new InvalidOperationException($"Cannot start {startInfo.FileName}");
    await process.WaitForExitAsync();
    return process.ExitCode;
}
