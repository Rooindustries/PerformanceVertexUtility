# Publishing a beta update

Testers' apps read the signed feed in `update-feed.txt`. They only offer a version that is newer than the one installed, by SemVer order. They trust only a feed signed with the private half of a key in `update-keys.json`. Keep that private key on the machine that signs releases and never copy it to Windows.

1. Raise `<Version>` in the app project and build on Windows with `tools\scripts\Build-Release.ps1`. It embeds the committed feed URL and refuses a version that is not newer than every line in `released-versions.txt`.
2. Copy the installer to the signing machine and sign its manifest. Use a fresh random path segment so the installer URL is never reused:

   ```sh
   python3 tools/release/publish_update.py manifest --installer <setup.exe> --version <version> --url https://<feed-host>/b/<random>/RooIndustries-OptimizationSuite-<version>-setup.exe --notes-file <notes.txt> --key <private-key.pem> --out <version>-feed.json
   python3 tools/release/publish_update.py verify --manifest <version>-feed.json --installer <setup.exe> --feed-url "$(cat tools/release/update-feed.txt)"
   ```

3. Dry run, then publish with `BLOB_READ_WRITE_TOKEN` set:

   ```sh
   python3 tools/release/publish_update.py publish --installer <setup.exe> --manifest <version>-feed.json --installer-path b/<random>/RooIndustries-OptimizationSuite-<version>-setup.exe --feed-path <feed path>
   python3 tools/release/publish_update.py publish ... --yes-publish
   ```

   Both runs stop if the version is not newer than the live beta, or if the live feed doesn't verify (repair it with `set-feed` first). They save the live manifest as `<version>-feed.previous-live.json`, which is the rollback copy. After uploading, the tool reads the feed and the installer back over HTTPS.
4. Add the published version to `released-versions.txt` on `main`.

## Rolling back

Point the feed back at the saved manifest. The tool first checks that its installer still downloads with the signed bytes:

```sh
python3 tools/release/publish_update.py set-feed --manifest <version>-feed.previous-live.json --feed-path <feed path>
python3 tools/release/publish_update.py set-feed --manifest <version>-feed.previous-live.json --feed-path <feed path> --yes-publish
```

This stops new downloads within about a minute. An app that already downloaded the bad version can still install it from its cache, and an app that installed it keeps it, because apps never move to a lower version. To replace a version testers already have, publish a fixed build with a higher version.

If a publish stops after the installer upload, the immutable installer path can't be uploaded again. Run `set-feed` with the new manifest to finish it.

Before publication, run the [release upgrade rehearsal](../validation/Update/README.md#release-upgrade-rehearsal) with the signed manifest and matching installer as inputs. Run its read-only preflight first. Use an exclusive test window for `-MoveAsideExistingState`, and require `restore-verification` with `restored: true`, an empty `cleanupErrors` list and a passing invocation. Retain its ownership ledger and data archives. After publication, repeat with `-LiveFeed` to prove the real old app downloads and installs the live release.
