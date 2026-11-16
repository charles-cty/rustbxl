using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace RustBxl.Processes;

[SupportedOSPlatform("windows")]
internal static class ArtifactCompression
{
    internal sealed record Request(string StateRoot, string Scenario, string[] ActiveInstances,
        string[] ExcludePaths, int MinimumAgeDays, long MinimumBytes, bool Apply);
    private readonly record struct Identity(uint Volume, uint High, uint Low);
    private sealed class Entry(string path, Identity identity, FileInformation information)
    {
        public string Path { get; } = path;
        public Identity Identity { get; } = identity;
        public HashSet<string> Names { get; } = new(StringComparer.OrdinalIgnoreCase) { path };
        public uint Links { get; } = information.Links;
        public long Length { get; } = ((long)information.SizeHigh << 32) | information.SizeLow;
        public DateTime LastWriteUtc { get; } = DateTime.FromFileTimeUtc(information.Write);
        public uint Attributes { get; } = information.Attributes;
        public bool Protected { get; set; }
        public bool Eligible { get; set; }
    }
    private sealed record FileResult(string Path, long LogicalBytes, long AllocatedBefore,
        long AllocatedAfter, string Status);

    public static void Run(string requestFile)
    {
        var request = JsonSerializer.Deserialize<Request>(File.ReadAllText(requestFile))!;
        var state = Path.GetFullPath(request.StateRoot).TrimEnd('\\');
        var instances = Path.Combine(state, "instances");
        var shared = Path.Combine(state, "cache", request.Scenario, "Shared");
        if (request.MinimumAgeDays < 0 || request.MinimumBytes < 1)
            throw new ArgumentException("Invalid compression age or size threshold.");
        if (string.IsNullOrEmpty(request.Scenario) || request.Scenario.Any(character =>
            !char.IsAsciiLetterOrDigit(character) && character is not '_' and not '-'))
            throw new ArgumentException("Invalid cache scenario.");
        var active = request.ActiveInstances.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var excludes = request.ExcludePaths.Select(Path.GetFullPath).ToArray();
        if (excludes.Any(path => !Within(path, state)))
            throw new ArgumentException("Compression exclusions must be inside the state directory.");
        RequireNtfs(state);
        var inventory = new Dictionary<Identity, Entry>();
        Scan(instances, (path, relative) =>
        {
            var parts = relative.Split(Path.DirectorySeparatorChar);
            var isActive = active.Contains(parts[0]);
            var target = parts.Length > 2 && parts[1].Equals("target", StringComparison.OrdinalIgnoreCase);
            var logs = parts.Length > 3 && parts[1].Equals("run", StringComparison.OrdinalIgnoreCase)
                && parts[2].Equals("logs", StringComparison.OrdinalIgnoreCase);
            var mutable = parts.Contains("incremental", StringComparer.OrdinalIgnoreCase)
                || path.EndsWith(".lock", StringComparison.OrdinalIgnoreCase)
                || path.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase);
            return (!isActive && !mutable && (target || logs), isActive || mutable || (!target && !logs));
        });
        Scan(shared, (_, relative) =>
        {
            var parts = relative.Split(Path.DirectorySeparatorChar);
            var blob = parts.Length == 3 && !parts[0].Equals("temp", StringComparison.OrdinalIgnoreCase)
                && parts[2].EndsWith(".blob", StringComparison.OrdinalIgnoreCase);
            return (blob, !blob);
        });

        var cutoff = DateTime.UtcNow.AddDays(-request.MinimumAgeDays);
        var skipped = new SortedDictionary<string, int>(StringComparer.Ordinal);
        var files = new List<FileResult>();
        var candidates = 0;
        foreach (var entry in inventory.Values.OrderBy(entry => entry.Path, StringComparer.OrdinalIgnoreCase))
        {
            var reason = entry.Protected ? "protected" : !entry.Eligible ? "outside-scope"
                : entry.Names.Count != entry.Links ? "unmanaged-hardlinks"
                : entry.LastWriteUtc > cutoff ? "recent"
                : entry.Length < request.MinimumBytes ? "small"
                : (entry.Attributes & 0x800) != 0 ? "already-compressed"
                : (entry.Attributes & (0x200 | 0x4000)) != 0 ? "sparse-or-encrypted" : null;
            if (reason is not null) { Skip(reason); continue; }
            candidates++;
            var before = AllocatedBytes(entry.Path);
            if (!request.Apply)
            {
                files.Add(new(entry.Path, entry.Length, before, before, "candidate"));
                continue;
            }
            using (var stream = OpenForCompression(entry))
            {
                if (stream is null) { Skip("access-denied-or-in-use"); continue; }
                var handle = stream.SafeFileHandle;
                var current = Information(handle, entry.Path);
                CheckUnchanged(entry, current);
                ushort format = 2; // Native NTFS LZNT1; retain the file and all hard links.
                if (!DeviceIoControl(handle, 0x0009C040, ref format, 2, 0, 0, out _, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"Cannot compress {entry.Path}");
            }
            var after = AllocatedBytes(entry.Path);
            files.Add(new(entry.Path, entry.Length, before, after, "compressed"));
        }
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            Mode = request.Apply ? "applied" : "preview", ActiveInstances = request.ActiveInstances,
            request.MinimumAgeDays, request.MinimumBytes, ScannedUniqueFiles = inventory.Count,
            CandidateFiles = candidates, CompressedFiles = files.Count(file => file.Status == "compressed"),
            AllocatedBefore = files.Sum(file => file.AllocatedBefore),
            AllocatedAfter = files.Sum(file => file.AllocatedAfter),
            SavedBytes = files.Sum(file => file.AllocatedBefore - file.AllocatedAfter), Skipped = skipped, Files = files
        }));

        void Skip(string reason) => skipped[reason] = skipped.GetValueOrDefault(reason) + 1;
        void Scan(string root, Func<string, string, (bool Eligible, bool Protected)> classify)
        {
            if (!Directory.Exists(root)) return;
            for (var parent = root; Within(parent, state); parent = Path.GetDirectoryName(parent)!)
                if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException($"Compression root contains a reparse point: {parent}");
            var options = new EnumerationOptions { RecurseSubdirectories = true,
                AttributesToSkip = FileAttributes.ReparsePoint, IgnoreInaccessible = false };
            foreach (var path in Directory.EnumerateFiles(root, "*", options))
            {
                using var handle = Open(path, 0, 7);
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), path);
                var information = Information(handle, path);
                var identity = Id(information);
                if (!inventory.TryGetValue(identity, out var entry))
                    inventory.Add(identity, entry = new Entry(path, identity, information));
                else entry.Names.Add(path);
                var policy = classify(path, Path.GetRelativePath(root, path));
                entry.Eligible |= policy.Eligible;
                entry.Protected |= policy.Protected || excludes.Any(exclude => Within(path, exclude));
            }
        }
    }

    private static FileStream? OpenForCompression(Entry entry)
    {
        var path = entry.Path;
        var handle = Open(path, 0xC0000000, 0);
        if (!handle.IsInvalid) return new FileStream(handle, FileAccess.ReadWrite);
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        if (error == 32) return null;
        if (error != 5) throw new Win32Exception(error, path);

        // BuildXL denies writes to immutable CAS content. Temporarily remove only
        // its explicit Everyone WriteData/AppendData deny rule, then restore the
        // original DACL before compression. A security-only handle prevents
        // replacement and restores the same file even if opening for data fails.
        // Its metadata access does not conflict with the exclusive data handle.
        using var securityHandle = Open(path, 0x00060000, 3); // READ_CONTROL | WRITE_DAC; deny deletion.
        if (securityHandle.IsInvalid)
        {
            error = Marshal.GetLastWin32Error();
            if (error is 5 or 32) return null;
            throw new Win32Exception(error, path);
        }
        CheckUnchanged(entry, Information(securityHandle, path));
        using var security = new FileStream(securityHandle, FileAccess.Read);
        var descriptor = security.GetAccessControl().GetSecurityDescriptorBinaryForm();
        var original = new FileSecurity();
        original.SetSecurityDescriptorBinaryForm(descriptor, AccessControlSections.Access);
        var writable = new FileSecurity();
        writable.SetSecurityDescriptorBinaryForm(descriptor, AccessControlSections.Access);
        var denies = writable.GetAccessRules(true, false, typeof(SecurityIdentifier)).OfType<FileSystemAccessRule>()
            .Where(rule => rule.AccessControlType == AccessControlType.Deny
                && rule.IdentityReference.Value == "S-1-1-0"
                && rule.FileSystemRights == (FileSystemRights.WriteData | FileSystemRights.AppendData)).ToArray();
        if (denies.Length == 0) return null;
        foreach (var rule in denies) writable.RemoveAccessRuleSpecific(rule);
        FileStream? stream = null;
        var changed = false;
        try
        {
            security.SetAccessControl(writable);
            changed = true;
            handle = Open(path, 0xC0000000, 0);
            if (!handle.IsInvalid)
            {
                stream = new FileStream(handle, FileAccess.ReadWrite);
            }
            else
            {
                error = Marshal.GetLastWin32Error();
                handle.Dispose();
            }
        }
        finally
        {
            if (changed)
            {
                try
                {
                    security.SetAccessControl(original);
                }
                catch { stream?.Dispose(); throw; }
            }
        }
        if (stream is null)
        {
            if (error is 5 or 32) return null;
            throw new Win32Exception(error, path);
        }
        return stream;
    }

    private static void CheckUnchanged(Entry entry, FileInformation information)
    {
        if (Id(information) != entry.Identity || information.Links != entry.Links
            || information.Write != entry.LastWriteUtc.ToFileTimeUtc()
            || information.SizeHigh != (uint)(entry.Length >> 32) || information.SizeLow != (uint)entry.Length)
            throw new IOException($"Artifact changed during compression planning: {entry.Path}");
    }

    private static Identity Id(FileInformation information) => new(information.Volume, information.IndexHigh, information.IndexLow);
    private static bool Within(string path, string root) => path.Equals(root, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(root.TrimEnd('\\') + '\\', StringComparison.OrdinalIgnoreCase);
    private static SafeFileHandle Open(string path, uint access, uint share) =>
        CreateFileW(NativePath(path), access, share, 0, 3, 0x00200000, 0);
    private static string NativePath(string path) => path.StartsWith(@"\\?\", StringComparison.Ordinal) ? path : @"\\?\" + path;
    private static FileInformation Information(SafeFileHandle handle, string path)
    {
        if (!GetFileInformationByHandle(handle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        return information;
    }
    private static long AllocatedBytes(string path)
    {
        using var handle = Open(path, 0x80, 7); // FILE_READ_ATTRIBUTES.
        if (handle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        if (!GetFileInformationByHandleEx(handle, 1, out var information, (uint)Marshal.SizeOf<StandardInformation>()))
            throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        return information.AllocationSize;
    }
    private static void RequireNtfs(string state)
    {
        if ((File.GetAttributes(state) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Compression state must not be a reparse point.");
        var drive = new DriveInfo(Path.GetPathRoot(state)!);
        if (!drive.DriveFormat.Equals("NTFS", StringComparison.OrdinalIgnoreCase))
            throw new NotSupportedException("Artifact compression requires NTFS.");
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct FileInformation
    {
        public uint Attributes;
        public long Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct StandardInformation
    {
        public long AllocationSize, EndOfFile;
        public uint NumberOfLinks;
        public byte DeletePending, Directory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, nint security,
        uint creation, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind,
        out StandardInformation information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle file, uint code, ref ushort input,
        uint inputSize, nint output, uint outputSize, out uint returned, nint overlapped);
}
