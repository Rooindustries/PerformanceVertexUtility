# Process Control Backup Manifest

The process-control backup manifest is the restore contract for bounded process policy actions. It is written under the caller-provided runtime state root, not under the repository state folder.

## Root fields

- `schemaVersion`: integer, currently `1`.
- `productName`: `Roo Industries Optimization Suite`.
- `manifestKind`: `processControlBackupManifest`.
- `backupId`: stable identifier for this manifest.
- `actionId`: action that created the backup, such as `performance.policy.rule.apply` or `performance.policy.startSession`.
- `ruleId`: durable rule id when the manifest was created by rule lifecycle apply; null for session-wide backups.
- `sessionId`: session id when the manifest was created by a persistent policy session.
- `createdAtUtc`: UTC ISO-8601 timestamp.
- `stateRoot`: runtime state root that owns the manifest.
- `dryRun`: false for manifests that can restore live changes.
- `restore`: object with `available`, `status`, and `path`.
- `snapshots`: array of per-process original-control records.

## Snapshot fields

- `snapshotId`: stable identifier for the snapshot row.
- `ruleId`: rule that produced the applied controls.
- `targetProcess`: object with `identity`, `processId`, `processName`, `executablePath`, and `publisher`.
- `processId`, `processName`, `executablePath`, `publisher`: flattened process identity fields for compatibility with existing session restore helpers.
- `startTimeUtc`: process start time when available, used to avoid restoring a different process instance.
- `protectionCategory`: category used for safety and audit reporting.
- `originalPriorityClass`, `originalAffinityMask`, `originalIoPriority`, `originalGpuPriority`: values captured before apply.
- `proposedPriorityClass`, `proposedAffinityMask`, `proposedIoPriority`, `proposedGpuPriority`: values requested by the policy.
- `controlChanges`: normalized control changes that were eligible for apply.
- `capturedAtUtc`: UTC ISO-8601 capture time.
- `reason`: human-readable policy reason.

Restore must read the manifest, verify process identity, compute restore changes from the original values, write audit rows for each control, and leave the rule/session restorable until confirmed restore succeeds or the target process is no longer running.
