using System.Security.Cryptography;
using System.Text.Json;

namespace RustBxl.Processes;

internal static class ExecutionPlans
{
    public static string Save<T>(string directory, T plan)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(plan);
        var path = Path.Combine(directory, Convert.ToHexString(SHA256.HashData(bytes)) + ".json");
        if (File.Exists(path)) return path;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, Guid.NewGuid() + ".tmp");
        try
        {
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path);
        }
        finally { File.Delete(temporary); }
        return path;
    }
}
