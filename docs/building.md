# Building omux

```sh
./build.sh
open /Applications/omux.app
```

`build.sh` builds a release binary, assembles `build/omux.app`, and then **replaces `/Applications/omux.app`** so the Finder service and Dock entry stay registered. It signs with the first "Apple Development" certificate in your keychain, or ad hoc if there is none.

```sh
./build.sh --beta
```

builds and installs **omux Beta** next to the release app instead, with its own bundle id, preferences and workspace, so you can try a branch without touching your sessions. On its first launch it copies the release app's settings. Keep Awake needs a build signed with a real certificate: the helper only answers an app signed by its own team, so in an ad hoc build it refuses and the lid can't close (a free Apple Development certificate from Xcode › Settings › Accounts is enough). If you switch an installed beta from ad hoc to signed, turn Keep Awake off and on once so the helper is registered again. Also, the release and beta apps shouldn't both keep the Mac awake at once: they share the system's one sleep setting.

```sh
./build.sh --dist
```

builds the release that goes on GitHub: signed with the Developer ID certificate and the hardened runtime, notarized, stapled, and packaged as `build/omux-<version>.dmg` and `.zip`. It also signs the zip for Sparkle and adds the version to `site/appcast.xml`, which goes live with the site. It needs the notarization credentials stored once with `xcrun notarytool store-credentials omux-notary`; `--no-notarize` only signs.

## Tests

```sh
swift test
```

To try Keep Awake's time limit without waiting hours, `defaults write net.pf1.omux.beta stayAwakeLimitMinutes 2` makes it 2 minutes in the beta (it counts while the screen is dark, so use View › Screen Off) (`defaults delete net.pf1.omux.beta stayAwakeLimitMinutes` undoes it).

The opt-in Codex integration checks are described in [codex.md](codex.md#checks). A GitHub Actions workflow builds and tests every pull request.
