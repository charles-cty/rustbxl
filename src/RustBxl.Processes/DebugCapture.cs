using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace RustBxl.Processes;

// Windows x64 debugger events provide a recursive process inventory.
// PEB snapshots are taken while a new process is suspended, before it can exit.
internal static class DebugCapture
{
    public static int Run(string outputFile, string[] command)
    {
        var commandLine = new StringBuilder(string.Join(" ", command.Select(Quote)));
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        if (!CreateProcessW(command[0], commandLine, 0, 0, false, 1, 0, null, ref startup, out var initial)) ThrowLastError();
        CloseHandle(initial.Process);
        CloseHandle(initial.Thread);
        var processes = new Dictionary<uint, nint>();
        var retainedHandles = new List<nint>();
        var eventBuffer = Marshal.AllocHGlobal(256);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputFile))!);
        using var writer = new StreamWriter(outputFile, false, new UTF8Encoding(false));
        var rootExit = 0;
        try
        {
            do
            {
                if (!WaitForDebugEventEx(eventBuffer, uint.MaxValue)) ThrowLastError();
                var code = (uint)Marshal.ReadInt32(eventBuffer);
                var pid = (uint)Marshal.ReadInt32(eventBuffer, 4);
                var tid = (uint)Marshal.ReadInt32(eventBuffer, 8);
                var data = eventBuffer + 16;
                var disposition = 0x00010002u;
                if (code == 3)
                {
                    var handle = Marshal.ReadIntPtr(data, 8);
                    processes.Add(pid, handle);
                    // Keep exited process objects alive until capture ends. Windows
                    // can otherwise reuse a PID while BuildXL's trace still refers
                    // to it, making per-PID file access attribution ambiguous.
                    // ContinueDebugEvent closes the original debugger handle on
                    // process exit. Retain an independent duplicate instead.
                    if (!DuplicateHandle((nint)(-1), handle, (nint)(-1), out var retained, 0, false, 2)) ThrowLastError();
                    retainedHandles.Add(retained);
                    writer.WriteLine(JsonSerializer.Serialize(new { ProcessId = pid, Invocation = Snapshot(handle) }));
                    writer.Flush();
                    CloseHandle(Marshal.ReadIntPtr(data));
                    // Windows owns the original process and thread debug handles
                    // and closes them when their exit events are continued.
                }
                else if (code == 6) CloseHandle(Marshal.ReadIntPtr(data));
                else if (code == 5)
                {
                    if (pid == initial.ProcessId) rootExit = Marshal.ReadInt32(data);
                    processes.Remove(pid);
                }
                else if (code == 1)
                {
                    var exception = (uint)Marshal.ReadInt32(data);
                    if (exception is not 0x80000003 and not 0x80000004) disposition = 0x80010001;
                }
                if (!ContinueDebugEvent(pid, tid, disposition)) ThrowLastError();
            } while (processes.Count > 0);
        }
        finally
        {
            foreach (var handle in retainedHandles) CloseHandle(handle);
            Marshal.FreeHGlobal(eventBuffer);
        }
        return rootExit;
    }

    private static Invocation Snapshot(nint process)
    {
        var basic = new byte[48];
        var status = NtQueryInformationProcess(process, 0, basic, basic.Length, out _);
        if (status != 0) throw new InvalidOperationException($"NtQueryInformationProcess: 0x{status:X8}");
        var peb = BitConverter.ToInt64(basic, 8);
        var parameters = BitConverter.ToInt64(Read(process, peb + 0x20, 8));
        var header = Read(process, parameters, 0x88);
        var image = ReadUnicode(process, header, 0x60);
        var line = ReadUnicode(process, header, 0x70);
        var cwd = ReadUnicode(process, header, 0x38);
        var environmentAddress = BitConverter.ToInt64(header, 0x80);
        var environmentBytes = new List<byte>();
        for (var offset = 0; offset < 1024 * 1024; offset += 4096)
        {
            var block = Read(process, environmentAddress + offset, 4096, allowPartial: true);
            environmentBytes.AddRange(block);
            var bytes = environmentBytes.ToArray();
            for (var index = Math.Max(0, offset - 2); index + 3 < bytes.Length; index += 2)
            {
                if (bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 || bytes[index + 3] != 0) continue;
                var environment = Encoding.Unicode.GetString(bytes, 0, index).Split('\0')
                    .Where(value => value.IndexOf('=') > 0).Select(value => value.Split('=', 2))
                    .Where(pair => CaptureEnvironment.IsRelevant(pair[0]))
                    .ToDictionary(pair => pair[0], pair => pair[1], StringComparer.OrdinalIgnoreCase);
                return new Invocation(image, SplitCommandLine(line)[1..], cwd, environment);
            }
            if (block.Length != 4096) break;
        }
        throw new InvalidOperationException($"No environment terminator for {image}");
    }

    private static string ReadUnicode(nint process, byte[] header, int offset) =>
        Encoding.Unicode.GetString(Read(process, BitConverter.ToInt64(header, offset + 8), BitConverter.ToUInt16(header, offset)));

    private static byte[] Read(nint process, long address, int count, bool allowPartial = false)
    {
        var bytes = new byte[count];
        var success = ReadProcessMemory(process, (nint)address, bytes, (nuint)count, out var read);
        if (!success && (!allowPartial || read == 0)) ThrowLastError();
        return bytes[..(int)read];
    }

    public static string[] SplitCommandLine(string line)
    {
        var pointer = CommandLineToArgvW(line, out var count);
        if (pointer == 0) ThrowLastError();
        try { return Enumerable.Range(0, count).Select(index => Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, index * 8))!).ToArray(); }
        finally { LocalFree(pointer); }
    }

    public static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        var slashes = 0;
        foreach (var character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(character);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    private static void ThrowLastError() => throw new Win32Exception(Marshal.GetLastWin32Error());

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public nint Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, ReservedSize;
        public nint ReservedPointer, StdInput, StdOutput, StdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public nint Process, Thread; public uint ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(string application, StringBuilder command, nint processAttributes,
        nint threadAttributes, bool inheritHandles, uint flags, nint environment, string? directory,
        ref StartupInfo startup, out ProcessInformation information);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WaitForDebugEventEx(nint debugEvent, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ContinueDebugEvent(uint process, uint thread, uint status);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateHandle(nint sourceProcess, nint source, nint targetProcess,
        out nint target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadProcessMemory(nint process, nint address, byte[] buffer, nuint size, out nuint read);
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(nint process, int infoClass, byte[] buffer, int size, out int returned);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern nint LocalFree(nint pointer);
}
