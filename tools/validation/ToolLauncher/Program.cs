using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

try
{
    var numeric = new FirmwareSettingRow(new FirmwareQuestion("numeric", "Delay", "", "5", "decimal", 1, [], "", ""));
    numeric.SelectedOption = null;
    if (numeric.Selection != "5" || numeric.Changed) throw new InvalidOperationException("An unused choice editor changed a numeric setting before user input.");
    var choice = new FirmwareSettingRow(new FirmwareQuestion("choice", "Mode", "", "00", "choice", 1, [new("00", "Off"), new("01", "On")], "", ""));
    choice.SelectedOption = null;
    if (choice.SelectedOption?.Value != "00" || choice.Changed) throw new InvalidOperationException("Binding initialization discarded the current choice.");
    choice.SelectedOption = choice.Options[1];
    if (choice.Selection != "01" || !choice.Changed) throw new InvalidOperationException("Choosing an option did not create the requested change.");
    numeric.Selection = "9";
    if (!numeric.Changed) throw new InvalidOperationException("Editing a numeric value did not create a change.");
    Console.WriteLine("PASS BIOS editor preserves loaded values during binding initialization and changes only edited rows");
    if (args.Length != 1) throw new ArgumentException("Supply the disposable CLI fixture directory.");
    ToolLauncherChecks.Run((success, message) =>
    {
        if (!success) throw new InvalidOperationException(message);
        Console.WriteLine("PASS " + message);
    }, args[0]);
}
catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }
