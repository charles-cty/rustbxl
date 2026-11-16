namespace RustBxl.Processes;

internal static class ArgumentChecks
{
    public static void Run()
    {
        List<string[]> cases = [
            [""], ["x", ""], ["C:\\directory with spaces\\"], ["a\"b", "c\\\\\"d"], ["中文", "a b", "\\"]
        ];
        var random = new Random(2147);
        const string alphabet = "ab \\\"中";
        for (var sample = 0; sample < 500; sample++)
        {
            cases.Add(Enumerable.Range(0, random.Next(1, 8)).Select(_ => new string(
                Enumerable.Range(0, random.Next(0, 40)).Select(_ => alphabet[random.Next(alphabet.Length)]).ToArray())).ToArray());
        }
        foreach (var arguments in cases)
        {
            var line = "program " + string.Join(" ", arguments.Select(DebugCapture.Quote));
            var actual = DebugCapture.SplitCommandLine(line)[1..];
            if (!arguments.SequenceEqual(actual)) throw new InvalidOperationException("Win32 argument round trip failed.");
        }
        Console.WriteLine($"ARGUMENT_CHECKS\t{cases.Count} cases passed against CommandLineToArgvW");
    }
}
