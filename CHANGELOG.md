# Changelog

All notable changes to omux are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Changed

- **Universal distribution builds.** `./build.sh --dist` builds for Apple Silicon and Intel, combines the binaries before signing, and checks that every embedded Mach-O supports both architectures before packaging the DMG and zip. Build failures stop packaging. Development and beta installs still build for the current Mac.
- Building from source requires Swift 6.2 or later to match the locked SwiftTerm dependency; downloaded releases do not require Swift.

## [0.6.0] - 2026-10-30

### Added

- **Updates.** omux checks for new versions about once a day with [Sparkle](https://sparkle-project.org) and offers to install them; Help › Check for Updates… checks now. Updates are signed and must pass notarization before they're installed.

## [0.5.1] - 2026-10-30

### Changed

- **Notarized, and a disk image.** Releases are signed with a Developer ID certificate, use the hardened runtime and are notarized by Apple, so the download opens without the right-click › Open step. Each release ships `omux-<version>.dmg` (drag omux to Applications) and the same build as a zip. `./build.sh --dist` makes both.

## [0.5.0] - 2026-10-30

### Added

- **Worktree setup.** A project can have a setup command that runs in each new worktree before the session starts, such as `cp "$OMUX_REPO/.env" . && npm install`, so the files Git ignores and the dependencies are in place before Claude begins. The session's command only starts if setup succeeds. Set it in the New Session in Worktree sheet or in Edit Project. `$OMUX_REPO` points to the main checkout in every worktree session. ([#5](https://github.com/onurozcan/omux/pull/5))
- **Welcome sheet** on first launch, and under Help › Welcome to omux: checks that Claude Code and Codex are installed, turns on notifications, checks the usage limits with an explanation of what they need, and opens a first project.
- **Paste images and drop files into a session.** ⌘V with an image on the clipboard saves it and pastes its path, which Claude Code and Codex read as an attachment; ⌘V with files, or dropping files on the terminal, pastes their paths.
- **Notification style and sound.** Settings › Notifications can play a sound without a banner, and pick which macOS sound.

### Changed

- The usage bar says what's wrong when it can't show limits (no Claude login, API key login, Keychain access denied, login expired) and clicking it retries. The old text was "Not signed in to Claude Code" for all of them.

## [0.4.0] - 2026-10-30

### Added

- **Codex sessions.** A project or session can run [Codex](https://developers.openai.com/codex/cli) instead of Claude Code: pick the agent in the project or session settings, in the worktree sheet, or with File › New Codex Session. omux starts a private Codex app-server per session, so a Codex session keeps its conversation across relaunches, shows its status, Allow/Deny for command and file-change approvals, its subagents and their transcripts, recent Codex conversations (⇧⌘O) and Codex usage limits. Needs Codex CLI 0.165 or later as `codex`. ([#7](https://github.com/onurozcan/omux/pull/7))
- **Beta builds.** `./build.sh --beta` installs "omux Beta" next to the release app, with its own preferences and workspace, for trying a branch. It starts with the release app's settings.

### Changed

- Pressing ▶ on a Claude session that has no conversation yet starts one pinned to the session's id, instead of continuing the folder's most recent conversation.

### Fixed

- The sidebar's new session, open folder, recent conversations and settings buttons didn't respond to clicks: the session list extended up under them.
- The session header and the right panel's tabs sat below the title bar instead of level with the sidebar's buttons.
- 0.3.0 kept an invisible window toolbar so the window buttons show on every macOS version, which pushed the content down. The toolbar is hidden again and the buttons are kept visible directly.

## [0.3.0] - 2026-10-29

### Added

- **Pull request status** for worktree sessions, through the GitHub CLI. The sidebar and header show the pull request's number and state (checks running or failing, changes requested, approved, merged), the header chip lists each check, and the session asks for your attention when checks fail, a review arrives or the pull request is merged. Without `gh`, nothing changes. ([#2](https://github.com/onurozcan/omux/pull/2))
- **Clean up merged worktrees.** When a worktree session's pull request is merged, the sidebar, the session menu and the pull request chip offer to close the session and delete its worktree and branch. Closing a merged session says so instead of listing commits that a squash merge leaves behind. ([#3](https://github.com/onurozcan/omux/pull/3))
- **Notifications.** A macOS notification when a session you aren't looking at needs you, such as a tool permission. Clicking it opens the session. Optional notifications when a session finishes, and for notifications programs send with OSC 9 or OSC 777, such as Claude Code's (and its plugins') when its notification channel is `ghostty` or `iterm2`. Each kind can be turned off in Settings › Notifications. ([#4](https://github.com/onurozcan/omux/pull/4))

### Fixed

- The window's close, minimize and full screen buttons were missing on some macOS versions.
- Scanning a session's output for file paths and local URLs read the terminal from a background thread ([#1](https://github.com/onurozcan/omux/issues/1)).

## [0.2.0] - 2026-10-28

### Added

- **Worktree sessions** (⌥⌘T). A session can get its own Git branch and folder, next to the repo in `<repo>.worktrees/<branch>`, so parallel sessions don't touch each other's files. A project setting makes it the default for new sessions. Right-click a worktree session to create a pull request, merge it into its base branch or open its folder. Closing one asks whether to keep or delete the worktree.
- **Tabs in the right panel:** Files (⌥⌘1), Changes (⌥⌘2) and Browser (⌥⌘3).
- **Changes tab.** Shows the session's diff: against the base branch for worktree sessions, uncommitted changes otherwise. Click a line to leave a note, then send all notes to Claude in one message.
- **Browser tab.** A web view per session that opens the local server the session prints, such as `localhost:3000`. The pick button adds an element's HTML, styles and a screenshot to the prompt.
- **Allow and Deny** in the sidebar and the session header when Claude asks for a tool permission, so you can answer without switching sessions.
- **Subagents.** The selected session lists its running subagents and what each one is doing. Other sessions show a count. The header's agents button lists them all, and clicking one opens its live transcript.

### Fixed

- Restarting a session could mark it as stopped when the old terminal's exit arrived after the new one started.

## [0.1.0] - 2026-10-27

First public release.

- Projects and sessions in a sidebar, with drag to reorder, rename and colors.
- Claude conversations that resume after you quit and reopen omux.
- Live status for each session (working, needs you, done) and a Dock badge for sessions waiting on you.
- Files panel that previews Markdown, code and text, images, PDFs, audio, video and anything Quick Look can show.
- Recent Claude conversations (⇧⌘O), Claude plan usage limits in the sidebar, themes, terminal font settings and a quick switcher (⌘K).
- Open folders from Finder's "Open in omux" service, the Dock icon or `open -a omux <folder>`.

[0.6.0]: https://github.com/onurozcan/omux/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/onurozcan/omux/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/onurozcan/omux/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/onurozcan/omux/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/onurozcan/omux/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/onurozcan/omux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/onurozcan/omux/releases/tag/v0.1.0
