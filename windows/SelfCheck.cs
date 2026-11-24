using System.Runtime.CompilerServices;

namespace BisprBlow;

// `BisprBlow --self-check`: asserts the text logic that silently loses user words if it breaks, plus
// the input and cloud pieces that can be checked without a keyboard or a network. Every failure is
// printed, and the exit code is the number of them.
static class Check
{
    public static int Failures;

    public static void That(bool ok, [CallerArgumentExpression(nameof(ok))] string what = "",
                            [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (ok) return;
        Failures++;
        Console.WriteLine($"FAIL {System.IO.Path.GetFileName(file)}:{line}  {what}");
    }

    public static void Equal<T>(T actual, T expected, [CallerArgumentExpression(nameof(actual))] string what = "",
                                [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (EqualityComparer<T>.Default.Equals(actual, expected)) return;
        Failures++;
        Console.WriteLine($"FAIL {System.IO.Path.GetFileName(file)}:{line}  {what}\n  got:      {actual}\n  expected: {expected}");
    }
}

static partial class SelfCheck
{
    public static int Run()
    {
        // Each area owns its checks, in the file named after the Swift one.
        RunText();
        SelfCheckText.Run();
        SelfCheckInput.Run();
        SelfCheckCloud.Run();
        Console.WriteLine(Check.Failures == 0 ? "self-check passed" : $"self-check FAILED ({Check.Failures})");
        return Check.Failures;
    }
}
