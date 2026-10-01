using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

class EnvironmentReporter
{
    static int Main(string[] args)
    {
        var report = new List<string> { "#IMAGE=" + Process.GetCurrentProcess().MainModule.FileName, "#PID=" + Process.GetCurrentProcess().Id, "#ARGS=" + string.Join("|", args) };
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) report.Add((string)entry.Key + "=" + (string)entry.Value);
        File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "env-report.txt"), report.ToArray(), new UTF8Encoding(false));
        return 0;
    }
}
