# Process policy polling

Reviewed on 2026-09-16. A disposable Windows fixture profiled Roo baseline `04912080dc51128706aca349e0962f798e47c45e` on .NET **8.0.31**, with one active CPU-priority rule. Each component received ten warm-up calls before the timed loop. These measurements identify optimization candidates; they establish no advantage over another controller.

## Measured components

| Component | Calls | Elapsed time | Managed allocation |
|---|---:|---:|---:|
| Restricted process-handle open | 1,000 | 6.07 ms | 0.14 MB |
| Identity using an already-held handle | 1,000 | 20.86 ms | 66.01 MB |
| `OperationOwner.Current` | 1,000 | 2.04 ms | 0.82 MB |
| Process-name enumeration | 100 | 45.38 ms | 0.44 MB |
| Existing-operation observation | 100 | 29.49 ms | 11.56 MB |
| Complete `Tick` | 100 | 123.70 ms | 26.85 MB |

Times are elapsed measurements from one component run, without confidence intervals. Allocation uses `GC.GetAllocatedBytesForCurrentThread`; MB is decimal. The CPU counters were too coarse for several short samples. Components overlap and their times must not be added. `Tick` excludes the worker's 500 ms wait. The separate `ownerQuery` probe omitted `OperationOwner` construction and `MachineName`, so it does not establish a comparable token-access speedup.

## Buffer change and follow-up probes

The profiled [identity method](../../backend/native/Optimizer.Core/ProcessTarget.cs) allocated a 32,768-character buffer for every image-path read. The implementation now starts at 260 characters, grows only on error 122, retains the 32,768 limit, and preserves every other failure. The Windows API receives capacity in characters and returns the complete path length on success. [Windows API contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew).

A component rerun reduced allocation for 1,000 identity reads from 66,008,384 to 992,176 bytes (98.5%) and 100 complete ticks from 26,852,448 to 7,346,816 bytes (72.6%). Tick CPU remained 0.125 seconds in both samples; elapsed time changed from 123.70 to 119.88 ms. This does not substantiate a CPU speedup. A real suspended process created from an executable path longer than 260 characters passed the regression. An independent 260-character Windows query failed with error 122, while the growing query matched a separate full-capacity query and the exact process creation time. Ordinary paths and saved GPU-policy polling/recovery also passed. The fixture used an explicit `CreateProcessW` application path, avoiding the command-line module-name limit, and verified termination before deleting its copied executable. [Process-creation contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).

Two further targets remain conditional:

- **Enumeration:** .NET 8.0.31 obtains a system-wide snapshot but filters by name before constructing matched process/thread objects. Preserve the existing filtered single-name path; require measured benefit before replacing the enumeration API. [.NET implementation](https://github.com/dotnet/runtime/blob/v8.0.31/src/libraries/System.Diagnostics.Process/src/System/Diagnostics/ProcessManager.Win32.cs#L252-L365).
- **JSON/locks:** [active observation](../../backend/native/Optimizer.Core/ProcessControlEngine.cs) rereads its preview and journal, takes file and process-instance leases, and serializes state for equality/change detection. Measure this after the buffer change. Any replacement for serialization-based change detection must preserve all status, error and observed-value transitions.

## Access and recovery contracts

The .NET initializer attempts to enable ambient `SeDebugPrivilege`, but Roo's [OpenWithoutPrivileges](../../backend/native/CpuSets/RooCpuSets.cs) creates a restricted token for **every process access check**, using existing impersonation when present and restoring it afterward. `DISABLE_MAX_PRIVILEGE` removes debug/ownership privileges from that check. The executed denied-child fixture returned `OpenProcess` error 5 without a privilege retry under an admin token. This verifies the controlled denial case, not game compatibility. [.NET initializer](https://github.com/dotnet/runtime/blob/v8.0.31/src/libraries/System.Diagnostics.Process/src/System/Diagnostics/ProcessManager.Windows.cs#L183-L216), [restricted-token contract](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken).

Retain the [worker's](../../backend/native/Optimizer.Core/ProcessPolicies.cs) polling interval, continuous native readback, rule edit/disable/delete detection, exact PID/creation/path identity, owner checks, both concurrency leases and conflict suspension. Preserve reviewed-byte validation, duplicate-JSON rejection, durable intent/flushes, forced-termination recovery and stop/restart restoration. Do not obtain lower overhead by skipping these checks or using timestamps as content authority. Pair managed traces with measured CPU deltas: `dotnet-trace` thread samples include waiting time and Windows collection omits native/kernel frames. [Tracing limits](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-trace).
