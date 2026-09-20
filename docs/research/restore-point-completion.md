# Restore-point completion and enumeration visibility

Checked against Microsoft documentation and retained test evidence on 2026-09-20. This research made no Windows calls or configuration changes.

`SRSetRestorePointW` success establishes API-call success and returns a restore-point sequence. It does not document an immediate visibility guarantee or a deadline for the WMI/CIM SystemRestore collection. A successful call can reuse an earlier point under the creation-frequency policy, so success alone does not establish a newly created point. [SRSetRestorePointW](https://learn.microsoft.com/en-us/windows/win32/api/srrestoreptapi/nf-srrestoreptapi-srsetrestorepointw)

| Evidence | What it establishes | Appropriate state |
| --- | --- | --- |
| BEGIN returns true and status ERROR_SUCCESS | The call succeeded and supplied a sequence; it may identify a reused point | Record the returned sequence durably |
| END succeeds using the BEGIN sequence | The change scope was ended successfully | Record completion independently of enumeration |
| Exact requested description and returned sequence appear once in CIM, and the sequence was absent before | The requested new point is currently listed | Verified creation and current availability |
| No match on the first enumeration | The collection does not currently show the point | Awaiting verification; no new creation call |
| No match by a bounded polling deadline | Verification has not completed within that deadline | Retain the sequence and completed-END state for a later verification retry |
| A previously verified point later disappears | Creation was previously verified but current availability changed | Retain creation history; report unavailable now |

Microsoft defines both STATEMGRSTATUS.llSequenceNumber and SystemRestore.SequenceNumber as the restore point's sequence number. SequenceNumber is the WMI key; no alternate conversion or offset between these identities is documented. Native status uses INT64 while WMI uses uint32, so retain the native value and range-check rather than truncating it. Matching both the unique request description and sequence binds the observed point to the initiating request. [STATEMGRSTATUS](https://learn.microsoft.com/en-us/windows/win32/api/srrestoreptapi/ns-srrestoreptapi-statemgrstatus), [SystemRestore class](https://learn.microsoft.com/en-us/windows/win32/sr/systemrestore)

BEGIN uses sequence zero; END uses the sequence returned by BEGIN. API status and enumeration availability are separate observations. The polling deadline is an implementation bound, not a Microsoft completion guarantee. An empty immediate list does not establish that System Protection is disabled or that the frequency policy suppressed creation. [RESTOREPOINTINFOW](https://learn.microsoft.com/en-us/windows/win32/api/srrestoreptapi/ns-srrestoreptapi-restorepointinfow)

## Executed evidence supplied by the validation run

The retained `restore-point-timing.json` validation artifact records:

- The before list and first list contain sequences 50, 51, and 52.
- The journal records sequence 58 and EndConfirmed=true, but the old implementation permanently records Created=false after that first list.
- The delayed list contains sequence 58 with the exact request description `Roo Industries settings de068479a27a41e9baab900a359baf06`; its recorded creation time is `2026-09-20T04:00:05.362505Z`.
- The validation run reports a ten-second delay before the second list. This shows that exact enumeration visibility lagged API completion in this test; it does not establish a universal ten-second limit or a specific internal cause.

The failure is therefore the terminal interpretation of an early negative observation. A bounded poll and a durable awaiting-verification journal permit progress without issuing another BEGIN or END for the same completed request. Sequence 56's earlier missing immediate observation remains independently unverified; sequence 58's later appearance does not retrospectively prove sequence 56's outcome.

## COM prerequisite remains a separate concern

Microsoft requires COM initialization and process COM security that permits callbacks from NetworkService, LocalService, and System. Its sample calls CoInitializeEx and CoInitializeSecurity before SRSetRestorePointW. The security descriptor is explicit and the sample notes that application-specific adjustment may be needed. [Using System Restore](https://learn.microsoft.com/en-us/windows/win32/sr/using-system-restore)

The inspected RestorePoints.cs does not perform that setup, and a scoped search of backend/native and tools/validation found no explicit calls. Runtime-provided setup remains unverified; absence of explicit source calls is not proof of the process's effective COM security. This is a separate contract concern, not an established cause of the enumeration delay. No production code was changed by this research.
