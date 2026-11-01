# Changelog

All notable changes to omux are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- **Session links.** `omux://reveal?tab=<id>` brings a session forward, so notifications and agent monitors in other apps can take you to it. A session can also be found by its Claude Code session id or Codex thread id. A link only selects a session.

## [0.9.1] - 2026-11-01

### Added

- **What ▶ starts.** Settings › Sessions chooses the agent ▶ starts in a plain shell session (Claude Code or Codex); the shell becomes that agent's session. A second setting decides what an agent with no saved conversation does: start fresh, or continue the folder's latest conversation (`claude --continue`). A saved conversation is always resumed exactly.

### Changed

- ▶ brings the session forward and focuses its terminal instead of starting it in the background.
- The ▶ and ■ buttons are smaller and centred on the session's name line.

## [0.9.0] - 2026-11-01

### Added

- **Panes.** Sessions of a project can be arranged in the main area: split a pane right or down with the buttons on its header (a shell in the same folder), drag a session from the sidebar onto a terminal's edge, or right-click it › Show in Pane. Dividers drag; a pane's header drags onto another pane's edge to move it; maximize shows one pane with the layout remembered; closing a pane only closes that pane. Each project has one arrangement, saved with the workspace and restored on launch. View › Tidy Panes evens them out, Clear Panes (⌥⇧⌘S) empties them, ⌥⌘S adds the selected session beside the current one. A new pane always gets usable space: a pane too small to halve sends the new one to the top level as its own column or row. Up to six.
- **The `omux` command in sessions.** Programs in a session can run `omux list`, `status`, `screen`, `new`, `send`, `close` and `wait` to see the project's other sessions, read their screens, and start and steer sessions of their own. A session can send text only to sessions it started, and only inside its own project; every such action shows a banner. The tool talks to the app over an owner-only Unix socket with a per-launch token, and session processes never inherit its descriptors. Settings › Sessions turns it off. See [docs/cli.md](docs/cli.md).
- A session's folder is asked for before an agent starts in a project that has none, and New Project starts with the folder picker. A project with no folder shows one quiet notice instead of an error per session.

### Changed

- The + next to a project opens a shell in the project's folder.
- The right panel opens as narrow as the sidebar and remembers the width you drag it to.
- In pane mode the top bar names the project; each pane carries its own session header.

## [0.8.0] - 2026-10-31

### Added

- **Sessions named after their conversation.** A session that still has a made-up name ("Session 3") takes the topic Claude Code gives the conversation, the way iTerm shows it in the tab. Renaming a session, in the sidebar or the Edit Session sheet, keeps your name from then on. ([#41](https://github.com/onurozcan/omux/pull/41))
- **Close a session from the sidebar.** Hovering a session row turns its status dot into a close button. Worktree sessions still ask before closing. ([#42](https://github.com/onurozcan/omux/pull/42))
- **⌘-click on `Foo.swift:12:4`** opens the file in the preview, the way plain paths do, instead of handing it to the default editor. ([#39](https://github.com/onurozcan/omux/pull/39))

### Changed

- **Closing the main window quits omux**, with the usual confirmation, instead of leaving every session running with no window. The close, minimize and zoom buttons also stay visible on newer macOS, where hiding the toolbar hid them too. ([#43](https://github.com/onurozcan/omux/pull/43))
- **Claude Code and Codex no longer start on their own in the home folder.** An agent started in `~` treats all of it as its project and reads Downloads, Documents, Pictures and Music, so macOS asked for access to each in omux's name. A session without a project folder now opens a shell and shows a banner pointing to Edit Session; starting the agent by hand still works. ([#45](https://github.com/onurozcan/omux/pull/45))
- **Allow picks Claude Code's "Yes"** wherever the highlight is in the prompt. It used to press Return, which took the highlighted row, so a moved highlight could switch the session to "accept edits" or deny the tool. Allow and Deny now appear only for tool prompts, not for plan approval or peer messages, whose first option isn't a plain yes. ([#36](https://github.com/onurozcan/omux/pull/36))
- Review notes that couldn't be sent because the session isn't running are kept, with a banner, instead of dropped. ([#28](https://github.com/onurozcan/omux/pull/28))
- A ⌘-clicked folder or app bundle is shown in Finder instead of opened. ([#39](https://github.com/onurozcan/omux/pull/39))

### Fixed

- A worktree branch name starting with `-`, such as `-D`, made git run `git branch -D <base>` and delete the base branch. Names git rejects are refused before anything runs, and a branch whose folder is already in use (`feat/x` and `feat-x` share one) no longer leaves a stray branch behind. ([#26](https://github.com/onurozcan/omux/pull/26))
- The browser's element picker accepted messages from any page or frame at any time and typed them into the session. It now takes a pick only while you're picking, from the page itself, with control characters removed. ([#34](https://github.com/onurozcan/omux/pull/34))
- A file name with a newline in it could end the typed line and run what followed: in review notes, where the name comes from git, and in files dropped or pasted into a session. Both are escaped now. ([#35](https://github.com/onurozcan/omux/pull/35), [#38](https://github.com/onurozcan/omux/pull/38))
- Invisible Unicode (tag characters, bidi overrides, zero-width spaces, variation selectors) is removed from pasted check logs, so what you read before sending is what the agent gets. ([#40](https://github.com/onurozcan/omux/pull/40))
- A double-click on Codex's Allow also accepted the next pending approval, which you hadn't seen. The buttons now answer only the request they showed. ([#37](https://github.com/onurozcan/omux/pull/37))
- Recent Conversations titled a session started with a skill's slash command after the skill's instructions ("Base directory for this skill: …") instead of what you typed. ([#27](https://github.com/onurozcan/omux/pull/27))
- A pull request result arriving for a session closed while gh ran left a Dock badge nothing could clear. ([#29](https://github.com/onurozcan/omux/pull/29))
- Saving the Edit Session sheet put a Codex session's thread back to the one from when the sheet opened, so a restart resumed the wrong conversation. The ids are written only when "Start a fresh conversation" was pressed. ([#30](https://github.com/onurozcan/omux/pull/30))
- Pressing Start right after New Session or Restart typed the startup command twice, and the second copy became the agent's first prompt. ([#31](https://github.com/onurozcan/omux/pull/31))
- Subagent transcripts showed Claude Code's own reminders as agent text, and forks had no task line. ([#32](https://github.com/onurozcan/omux/pull/32))
- The byte order mark gh puts before a failed log's first line kept that line's timestamp and `##[group]` marker in the pasted log. ([#33](https://github.com/onurozcan/omux/pull/33))

## [0.7.0] - 2026-10-30

### Added

- **Send failing checks to a session.** When a worktree session's pull request has failing checks, "Send Failing Checks to Session" in the pull request chip and the session menu fetches the failed steps' logs of each GitHub Actions check through gh, trims them to the last lines and pastes them into the session without submitting, so you can read them before the agent acts on them. Other checks are listed with their links. ([#6](https://github.com/onurozcan/omux/pull/6))
- **Line counts in the sidebar.** Worktree sessions show their added and removed lines next to the branch. The selected session updates as its files change, the others about once a minute and when you come back to omux.
- **Terminal font size from the keyboard.** ⌘+ (or ⌘=), ⌘− and ⌘0 in the View menu. ([#17](https://github.com/onurozcan/omux/pull/17))

### Changed

- Errors and results of Git actions appear in a banner over the terminal instead of an alert, so they no longer stop what you're doing. Errors stay until dismissed and their text can be selected; results go away on their own. Questions that need an answer are still alerts.

### Fixed

- The Changes tab missed commits and resets in worktree sessions and in sessions in a subfolder of a repository, because Git's files are outside the session's folder there. It also now notices when `git init` runs in a session's folder.
- Four more Changes tab bugs: sessions in a subfolder of a repository got a blank diff, file names that look like patterns (`a*`, `:x`) were read as patterns, staged files before a repository's first commit didn't show, and an untracked symlink to a big file was read in full on every refresh. ([#19](https://github.com/onurozcan/omux/pull/19))
- A worktree setup command ending in `;` or `&` was a shell parse error, so neither the setup nor the session ran. ([#20](https://github.com/onurozcan/omux/pull/20))
- Closing a worktree session whose base branch had been deleted or renamed said the worktree had nothing new, right above the Delete button. It now says the commits couldn't be compared. ([#21](https://github.com/onurozcan/omux/pull/21))
- Text pasted into a session can no longer end the paste early: escape characters are removed inside a bracketed paste, so a file name from a cloned repository can't submit lines after it as commands. ([#22](https://github.com/onurozcan/omux/pull/22))
- The browser's Try Again now loads the address that failed, so it works once a dev server comes up. ([#23](https://github.com/onurozcan/omux/pull/23))
- A missing or crashing `codex` showed a bare CancellationError instead of the message saying to install Codex CLI. ([#24](https://github.com/onurozcan/omux/pull/24))
- A Codex rate limit update with a null field cleared the known 5-hour window and its reset time until the next full read. ([#25](https://github.com/onurozcan/omux/pull/25))
- Opening a folder whose project was saved as `~/code/app` or with a trailing slash created a second project instead of reusing the first. ([#13](https://github.com/onurozcan/omux/pull/13))
- A dropped or pasted file whose name contains `!` failed in the shell with "event not found". ([#15](https://github.com/onurozcan/omux/pull/15))
- `build.sh` kept going after a failed `swift build` and reinstalled the previous binary. It now stops, and a macOS CI workflow builds and tests every pull request. ([#16](https://github.com/onurozcan/omux/pull/16))

## [0.6.1] - 2026-10-30

### Added

- **Drop images into a session from any app.** Dropping image data, or a file promise as Photos and browsers send, saves the image and pastes its path, which Claude Code and Codex read as an attachment. Until now only files could be dropped. ([#8](https://github.com/onurozcan/omux/pull/8))

### Fixed

- A value from a newer version in `workspace.json`, such as an unknown session provider or color, made the whole workspace fail to load and get overwritten with an empty one. Unknown values now decode as unset. Recent conversations with non-ASCII text near the 128 KB read limit no longer go missing from the list. ([#12](https://github.com/onurozcan/omux/pull/12))
- A commit hook that printed more than 64 KB to stderr froze omux for good. Diffs for a file that changed between a symlink and a regular file showed a second file header as content. Session names with `..` or `//` produced branch names git rejects. ([#9](https://github.com/onurozcan/omux/pull/9))
- Option typed the Meta prefix instead of the keyboard layout's character, so ⌥Q on a Turkish layout didn't give "@". Option now composes the layout's character and stays Meta only on keys without one: arrows, ⌥⏎, ⌥⌫, Escape and Tab. ([#11](https://github.com/onurozcan/omux/pull/11))

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

[0.6.1]: https://github.com/onurozcan/omux/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/onurozcan/omux/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/onurozcan/omux/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/onurozcan/omux/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/onurozcan/omux/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/onurozcan/omux/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/onurozcan/omux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/onurozcan/omux/releases/tag/v0.1.0
