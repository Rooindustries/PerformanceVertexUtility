using Microsoft.Win32;
using RooIndustries.Optimizer;

static class PowerChecks
{
    public static void Run(string files, Action<bool, string> check)
    {
        var address = new ControlAddress("hibernation", "system", "configuration");
        var native = new WindowsControlStore(); var original = native.Read(address);
        if (original.Value.GetProperty("mode").GetString() != "Off") throw new InvalidDataException("The approved power fixture requires originally disabled hibernation.");
        var disk = new DriveInfo(Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.System))!);
        if ((ulong)disk.AvailableFreeSpace < (ulong)TweakHardwareValues.InstalledMemoryKiB() * 1024 + 5UL * 1024 * 1024 * 1024) throw new InvalidDataException("Insufficient free space for the approved power fixture.");
        using var users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var user = users.OpenSubKey(OperationOwner.Current().UserSid, true)!;
        using (var existing = user.OpenSubKey(RegistryTweakChecks.Root)) if (existing is not null) throw new InvalidDataException("A fixture recovery record already exists.");
        var recovery = new RegistryAddress("CurrentUser", "Registry64", RegistryTweakChecks.Root + @"\Recovery", "value", "State");
        var options = new TweakOption[]
        {
            new("full", "Full", [], Controls: [new(address, ControlValues.From(new { mode = "Full", enabled = 1, configuredType = 2 }), true)]),
            new("reduced", "Reduced", [], Controls: [new(address, ControlValues.From(new { mode = "Reduced", enabled = 1, configuredType = 1, sizePercent = 0 }), true)]),
        };
        var catalog = new TweakCatalog(1, "power-fixture", [new("hibernation", "Hibernation", "Fixture", "Configuration round trip", 26200, 26200, ["*"], "none", options, [new("Roo Industries", "approved fixture", "powercfg round trip")])], []);
        var store = new RegistryTweakStore(recovery); var engine = new TweakEngine(catalog, store);
        void Apply(params TweakSelection[] choices)
        {
            var plan = engine.Preview("power-fixture", choices); var path = Path.Combine(files, plan.OperationId + ".json"); OperationFiles.Write(path, plan); engine.Apply(path, OperationFiles.HashFile(path));
        }
        try
        {
            Apply(new TweakSelection("hibernation", "full"));
            check(native.Read(address).Value.GetProperty("mode").GetString() == "Full", "Native profile creates the requested full hibernation mode");
            Apply(new TweakSelection("hibernation", "reduced"));
            check(native.Read(address).Value.GetProperty("mode").GetString() == "Reduced", "Native profile changes to the requested reduced hibernation mode");
            Apply();
            check(native.Read(address).Same(original), "Native profile restores all captured power values and the original disabled mode");
            check(store.ReadState()!.Profiles.Length == 0 && store.Recovery().Pending is null, "Power profile restore closes ownership and its operation journal");
        }
        finally
        {
            var current = native.Read(address);
            if (!current.Same(original)) native.Write(current, original.Value);
            if (!native.Read(address).Same(original)) throw new InvalidDataException("Power fixture recovery is incomplete; its receipt was retained.");
            user.DeleteSubKeyTree(RegistryTweakChecks.Root, false);
            check(native.Read(address).Value.GetProperty("mode").GetString() == "Off", "Power validation ends with hibernation disabled");
        }
    }
}
