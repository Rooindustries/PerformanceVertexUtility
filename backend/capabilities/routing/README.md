# Capability Route Manifests

Capability route manifests live at `backend/capabilities/routing/<family>.routes.json`.

Each manifest declares one family and a `routes` array. A route is keyed by `capabilityId` and may define `preview`, `apply`, and `restore` sections. Dispatch sections use:

```json
{
  "script": "backend/scripts/Example.ps1",
  "args": ["-LiteralArg", "value"],
  "timeoutSeconds": 60,
  "changedEvidencePath": "summary.changedCount",
  "restorableEvidencePath": "restorable"
}
```

The router invokes dispatch sections with `powershell -NoProfile -ExecutionPolicy Bypass -File`, then appends only optional caller parameters explicitly declared by the route:

- `fixtureRootParam` receives the caller's `-FixtureRoot` value.
- `disposableProbeParam` receives the caller's `-TargetProcessId` value.
- `requestPathParam` receives the caller's `-RequestPath` JSON file. Only the declared optimizer request wrapper accepts this parameter; it validates allowed fields and dispatches a fixed backend operation.

Routes that cannot dispatch use a status-only section:

```json
{
  "statusOnly": true,
  "reason": "read-only budget measurement",
  "nextRequiredStep": "Use preview to run Measure-RooIndustriesBackendFootprint.ps1; this capability has no mutating apply path."
}
```

Status-only sections never launch a script. Mutating `apply` and `restore` sections are dispatched only after `Invoke-RooIndustriesCapability.ps1` receives `-ConfirmApply`, and the target script still keeps its own gates.

CPU Set and bulk uninstall requests retain the hashes of their reviewed preview files inside the typed request. The router preserves structured backend rejection evidence, including Windows API names and error codes. See [Optimization controls](../../../docs/optimization-controls.md) for the request fields and recovery behavior.
