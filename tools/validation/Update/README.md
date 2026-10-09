# OTA end-to-end checks

Run `python3 -I tools/validation/Update/run_e2e.py --scenario all` from this worktree. The only Windows target is `optimizer-9070` / `SERVI-WINDOWS-D`. The runner stages a fresh protected source frame, builds 0.11.0-beta and a temporary 0.11.1-beta copy, serves signed releases through tailnet HTTPS port 8460, and drives the installed app through UIAutomation. It leaves 0.11.0-beta installed with the test feed and stops its own processes. It never publishes to Vercel or copies the signing key to Windows.

Each named scenario records installed DisplayVersion, the running executable's product version, Settings and banner text, update-folder files/hashes, process-start events, saved-rule/settings/undo hashes, and screenshots under `artifacts/roo-20/ota/`. The three versions and installer URLs stay fixed while each refusal case varies its named input.

Failure cases recorded before implementation:

- Unreachable, slow, redirected-to-HTTP, malformed, non-200 or oversized feeds must finish with a visible refusal without blocking navigation.
- Invalid envelope/schema/key/base64/signature or payload/product/channel/version/URL/size/hash must never reach download or execution.
- Equal, older, or prerelease versions with lower SemVer precedence must not download.
- Automatic download off must require Download; repeated checks/clicks must not overlap.
- Truncated, oversized or changed installer bytes must remove partials and never start setup.
- A changed ready installer or mismatched product version must fail a locked-handle recheck before execution.
- An active game session or timer must prevent installation, including a session started during the confirmation dialog.
- A canceled confirmation must not start setup or write a pending installation.
- Silent setup must exit and relaunch on success and on a failure before file replacement, without waiting for a prompt.
- Upgrades must preserve settings, rules, undo data and governor enabled/running state.
- Update storage must deny non-administrator writes, links and untrusted paths; runtime settings cannot choose a feed or executable.
- Cleanup must affect only this runner's frame, tasks, PIDs and tailnet port 8460.

The pure contract probe consumes real signed manifests and streamed installer files; the desktop cases exercise the installed release app and installer. Neither uses a production endpoint.

`scheduled-download` waits for the startup check without pressing Check. `slow-feed` uses the standard library HTTP fixture to delay the same feed body for 25 seconds; the normal scenarios use `python3 -m http.server`. Equal/older and wrong-product/channel manifests change only their named payload field and are re-signed on Linux. `tampered-size` appends one byte to exercise the hard cap, while `tampered` flips one byte without changing size.

To resume a journey, stage a fresh frame with `windows_ssh.py upload`, then pass `--receipt`, `--build-root`, `--evidence-root`, `--skip-build` and `--from-scenario <name>` to the runner. Keep the original `seed/preservation.json` and `seed/before.json`; they are frozen baseline data. The first manual upgrade proof remains in `manual-0.10-to-A`, and the later reset uses `reset-A`.

After copying evidence, clean each owned staging/build frame by passing its exact path to `Clear-UpdateFrame.ps1` through `windows_ssh.py run`. It accepts only this OTA runner's prefixes and refuses live processes and linked entries. The installed app, saved rule/theme, undo data and verified cached installer remain for the next slice.
