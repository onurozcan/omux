# omux

A native macOS terminal for running [Claude Code](https://claude.com/claude-code) and [Codex](https://developers.openai.com/codex/cli) sessions side by side. Sessions are grouped into projects in a sidebar, each one keeps its own conversation across relaunches, and a files panel previews whatever the session is working on.

![omux with eight projects in the sidebar, a session running five subagents, a session waiting on Allow or Deny, two Codex sessions, and the Changes tab showing the diff](docs/screenshot.png)

Built with SwiftUI and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Features

- **Projects and sessions.** A project is a folder plus a default command; sessions live under it in the sidebar. Drag to reorder or move sessions between projects, rename them, and give them colors.
- **Agent selection.** Choose Claude Code, Codex, a plain shell, or a custom command in project/session settings. File › New Codex Session starts Codex directly. Worktree sessions also have an agent selector.
- **Conversations that resume.** Claude sessions keep their pinned UUID; Codex sessions keep the thread ID assigned by Codex. Restart and Continue reopen that exact conversation.
- **Live status.** Each session shows whether its agent is working, needs you or is done, and the Dock badge counts sessions waiting on you.
- **Notifications.** When a session you aren't looking at needs you, omux posts a macOS notification with a sound; clicking it opens the session. Notifications for finished sessions are optional, and Settings can make it sound only, with the macOS sound of your choice. Programs can send their own with OSC 9 or OSC 777: set Claude Code's notification channel to `ghostty` (in `/config`) to get its notifications, and its plugins', this way. Turn each kind on or off in Settings › Notifications.
- **Allow or deny from the sidebar.** Claude tool permissions and Codex command/file-change approvals can be answered in the sidebar or header. Codex's info button shows the requested command or reason. Other Codex permission forms and questions are answered in its terminal.
- **Subagents.** While Claude Code or Codex runs subagents, the selected session lists them in the sidebar with what each one is doing; other sessions show a count. The header's agents button lists them all, and clicking one opens its transcript in the right panel.
- **Worktree sessions** (⌥⌘T). A session can get its own Git branch and folder (`<repo>.worktrees/<branch>` next to the repo), so parallel sessions don't touch each other's files. Turn it on per project to make it the default. A project can also have a setup command that runs in each new worktree before the session starts, such as `cp "$OMUX_REPO/.env" . && npm install` (`$OMUX_REPO` is the main checkout), so files Git ignores and dependencies are there before the agent begins. Right-click a worktree session to create a pull request, merge it into its base branch or open its folder; closing one asks whether to keep or delete the worktree.
- **Pull request status.** With the [GitHub CLI](https://cli.github.com) installed, a worktree session whose branch has a pull request shows its number and state in the sidebar and header: checks running or failing, changes requested, approved or merged. Click the header chip to see each check and open it on GitHub. The session asks for your attention when checks start failing, a review comes in or the pull request is merged. Once it's merged, the session offers to delete its worktree and branch.
- **Right panel** (⌥⌘F), with three tabs:
  - **Files** (⌥⌘1). Browses the session's folder and previews Markdown, code and text (with optional line wrapping), images, PDFs, audio, video, and anything else Quick Look can show. File paths mentioned in the session's output are listed at the top; ⌘-click a path in the terminal to preview it.
  - **Changes** (⌥⌘2). The session's diff: against the base branch for worktree sessions, uncommitted changes otherwise. Click a line to leave a note, then send all notes to Claude in one message.
  - **Browser** (⌥⌘3). A web view per session that opens the local server the session prints (like `localhost:3000`). The pick button sends an element's HTML, styles and a screenshot to the prompt.
- **Images and files in the prompt.** ⌘V with an image on the clipboard pastes it as a file path, which Claude Code and Codex read as an attachment. ⌘V with files, or dropping files onto the terminal, pastes their paths.
- **Recent conversations** (⇧⌘O). Switch between Claude Code's recent conversations and the Codex conversation catalog.
- **Usage limits.** The sidebar shows the selected provider's plan limits when available (see [Privacy](#privacy)).
- **Updates.** omux checks for new versions about once a day and offers to install them, with the release notes; Help › Check for Updates… checks now. Updates are signed and verified before they're installed.
- **Open folders from anywhere.** Finder's right-click "Open in omux" service, dropping a folder on the Dock icon, or `open -a omux <folder>`.
- Themes, terminal font and size, and a quick switcher (⌘K).

## Requirements

- A Mac with Apple Silicon running macOS 14 or later
- To build from source: Swift 6.2 or later (Xcode 26 or the Command Line Tools); the downloaded app needs no Swift
- [Claude Code](https://claude.com/claude-code) installed as `claude` for Claude sessions; plain shell sessions work without it
- Codex CLI **0.165.0 or later** installed as `codex` for managed Codex sessions. Tested with 0.166.0; the app-server integration is experimental on the Codex side.

## Codex sessions

Select **Codex** in a project's settings to make it the default, or use **File › New Codex Session**. Session settings can override the project. Codex uses its existing CLI login and configuration; omux does not implement a separate login or read its credentials.

Each Codex terminal and omux's management client connect to the same private local app-server. Each terminal has its own server, so closing it does not stop an external Codex daemon or another terminal's server. Servers require a random bearer token kept in memory and passed to the TUI through its environment. No token is saved in `workspace.json`.

Codex permits one writing app-server per conversation. A conversation currently running in another app-server must be closed there before opening it in omux; omux reports the failure and keeps the saved ID. Restart waits for its previous server to exit before reopening the conversation.

Codex subagents appear in the sidebar/header. Their preview shows up to 100 recent protocol items. Review notes and browser picks are pasted into the selected session's prompt. Managed sessions use the Codex provider selection; custom wrappers remain terminal commands.

## Install

Download `omux-<version>.dmg` from the [latest release](https://github.com/onurozcan/omux/releases/latest), open it and drag omux to Applications. The app is signed with a Developer ID and notarized, so it opens without a warning. Or build it yourself:

## Build

```sh
./build.sh
open /Applications/omux.app
```

`build.sh` builds a release binary, assembles `build/omux.app`, and then **replaces `/Applications/omux.app`** so the Finder service and Dock entry stay registered. It signs with the first "Apple Development" certificate in your keychain, or ad hoc if there is none.

```sh
./build.sh --beta
```

builds and installs **omux Beta** next to the release app instead, with its own bundle id, preferences and workspace, so you can try a branch without touching your sessions. On its first launch it copies the release app's settings.

```sh
./build.sh --dist
```

builds the release that goes on GitHub: signed with the Developer ID certificate and the hardened runtime, notarized, stapled, and packaged as `build/omux-<version>.dmg` and `.zip`. It also signs the zip for Sparkle and adds the version to `site/appcast.xml`, which goes live with the site. It needs the notarization credentials stored once with `xcrun notarytool store-credentials omux-notary`; `--no-notarize` only signs.

## Linux

A native Linux version (GTK 4, libadwaita, VTE, WebKitGTK) lives in [`linux/`](linux/README.md). It is a separate Rust app with the same features, workspace format and settings; see [linux/README.md](linux/README.md) for installing and building it.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New session / new shell / new project | ⌘T / ⇧⌘T / ⇧⌘N |
| New session in a worktree | ⌥⌘T |
| Open folder / recent conversation | ⌘O / ⇧⌘O |
| Close session | ⌘W |
| Rename / edit session | ⌘R / ⌘I |
| Restart session | ⇧⌘R |
| Interrupt (Ctrl-C) | ⇧⌘. |
| Start or continue the session | ⇧⌘↩ |
| Jump to session | ⌘K |
| Next / previous session | ⇧⌘] / ⇧⌘[ |
| Session 1–9 in the current project | ⌘1 … ⌘9 |
| Right panel / Files / Changes / Browser | ⌥⌘F / ⌥⌘1 / ⌥⌘2 / ⌥⌘3 |

## Privacy

omux has no telemetry. Its integrations use these network paths:

- **Usage limits.** To show your plan limits, omux reads Claude Code's login from the macOS Keychain (the `Claude Code-credentials` item, via `/usr/bin/security`) and sends it to `https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` command uses. The token is never written to disk or logged. This endpoint is undocumented and may change or stop working at any time.
- **Pull request status.** If `gh` is installed, omux runs `gh pr view` for each worktree session's branch about once a minute and when you switch back to omux. gh uses its own login; omux never reads or stores your GitHub token.
- **Updates.** About once a day, omux fetches `https://omux.app/appcast.xml` to see whether a newer version exists, and downloads the update from GitHub only when you accept it. Nothing about you or your machine is sent.
- **Codex.** omux communicates with its owned Codex app-servers over authenticated loopback WebSockets. Codex itself connects to the model provider, tools, and services configured in your Codex settings. Usage is requested through `account/rateLimits/read`; accounts without supported plan limits display an unavailable message. omux starts its app-servers with analytics disabled.

Local files omux touches:

- `~/Library/Application Support/omux/workspace.json`: your projects and sessions (plus a `.bak` copy).
- `~/.claude/projects`: read to list recent conversations, to check whether a session's conversation exists, and to show a running session's subagents and their transcripts.
- Worktree sessions run `git` in your repository, and creating a pull request runs `git push` through your login shell. Nothing else is pushed or committed unless you confirm it.
- Elements picked in the browser are saved under your temporary folder (`omux-picks`) so Claude can read them.
- Settings are stored in the standard macOS preferences.

## Development checks

```sh
swift test
OMUX_CODEX_INTEGRATION=1 swift test
node scripts/codex-protocol-smoke.mjs
```

The opt-in Swift test starts the installed CLI with a temporary Codex home and tests exact thread IDs across server restarts. The Node 22+ smoke test uses a local fake model and real Codex CLI/TUI to check shared approvals, Allow, Deny, interruption, transcript items, and completion. Neither check sends a prompt to a real model or reads your saved conversations.

## Disclaimer

omux is an independent project and is not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## License

[MIT](LICENSE)
