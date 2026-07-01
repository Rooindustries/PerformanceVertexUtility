# Performance Target

Captured: June 28, 2026

## North Star

The product goal is not the lowest process count. The product goal is smooth gameplay under memory pressure.

Primary target scenario:

- Game: Overwatch.
- Background workload: OBS open and active, Discord open in the background, Discord stream active.
- System memory target: 16 GB RAM class machines.
- Display target: 144 Hz.
- Desired outcome: hold 144 FPS where possible, but prioritize stable frame pacing and no visible stutter even if average FPS must be slightly lower.

## Optimization Priority

Optimize for this order:

1. Frame-time stability.
2. 1% low FPS and 0.1% low FPS.
3. RAM pressure reduction.
4. Process count and background workload reduction.
5. VRAM/shared-GPU-memory pressure reduction.
6. Input responsiveness.
7. Average FPS.

Process count is not a vanity metric in this product. On 16 GB RAM class machines, high process count is often the visible symptom of background memory pressure, service sprawl, overlays, launchers, update helpers, WebView-heavy apps, scheduled tasks, and vendor utilities. It should be treated as a first-class diagnostic and optimization target when it correlates with memory pressure or stutter risk.

## Target Metrics

For 144 Hz, the ideal frame-time budget is about 6.94 ms per frame.

Launch testing should track:

- Average FPS.
- 1% low FPS.
- 0.1% low FPS.
- Frame-time spikes over 16.7 ms, 25 ms, and 33.3 ms.
- Working set and private bytes for Overwatch, OBS, Discord, browser/WebView processes, and major background apps.
- Total process count and background process count.
- Startup process count after clean boot.
- Service-hosted background workload count.
- Commit charge and available physical memory.
- GPU dedicated/shared memory usage where available.
- CPU package utilization and per-process CPU usage.
- GPU utilization and encode/decode activity where available.
- Disk read/write spikes during gameplay.
- Network stability if Discord stream or OBS stream is active.

## Game Tune Session

The app should include a Game Tune session profile built around the primary target scenario.

The session profile should:

- Start from the safe optimizer profile.
- Apply a game foreground boost.
- Demote non-critical background apps.
- Reduce process count and startup background workload before the game session starts.
- Preserve OBS, Discord, network, audio, input, anti-cheat, GPU drivers, and security components.
- Protect Tailscale, Wispr Flow, Samsung continuity, Defender, firewall, Store/WebView2, and Windows Update from unsafe blanket changes.
- Offer per-app memory and process visibility before changing anything.
- Prefer stable caps and frame pacing over maximum uncapped FPS.
- Keep rollback one click away.

## Process Lasso Replacement Implications

The native performance-profile engine should be judged against this scenario.

Required MVP behaviors:

- Detect the foreground game process.
- Protect OBS and Discord from being demoted too aggressively.
- Demote selected launchers, updaters, browser helpers, chat helpers, vendor trays, and indexing-style background work.
- Treat process count reduction as a primary signal when it frees RAM, commit, CPU wakeups, disk activity, handles, or overlay/background contention.
- Apply per-process priority rules with saved original states.
- Support affinity rules only where tested and reversible.
- Keep network, audio, input, anti-cheat, GPU, and security processes protected.
- Show the expected memory/CPU impact before applying.

## Revo-Style Cleanup Implications

The uninstall/cleanup module should help remove background bloat that causes memory pressure, startup load, update tasks, overlays, and tray processes.

For launch, prioritize:

- Startup-heavy apps.
- Vendor updaters and launchers.
- Unused overlays.
- Trialware and bundled utilities.
- Apps with services or scheduled tasks.

Do not remove shared runtimes, GPU/audio/network drivers, anti-cheat components for installed games, OBS dependencies, Discord dependencies, WebView2, VC++ redistributables, .NET, DirectX, or Store components unless explicitly selected and validated.

## Driver/Profile Implications

Driver recommendations should be game-aware and stability-aware, not just newest-version-first.

For Overwatch-style targets:

- Recommend drivers by stability, 1% lows, frame-time consistency, and OBS/Discord compatibility.
- Track whether a driver improves average FPS at the cost of stutter.
- Track whether a profile reduces VRAM/shared-memory pressure or shader stutter.
- Keep DDU/NVCleanstall manual and gated.
- Keep NVIDIA Profile Inspector profile application gated until benchmarked.

## Acceptance Test

A profile is successful if it makes the Overwatch + OBS + Discord scenario visibly smoother, with lower background process count, less memory pressure, fewer frame-time spikes, and better lows, even if average FPS is slightly lower.

A profile fails if it reduces process count in a way that causes more stutter, worse 1% lows, worse stream stability, audio dropouts, network issues, broken app/device functionality, or higher memory pressure elsewhere.
