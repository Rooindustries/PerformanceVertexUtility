using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class BugSpecField : ObservableObject
{
    public string Key { get; }
    public string Label { get; }
    [ObservableProperty] private string _value;

    public BugSpecField(string key, string label, string value)
    {
        Key = key;
        Label = label;
        _value = value;
    }
}

public partial class BugReportViewModel : ObservableObject
{
    private const string NoAttachment = "No logs attached yet.";
    private static readonly (string Key, string Label)[] SpecLabels =
    {
        ("windows", "Windows"),
        ("cpu", "Processor"),
        ("gpu", "Graphics and driver"),
        ("ram", "Memory"),
        ("motherboard", "Motherboard"),
        ("bios", "BIOS version"),
        ("drive", "System drive"),
        ("display", "Main display"),
    };

    private readonly BugReportService _service = App.BugReports;
    private BugAttachment? _attachment;
    private bool _loaded;
    private string? _errorBeforeReport;

    [ObservableProperty] [NotifyPropertyChangedFor(nameof(CanSend))] private string _description = "";
    [ObservableProperty] private string _contact = "";
    [ObservableProperty] [NotifyPropertyChangedFor(nameof(CanSend), nameof(CanAttach))] private bool _busy;
    [ObservableProperty] [NotifyPropertyChangedFor(nameof(CanSend), nameof(CanAttach))] private bool _loadingSpecs;
    [ObservableProperty] private string _attachmentText = NoAttachment;
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _showSave;
    [ObservableProperty] [NotifyPropertyChangedFor(nameof(HasSavedReport))] private string? _savedPath;

    public ObservableCollection<BugSpecField> Specs { get; } = new();
    public bool OnlineAvailable => _service.OnlineAvailable;
    public bool OfflineOnly => !OnlineAvailable;
    public bool CanAttach => !Busy && !LoadingSpecs;
    public bool CanSend => !Busy && !LoadingSpecs && BugReportService.CanSubmit(Description, _attachment);
    public bool HasSavedReport => SavedPath is not null;

    public BugReportViewModel() => _showSave = OfflineOnly;

    public async Task LoadAsync()
    {
        _errorBeforeReport = App.Live.LastError ?? _errorBeforeReport;
        if (_loaded) return;
        _loaded = true;
        LoadingSpecs = true;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var result = await App.Live.RunBackendScriptResultAsync("Get-BugReportSpecs.ps1");
            if (result.Error is null && result.Value is { } json)
            {
                using var document = JsonDocument.Parse(json);
                foreach (var property in document.RootElement.EnumerateObject())
                    if (property.Value.ValueKind == JsonValueKind.String && property.Value.GetString() is { Length: > 0 } value) values[property.Name] = value.Trim();
            }
        }
        catch (Exception error)
        {
            AppLog.Write("bug-report", error.ToString());
        }
        finally
        {
            Specs.Clear();
            foreach (var (key, label) in SpecLabels) Specs.Add(new(key, label, values.TryGetValue(key, out var value) ? value : "Unknown"));
            Specs.Add(new("app", "App version", App.VersionText));
            LoadingSpecs = false;
        }
    }

    public async Task AttachAsync()
    {
        if (Busy) return;
        Busy = true;
        Status = "";
        try
        {
            AttachmentText = "Collecting logs...";
            var summary = await TweakSummaryAsync();
            var specs = CurrentSpecs();
            _attachment = await Task.Run(() => _service.CreateAttachment(specs, summary));
            AttachmentText = "Attached " + _attachment.FileName + " (" + Format.Bytes(_attachment.Bytes) + ")";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            AppLog.Write("bug-report", error.ToString());
            _attachment = null;
            AttachmentText = "Couldn't attach the logs. Try again.";
        }
        finally
        {
            Busy = false;
        }
    }

    public async Task SendAsync()
    {
        if (!CanSend) return;
        Busy = true;
        Status = "Sending your report...";
        try
        {
            var outcome = await _service.SendAsync(Report(), _attachment);
            var seconds = Math.Max(1, (int)Math.Ceiling(outcome.Wait.TotalSeconds));
            switch (outcome.Status)
            {
                case BugSendStatus.Sent:
                    Status = "Thanks! Your report was sent to Roo Industries.";
                    Description = "";
                    Contact = "";
                    _attachment = null;
                    AttachmentText = NoAttachment;
                    SavedPath = null;
                    ShowSave = OfflineOnly;
                    break;
                case BugSendStatus.Throttled:
                    Status = "Please wait " + seconds + " seconds before sending another report.";
                    break;
                case BugSendStatus.RateLimited:
                    Status = "Too many reports are being sent right now. Try again in " + seconds + " seconds, or save the report to a file.";
                    ShowSave = true;
                    break;
                case BugSendStatus.Offline:
                    Status = "Couldn't reach Roo Industries. Check your internet connection and try again, or save the report to a file and send it yourself.";
                    ShowSave = true;
                    break;
                case BugSendStatus.NotConfigured:
                    Status = "Online reporting isn't set up in this build. Save the report to a file instead.";
                    ShowSave = true;
                    break;
                case BugSendStatus.NeedsDetails:
                    Status = "Describe what went wrong and attach logs first.";
                    break;
                default:
                    Status = "The report couldn't be delivered. Try again later, or save the report to a file and send it yourself.";
                    ShowSave = true;
                    break;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            AppLog.Write("bug-report", error.ToString());
            Status = "The report couldn't be prepared. Attach logs again, then retry.";
            ShowSave = true;
        }
        finally
        {
            Busy = false;
        }
    }

    public async Task SaveAsync()
    {
        if (!CanSend || _attachment is not { } attachment) return;
        Busy = true;
        try
        {
            var report = Report();
            SavedPath = await Task.Run(() => _service.SaveReport(report, attachment));
            Status = "Saved " + Path.GetFileName(SavedPath) + ". Select Open folder, then send that file to Roo Industries.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or InvalidDataException)
        {
            AppLog.Write("bug-report", error.ToString());
            Status = "Couldn't save the report. Try again.";
        }
        finally
        {
            Busy = false;
        }
    }

    public void OpenFolder()
    {
        if (SavedPath is not { } path) return;
        try
        {
            using var process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "/select,\"" + path + "\"") { UseShellExecute = true });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
        {
            AppLog.Write("bug-report", error.ToString());
        }
    }

    private BugReport Report() => new(App.VersionText, CurrentSpecs(), Contact, Description);

    private BugSpec[] CurrentSpecs() => Specs.Select(spec => new BugSpec(spec.Key, spec.Label, string.IsNullOrWhiteSpace(spec.Value) ? "Unknown" : spec.Value.Trim())).ToArray();

    private async Task<string> TweakSummaryAsync()
    {
        TweakRecovery? recovery = null;
        string? readError = null;
        try
        {
            recovery = await App.Operations.ReadWindowsRecoveryAsync();
        }
        catch (Exception error)
        {
            readError = error.Message;
        }
        return BugReportService.TweakSummaryJson(
            recovery?.State?.Profiles.Select(profile => profile.Id) ?? Enumerable.Empty<string>(),
            recovery is null ? null : recovery.Pending is not null,
            recovery?.Pending?.Phase,
            new[] { readError, _errorBeforeReport, App.Live.LastError }.Distinct());
    }
}
