# omux for Linux: plan and decisions

The Linux port is a separate Rust app in `linux/`. It reimplements the behavior described in [PARITY.md](PARITY.md) with gtk4-rs, libadwaita, VTE and WebKitGTK. It shares no code with the Swift app, but it reads and writes the same `workspace.json` format and uses the same settings keys.

Target: Ubuntu 24.04 and newer (GTK 4.14, libadwaita 1.5, VTE 0.76, WebKitGTK 6.0).

## Decisions

These resolve the open questions in PARITY.md section 13.

1. **Program status (OSC 7501) through our own PTY.** VTE has no hook for unknown OSC sequences. omux opens the PTY itself and starts the shell on it. A reader thread passes every byte to VTE with `feed()`, and a small scanner watches the same stream for OSC 7501, OSC 9, OSC 777 and OSC 133. Bytes are never removed or changed, so VTE still renders everything. Keyboard input, pastes and terminal replies reach the PTY through VTE's `commit` signal. The scanner answers the `OSC 7501 ; ?` query the way SwiftTerm does. The record store and parser are a direct port of SwiftTerm 1.99.1 `ProgramStatus.swift`.
2. **Environment.** The Mac builds a clean environment with a Homebrew PATH. On Linux a clean environment would drop the display, D-Bus, SSH agent and locale variables that programs need. So the session inherits omux's environment (read with `vars_os`), and then:
   - it removes the markers of a Claude Code session that omux itself may have been started from: `CLAUDECODE`, `CLAUDE_CODE_*`, `CLAUDE_PID`, `CLAUDE_EFFORT` and `AI_AGENT`;
   - it keeps user configuration such as `CLAUDE_CONFIG_DIR` and `ANTHROPIC_*`;
   - it sets `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=omux`, and `OMUX_CODEX_TOKEN` and `OMUX_REPO` as on the Mac.
   
   The shell is a login shell (`$SHELL -l`, else the passwd shell, else `/bin/bash`), so profile settings apply as on the Mac.
3. **Files.**
   - Workspace: `$XDG_CONFIG_HOME/omux/workspace.json` with `.bak`; `OMUX_WORKSPACE_DIRECTORY` overrides the directory, as on the Mac.
   - Settings: `settings.json` in the same directory, with the Mac's `UserDefaults` key names and defaults.
   - The JSON is written byte for byte like Swift's `JSONEncoder([.prettyPrinted, .sortedKeys])`.
4. **Attention count (the Dock badge).** Two places:
   - a `com.canonical.Unity.LauncherEntry` D-Bus signal, which the Ubuntu Dock, Dash to Dock and KDE show as a count;
   - a `(N)` prefix on the window title.
5. **Claude usage.** The token comes from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`), which has the same shape as the macOS Keychain item.
6. **Notifications.**
   - Banners use `gio::Notification`, with one id per session, and clicking one reveals the session.
   - Sounds play the freedesktop sound theme with `canberra-gtk-play` when it is installed, else `paplay`/`pw-play` on `/usr/share/sounds/freedesktop/stereo`.
7. **Previews.** There is no Quick Look on Linux, so previews are built from these pieces:
   - images: `gtk::Picture`
   - audio and video: `gtk::Video`
   - PDF and SVG: WebKitGTK, which ships PDF.js
   - text: plain monospace
   - Markdown: `pulldown-cmark`
   
   Anything else falls back to "Open with default app".
8. **Concurrency.** There is no async runtime. Blocking work (git, gh, file scans, HTTP with `ureq`, the Codex WebSocket with `tungstenite`) runs on threads and reports to the GTK main loop over `async-channel`.
9. **Shortcuts.** We follow PARITY.md 11.4: GNOME Terminal conventions (Ctrl+Shift+…) so that readline keys reach the shell.
10. **Changes panel.** The Mac watches the folder with FSEvents. Linux instead polls `git` every 2 s while the panel shows Changes, and refreshes when the session changes or omux becomes active. A recursive inotify watch of a large repository (node_modules included) can run out of watches. The Files tab watches only the root and the folders that are open.
11. **Small deliberate differences.**
    - The Codex port pick retries a few times if the port is taken.
    - A subagent's start time falls back to the file's modified time when the filesystem has no birth time.

## Status

All milestones are implemented. CI is green: fmt, clippy with `-D warnings`, the unit tests, the Codex integration test against the real CLI, the release build, the `.deb`, desktop and AppStream validation, and Xvfb screenshots.

The code was reviewed against the Swift sources in four areas: lifecycle and UI, terminal and data, agents, and panels and Git. The defects found were fixed. These known gaps remain, all minor:

- Codex usage is read through the shared catalog server, even when a session's own server is ready.
- Links in Markdown previews are styled but can't be clicked.
- The subagent transcript header has no live dot, elapsed time, or Allow/Deny.
- Image previews decode on the main thread.

## Milestones

Each milestone is a commit series on `linux-port`. CI must be green at the end of each one. CI runs fmt, clippy with warnings as errors, the tests, and a release build, and it takes an xvfb screenshot of the window.

| # | Milestone | Contents |
|---|---|---|
| 1 | Core model | workspace schema and back-compat, Swift-identical JSON writer, settings, `SessionProvider` (infer, Claude pinning). Ports `SessionProviderTests`. |
| 2 | Terminal | PTY spawn (login shell, env, cwd), VTE feed/commit bridge, resize, busy detection, process-tree kill, OSC scanner + program status store (unit tests from the SwiftTerm rules), bell, title, cwd. |
| 3 | App shell | window, sidebar (projects, sessions, status dots, rename, context menus, drag), session header, start/continue/stop/restart/kill/close, attention, notifications, badge, themes and fonts, settings window, shortcuts, quick switcher, edit sheets, quit confirmation, single instance, open folders, `.desktop`. |
| 4 | Claude | subagent monitor and transcript view, recent conversations, usage strip, welcome sheet. |
| 5 | Codex | app-server connection, protocol state machine (ports `CodexProtocolTests`), approvals, subagents, usage, recent conversations. |
| 6 | Git | worktree sessions and setup command, close/merge/PR flows, PR monitor, Changes tab with review notes. |
| 7 | Panels | Files tab (tree, watcher, mentioned paths, previews, Markdown), Browser tab with the element picker, paste and drop of files and images. |
| 8 | Release | `.deb` and tarball from CI, install docs, README and CHANGELOG entries, screenshots, upstream pull request. |
