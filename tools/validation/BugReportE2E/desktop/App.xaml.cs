using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Roo70Fixture;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.OptimizationSuite.Views;

namespace RooIndustries.OptimizationSuite;
public partial class App : Application
{
    private Window? window;
    private BugReportPage? page;
    private OwnedBoundary? boundary;
    private Exception? failure;
    private readonly List<string> seen = new();
    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => Fail(e.Exception);
    }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            boundary = OwnedBoundary.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
            ScenarioDriver.RequireDisabledLog();
            window = new Window { Title = "ROO70 isolated bug-report fixture " + boundary.Nonce };
            await ScenarioDriver.RunAsync(boundary.Data, boundary.Output, CreateSurface, CaptureAsync,
                "Native planned: exact XAML/page handlers via ButtonAutomationPeer; VM input seeding is not UIA typing; isolated bootstrap");
            ScenarioDriver.Require(seen.SequenceEqual(ScenarioDriver.Names), "Six captured scenes required in order.");
            Atomic("final-result.json", new { schemaVersion = 1, boundary.Nonce, sourceCommit = BuildBinding.SourceCommit,
                seen, native = true, productionStartupProved = false, proofSeam = "Minimal App + fake Live/Operations/FakeSender; actual page/VM/service/parser/resources; seeded inputs",
                positiveMarker = "ROO_INDUSTRIES_BUG_REPORT_RENDERED_6COMPLETE" });
            ReaderAdverse.AttachIfRequested(boundary.Frame, boundary.Nonce, "rendered");
            window.Close();
            Exit();
        }
        catch (Exception error) { Fail(error); }
    }
    private async Task<Surface> CreateSurface(BugReportService service, FixtureSender sender)
    {
        BugReports = service;
        page = new BugReportPage();
        var currentPage = page;
        var vm = currentPage.ViewModel;
        var loaded = new TaskCompletionSource<bool>();
        currentPage.Loaded += (_, _) => loaded.TrySetResult(true);
        window!.Content = currentPage;
        window.Activate();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        Microsoft.UI.Windowing.AppWindow.GetFromWindowId(id).Resize(new Windows.Graphics.SizeInt32(1280, 1000));
        if (await Task.WhenAny(loaded.Task, Task.Delay(5000)) != loaded.Task) throw new TimeoutException("Actual BugReportPage.Loaded did not fire.");
        await ScenarioDriver.Wait(() => !vm.LoadingSpecs && vm.Specs.Count == 9, "Actual Page Loaded/LoadAsync did not settle.");
        currentPage.UpdateLayout();
        ScenarioDriver.Require(currentPage.ActualWidth > 0 && currentPage.ActualHeight > 0, "Actual page has no layout.");
        async Task Invoke(string automationId, Func<bool> complete)
        {
            var button = Descendants(currentPage).OfType<Button>().Single(x => AutomationProperties.GetAutomationId(x) == automationId);
            ScenarioDriver.Require(button.IsEnabled && button.Visibility == Visibility.Visible, "Actual button not available: " + automationId);
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) ?? new ButtonAutomationPeer(button);
            if (peer.GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new InvalidOperationException("Actual button has no Invoke provider.");
            invoke.Invoke();
            await ScenarioDriver.Wait(() => !vm.Busy && complete(), "Actual click handler did not complete: " + automationId);
        }
        async Task SeedVisible()
        {
            await ScenarioDriver.Wait(() =>
            {
                var boxes = Descendants(currentPage).OfType<TextBox>().ToArray();
                return ScenarioDriver.CanonicalDescription(vm.Description) == ScenarioDriver.Description
                    && ScenarioDriver.CanonicalDescription(boxes.Single(x => AutomationProperties.GetAutomationId(x) == "BugDescription").Text) == ScenarioDriver.Description
                    && boxes.Single(x => AutomationProperties.GetAutomationId(x) == "BugContact").Text == vm.Contact
                    && boxes.Single(x => (x.Header as string) == "Processor").Text == ScenarioDriver.Raw;
            }, "Seeded actual bound textboxes did not update.");
        }
        return new Surface(vm, () => Invoke("BugAttachLogs", () => vm.AttachmentText.StartsWith("Attached ", StringComparison.Ordinal)),
            () => Invoke("BugSave", () => vm.HasSavedReport),
            () => Invoke("BugSend", () => sender.Calls.Count == 1 && vm.Status != "Sending your report..."), SeedVisible);
    }
    private async Task CaptureAsync(SceneReceipt receipt, BugReportViewModel vm)
    {
        ScenarioDriver.Require(seen.Count < ScenarioDriver.Names.Length && ScenarioDriver.Names[seen.Count] == receipt.Name, "Unexpected checkpoint.");
        var initial = StateInvariant(vm);
        var currentPage = page!;
        currentPage.UpdateLayout();
        var buttons = Descendants(currentPage).OfType<Button>().ToArray();
        Button Button(string id) => buttons.Single(x => AutomationProperties.GetAutomationId(x) == id);
        ScenarioDriver.Require(Button("BugAttachLogs").IsEnabled == vm.CanAttach
            && Button("BugSave").IsEnabled == vm.CanSend && Button("BugSend").IsEnabled == vm.CanSend
            && (Button("BugSend").Visibility == Visibility.Visible) == vm.OnlineAvailable
            && (Button("BugSave").Visibility == Visibility.Visible) == vm.ShowSave
            && (Button("BugOpenFolder").Visibility == Visibility.Visible) == vm.HasSavedReport, "Actual button bindings mismatch.");
        var offline = Descendants(currentPage).OfType<TextBlock>().Single(x => x.Text == "Online reporting isn't set up in this build. Save the report to a file and send it to the developers.");
        ScenarioDriver.Require((offline.Visibility == Visibility.Visible) == vm.OfflineOnly, "Offline notice binding mismatch.");
        var scroll = Descendants(currentPage).OfType<ScrollViewer>().First();
        var semantic = JsonSerializer.Serialize(receipt);
        foreach (var view in new[] { "top", "bottom" })
        {
            var target = view == "top" ? 0 : scroll.ScrollableHeight;
            if (view == "bottom") ScenarioDriver.Require(target > 0, "Bottom capture requires scrollable actual content.");
            scroll.ChangeView(null, target, null, true);
            currentPage.UpdateLayout();
            await ScenarioDriver.Wait(() => Math.Abs(scroll.VerticalOffset - target) < 2, "Actual ScrollViewer did not settle.");
            await Task.Delay(150);
            ScenarioDriver.Require(StateInvariant(vm) == initial, "Screenshot navigation changed VM semantics.");
            using var process = Process.GetCurrentProcess();
            var checkpointId = Guid.NewGuid().ToString("N");
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window!);
            ScenarioDriver.Require(hwnd != IntPtr.Zero, "No actual fixture HWND.");
            Atomic(receipt.Name + "-" + view + "-checkpoint.json", new { schemaVersion = 1, boundary!.Nonce, sourceCommit = BuildBinding.SourceCommit,
                fixturePid = process.Id, creationTimeFileTimeUtc = process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
                windowHandle = hwnd.ToInt64().ToString(), checkpointId, name = receipt.Name, view,
                receipt = semantic, receiptSha256 = Hash(Encoding.UTF8.GetBytes(semantic)), state = FullState(vm), stateSha256 = Hash(Encoding.UTF8.GetBytes(initial)),
                scrollOffset = scroll.VerticalOffset, scrollableHeight = scroll.ScrollableHeight, native = true,
                positiveMarker = "ROO70_RENDERED_BUG_REPORT_CHECKPOINT" });
            var ack = Path.Combine(boundary.Output, "ack-" + checkpointId + ".json");
            var clock = Stopwatch.StartNew();
            while (!File.Exists(ack))
            {
                if (clock.Elapsed > TimeSpan.FromSeconds(30)) throw new TimeoutException("Bound acknowledgment missing.");
                await Task.Delay(50);
            }
            using var json = JsonDocument.Parse(FixtureFiles.ReadShared(ack));
            var root = json.RootElement;
            ScenarioDriver.Require(root.GetProperty("schemaVersion").GetInt32() == 1 && root.GetProperty("nonce").GetString() == boundary.Nonce
                && root.GetProperty("checkpointId").GetString() == checkpointId && root.GetProperty("action").GetString() == "continue", "Acknowledgment binding mismatch.");
            ScenarioDriver.Require(StateInvariant(vm) == initial, "Captured scene state changed during acknowledgment.");
        }
        scroll.ChangeView(null, 0, null, true);
        ScenarioDriver.Require(StateInvariant(vm) == initial, "Scene navigation mutated state.");
        seen.Add(receipt.Name);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var item = VisualTreeHelper.GetChild(parent, index);
            yield return item;
            foreach (var nested in Descendants(item)) yield return nested;
        }
    }
    private static object FullState(BugReportViewModel vm) => new { model = ScenarioDriver.State(vm), specs = vm.Specs.Select(x => new { x.Key, x.Label, x.Value }).ToArray() };
    private static string StateInvariant(BugReportViewModel vm) => JsonSerializer.Serialize(FullState(vm));
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private void Atomic(string name, object value)
    {
        FixtureFiles.WriteNew(Path.Combine(boundary!.Output, name), value);
    }
    private void Fail(Exception error)
    {
        Environment.ExitCode = 1;
        if (failure is not null) return;
        failure = error;
        try
        {
            if (boundary is not null) Atomic("failure.json", new { schemaVersion = 1, boundary.Nonce, sourceCommit = BuildBinding.SourceCommit, error = failure.ToString(), seen, native = true });
        }
        catch (Exception receiptError)
        {
            Console.Error.WriteLine("ROO70_RENDERED_FAILED: " + failure + Environment.NewLine + "Failure receipt: " + receiptError);
        }
        finally
        {
            try { window?.Close(); }
            finally { Exit(); }
        }
    }
}
