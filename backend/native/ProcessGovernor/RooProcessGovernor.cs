using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class RooProcessGovernor
{
    private const string ProductName = "Roo Industries Optimization Suite";
    private const string ActionId = "performance.nativeGovernor.startSession";
    private const int ProcessIoPriorityInformationClass = 33;

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref int information, int informationLength, IntPtr returnLength);

    [DllImport("ntdll.dll")]
    private static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int informationLength);

    [DllImport("gdi32.dll")]
    private static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int priorityClass);

    [DllImport("gdi32.dll")]
    private static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr process, int priorityClass);

    public static int Main(string[] args)
    {
        if (args.Length > 0 && StringEquals(args[0], "--probe"))
        {
            return RunProbe(args);
        }

        string policyPath = GetArg(args, "--policy");
        string outputPath = GetArg(args, "--output");
        MeasurementStart measurement = MeasurementStart.Capture();
        Dictionary<string, object> result;
        int exitCode = 0;

        try
        {
            if (String.IsNullOrWhiteSpace(policyPath))
            {
                throw new InvalidOperationException("Missing --policy <path> argument.");
            }

            result = RunPolicy(Path.GetFullPath(policyPath), measurement);
            string status = AsString(result, "status");
            if (StringEquals(status, "failed"))
            {
                exitCode = 1;
            }
        }
        catch (Exception ex)
        {
            exitCode = 1;
            result = NewFailureResult(policyPath, ex, measurement);
        }

        WriteJson(result, outputPath);
        return exitCode;
    }

    private static int RunProbe(string[] args)
    {
        string mode = args.Length > 1 ? args[1] : "sleep";
        int busySeconds = ParseInt(args.Length > 2 ? args[2] : null, 0);
        int sleepSeconds = ParseInt(args.Length > 3 ? args[3] : null, 60);

        if (StringEquals(mode, "busy") || StringEquals(mode, "busy-then-sleep"))
        {
            DateTime end = DateTime.UtcNow.AddSeconds(Math.Max(1, busySeconds));
            double value = 1;
            while (DateTime.UtcNow < end)
            {
                value += Math.Sqrt(value + 144.0);
                if (value > 1000000.0)
                {
                    value = 1;
                }
            }
        }

        if (sleepSeconds > 0)
        {
            Thread.Sleep(sleepSeconds * 1000);
        }

        return 0;
    }

    private static Dictionary<string, object> RunPolicy(string policyPath, MeasurementStart measurement)
    {
        JavaScriptSerializer serializer = NewSerializer();
        GovernorPolicy policy = serializer.Deserialize<GovernorPolicy>(File.ReadAllText(policyPath));
        if (policy == null)
        {
            throw new InvalidOperationException("Policy JSON did not deserialize.");
        }

        GovernorSession session = policy.session ?? new GovernorSession();
        GovernorSafety safety = policy.safety ?? new GovernorSafety();
        GovernorRestraint restraint = policy.restraint ?? new GovernorRestraint();
        int maxDurationSeconds = Clamp(session.maxDurationSeconds, 1, 300, 3);
        int pollIntervalMilliseconds = Clamp(session.pollIntervalMilliseconds, 100, 60000, 1000);
        bool confirmApply = policy.confirmApply;
        bool allowLiveApply = GetBool(safety.allowLiveApply, false);
        bool requireDisposableTargets = GetBool(safety.requireDisposableTargets, true);
        bool protectForegroundProcess = GetBool(safety.protectForegroundProcess, true);
        bool protectGameObsDiscord = GetBool(safety.protectGameObsDiscord, true);
        bool restoreOnExit = GetBool(session.restoreOnExit, true);
        string policyId = String.IsNullOrWhiteSpace(policy.policyId) ? "native-process-governor" : policy.policyId;
        string sessionId = "native-process-governor-" + SafeId(policyId) + "-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
        string policyDirectory = Path.GetDirectoryName(policyPath);
        string stateRoot = ResolvePolicyPath(session.stateRoot, policyDirectory);
        string sessionDirectory = null;
        string sessionPath = null;
        string backupPath = null;
        ProcessSelectorPlan selectorPlan = ProcessSelectorPlan.FromPolicy(policy);
        int foregroundProcessId = session.foregroundProcessId > 0 ? session.foregroundProcessId : 0;
        if (foregroundProcessId <= 0 && protectForegroundProcess)
        {
            foregroundProcessId = GetForegroundProcessId();
        }

        if (confirmApply)
        {
            if (String.IsNullOrWhiteSpace(stateRoot))
            {
                stateRoot = Path.Combine(Path.GetTempPath(), "roo-native-process-governor-state");
            }

            sessionDirectory = Path.Combine(stateRoot, sessionId);
            Directory.CreateDirectory(sessionDirectory);
            sessionPath = Path.Combine(sessionDirectory, "session.json");
            backupPath = Path.Combine(sessionDirectory, "backup.json");
        }

        List<Dictionary<string, object>> previewItems = new List<Dictionary<string, object>>();
        List<Dictionary<string, object>> changedItems = new List<Dictionary<string, object>>();
        List<Dictionary<string, object>> skippedItems = new List<Dictionary<string, object>>();
        List<Dictionary<string, object>> restoredItems = new List<Dictionary<string, object>>();
        List<Dictionary<string, object>> polls = new List<Dictionary<string, object>>();
        List<BackupSnapshot> snapshots = new List<BackupSnapshot>();
        Dictionary<int, BackupSnapshot> active = new Dictionary<int, BackupSnapshot>();
        HashSet<string> appliedKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        HashSet<string> skipKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        HashSet<string> previewKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        HashSet<string> observedProcessKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long peakWorkingSet = measurement.workingSetBytes;
        long peakPrivateBytes = measurement.privateBytes;
        int fullEnumerationPolls = 0;
        int targetedEnumerationPolls = 0;
        int newlyDetectedProcessCount = 0;
        int duplicateApplySuppressedCount = 0;
        Stopwatch timer = Stopwatch.StartNew();
        DateTime startedAtUtc = DateTime.UtcNow;
        int pollIndex = 0;

        while (timer.Elapsed.TotalSeconds < maxDurationSeconds)
        {
            pollIndex++;
            DateTime pollStartedAtUtc = DateTime.UtcNow;
            List<Dictionary<string, object>> pollPreview = new List<Dictionary<string, object>>();
            List<Dictionary<string, object>> pollChanged = new List<Dictionary<string, object>>();
            List<Dictionary<string, object>> pollSkipped = new List<Dictionary<string, object>>();
            int pollNewlyDetected = 0;
            int pollDuplicateSuppressed = 0;

            ProcessSnapshotBatch processBatch = SnapshotProcesses(selectorPlan);
            if (processBatch.fullEnumeration)
            {
                fullEnumerationPolls++;
            }
            else
            {
                targetedEnumerationPolls++;
            }
            List<ProcessSnapshot> processes = processBatch.processes;
            foreach (ProcessSnapshot process in processes)
            {
                Decision decision = EvaluateProcess(process, policy, safety, foregroundProcessId, protectGameObsDiscord, protectForegroundProcess);
                if (!decision.candidateMatched && !decision.blocked)
                {
                    continue;
                }

                List<Dictionary<string, object>> changes = BuildControlChanges(process, restraint);
                List<Dictionary<string, object>> applicableChanges = ApplicableControlChanges(changes);
                Dictionary<string, object> entry = NewPreviewEntry(process, decision, changes);
                string itemKey = process.pid.ToString() + "|" + process.processName;
                bool newlyDetected = !observedProcessKeys.Contains(itemKey);
                if (newlyDetected)
                {
                    observedProcessKeys.Add(itemKey);
                    if (pollIndex > 1)
                    {
                        pollNewlyDetected++;
                        newlyDetectedProcessCount++;
                    }
                }
                entry["detectionKind"] = pollIndex == 1 ? "existingAtSessionStart" : (newlyDetected ? "newlySpawnedDuringSession" : "previouslyObserved");

                if (!previewKeys.Contains(itemKey))
                {
                    previewItems.Add(entry);
                    previewKeys.Add(itemKey);
                }
                pollPreview.Add(entry);

                if (decision.blocked)
                {
                    AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, decision.reason, decision.reasonCodes, pollIndex, "protected");
                    continue;
                }

                if (applicableChanges.Count == 0)
                {
                    if (HasBlockedControlChange(changes))
                    {
                        AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, BlockedControlReason(changes), new string[] { "NATIVE_GOVERNOR_CONTROL_UNSUPPORTED" }, pollIndex, "unsupported-control");
                        continue;
                    }
                    if (appliedKeys.Contains(itemKey) || active.ContainsKey(process.pid))
                    {
                        pollDuplicateSuppressed++;
                        duplicateApplySuppressedCount++;
                    }
                    AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, "No priority, affinity, or I/O priority change was needed.", new string[] { "NO_CONTROL_CHANGE_NEEDED" }, pollIndex, "no-change");
                    continue;
                }

                if (!confirmApply)
                {
                    continue;
                }

                if (!allowLiveApply)
                {
                    AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, "Policy did not allow confirmed live apply.", new string[] { "LIVE_APPLY_NOT_ALLOWED" }, pollIndex, "not-allowed");
                    continue;
                }

                if (requireDisposableTargets && !IsDisposableTarget(process, safety))
                {
                    AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, "Confirmed apply is allowed only for disposable validation probe targets.", new string[] { "NON_DISPOSABLE_TARGET" }, pollIndex, "non-disposable");
                    continue;
                }

                if (HasBlockedControlChange(changes))
                {
                    AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, BlockedControlReason(changes), new string[] { "NATIVE_GOVERNOR_CONTROL_UNSUPPORTED" }, pollIndex, "unsupported-control");
                }

                if (appliedKeys.Contains(itemKey))
                {
                    pollDuplicateSuppressed++;
                    duplicateApplySuppressedCount++;
                    continue;
                }

                Process live = null;
                try
                {
                    live = Process.GetProcessById(process.pid);
                    BackupSnapshot snapshot = BackupSnapshot.FromProcess(process, live, applicableChanges, policyId, sessionId);
                    ApplyChanges(live, applicableChanges);
                    ProcessSnapshot after = SnapshotProcess(live);
                    snapshots.Add(snapshot);
                    active[process.pid] = snapshot;
                    appliedKeys.Add(itemKey);

                    Dictionary<string, object> changed = Dict(
                        "processId", process.pid,
                        "processName", process.processName,
                        "executablePath", process.executablePath,
                        "originalPriorityClass", snapshot.originalPriorityClass,
                        "appliedPriorityClass", after.priorityClass,
                        "originalAffinityMask", snapshot.originalAffinityMask,
                        "appliedAffinityMask", after.affinityMask,
                        "originalIoPriority", snapshot.originalIoPriority,
                        "appliedIoPriority", after.ioPriority,
                        "originalGpuPriority", snapshot.originalGpuPriority,
                        "appliedGpuPriority", after.gpuPriority,
                        "appliedControls", applicableChanges,
                        "ruleId", decision.ruleId,
                        "reason", decision.reason,
                        "reasonCodes", decision.reasonCodes,
                        "detectionKind", entry["detectionKind"],
                        "lifecycleState", "restrained",
                        "pollIndex", pollIndex,
                        "changedAtUtc", UtcNow()
                    );
                    changedItems.Add(changed);
                    pollChanged.Add(changed);
                    WriteBackup(backupPath, policyId, sessionId, startedAtUtc, snapshots);
                }
                catch (Exception ex)
                {
                    AddSkipOnce(skippedItems, pollSkipped, skipKeys, process, "Apply failed: " + ex.Message, new string[] { "PROCESS_CONTROL_APPLY_FAILED" }, pollIndex, "apply-failed");
                }
                finally
                {
                    if (live != null)
                    {
                        live.Dispose();
                    }
                }
            }

            Process selfSample = Process.GetCurrentProcess();
            selfSample.Refresh();
            if (selfSample.WorkingSet64 > peakWorkingSet)
            {
                peakWorkingSet = selfSample.WorkingSet64;
            }
            if (selfSample.PrivateMemorySize64 > peakPrivateBytes)
            {
                peakPrivateBytes = selfSample.PrivateMemorySize64;
            }

            Dictionary<string, object> poll = Dict(
                "pollIndex", pollIndex,
                "capturedAtUtc", pollStartedAtUtc.ToString("o"),
                "previewCount", pollPreview.Count,
                "changedCount", pollChanged.Count,
                "skippedCount", pollSkipped.Count,
                "activeRestraintCount", active.Count,
                "enumerationMode", processBatch.enumerationMode,
                "scannedProcessCount", processBatch.scannedProcessCount,
                "snapshotProcessCount", processes.Count,
                "newlyDetectedProcessCount", pollNewlyDetected,
                "duplicateApplySuppressedCount", pollDuplicateSuppressed,
                "previewItems", pollPreview,
                "changedItems", pollChanged,
                "skippedItems", pollSkipped
            );
            polls.Add(poll);

            if (confirmApply)
            {
                WriteSession(sessionPath, policy, sessionId, "running", startedAtUtc, null, pollIndex, stateRoot, sessionPath, backupPath, changedItems, skippedItems, restoredItems, active, polls);
            }

            int remainingMs = (int)Math.Round((maxDurationSeconds - timer.Elapsed.TotalSeconds) * 1000.0);
            if (remainingMs <= 0)
            {
                break;
            }
            Thread.Sleep(Math.Min(pollIntervalMilliseconds, remainingMs));
        }

        timer.Stop();

        if (confirmApply && restoreOnExit)
        {
            foreach (BackupSnapshot snapshot in new List<BackupSnapshot>(active.Values))
            {
                Dictionary<string, object> restored = RestoreSnapshot(snapshot, restoredItems.Count + 1);
                restoredItems.Add(restored);
            }
            active.Clear();
        }

        string completedAtUtc = UtcNow();
        if (confirmApply)
        {
            WriteSession(sessionPath, policy, sessionId, "completed", startedAtUtc, completedAtUtc, pollIndex, stateRoot, sessionPath, backupPath, changedItems, skippedItems, restoredItems, active, polls);
        }

        Dictionary<string, object> footprint = BuildFootprint(measurement, peakWorkingSet, peakPrivateBytes);
        Dictionary<string, object> backup = confirmApply ? NewBackupMetadata(policyId, sessionId, startedAtUtc, backupPath, snapshots) : null;
        Dictionary<string, object> result = Dict(
            "actionId", ActionId,
            "schemaVersion", 1,
            "productName", ProductName,
            "policyId", policyId,
            "correlationId", confirmApply ? sessionId : null,
            "sessionId", confirmApply ? sessionId : null,
            "dryRun", !confirmApply,
            "confirmApply", confirmApply,
            "status", "completed",
            "sessionStatus", "completed",
            "startedAtUtc", startedAtUtc.ToString("o"),
            "completedAtUtc", completedAtUtc,
            "boundedSession", true,
            "maxDurationSeconds", maxDurationSeconds,
            "pollIntervalMilliseconds", pollIntervalMilliseconds,
            "pollCount", pollIndex,
            "fullEnumerationPollCount", fullEnumerationPolls,
            "targetedEnumerationPollCount", targetedEnumerationPolls,
            "stateRoot", confirmApply ? stateRoot : null,
            "sessionPath", sessionPath,
            "backupManifestPath", backupPath,
            "restorable", active.Count > 0,
            "activeRestraints", SnapshotsToDictionaries(active.Values),
            "preview", previewItems,
            "changedItems", changedItems,
            "skippedItems", skippedItems,
            "restoredItems", restoredItems,
            "polls", polls,
            "backup", backup,
            "footprint", footprint,
            "residentPolicy", Dict(
                "boundedResidentPolicySession", true,
                "launchWatcherEnabled", true,
                "launchWatcherMode", selectorPlan.useTargetedEnumeration ? "targeted-process-name-polling" : "full-process-polling",
                "newlySpawnedProcessDetection", true,
                "newlyDetectedProcessCount", newlyDetectedProcessCount,
                "duplicateApplySuppressedCount", duplicateApplySuppressedCount,
                "restoreOnExit", restoreOnExit,
                "restoreLifecycle", restoreOnExit ? "calm-restore-on-session-exit" : "leave-restorable-backup",
                "protectedRuleCategories", new string[] { "foregroundGame", "captureStreaming", "voiceChat", "antiCheat", "network", "audioInput", "gpuDriver", "security", "windowsCore" }
            ),
            "engineCapabilities", BuildEngineCapabilities(selectorPlan),
            "host", Dict(
                "processId", Process.GetCurrentProcess().Id,
                "processName", Process.GetCurrentProcess().ProcessName,
                "executionMode", "compiledWorker",
                "workerKind", "csc-dotnet-framework",
                "workerClassification", "managed-csc",
                "workerIsTrueNative", false,
                "nativeAot", false,
                "serviceReady", true,
                "serviceInstalled", false,
                "serviceInstallActionPerformed", false,
                "persistentUiProcessRequired", false
            ),
            "dependencyProof", Dict(
                "frontendProcessRequired", false,
                "persistentUiProcessRequired", false,
                "externalProcessGovernorDependencyRequired", false,
                "processLassoProcessStartedByHost", false
            ),
            "safety", Dict(
                "allowLiveApply", allowLiveApply,
                "requireDisposableTargets", requireDisposableTargets,
                "protectForegroundProcess", protectForegroundProcess,
                "protectGameObsDiscord", protectGameObsDiscord,
                "confirmedApplyOnlyDisposableValidationProbes", requireDisposableTargets
            ),
            "warnings", NewWarnings(confirmApply, allowLiveApply, requireDisposableTargets, restraint),
            "errors", new List<Dictionary<string, object>>(),
            "logs", new List<Dictionary<string, object>> {
                NewLog("Native process governor bounded session completed without service installation or system-tweak changes.", "info")
            }
        );
        return result;
    }

    private static Decision EvaluateProcess(ProcessSnapshot process, GovernorPolicy policy, GovernorSafety safety, int foregroundProcessId, bool protectGameObsDiscord, bool protectForegroundProcess)
    {
        Decision decision = new Decision();
        decision.ruleId = "native-governor-skip";
        decision.reason = "Process is not a governor candidate.";
        decision.reasonCodes = new List<string>();

        Selector matchedSelector = FindCandidateSelector(process, policy);
        if (matchedSelector != null)
        {
            decision.candidateMatched = true;
            decision.ruleId = String.IsNullOrWhiteSpace(matchedSelector.ruleId) ? "native-governor-candidate" : matchedSelector.ruleId;
            decision.reason = String.IsNullOrWhiteSpace(matchedSelector.reason) ? "Process matched a native governor candidate selector." : matchedSelector.reason;
            AddRange(decision.reasonCodes, matchedSelector.reasonCodes);
            if (decision.reasonCodes.Count == 0)
            {
                decision.reasonCodes.Add("NATIVE_GOVERNOR_CANDIDATE");
            }
        }

        if (process.pid <= 4)
        {
            BlockDecision(decision, "System process IDs are excluded from native governor restraint.", "SYSTEM_PROCESS_EXCLUDED");
        }

        if (process.pid == Process.GetCurrentProcess().Id)
        {
            BlockDecision(decision, "The native worker protects its own process.", "WORKER_SELF_PROTECTED");
        }

        if (protectForegroundProcess && foregroundProcessId > 0 && process.pid == foregroundProcessId)
        {
            BlockDecision(decision, "Foreground process is excluded from native governor restraint.", "FOREGROUND_PROCESS_EXCLUDED");
        }

        if (IsCoreProtectedCategory(process.category))
        {
            BlockDecision(decision, "Windows core, security, network, audio/input, anti-cheat, and GPU driver categories are protected from native governor restraint.", "PROTECTED_CATEGORY");
        }

        if (protectGameObsDiscord && (StringEquals(process.category, "foregroundGame") || StringEquals(process.category, "captureStreaming") || StringEquals(process.category, "voiceChat")))
        {
            BlockDecision(decision, "Foreground game, OBS/capture, and Discord/voice companion categories are protected.", "GAME_OBS_DISCORD_PROTECTED");
        }

        ProtectedProcessItem item = FindProtectedProcess(process, policy);
        if (item != null)
        {
            string reason = String.IsNullOrWhiteSpace(item.reason) ? "Policy protected process match." : item.reason;
            BlockDecision(decision, reason, "POLICY_PROTECTED_PROCESS");
            AddRange(decision.reasonCodes, item.reasonCodes);
        }

        if (decision.blocked)
        {
            decision.ruleId = "native-governor-skip";
        }

        return decision;
    }

    private static Selector FindCandidateSelector(ProcessSnapshot process, GovernorPolicy policy)
    {
        Selector[] selectors = policy.candidateSelectors ?? new Selector[0];
        for (int i = 0; i < selectors.Length; i++)
        {
            Selector selector = selectors[i];
            if (selector == null)
            {
                continue;
            }
            if (selector.enabled.HasValue && !selector.enabled.Value)
            {
                continue;
            }
            MatchRule match = selector.match ?? new MatchRule();
            if (MatchesRule(process, match))
            {
                return selector;
            }
        }
        return null;
    }

    private static ProtectedProcessItem FindProtectedProcess(ProcessSnapshot process, GovernorPolicy policy)
    {
        ProtectedProcessItem[] items = policy.protectedProcesses ?? new ProtectedProcessItem[0];
        for (int i = 0; i < items.Length; i++)
        {
            ProtectedProcessItem item = items[i];
            if (item == null)
            {
                continue;
            }

            MatchRule match = new MatchRule();
            match.processNames = Merge(item.names, item.processNames);
            match.namePatterns = item.namePatterns;
            match.pathPatterns = item.pathPatterns;
            match.processCategories = item.processCategories;
            if (MatchesRule(process, match))
            {
                return item;
            }
        }
        return null;
    }

    private static bool MatchesRule(ProcessSnapshot process, MatchRule match)
    {
        if (match == null)
        {
            return false;
        }

        bool matched = false;
        bool hasPositive = false;

        if (AnyNameMatch(process.processName, match.processNames) || AnyNameMatch(process.processName, match.names))
        {
            matched = true;
            hasPositive = true;
        }
        if (HasAny(match.processNames) || HasAny(match.names))
        {
            hasPositive = true;
        }

        if (AnyWildcardMatch(process.processName, match.namePatterns))
        {
            matched = true;
            hasPositive = true;
        }
        if (HasAny(match.namePatterns))
        {
            hasPositive = true;
        }

        if (AnyWildcardMatch(process.executablePath, match.pathPatterns))
        {
            matched = true;
            hasPositive = true;
        }
        if (HasAny(match.pathPatterns))
        {
            hasPositive = true;
        }

        if (AnyStringEquals(process.category, match.processCategories))
        {
            matched = true;
            hasPositive = true;
        }
        if (HasAny(match.processCategories))
        {
            hasPositive = true;
        }

        if (!hasPositive || !matched)
        {
            return false;
        }

        if (AnyNameMatch(process.processName, match.excludeProcessNames))
        {
            return false;
        }
        if (AnyWildcardMatch(process.processName, match.excludeNamePatterns))
        {
            return false;
        }
        if (AnyStringEquals(process.category, match.excludeProcessCategories))
        {
            return false;
        }

        return true;
    }

    private static List<Dictionary<string, object>> BuildControlChanges(ProcessSnapshot process, GovernorRestraint restraint)
    {
        List<Dictionary<string, object>> changes = new List<Dictionary<string, object>>();
        string priority = String.IsNullOrWhiteSpace(restraint.priorityClass) ? null : restraint.priorityClass;
        if (!String.IsNullOrWhiteSpace(priority) && IsPriorityAllowed(priority) && !StringEquals(process.priorityClass, priority))
        {
            changes.Add(Dict(
                "control", "priorityClass",
                "currentValue", process.priorityClass,
                "proposedValue", NormalizePriority(priority),
                "action", "setPriority",
                "reason", "Temporarily set process priority from native worker.",
                "blocked", false,
                "blockedReason", null
            ));
        }

        if (restraint.affinityMask.HasValue && restraint.affinityMask.Value > 0 && IsAffinityAllowed(restraint.affinityMask.Value) && process.affinityMask != restraint.affinityMask.Value)
        {
            changes.Add(Dict(
                "control", "affinityMask",
                "currentValue", process.affinityMask,
                "proposedValue", restraint.affinityMask.Value,
                "action", "setAffinity",
                "reason", "Temporarily set CPU affinity from native worker.",
                "blocked", false,
                "blockedReason", null
            ));
        }

        string ioPriority = String.IsNullOrWhiteSpace(restraint.ioPriority) ? null : NormalizeIoPriority(restraint.ioPriority);
        if (!String.IsNullOrWhiteSpace(ioPriority) && IsIoPriorityAllowed(ioPriority) && !StringEquals(process.ioPriority, ioPriority))
        {
            changes.Add(Dict(
                "control", "ioPriority",
                "currentValue", process.ioPriority,
                "proposedValue", ioPriority,
                "action", "setIoPriority",
                "reason", "Temporarily set process I/O priority from native worker through NtSetInformationProcess.",
                "blocked", false,
                "blockedReason", null
            ));
        }

        string gpuPriority = String.IsNullOrWhiteSpace(restraint.gpuPriority) ? null : NormalizeGpuPriority(restraint.gpuPriority);
        if (!String.IsNullOrWhiteSpace(gpuPriority))
        {
            if (!IsGpuPriorityAllowed(gpuPriority))
            {
                changes.Add(Dict(
                    "control", "gpuPriority",
                    "currentValue", process.gpuPriority,
                    "proposedValue", gpuPriority,
                    "action", "setGpuPriority",
                    "reason", "Requested GPU scheduling priority is outside the native worker allow-list.",
                    "blocked", true,
                    "blockedReason", "GPU priority '" + restraint.gpuPriority + "' is outside the allow-list."
                ));
            }
            else if (!process.gpuPriorityAvailable)
            {
                changes.Add(Dict(
                    "control", "gpuPriority",
                    "currentValue", process.gpuPriority,
                    "proposedValue", gpuPriority,
                    "action", "setGpuPriority",
                    "reason", "Native D3DKMT GPU scheduling priority is unavailable for this process.",
                    "blocked", true,
                    "blockedReason", "D3DKMTGetProcessSchedulingPriorityClass failed for this process (status " + process.gpuPriorityStatus.ToString() + ")."
                ));
            }
            else if (!StringEquals(process.gpuPriority, gpuPriority))
            {
                changes.Add(Dict(
                    "control", "gpuPriority",
                    "currentValue", process.gpuPriority,
                    "proposedValue", gpuPriority,
                    "action", "setGpuPriority",
                    "reason", "Temporarily set process GPU scheduling priority from native worker through D3DKMT.",
                    "blocked", false,
                    "blockedReason", null
                ));
            }
        }

        return changes;
    }

    private static Dictionary<string, object> NewPreviewEntry(ProcessSnapshot process, Decision decision, List<Dictionary<string, object>> changes)
    {
        string proposedPriority = process.priorityClass;
        long proposedAffinity = process.affinityMask;
        string proposedIoPriority = process.ioPriority;
        string proposedGpuPriority = process.gpuPriority;
        int applicableChangeCount = CountApplicableControlChanges(changes);
        for (int i = 0; i < changes.Count; i++)
        {
            string control = AsString(changes[i], "control");
            if (IsBlockedChange(changes[i]))
            {
                continue;
            }
            if (StringEquals(control, "priorityClass"))
            {
                proposedPriority = AsString(changes[i], "proposedValue");
            }
            if (StringEquals(control, "affinityMask"))
            {
                proposedAffinity = Convert.ToInt64(changes[i]["proposedValue"]);
            }
            if (StringEquals(control, "ioPriority"))
            {
                proposedIoPriority = AsString(changes[i], "proposedValue");
            }
            if (StringEquals(control, "gpuPriority"))
            {
                proposedGpuPriority = AsString(changes[i], "proposedValue");
            }
        }

        return Dict(
            "previewId", SafeId("native-" + process.processName + "-" + process.pid),
            "type", "nativeProcessGovernorRestraint",
            "target", process.processName + ":" + process.pid,
            "displayName", process.processName,
            "processId", process.pid,
            "processName", process.processName,
            "executablePath", process.executablePath,
            "currentPriorityClass", process.priorityClass,
            "proposedPriorityClass", proposedPriority,
            "currentAffinityMask", process.affinityMask,
            "proposedAffinityMask", proposedAffinity,
            "currentIoPriority", process.ioPriority,
            "proposedIoPriority", proposedIoPriority,
            "currentGpuPriority", process.gpuPriority,
            "proposedGpuPriority", proposedGpuPriority,
            "gpuPriorityAvailable", process.gpuPriorityAvailable,
            "gpuPriorityStatus", process.gpuPriorityStatus,
            "proposedAction", decision.blocked || applicableChangeCount == 0 ? "noChange" : "setProcessControls",
            "controlChanges", changes,
            "ruleId", decision.ruleId,
            "reason", decision.reason,
            "reasonCodes", decision.reasonCodes.ToArray(),
            "classification", decision.blocked ? "protected" : "demotionCandidate",
            "blocked", decision.blocked,
            "blockedReason", decision.blocked ? decision.reason : null,
            "risk", decision.blocked ? "protected" : "low",
            "confidence", "medium",
            "protected", decision.blocked,
            "requiresConfirmation", !decision.blocked && applicableChangeCount > 0,
            "rollbackSupported", !decision.blocked && applicableChangeCount > 0,
            "currentState", Dict(
                "priorityClass", process.priorityClass,
                "affinityMask", process.affinityMask,
                "ioPriority", process.ioPriority,
                "gpuPriority", process.gpuPriority,
                "category", process.category
            ),
            "proposedState", Dict(
                "priorityClass", proposedPriority,
                "affinityMask", proposedAffinity,
                "ioPriority", proposedIoPriority,
                "gpuPriority", proposedGpuPriority
            )
        );
    }

    private static void ApplyChanges(Process process, List<Dictionary<string, object>> changes)
    {
        for (int i = 0; i < changes.Count; i++)
        {
            string control = AsString(changes[i], "control");
            if (StringEquals(control, "priorityClass"))
            {
                string priority = NormalizePriority(AsString(changes[i], "proposedValue"));
                process.PriorityClass = (ProcessPriorityClass)Enum.Parse(typeof(ProcessPriorityClass), priority, true);
            }
            else if (StringEquals(control, "affinityMask"))
            {
                long mask = Convert.ToInt64(changes[i]["proposedValue"]);
                process.ProcessorAffinity = new IntPtr(mask);
            }
            else if (StringEquals(control, "ioPriority"))
            {
                SetIoPriority(process, NormalizeIoPriority(AsString(changes[i], "proposedValue")));
            }
            else if (StringEquals(control, "gpuPriority"))
            {
                SetGpuPriority(process, NormalizeGpuPriority(AsString(changes[i], "proposedValue")));
            }
        }
    }

    private static Dictionary<string, object> RestoreSnapshot(BackupSnapshot snapshot, int restoreIndex)
    {
        List<Dictionary<string, object>> restoredControls = new List<Dictionary<string, object>>();
        string reason = "Restore original process controls from native governor backup.";
        bool blocked = false;
        string blockedReason = null;

        try
        {
            Process live = Process.GetProcessById(snapshot.processId);
            ProcessSnapshot current = SnapshotProcess(live);
            if (!NameEquals(current.processName, snapshot.processName))
            {
                blocked = true;
                blockedReason = "Live process name no longer matches backup snapshot.";
            }
            else
            {
                if (!String.IsNullOrWhiteSpace(snapshot.originalPriorityClass) && !StringEquals(current.priorityClass, snapshot.originalPriorityClass))
                {
                    live.PriorityClass = (ProcessPriorityClass)Enum.Parse(typeof(ProcessPriorityClass), snapshot.originalPriorityClass, true);
                    restoredControls.Add(Dict("control", "priorityClass", "restoredValue", snapshot.originalPriorityClass));
                }
                if (snapshot.originalAffinityMask > 0 && current.affinityMask != snapshot.originalAffinityMask)
                {
                    live.ProcessorAffinity = new IntPtr(snapshot.originalAffinityMask);
                    restoredControls.Add(Dict("control", "affinityMask", "restoredValue", snapshot.originalAffinityMask));
                }
                if (!String.IsNullOrWhiteSpace(snapshot.originalIoPriority) && !StringEquals(current.ioPriority, snapshot.originalIoPriority))
                {
                    SetIoPriority(live, snapshot.originalIoPriority);
                    restoredControls.Add(Dict("control", "ioPriority", "restoredValue", snapshot.originalIoPriority));
                }
                if (!String.IsNullOrWhiteSpace(snapshot.originalGpuPriority) && !StringEquals(current.gpuPriority, snapshot.originalGpuPriority))
                {
                    SetGpuPriority(live, snapshot.originalGpuPriority);
                    restoredControls.Add(Dict("control", "gpuPriority", "restoredValue", snapshot.originalGpuPriority));
                }
            }
        }
        catch (Exception ex)
        {
            blocked = true;
            blockedReason = ex.Message;
        }

        return Dict(
            "processId", snapshot.processId,
            "processName", snapshot.processName,
            "executablePath", snapshot.executablePath,
            "originalPriorityClass", snapshot.originalPriorityClass,
            "originalAffinityMask", snapshot.originalAffinityMask,
            "originalIoPriority", snapshot.originalIoPriority,
            "originalGpuPriority", snapshot.originalGpuPriority,
            "restoredControls", restoredControls,
            "restoreIndex", restoreIndex,
            "restoredAtUtc", UtcNow(),
            "lifecycleState", blocked ? "restoreBlocked" : "restored",
            "reason", blocked ? blockedReason : reason,
            "blocked", blocked
        );
    }

    private static ProcessSnapshotBatch SnapshotProcesses(ProcessSelectorPlan selectorPlan)
    {
        ProcessSnapshotBatch batch = new ProcessSnapshotBatch();
        List<ProcessSnapshot> items = new List<ProcessSnapshot>();
        List<Process> processes = new List<Process>();
        HashSet<int> seenProcessIds = new HashSet<int>();

        if (selectorPlan != null && selectorPlan.useTargetedEnumeration)
        {
            batch.fullEnumeration = false;
            batch.enumerationMode = "targeted-process-name";
            for (int i = 0; i < selectorPlan.exactProcessNames.Count; i++)
            {
                string processName = ProcessNameWithoutExe(selectorPlan.exactProcessNames[i]);
                if (String.IsNullOrWhiteSpace(processName))
                {
                    continue;
                }
                Process[] namedProcesses = Process.GetProcessesByName(processName);
                for (int j = 0; j < namedProcesses.Length; j++)
                {
                    if (seenProcessIds.Add(namedProcesses[j].Id))
                    {
                        processes.Add(namedProcesses[j]);
                    }
                    else
                    {
                        namedProcesses[j].Dispose();
                    }
                }
            }
        }
        else
        {
            batch.fullEnumeration = true;
            batch.enumerationMode = "full-process-list";
            Process[] allProcesses = Process.GetProcesses();
            for (int i = 0; i < allProcesses.Length; i++)
            {
                if (seenProcessIds.Add(allProcesses[i].Id))
                {
                    processes.Add(allProcesses[i]);
                }
                else
                {
                    allProcesses[i].Dispose();
                }
            }
        }

        batch.scannedProcessCount = processes.Count;
        for (int i = 0; i < processes.Count; i++)
        {
            try
            {
                items.Add(SnapshotProcess(processes[i]));
            }
            catch
            {
            }
            finally
            {
                processes[i].Dispose();
            }
        }
        batch.processes = items;
        return batch;
    }

    private static ProcessSnapshot SnapshotProcess(Process process)
    {
        ProcessSnapshot snap = new ProcessSnapshot();
        snap.pid = process.Id;
        snap.processName = EnsureExeName(process.ProcessName);
        snap.executablePath = SafeProcessPath(process);
        snap.priorityClass = SafePriority(process);
        snap.affinityMask = SafeAffinity(process);
        snap.ioPriority = SafeIoPriority(process);
        GpuPriorityState gpu = SafeGpuPriority(process);
        snap.gpuPriority = gpu.name;
        snap.gpuPriorityAvailable = gpu.available;
        snap.gpuPriorityStatus = gpu.status;
        snap.category = CategoryForName(snap.processName);
        return snap;
    }

    private static string CategoryForName(string processName)
    {
        string n = NormalizeName(processName);
        if (n.IndexOf("overwatch", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("valorant", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("fortnite", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("r5apex", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "foregroundGame";
        }
        if (n.IndexOf("obs", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("streamlabs", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "captureStreaming";
        }
        if (n.IndexOf("discord", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("teamspeak", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("mumble", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "voiceChat";
        }
        if (n.IndexOf("vgc", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("vgtray", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("easyanticheat", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("eaclauncher", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("beservice", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("battleye", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("faceit", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "antiCheat";
        }
        if (n == "system" || n == "registry" || n == "smss" || n == "csrss" || n == "wininit" || n == "services" ||
            n == "lsass" || n == "svchost" || n == "fontdrvhost" || n == "winlogon" || n == "dwm" || n == "explorer" ||
            n == "taskhostw" || n == "sihost" || n == "runtimebroker" || n == "searchindexer")
        {
            return "windowsCore";
        }
        if (n == "msmpeng" || n.IndexOf("securityhealth", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("mpssvc", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("defender", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("smartscreen", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("sense", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "security";
        }
        if (n.IndexOf("tailscale", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("wireguard", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("openvpn", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("dns", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("dhcp", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("zerotier", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("wlanext", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("dashost", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "network";
        }
        if (n.IndexOf("audiodg", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("wispr flow", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("inputapp", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("textinputhost", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("ctfmon", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("lghub", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("razer", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("steelseries", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("nahimic", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "audioInput";
        }
        if (n.IndexOf("nvdisplay", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("nvidia", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("nvcontainer", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("radeon", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("amdrsserv", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("amdow", StringComparison.OrdinalIgnoreCase) >= 0 ||
            n.IndexOf("igfx", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("intelgraphics", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "gpuDriver";
        }
        return "backgroundApp";
    }

    private static bool IsCoreProtectedCategory(string category)
    {
        return StringEquals(category, "windowsCore") ||
            StringEquals(category, "security") ||
            StringEquals(category, "network") ||
            StringEquals(category, "audioInput") ||
            StringEquals(category, "gpuDriver") ||
            StringEquals(category, "antiCheat");
    }

    private static bool IsDisposableTarget(ProcessSnapshot process, GovernorSafety safety)
    {
        string[] patterns = safety.disposableNamePatterns ?? new string[0];
        if (patterns.Length == 0)
        {
            patterns = new string[] { "Roo*Probe.exe", "RooNativeGovernor*Probe.exe" };
        }
        return AnyWildcardMatch(process.processName, patterns);
    }

    private static bool IsPriorityAllowed(string priority)
    {
        string normalized = NormalizePriority(priority);
        return normalized == "Idle" || normalized == "BelowNormal" || normalized == "Normal" || normalized == "AboveNormal" || normalized == "High";
    }

    private static string NormalizePriority(string priority)
    {
        if (StringEquals(priority, "belownormal")) return "BelowNormal";
        if (StringEquals(priority, "abovenormal")) return "AboveNormal";
        if (StringEquals(priority, "idle")) return "Idle";
        if (StringEquals(priority, "normal")) return "Normal";
        if (StringEquals(priority, "high")) return "High";
        return priority;
    }

    private static bool IsAffinityAllowed(long mask)
    {
        if (mask <= 0)
        {
            return false;
        }
        int processorCount = Environment.ProcessorCount;
        if (processorCount >= 63)
        {
            return true;
        }
        long allowedMask = (1L << processorCount) - 1L;
        return (mask & allowedMask) == mask;
    }

    private static bool IsIoPriorityAllowed(string priority)
    {
        return IoPriorityToValue(priority).HasValue;
    }

    private static string NormalizeIoPriority(string priority)
    {
        if (StringEquals(priority, "idle")) return "VeryLow";
        if (StringEquals(priority, "verylow")) return "VeryLow";
        if (StringEquals(priority, "low")) return "Low";
        if (StringEquals(priority, "normal")) return "Normal";
        return priority;
    }

    private static int? IoPriorityToValue(string priority)
    {
        string normalized = NormalizeIoPriority(priority);
        if (StringEquals(normalized, "VeryLow")) return 0;
        if (StringEquals(normalized, "Low")) return 1;
        if (StringEquals(normalized, "Normal")) return 2;
        return null;
    }

    private static string IoPriorityFromValue(int value)
    {
        if (value == 0) return "VeryLow";
        if (value == 1) return "Low";
        if (value == 2) return "Normal";
        return "Unknown(" + value.ToString() + ")";
    }

    private static bool IsGpuPriorityAllowed(string priority)
    {
        return GpuPriorityToValue(priority).HasValue;
    }

    private static string NormalizeGpuPriority(string priority)
    {
        if (StringEquals(priority, "idle")) return "Idle";
        if (StringEquals(priority, "belownormal")) return "BelowNormal";
        if (StringEquals(priority, "normal")) return "Normal";
        if (StringEquals(priority, "abovenormal")) return "AboveNormal";
        if (StringEquals(priority, "high")) return "High";
        if (StringEquals(priority, "realtime")) return "Realtime";
        if (StringEquals(priority, "realTime")) return "Realtime";
        return priority;
    }

    private static int? GpuPriorityToValue(string priority)
    {
        string normalized = NormalizeGpuPriority(priority);
        if (StringEquals(normalized, "Idle")) return 0;
        if (StringEquals(normalized, "BelowNormal")) return 1;
        if (StringEquals(normalized, "Normal")) return 2;
        if (StringEquals(normalized, "AboveNormal")) return 3;
        if (StringEquals(normalized, "High")) return 4;
        if (StringEquals(normalized, "Realtime")) return 5;
        return null;
    }

    private static string GpuPriorityFromValue(int value)
    {
        if (value == 0) return "Idle";
        if (value == 1) return "BelowNormal";
        if (value == 2) return "Normal";
        if (value == 3) return "AboveNormal";
        if (value == 4) return "High";
        if (value == 5) return "Realtime";
        return "Unknown(" + value.ToString() + ")";
    }

    private static string SafeIoPriority(Process process)
    {
        try
        {
            int value = 0;
            int status = NtQueryInformationProcess(process.Handle, ProcessIoPriorityInformationClass, ref value, 4, IntPtr.Zero);
            if (status == 0)
            {
                return IoPriorityFromValue(value);
            }
        }
        catch
        {
        }
        return null;
    }

    private static void SetIoPriority(Process process, string priority)
    {
        int? value = IoPriorityToValue(priority);
        if (!value.HasValue)
        {
            throw new InvalidOperationException("I/O priority '" + priority + "' is outside the allow-list.");
        }
        int nativeValue = value.Value;
        int status = NtSetInformationProcess(process.Handle, ProcessIoPriorityInformationClass, ref nativeValue, 4);
        if (status != 0)
        {
            throw new InvalidOperationException("Failed to set I/O priority '" + priority + "' (NTSTATUS " + status.ToString() + ").");
        }
    }

    private static GpuPriorityState SafeGpuPriority(Process process)
    {
        GpuPriorityState state = new GpuPriorityState();
        state.available = false;
        state.name = null;
        state.status = 0;
        try
        {
            int value;
            int status = D3DKMTGetProcessSchedulingPriorityClass(process.Handle, out value);
            state.status = status;
            if (status == 0)
            {
                state.available = true;
                state.name = GpuPriorityFromValue(value);
            }
        }
        catch
        {
            state.available = false;
            state.name = null;
            state.status = Int32.MinValue;
        }
        return state;
    }

    private static void SetGpuPriority(Process process, string priority)
    {
        int? value = GpuPriorityToValue(priority);
        if (!value.HasValue)
        {
            throw new InvalidOperationException("GPU priority '" + priority + "' is outside the allow-list.");
        }
        int status = D3DKMTSetProcessSchedulingPriorityClass(process.Handle, value.Value);
        if (status != 0)
        {
            throw new InvalidOperationException("Failed to set GPU priority '" + priority + "' (status " + status.ToString() + ").");
        }
    }

    private static bool IsBlockedChange(Dictionary<string, object> change)
    {
        if (change == null || !change.ContainsKey("blocked") || change["blocked"] == null)
        {
            return false;
        }
        try
        {
            return Convert.ToBoolean(change["blocked"]);
        }
        catch
        {
            return false;
        }
    }

    private static List<Dictionary<string, object>> ApplicableControlChanges(List<Dictionary<string, object>> changes)
    {
        List<Dictionary<string, object>> applicable = new List<Dictionary<string, object>>();
        if (changes == null)
        {
            return applicable;
        }
        for (int i = 0; i < changes.Count; i++)
        {
            if (!IsBlockedChange(changes[i]))
            {
                applicable.Add(changes[i]);
            }
        }
        return applicable;
    }

    private static int CountApplicableControlChanges(List<Dictionary<string, object>> changes)
    {
        return ApplicableControlChanges(changes).Count;
    }

    private static bool HasBlockedControlChange(List<Dictionary<string, object>> changes)
    {
        if (changes == null)
        {
            return false;
        }
        for (int i = 0; i < changes.Count; i++)
        {
            if (IsBlockedChange(changes[i]))
            {
                return true;
            }
        }
        return false;
    }

    private static string BlockedControlReason(List<Dictionary<string, object>> changes)
    {
        if (changes == null)
        {
            return "Requested native process control is unsupported for this process.";
        }
        for (int i = 0; i < changes.Count; i++)
        {
            if (IsBlockedChange(changes[i]))
            {
                string blockedReason = AsString(changes[i], "blockedReason");
                if (!String.IsNullOrWhiteSpace(blockedReason))
                {
                    return blockedReason;
                }
                string reason = AsString(changes[i], "reason");
                if (!String.IsNullOrWhiteSpace(reason))
                {
                    return reason;
                }
            }
        }
        return "Requested native process control is unsupported for this process.";
    }

    private static void AddSkipOnce(List<Dictionary<string, object>> skippedItems, List<Dictionary<string, object>> pollSkipped, HashSet<string> skipKeys, ProcessSnapshot process, string reason, IEnumerable<string> reasonCodes, int pollIndex, string category)
    {
        string key = process.pid.ToString() + "|" + process.processName + "|" + category;
        Dictionary<string, object> skip = Dict(
            "processId", process.pid,
            "processName", process.processName,
            "executablePath", process.executablePath,
            "reason", reason,
            "reasonCodes", ToArray(reasonCodes),
            "pollIndex", pollIndex,
            "skippedAtUtc", UtcNow()
        );
        pollSkipped.Add(skip);
        if (!skipKeys.Contains(key))
        {
            skippedItems.Add(skip);
            skipKeys.Add(key);
        }
    }

    private static void BlockDecision(Decision decision, string reason, string reasonCode)
    {
        decision.blocked = true;
        if (String.IsNullOrWhiteSpace(decision.reason) || StringEquals(decision.reason, "Process is not a governor candidate."))
        {
            decision.reason = reason;
        }
        else if (decision.reason.IndexOf(reason, StringComparison.OrdinalIgnoreCase) < 0)
        {
            decision.reason = decision.reason + " " + reason;
        }
        if (!decision.reasonCodes.Contains(reasonCode))
        {
            decision.reasonCodes.Add(reasonCode);
        }
    }

    private static void WriteBackup(string backupPath, string policyId, string sessionId, DateTime startedAtUtc, List<BackupSnapshot> snapshots)
    {
        if (String.IsNullOrWhiteSpace(backupPath))
        {
            return;
        }
        Dictionary<string, object> backup = NewBackupMetadata(policyId, sessionId, startedAtUtc, backupPath, snapshots);
        WriteJsonFile(backup, backupPath);
    }

    private static Dictionary<string, object> NewBackupMetadata(string policyId, string sessionId, DateTime startedAtUtc, string backupPath, List<BackupSnapshot> snapshots)
    {
        return Dict(
            "schemaVersion", 1,
            "productName", ProductName,
            "backupId", "native-process-governor-" + SafeId(policyId) + "-" + startedAtUtc.ToString("yyyyMMdd-HHmmss"),
            "sessionId", sessionId,
            "createdAtUtc", startedAtUtc.ToString("o"),
            "scope", "native-process-governor-process-controls",
            "location", backupPath,
            "restorePoint", Dict(
                "requested", false,
                "status", "not-required-for-process-restraint",
                "id", null
            ),
            "snapshots", SnapshotsToDictionaries(snapshots),
            "rollbackActionId", "performance.nativeGovernor.restore",
            "rollbackSupported", true
        );
    }

    private static void WriteSession(string sessionPath, GovernorPolicy policy, string sessionId, string status, DateTime startedAtUtc, string completedAtUtc, int pollCount, string stateRoot, string sessionStatePath, string backupPath, List<Dictionary<string, object>> changedItems, List<Dictionary<string, object>> skippedItems, List<Dictionary<string, object>> restoredItems, Dictionary<int, BackupSnapshot> active, List<Dictionary<string, object>> polls)
    {
        if (String.IsNullOrWhiteSpace(sessionPath))
        {
            return;
        }
        Dictionary<string, object> session = Dict(
            "schemaVersion", 1,
            "productName", ProductName,
            "actionId", ActionId,
            "sessionId", sessionId,
            "policyId", policy.policyId,
            "status", status,
            "sessionStatus", status,
            "startedAtUtc", startedAtUtc.ToString("o"),
            "completedAtUtc", completedAtUtc,
            "stateRoot", stateRoot,
            "sessionPath", sessionStatePath,
            "backupManifestPath", backupPath,
            "pollCount", pollCount,
            "restorable", active.Count > 0,
            "activeRestraints", SnapshotsToDictionaries(active.Values),
            "changedItems", changedItems,
            "skippedItems", skippedItems,
            "restoredItems", restoredItems,
            "polls", polls
        );
        WriteJsonFile(session, sessionPath);
    }

    private static Dictionary<string, object> BuildFootprint(MeasurementStart measurement, long peakWorkingSet, long peakPrivateBytes)
    {
        Process self = Process.GetCurrentProcess();
        self.Refresh();
        double elapsed = Math.Max(0.001, (DateTime.UtcNow - measurement.startedAtUtc).TotalSeconds);
        double cpuAfter = self.TotalProcessorTime.TotalSeconds;
        double cpuDelta = Math.Max(0.0, cpuAfter - measurement.cpuSeconds);
        int processorCount = Math.Max(1, Environment.ProcessorCount);
        double averageCpu = ((cpuDelta / elapsed) / processorCount) * 100.0;
        int processCountAfter = Process.GetProcesses().Length;
        long workingSet = self.WorkingSet64;
        long privateBytes = self.PrivateMemorySize64;
        if (workingSet > peakWorkingSet) peakWorkingSet = workingSet;
        if (privateBytes > peakPrivateBytes) peakPrivateBytes = privateBytes;

        return Dict(
            "elapsedRuntimeSeconds", Math.Round(elapsed, 3),
            "cpuTimeDeltaSeconds", Math.Round(cpuDelta, 6),
            "averageCpuPercent", Math.Round(averageCpu, 4),
            "processorCount", processorCount,
            "workingSetBytes", workingSet,
            "privateBytes", privateBytes,
            "peakWorkingSetBytes", peakWorkingSet,
            "peakPrivateBytes", peakPrivateBytes,
            "handleCount", SafeHandleCount(self),
            "handleCountAvailable", true,
            "processCount", Dict(
                "before", measurement.processCount,
                "after", processCountAfter,
                "delta", processCountAfter - measurement.processCount
            )
        );
    }

    private static Dictionary<string, object> NewFailureResult(string policyPath, Exception ex, MeasurementStart measurement)
    {
        return Dict(
            "actionId", ActionId,
            "schemaVersion", 1,
            "productName", ProductName,
            "policyPath", policyPath,
            "dryRun", true,
            "confirmApply", false,
            "status", "failed",
            "sessionStatus", "failed",
            "completedAtUtc", UtcNow(),
            "preview", new List<Dictionary<string, object>>(),
            "changedItems", new List<Dictionary<string, object>>(),
            "skippedItems", new List<Dictionary<string, object>>(),
            "restoredItems", new List<Dictionary<string, object>>(),
            "footprint", BuildFootprint(measurement, measurement.workingSetBytes, measurement.privateBytes),
            "errors", new List<Dictionary<string, object>> {
                NewIssue("NATIVE_GOVERNOR_FAILED", ex.Message, "error", true)
            },
            "warnings", new List<Dictionary<string, object>>(),
            "logs", new List<Dictionary<string, object>> {
                NewLog("Native process governor failed.", "error")
            }
        );
    }

    private static List<Dictionary<string, object>> NewWarnings(bool confirmApply, bool allowLiveApply, bool requireDisposableTargets, GovernorRestraint restraint)
    {
        List<Dictionary<string, object>> warnings = new List<Dictionary<string, object>>();
        if (!confirmApply)
        {
            warnings.Add(NewIssue("NATIVE_GOVERNOR_DRY_RUN", "Native process governor ran in dry-run mode. No process controls were changed.", "info", false));
        }
        if (confirmApply && !allowLiveApply)
        {
            warnings.Add(NewIssue("NATIVE_GOVERNOR_LIVE_APPLY_BLOCKED", "Confirmed apply was requested but safety.allowLiveApply was false.", "warning", false));
        }
        if (confirmApply && requireDisposableTargets)
        {
            warnings.Add(NewIssue("NATIVE_GOVERNOR_DISPOSABLE_ONLY", "Confirmed apply was limited to disposable validation probe process names.", "info", false));
        }
        return warnings;
    }

    private static Dictionary<string, object> BuildEngineCapabilities(ProcessSelectorPlan selectorPlan)
    {
        return Dict(
            "nativeWorkerControls", new object[] {
                Dict(
                    "control", "priorityClass",
                    "applySupported", true,
                    "restoreSupported", true,
                    "implementation", "System.Diagnostics.Process.PriorityClass",
                    "safetyScope", "disposable validation targets unless policy safety is relaxed"
                ),
                Dict(
                    "control", "affinityMask",
                    "applySupported", true,
                    "restoreSupported", true,
                    "implementation", "System.Diagnostics.Process.ProcessorAffinity",
                    "safetyScope", "positive masks within the processor-count allow-list"
                ),
                Dict(
                    "control", "ioPriority",
                    "applySupported", true,
                    "restoreSupported", true,
                    "implementation", "ntdll!NtQueryInformationProcess/NtSetInformationProcess class 33",
                    "safetyScope", "VeryLow, Low, and Normal only"
                ),
                Dict(
                    "control", "gpuPriority",
                    "applySupported", true,
                    "restoreSupported", true,
                    "implementation", "gdi32!D3DKMTGetProcessSchedulingPriorityClass/D3DKMTSetProcessSchedulingPriorityClass",
                    "safetyScope", "Idle, BelowNormal, Normal, AboveNormal, High, and Realtime when Windows accepts the target process"
                )
            },
            "powerShellFallbackControls", new object[] {
                Dict("control", "priorityClass", "fallbackAvailable", true, "script", "ProcessProfile.Common.ps1"),
                Dict("control", "affinityMask", "fallbackAvailable", true, "script", "ProcessProfile.Common.ps1"),
                Dict("control", "ioPriority", "fallbackAvailable", true, "script", "ProcessProfile.Common.ps1"),
                Dict("control", "gpuPriority", "fallbackAvailable", true, "script", "ProcessProfile.Common.ps1")
            },
            "unsupportedControls", new object[] {},
            "trueNativeStatus", Dict(
                "workerIsTrueNative", false,
                "workerClassification", "managed-csc",
                "reason", "Built with .NET Framework csc.exe; not C++ Win32 and not .NET NativeAOT."
            ),
            "serviceReadyStatus", Dict(
                "boundedWorkerReady", true,
                "windowsServiceInstalled", false,
                "serviceInstallActionPerformed", false,
                "requiresServiceForAlwaysOnParity", true
            ),
            "processLassoDependencyStatus", Dict(
                "processLassoRequired", false,
                "processLassoProcessStartedByWorker", false,
                "replacementMode", "backend-worker"
            ),
            "scanStrategy", Dict(
                "mode", selectorPlan == null ? "full-process-list" : selectorPlan.enumerationMode,
                "avoidsFullEnumerationWhenExactProcessNamesAreAvailable", selectorPlan != null && selectorPlan.useTargetedEnumeration
            )
        );
    }

    private static Dictionary<string, object> NewIssue(string code, string message, string severity, bool blocking)
    {
        return Dict(
            "code", code,
            "message", message,
            "severity", severity,
            "blocking", blocking
        );
    }

    private static Dictionary<string, object> NewLog(string message, string level)
    {
        return Dict(
            "timestampUtc", UtcNow(),
            "level", level,
            "message", message
        );
    }

    private static List<Dictionary<string, object>> SnapshotsToDictionaries(IEnumerable<BackupSnapshot> snapshots)
    {
        List<Dictionary<string, object>> items = new List<Dictionary<string, object>>();
        if (snapshots == null)
        {
            return items;
        }
        foreach (BackupSnapshot snapshot in snapshots)
        {
            items.Add(Dict(
                "processId", snapshot.processId,
                "processName", snapshot.processName,
                "executablePath", snapshot.executablePath,
                "originalPriorityClass", snapshot.originalPriorityClass,
                "originalAffinityMask", snapshot.originalAffinityMask,
                "originalIoPriority", snapshot.originalIoPriority,
                "originalGpuPriority", snapshot.originalGpuPriority,
                "appliedControls", snapshot.appliedControls,
                "capturedAtUtc", snapshot.capturedAtUtc,
                "policyId", snapshot.policyId,
                "sessionId", snapshot.sessionId
            ));
        }
        return items;
    }

    private static void WriteJson(object value, string outputPath)
    {
        string json = NewSerializer().Serialize(value);
        if (!String.IsNullOrWhiteSpace(outputPath))
        {
            string full = Path.GetFullPath(outputPath);
            string parent = Path.GetDirectoryName(full);
            if (!String.IsNullOrWhiteSpace(parent))
            {
                Directory.CreateDirectory(parent);
            }
            File.WriteAllText(full, json);
        }
        else
        {
            Console.WriteLine(json);
        }
    }

    private static void WriteJsonFile(object value, string path)
    {
        string parent = Path.GetDirectoryName(path);
        if (!String.IsNullOrWhiteSpace(parent))
        {
            Directory.CreateDirectory(parent);
        }
        File.WriteAllText(path, NewSerializer().Serialize(value));
    }

    private static JavaScriptSerializer NewSerializer()
    {
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = Int32.MaxValue;
        serializer.RecursionLimit = 100;
        return serializer;
    }

    private static Dictionary<string, object> Dict(params object[] pairs)
    {
        Dictionary<string, object> dict = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i + 1 < pairs.Length; i += 2)
        {
            dict[(string)pairs[i]] = pairs[i + 1];
        }
        return dict;
    }

    private static string[] Merge(string[] first, string[] second)
    {
        List<string> values = new List<string>();
        if (first != null) values.AddRange(first);
        if (second != null) values.AddRange(second);
        return values.ToArray();
    }

    private static void AddRange(List<string> target, string[] values)
    {
        if (values == null)
        {
            return;
        }
        for (int i = 0; i < values.Length; i++)
        {
            if (!String.IsNullOrWhiteSpace(values[i]) && !target.Contains(values[i]))
            {
                target.Add(values[i]);
            }
        }
    }

    private static object[] ToArray(IEnumerable<string> values)
    {
        List<string> list = new List<string>();
        if (values != null)
        {
            foreach (string value in values)
            {
                if (!String.IsNullOrWhiteSpace(value) && !list.Contains(value))
                {
                    list.Add(value);
                }
            }
        }
        return list.ToArray();
    }

    private static string GetArg(string[] args, string name)
    {
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (StringEquals(args[i], name))
            {
                return args[i + 1];
            }
        }
        return null;
    }

    private static int ParseInt(string value, int defaultValue)
    {
        int parsed;
        if (Int32.TryParse(value, out parsed))
        {
            return parsed;
        }
        return defaultValue;
    }

    private static int Clamp(int value, int min, int max, int defaultValue)
    {
        if (value <= 0)
        {
            value = defaultValue;
        }
        if (value < min)
        {
            value = min;
        }
        if (value > max)
        {
            value = max;
        }
        return value;
    }

    private static bool GetBool(bool? value, bool defaultValue)
    {
        return value.HasValue ? value.Value : defaultValue;
    }

    private static string ResolvePolicyPath(string path, string policyDirectory)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            return null;
        }
        if (Path.IsPathRooted(path))
        {
            return Path.GetFullPath(path);
        }
        return Path.GetFullPath(Path.Combine(policyDirectory, path));
    }

    private static string SafeId(string value)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return "item";
        }
        return Regex.Replace(value.ToLowerInvariant(), "[^a-z0-9\\-]+", "-").Trim('-');
    }

    private static string UtcNow()
    {
        return DateTime.UtcNow.ToString("o");
    }

    private static string EnsureExeName(string processName)
    {
        if (String.IsNullOrWhiteSpace(processName))
        {
            return "";
        }
        if (processName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            return processName;
        }
        return processName + ".exe";
    }

    private static string ProcessNameWithoutExe(string processName)
    {
        if (String.IsNullOrWhiteSpace(processName))
        {
            return "";
        }
        string name = processName.Trim();
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            return name.Substring(0, name.Length - 4);
        }
        return name;
    }

    private static string NormalizeName(string value)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return "";
        }
        string n = value.Trim().ToLowerInvariant();
        if (n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            n = n.Substring(0, n.Length - 4);
        }
        return n;
    }

    private static bool NameEquals(string left, string right)
    {
        return NormalizeName(left) == NormalizeName(right);
    }

    private static bool StringEquals(string left, string right)
    {
        return String.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    }

    private static bool AnyNameMatch(string processName, string[] names)
    {
        if (names == null)
        {
            return false;
        }
        for (int i = 0; i < names.Length; i++)
        {
            if (NameEquals(processName, names[i]))
            {
                return true;
            }
        }
        return false;
    }

    private static bool AnyStringEquals(string value, string[] values)
    {
        if (values == null)
        {
            return false;
        }
        for (int i = 0; i < values.Length; i++)
        {
            if (StringEquals(value, values[i]))
            {
                return true;
            }
        }
        return false;
    }

    private static bool HasAny(string[] values)
    {
        return values != null && values.Length > 0;
    }

    private static bool AnyWildcardMatch(string value, string[] patterns)
    {
        if (String.IsNullOrWhiteSpace(value) || patterns == null)
        {
            return false;
        }
        for (int i = 0; i < patterns.Length; i++)
        {
            string pattern = patterns[i];
            if (String.IsNullOrWhiteSpace(pattern))
            {
                continue;
            }
            string regex = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
            if (Regex.IsMatch(value, regex, RegexOptions.IgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private static string SafeProcessPath(Process process)
    {
        try
        {
            if (process.MainModule != null)
            {
                return process.MainModule.FileName;
            }
        }
        catch
        {
        }
        return null;
    }

    private static string SafePriority(Process process)
    {
        try
        {
            return process.PriorityClass.ToString();
        }
        catch
        {
            return null;
        }
    }

    private static long SafeAffinity(Process process)
    {
        try
        {
            return process.ProcessorAffinity.ToInt64();
        }
        catch
        {
            return 0;
        }
    }

    private static int SafeHandleCount(Process process)
    {
        try
        {
            return process.HandleCount;
        }
        catch
        {
            return 0;
        }
    }

    private static int GetForegroundProcessId()
    {
        try
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero)
            {
                return 0;
            }
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            return (int)pid;
        }
        catch
        {
            return 0;
        }
    }

    private static string AsString(Dictionary<string, object> dict, string name)
    {
        if (dict == null || !dict.ContainsKey(name) || dict[name] == null)
        {
            return null;
        }
        return Convert.ToString(dict[name]);
    }

    public sealed class GovernorPolicy
    {
        public int schemaVersion { get; set; }
        public string productName { get; set; }
        public string policyId { get; set; }
        public bool confirmApply { get; set; }
        public GovernorSession session { get; set; }
        public GovernorRestraint restraint { get; set; }
        public GovernorSafety safety { get; set; }
        public Selector[] candidateSelectors { get; set; }
        public ProtectedProcessItem[] protectedProcesses { get; set; }
    }

    public sealed class GovernorSession
    {
        public int maxDurationSeconds { get; set; }
        public int pollIntervalMilliseconds { get; set; }
        public int foregroundProcessId { get; set; }
        public string stateRoot { get; set; }
        public bool? restoreOnExit { get; set; }
    }

    public sealed class GovernorRestraint
    {
        public string priorityClass { get; set; }
        public long? affinityMask { get; set; }
        public string ioPriority { get; set; }
        public string gpuPriority { get; set; }
    }

    public sealed class GovernorSafety
    {
        public bool? allowLiveApply { get; set; }
        public bool? requireDisposableTargets { get; set; }
        public bool? protectForegroundProcess { get; set; }
        public bool? protectGameObsDiscord { get; set; }
        public string[] disposableNamePatterns { get; set; }
    }

    public sealed class Selector
    {
        public string ruleId { get; set; }
        public bool? enabled { get; set; }
        public MatchRule match { get; set; }
        public string reason { get; set; }
        public string[] reasonCodes { get; set; }
    }

    public sealed class MatchRule
    {
        public string[] names { get; set; }
        public string[] processNames { get; set; }
        public string[] namePatterns { get; set; }
        public string[] pathPatterns { get; set; }
        public string[] processCategories { get; set; }
        public string[] excludeProcessNames { get; set; }
        public string[] excludeNamePatterns { get; set; }
        public string[] excludeProcessCategories { get; set; }
    }

    public sealed class ProtectedProcessItem
    {
        public string itemId { get; set; }
        public string[] names { get; set; }
        public string[] processNames { get; set; }
        public string[] namePatterns { get; set; }
        public string[] pathPatterns { get; set; }
        public string[] processCategories { get; set; }
        public string reason { get; set; }
        public string[] reasonCodes { get; set; }
    }

    public sealed class ProcessSnapshot
    {
        public int pid;
        public string processName;
        public string executablePath;
        public string priorityClass;
        public long affinityMask;
        public string ioPriority;
        public string gpuPriority;
        public bool gpuPriorityAvailable;
        public int gpuPriorityStatus;
        public string category;
    }

    public sealed class GpuPriorityState
    {
        public bool available;
        public string name;
        public int status;
    }

    public sealed class ProcessSnapshotBatch
    {
        public List<ProcessSnapshot> processes = new List<ProcessSnapshot>();
        public bool fullEnumeration;
        public string enumerationMode;
        public int scannedProcessCount;
    }

    public sealed class Decision
    {
        public bool candidateMatched;
        public bool blocked;
        public string ruleId;
        public string reason;
        public List<string> reasonCodes;
    }

    public sealed class BackupSnapshot
    {
        public int processId;
        public string processName;
        public string executablePath;
        public string originalPriorityClass;
        public long originalAffinityMask;
        public string originalIoPriority;
        public string originalGpuPriority;
        public List<Dictionary<string, object>> appliedControls;
        public string capturedAtUtc;
        public string policyId;
        public string sessionId;

        public static BackupSnapshot FromProcess(ProcessSnapshot snapshot, Process live, List<Dictionary<string, object>> changes, string policyId, string sessionId)
        {
            ProcessSnapshot original = SnapshotProcess(live);
            BackupSnapshot backup = new BackupSnapshot();
            backup.processId = snapshot.pid;
            backup.processName = snapshot.processName;
            backup.executablePath = snapshot.executablePath;
            backup.originalPriorityClass = original.priorityClass;
            backup.originalAffinityMask = original.affinityMask;
            backup.originalIoPriority = original.ioPriority;
            backup.originalGpuPriority = original.gpuPriority;
            backup.appliedControls = changes;
            backup.capturedAtUtc = UtcNow();
            backup.policyId = policyId;
            backup.sessionId = sessionId;
            return backup;
        }
    }

    public sealed class ProcessSelectorPlan
    {
        public bool useTargetedEnumeration;
        public string enumerationMode;
        public List<string> exactProcessNames = new List<string>();

        public static ProcessSelectorPlan FromPolicy(GovernorPolicy policy)
        {
            ProcessSelectorPlan plan = new ProcessSelectorPlan();
            HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool requiresFullEnumeration = false;

            Selector[] selectors = policy == null || policy.candidateSelectors == null ? new Selector[0] : policy.candidateSelectors;
            for (int i = 0; i < selectors.Length; i++)
            {
                Selector selector = selectors[i];
                if (selector == null || (selector.enabled.HasValue && !selector.enabled.Value))
                {
                    continue;
                }
                MatchRule match = selector.match;
                if (match == null || !AddExactNamesFromMatch(match, names))
                {
                    requiresFullEnumeration = true;
                }
            }

            ProtectedProcessItem[] protectedItems = policy == null || policy.protectedProcesses == null ? new ProtectedProcessItem[0] : policy.protectedProcesses;
            for (int i = 0; i < protectedItems.Length; i++)
            {
                ProtectedProcessItem item = protectedItems[i];
                if (item == null || !AddExactNamesFromProtectedItem(item, names))
                {
                    requiresFullEnumeration = true;
                }
            }

            plan.exactProcessNames.AddRange(names);
            plan.exactProcessNames.Sort(StringComparer.OrdinalIgnoreCase);
            plan.useTargetedEnumeration = !requiresFullEnumeration && plan.exactProcessNames.Count > 0;
            plan.enumerationMode = plan.useTargetedEnumeration ? "targeted-process-name" : "full-process-list";
            return plan;
        }

        private static bool AddExactNamesFromMatch(MatchRule match, HashSet<string> names)
        {
            bool hasExactName = AddNames(names, match.names);
            hasExactName = AddNames(names, match.processNames) || hasExactName;
            if (!hasExactName)
            {
                return false;
            }
            return IsEmpty(match.namePatterns) &&
                IsEmpty(match.pathPatterns) &&
                IsEmpty(match.processCategories);
        }

        private static bool AddExactNamesFromProtectedItem(ProtectedProcessItem item, HashSet<string> names)
        {
            bool hasExactName = AddNames(names, item.names);
            hasExactName = AddNames(names, item.processNames) || hasExactName;
            if (!hasExactName)
            {
                return false;
            }
            return IsEmpty(item.namePatterns) &&
                IsEmpty(item.pathPatterns) &&
                IsEmpty(item.processCategories);
        }

        private static bool AddNames(HashSet<string> target, string[] values)
        {
            bool added = false;
            if (values == null)
            {
                return false;
            }
            for (int i = 0; i < values.Length; i++)
            {
                if (String.IsNullOrWhiteSpace(values[i]))
                {
                    continue;
                }
                target.Add(EnsureExeName(values[i]));
                added = true;
            }
            return added;
        }

        private static bool IsEmpty(string[] values)
        {
            return values == null || values.Length == 0;
        }
    }

    public sealed class MeasurementStart
    {
        public DateTime startedAtUtc;
        public double cpuSeconds;
        public long workingSetBytes;
        public long privateBytes;
        public int processCount;

        public static MeasurementStart Capture()
        {
            Process self = Process.GetCurrentProcess();
            self.Refresh();
            MeasurementStart measurement = new MeasurementStart();
            measurement.startedAtUtc = DateTime.UtcNow;
            measurement.cpuSeconds = self.TotalProcessorTime.TotalSeconds;
            measurement.workingSetBytes = self.WorkingSet64;
            measurement.privateBytes = self.PrivateMemorySize64;
            measurement.processCount = Process.GetProcesses().Length;
            return measurement;
        }
    }
}
