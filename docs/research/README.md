# Windows optimization research

The product goal is a free Windows maintenance and process-control suite: thorough application removal, reversible scheduling controls, useful Windows settings, and measured results. Compatibility means using supported interfaces and respecting the target's access policy. It does not mean modifying anti-cheat software, hiding changes, or promising that every protected game will accept a control.

Research was checked against primary sources on 2026-09-14. Comparisons in the three detailed reports are pinned to repository baseline `33bbd55f1196657a5935c783db65a8a0c59448bb`; their statements about missing baseline features are intentionally historical. The implementation added afterward is described in [Optimization controls](../optimization-controls.md).

| Report | Main coverage |
|---|---|
| [Process management](process-management.md) | Process Lasso Free/Pro, CPU Sets, hard affinity, QoS, topology, restore ownership and anti-cheat evidence |
| [Application removal](uninstall-cleanup.md) | Revo editions, exact Windows app identity, MSI/Appx behavior, queue recovery, ownership and cleanup limits |
| [Process polling](process-polling.md) | Measured identity-buffer allocations, long-path regression and access contracts |
| [Performance evidence](parity-validation.md) | CPU, storage, GPU and stock-reference comparisons with explicit limits |
| [Current removal audit](removal-parity-audit.md) | Executed multi-app cleanup, shared ownership repair, discovery scope and remaining Revo features |
| [Windows settings](windows-settings.md) | WinUtil's maintained configuration, {source} R11H2 playbook, bundled Dash, source risk and coverage crosswalk |

The machine-readable [upstream inventory](../../backend/catalogs/upstream-settings-inventory.json) records 376 settings/control records, 267 application/package entries and 1,319 playbook action records. These totals describe different kinds of records, not a count of implemented product toggles. WinUtil is pinned to commit `fc60cbde09d669178bda1665be9cb1a703516fca`. The {source} R11H2 download matched its published SHA-256; it bundled Dash 2.4.9. Dash symbols indicate potential controls, not proven behavior or an exhaustive public specification.

WinUtil's repository declares MIT licensing. {source} declares {license}. The inventory contains factual metadata and references; the new Windows executors are independent implementations rather than copied {source} code. Asset redistribution and any commercial source reuse require a separate licensing assessment.

## Initial implementation at the research baseline

| Priority | Backend implementation | Practical limit |
|---|---|---|
| Compatible process selection | CPU Set topology, reviewed apply, Windows readback, identity-bound restore, exact access errors | No protected-game compatibility or performance claim; no persistent CPU Set watcher yet |
| Reliable bulk removal | Exact installed identity, frozen commands, executable/registration checks, durable ordered queue, cancellation and reconciliation | Uncertain attempts remain unresolved until evidence supports completion; vendor uninstall cannot be rolled back |
| Cleanup after a vendor remover | Fresh content review; old deletion approval is no longer reused | Shared ownership, registry/service leftovers and native file-handle deletion need further work |
| Correct existing process restoration | Native and PowerShell governors restore recorded controls while preserving conflicting external values | Windows has no atomic compare-and-set across independent process-control writers |
| Settings coverage | Queryable source inventory with explicit risks and inferred/source-confirmed evidence | Metadata does not turn an upstream tweak into a tested Roo Industries capability |

## Work proposed at the research baseline

1. Complete Windows regression checks for the final revision and keep machine/source evidence separate from static validation.
2. Add UI selection, operation progress, cancellation, reconciliation and recovery screens through the typed backend requests.
3. Extend CPU Sets with explicit saved policies and topology-aware selectors, then measure scheduling and frame-time effects using repeatable workloads.
4. Add native filesystem identity checks and dependency-aware post-uninstall selection before expanding automated leftover deletion.
5. Implement individual sourced Windows preferences through current-state detection and exact existence/type/value restoration. Do not use an upstream default as the user's backup.
6. Test individual games and anti-cheat versions only through supported settings and allowed processes. Record rejected access as a compatibility result; do not retry through stronger privileges or substitute a bypass.

The detailed reports include discriminating test cases and upstream limitations. Process Lasso already supplies its main governor and CPU Sets in its free edition; a better free alternative must demonstrate reliability, useful workflow and measurable outcomes rather than claim novelty from those APIs alone. Revo's broad scanning and installation tracing are also distinct capabilities, not implied by a working vendor-removal queue.
