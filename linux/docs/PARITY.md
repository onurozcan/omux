# omux Linux port: parity specification

Source of truth: the macOS SwiftUI app in `Sources/omux/` (version 0.5.0, build 5; `Info.plist:27-30`), tests in `Tests/omuxTests/`, `README.md`, `CHANGELOG.md`. Target: a separate Rust + gtk4-rs + libadwaita + VTE (`vte4`) + WebKitGTK 6 app under `linux/`, sharing no code with Swift.

Citation format is `File.swift:line` (all files under `Sources/omux/` unless noted). Swift `UserDefaults` keys are given verbatim so the Linux settings file can reuse them. "Mac" = the Swift app, "Linux" = the port.

Update for 0.6.1 (upstream `0e39e51`):
- unknown provider and color values decode as unset;
- Recent decodes the 128 KiB head leniently;
- `Git.slug` collapses runs of `.` and `/`;
- `parseDiff` resets on `diff ` lines (type changes);
- git's stderr is read concurrently;
- image data dropped on the terminal is saved as `image-<UUID>.png` and its path pasted;
- Option composes layout characters. On Linux that's AltGr, which VTE already handles.

Sparkle updates (0.6.0) are macOS-only. The Linux port follows all of the above.

Reading note: the one piece of behavior that is NOT in this repo is the OSC 7501 "program status" parser, which lives in the SwiftTerm dependency (`Package.swift:7`, resolved 1.99.1 in `Package.resolved`). Everything the app does with it is documented in section 4.1; the wire grammar is an open question (section 13).

---

## 1. Architecture overview

### 1.1 File ownership

| File | Owns |
|---|---|
| `OmuxApp.swift` | `@main` app, `Prefs` key constants (25-49), Settings window (64-135), `ContentView` layout and sheets (162-233), `SessionHeader` (236-299), menu commands/shortcuts (`AppCommands`, 301-360), Finder service (363-372), `AppDelegate` (quit confirmation, reopen, open-URLs) (374-412) |
| `Models.swift` | Persisted types `TabColor`, `TabItem`, `Worktree`, `TabGroup`, `Workspace`; live `TabRuntime`; `Persistence` (path, load, save, .bak) |
| `SessionProvider.swift` | `claude/codex/shell/custom` enum, `infer(command:)`, `claudeCommand(...)` (pins the Claude session UUID) |
| `Store.swift` | Central `@MainActor` model: groups, selection, per-tab runtime, terminal lifecycle (launch/start/stop/kill/restart/close), attention logic, notifications routing, tab/group CRUD, drag-move, persistence debounce |
| `TermView.swift` | SwiftTerm subclass: process start, OSC hooks (title, OSC 7, OSC 7501 status, OSC 9/777 notifications), paste/drop handling, path/URL regexes, scrollback reader |
| `Agents.swift` | Claude subagent discovery (`AgentMonitor`/`AgentScanner`), transcript reader (`Transcript`, `AgentTranscript`), subagent UI (rows, pill, popover, transcript view) |
| `CodexConnection.swift` | One `codex app-server` child process + one authenticated WebSocket JSON-RPC client |
| `CodexManager.swift` | Per-tab Codex connections, thread/turn/approval bookkeeping, status derivation, usage limits, recent conversations, transcripts |
| `CodexAgents.swift` | Codex subagent list UI + Codex transcript view (polls `thread/items/list`) |
| `UsageMonitor.swift`, `UsageView.swift` | Claude usage polling (Keychain token + HTTP) and the sidebar usage strip (Claude or Codex limits) |
| `RecentSessions.swift` | Scans `~/.claude/projects` for recent Claude conversations; `RecentConversation` union |
| `Git.swift` | Synchronous git/gh process wrappers, worktree helpers, diff parsing, file/diff models |
| `Worktrees.swift` | Worktree session creation, close/merge/PR/cleanup flows (alerts), `WorktreeSheet`, `BranchChip`, `PermissionButtons` |
| `PullRequests.swift` | `gh pr view` polling model and PR badge/chip/popover UI |
| `Changes.swift` | Changes tab: model (`Changes`), diff UI, review notes |
| `FilePanel.swift` | Files tab: lazy tree, FSEvents watcher, previews (text/markdown/image/media/PDF/QuickLook), markdown renderer |
| `Browser.swift` | Per-session WKWebView, element picker JS, picker output files |
| `RightPanel.swift` | Tab strip (Files/Changes/Browser) |
| `Sidebar.swift` | Sidebar list, session rows, group headers, context menus, inline rename, drop-folder |
| `Sheets.swift` | Quick switcher, session edit, project edit, recent conversations sheets |
| `Welcome.swift` | First-launch welcome sheet; `Tools.path(of:)` (login-shell `command -v`) |
| `Notifier.swift` | UNUserNotificationCenter wrapper and sound playback |
| `Theme.swift` | 11 themes (bg/chrome/fg + 16-color palettes), terminal font resolution |

### 1.2 Data flow

```
workspace.json  <->  Store.groups / selectedTabID  (debounced save 400 ms)
                          |
   Store.runtime[tabID] (TabRuntime, never persisted)  <-- TermEvent from TermView
        ^                                                   (title, cwd, bell, exit, status, notification)
        |-- CodexManager.onStatus (protocol is authoritative for Codex tabs)
        |-- AgentMonitor (2 s poll of ~/.claude/projects/*/<session>/subagents)
        |-- PullRequestMonitor (60 s poll of `gh pr view`)  -> Store.requestAttention
        |-- Changes (FSEvents on session folder -> git diff)
        v
SwiftUI views (Sidebar rows, SessionHeader, panels) + Dock badge + Notifier
```

- `Store` owns one `TermView` per tab in `terminals[UUID]` (Store.swift:53). Views are reparented, never recreated, when switching tabs (`TerminalHost`, TermView.swift:236-262). The terminal is created lazily: `terminal(for:)` (Store.swift:157-162) on first selection, or eagerly at launch when auto-resume is on.
- A replaced view (restart) still reports its exit; only the view currently registered for that tab may update runtime (Store.swift:183-186).
- `Store.update(id){...}` only publishes when the value changed (Store.swift:591-596). Dock badge = count of runtime entries with `needsAttention` (Store.swift:24-29).

### 1.3 Threading, timers, polling intervals (complete list)

| What | Interval / trigger | Where |
|---|---|---|
| Workspace save debounce | 400 ms after any change of `groups` or `selectedTabID` | Store.swift:73-80 |
| Auto-resume start stagger | 0.25 s between sessions, selected session first | Store.swift:164-176 |
| Command typed into new shell | 0.3 s after process start | Store.swift:237-241 |
| `stop` second Ctrl-C | 0.35 s after first; busy refresh at 1.5 s | Store.swift:292-294 |
| `start` busy refresh | 1.5 s after | Store.swift:422 |
| Submit after paste (`sendText(submit:true)`) | Return (`\r`) 0.15 s after paste | Store.swift:324-327 |
| Welcome sheet on fresh install | 0.5 s after launch | Store.swift:106 |
| Subagent scan (`AgentMonitor`) | 2 s timer, skipped if a scan is in flight; work on serial queue `omux.agents` (utility QoS) | Agents.swift:61-103 |
| Subagent folder lookup miss cache | 3 s | Agents.swift:159 |
| Subagent transcript view | 1.5 s timer, incremental read | Agents.swift:306 |
| Codex subagent transcript view | every 2 s (`thread/items/list`) | CodexAgents.swift:301 (file line 82) |
| Mentioned paths/URLs scan | every 4 s while the Files panel is mounted, and on tab selection change / panel appear; regex runs on a background task over a main-thread copy of the scrollback | FilePanel.swift:201-205, Store.swift:306-318 |
| FSEvents watcher (Files tab, Changes) | 1.0 s latency coalescing, `NoDefer` | FilePanel.swift:64-66 |
| Pull request poll | 60 s timer + on app becoming active + once at init; serial queue `omux.pulls` | PullRequests.swift:458-467 (file lines 82-91) |
| Claude usage poll | `usageInterval` seconds (default 300) while the sidebar usage strip exists; also immediate on appear / click | UsageMonitor.swift:34-46, UsageView.swift:199-201 |
| Codex usage poll | loop every `max(usageInterval, 30)` s while the selected session is Codex; plus after each `prepare` | UsageView.swift:202-208, CodexManager.swift:112 |
| Codex readiness probe | up to 80 tries, 0.3 s request timeout, 100 ms sleep | CodexConnection.swift:91-100 |
| Codex request timeout | 20 s each | CodexConnection.swift:141 |
| Codex previous-server wait | up to 100 x 100 ms = 10 s | CodexConnection.swift:191-198 |
| Codex interrupt wait for `turn/completed` | up to 100 x 100 ms per thread | CodexManager.swift:143-147 |
| `refreshBusy` | on tab selection (deferred), on every title change, on hover of a row, after start/stop | Store.swift:19-21, 513, Sidebar.swift:181 |

Everything model-ish is `@MainActor`; git/gh/FS scans run on detached tasks or serial dispatch queues and hop back to main to publish.

### 1.4 Window structure

Single window (`Window(id: "main")`, title "omux" / "omux Beta") default 1240x780, min 720x420, hidden title bar (OmuxApp.swift:12-19, 162-233). `NavigationSplitView`: sidebar (200..420, ideal 250; Sidebar.swift:94) | detail = `HSplitView{ [SessionHeader + terminal] (min 360) , RightPanel (min 260, ideal 380, max 900) when `showFiles` }`. Closing the last window does not quit (OmuxApp.swift:384). Reopening with no window opens it again (392-395).

---

## 2. Persistent data

### 2.1 `workspace.json`

**Location (Mac):** `~/Library/Application Support/omux/workspace.json`, backup `workspace.json.bak` in the same dir (Models.swift:179-200). Beta build uses `.../omux-beta/` (Models.swift:190, beta = bundle id suffix `.beta`; `build.sh:22`). Env override `OMUX_WORKSPACE_DIRECTORY=<dir>` (non-empty) replaces the directory entirely and creates it (Models.swift:183-187); keep this for tests.
**Location (Linux, proposed):** `$XDG_CONFIG_HOME/omux/workspace.json` (default `~/.config/omux/`), same `.bak` name; honor `OMUX_WORKSPACE_DIRECTORY`. Create the directory on first access.

**Encoding:** Swift `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` (Models.swift:216): 2-space indent, keys alphabetically sorted, `" : "` separator style (`"key" : value`), `/` escaped as `\/` (Foundation default). UUIDs are encoded as **uppercase hyphenated strings**. Optional properties that are nil are **omitted** (synthesized Codable `encodeIfPresent`). Enums are their `rawValue` strings. No dates. For byte-parity (so each app's change-detection .bak logic is not fooled) the Linux writer should produce the same format: sorted keys, 2-space pretty print, uppercase UUIDs, omit nulls. Readers must be tolerant (below).

**Schema:**

```jsonc
Workspace {
  "groups": [TabGroup],          // default []
  "selectedTabID": "UUID"        // optional; ignored if not the id of any tab
}
TabGroup {                       // Models.swift:82-114
  "id": "UUID",                  // default: new UUID when missing
  "name": "string",              // default "Project" when missing
  "directory": "string",         // optional; may contain "~" (expanded at use); nil = home
  "command": "string",           // optional. See defaults note below
  "provider": "claude|codex|shell|custom",   // missing => infer(command)
  "isCollapsed": bool,           // default false
  "useWorktrees": bool,          // default false
  "worktreeSetup": "string",     // default ""
  "tabs": [TabItem]              // default []
}
TabItem {                        // Models.swift:31-72
  "id": "UUID",                  // default new UUID
  "name": "string",              // default "Session"
  "directory": "string",         // optional; nil = inherit group's dir (then home)
  "command": "string",           // optional; absent = inherit group's command; "" = plain shell
  "provider": "claude|codex|shell|custom",  // optional; absent = inferred (see below)
  "color": "none|red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray", // default "none"
  "claudeSessionID": "UUID",     // default new UUID. Always present after first save.
  "codexThreadID": "string",     // optional, opaque (NOT necessarily a UUID; Tests CodexProtocolTests:95-99)
  "worktree": Worktree           // optional
}
Worktree { "branch": "string", "base": "string", "repo": "string" }   // all required (Models.swift:74-80)
```

**Decode/back-compat rules (must replicate):**
- Every TabItem and TabGroup field is `decodeIfPresent` with the defaults above, "so saved workspaces survive schema changes" (Models.swift:55, 102-113). Unknown keys are ignored. `Worktree` has no tolerant decoder: missing `branch`/`base`/`repo` makes the whole workspace fail to decode, then fall back to `.bak`.
- **Defaults when keys are missing differ from the in-memory defaults:** a group without `"command"` decodes `command = nil` (not `"claude"`); a group without `"provider"` gets `SessionProvider.infer(command: command)` which is `.shell` when command is nil/empty (Models.swift:108). The in-memory `TabGroup.init` default (`command = "claude"`, `provider = .claude`, Models.swift:86-87) only applies to groups created in the app. Test: legacy group `{"command":"claude --model opus","tabs":[{"claudeSessionID":"<id>","name":"Existing"}]}` decodes to provider claude, command preserved, tab session id preserved (SessionProviderTests:2-9 / file lines 5-14).
- Tab provider resolution `resolvedProvider(in:)` (Models.swift:69-71): `tab.provider ?? (tab.command != nil ? infer(command: tab.command!) : group.provider)`. So `command: ""` => `.shell` and never inherits the project agent (SessionProviderTests:210-214 equivalent).
- `infer(command:)` (SessionProvider.swift:26-32): trim whitespace+newlines; empty => `.shell`; exactly `"codex"` => `.codex`; `"claude"` or hasPrefix `"claude "` => `.claude`; else `.custom`. Tests: `env codex`, `codex exec task`, `npm run dev`, `/path/to/wrapper` are `.custom` (SessionProviderTests:228-232 equivalent).
- UUID decode accepts either case. Linux should keep the id string it read when re-saving where possible; when generating, use uppercase to match Swift.
- `loadWorkspace()` (Models.swift:203-212): tries `workspace.json` then `workspace.json.bak`; accepts the first file that (a) reads, (b) decodes as `Workspace`, (c) has **non-empty `groups`**. Otherwise returns nil => first-run state.
- First-run state (Store.swift:59-65): one group `{name:"Default", tabs:[{name:"Session 1"}]}` (created through `TabGroup(name:directory:tabs:)`, so it keeps the in-memory defaults `command:"claude"`, `provider:.claude`) and the workspace is saved immediately (`if saved == nil { save() }`, Store.swift:100).
- Selection restore: `selectedTabID` if it exists, else first tab of the first non-empty group (Store.swift:66-71).

**Save algorithm** (Models.swift:214-222): encode; if `workspace.json` currently exists and its bytes differ from the new encoding, write the *old* bytes to `workspace.json.bak` (atomic write), then write the new bytes to `workspace.json` (atomic write). Errors are swallowed. If bytes are identical nothing is touched, so the .bak is always "previous distinct version". Triggers: 400 ms-debounced on `groups` or `selectedTabID` change (Store.swift:73-80), immediately when a Codex thread id is assigned or changes (Store.swift:256, 98), at quit (`prepareForTermination`, Store.swift:805-810), and first run.

**Persisted vs runtime:** `TabRuntime` (title, cwd, busy, statusState, needsAttention, exited, ...) is never saved (Models.swift:121-177). Collapsed state IS saved (`isCollapsed`). Browser address, notes, panel contents are not saved.

**Secrets:** Codex bearer token is memory-only and never in the file (README "Codex sessions").

### 2.2 Settings (UserDefaults; Linux: `settings.json` or GSettings with the same key names)

Mac store: standard preferences domain `net.pf1.omux` (`beta`: `net.pf1.omux.beta`). Keys from `Prefs` (OmuxApp.swift:25-45) with defaults from `@AppStorage` (OmuxApp.swift:65-77, ContentView 165-168):

| Key | Type | Default | Meaning / used at |
|---|---|---|---|
| `confirmQuit` | bool | `true` | Confirm quit while sessions run (OmuxApp.swift:400) |
| `showFolderPath` | bool | `true` | Show folder path under session name (`statusLine(showFolder:)`) |
| `usageInterval` | double seconds | `300.0` | Picker values 60 / 300 / 1800 / 3600 (UsageMonitor.swift:36) |
| `theme` | string | `"dark"` | one of the 11 theme raw values (section 11.6) |
| `autoResume` | bool | `false` | Start every saved session at launch (Store.swift:109) |
| `showFiles` | bool | `false` | Right panel visible |
| `filesByDate` | bool | `false` | Files list sort by modification date |
| `filesBrowserCollapsed` | bool | `false` | Files tree collapsed to its 28 pt header |
| `previewWrapLines` | bool | `true` | Wrap in text preview and diff |
| `panelTab` | string | `"files"` | `files` / `changes` / `browser` |
| `fontFamily` | string | `""` | empty = system monospaced |
| `fontSize` | double | `13.0` | stepper 9...24; a stored value <= 0 means 13 (Theme.swift:93-107 region) |
| `notifyNeedsYou` | bool | `true` | read as `object(forKey:) as? Bool ?? true` (Store.swift:554) |
| `notifyDone` | bool | `false` | notify when finished/error (Store.swift:555) |
| `notifyPrograms` | bool | `true` | OSC 9/777 notifications (Store.swift:533) |
| `notifyStyle` | string | `"banner"` | `"banner"` or `"sound"` (sound only) |
| `notifySound` | string | `"Default"` | macOS sound name or "Default" (Notifier.swift list) |
| `welcomed` | bool | `false` | Set true on first launch (Store.swift:103-108) |
| `importedReleaseSettings` | bool | n/a | beta only: copy keys in `Prefs.all` from release domain once (OmuxApp.swift:51-61). `Prefs.all` omits `notifyStyle`, `notifySound`, `welcomed` (probable oversight). Not needed on Linux. |

Welcome logic: if `welcomed` false -> set true; show the welcome sheet only if there was no saved workspace (fresh install), 0.5 s later (Store.swift:103-108).

---

## 3. Session lifecycle

### 3.1 Process launch (exact)

`Store.launch` (Store.swift:191-242):

1. `dir` = `(tab.directory ?? group.directory)` with `~` expanded, else `$HOME`; if it does not exist or is not a directory, fall back to `$HOME` (192-195).
2. `shell = $SHELL ?? "/bin/zsh"` (198). **Linux: `$SHELL` else `/bin/bash`.**
3. **Clean environment** (comment: "like Terminal.app: nothing leaks in", 199-212). The child env is exactly:
   - `HOME`, `USER` (inherited or login name), `LOGNAME` (same), `SHELL`, `TMPDIR` (inherited or system temp), `PATH` = `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `LANG` (inherited or `en_US.UTF-8`), `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=omux`.
   - `__CF_USER_TEXT_ENCODING` if inherited (macOS only); `CODEX_HOME` if inherited (213-214).
   - `OMUX_CODEX_TOKEN=<token>` when the resolved provider is Codex (216-218).
   - `OMUX_REPO=<worktree.repo>` when the tab has a worktree (220).
   - Linux notes: the login shell sources the user's profile and fixes PATH; recommend a PATH that appends `~/.local/bin`, `~/.cargo/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`; additionally pass through `XDG_RUNTIME_DIR`, `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_*`, `SSH_AUTH_SOCK`, `LC_*`, `NO_COLOR`-style vars as the user expects; keep the principle of stripping `CLAUDE_CODE_*`/`CLAUDECODE` markers when omux itself was launched from a Claude session. This is a deliberate Linux decision (open question Q4).
4. `startProcess(executable: shell, args: ["-l"], environment: ..., execName: "-" + basename(shell), currentDirectory: dir)` (222-228): the shell is a **login shell** by two redundant mechanisms: `argv[0] = "-zsh"` AND `argv = ["-l"]`. On Linux use VTE `spawn_async` with argv `[ "-<shell>"? ...]`: simplest is `argv = [shell, "-l"]` (bash/zsh/fish all accept `-l`).
5. Runtime reset (229-233): `provider`, `agentConnected=false`, `exited=false`, `cwd=dir`, `title=""`, status fields cleared.
6. What is run in the shell afterwards (235-241):
   - If provider is Codex and `command == nil`: `startCodex` (section 5.3) which later types the codex resume line.
   - Else `command ?? startupCommand(tab, group)`; if non-empty, **0.3 s later the text `command + "\n"` is typed into the interactive shell** (not `exec`ed). So when the agent exits the user is back at a shell prompt, the tab stays alive, and `busy` goes false.
   - `command == ""` (explicit empty) means "start nothing" (used for dormant tabs and New Shell).

`startupCommand(tab, group)` (Store.swift:427-434):
```
raw = trim(tab.command ?? group.command ?? "")   // trims spaces only (.whitespaces)
if resolvedProvider == .shell -> nil
if raw empty -> nil
if resolvedProvider != .claude -> raw          // custom commands and "codex" returned verbatim
else -> claudeCommand(raw, sessionID: tab.claudeSessionID, conversationExists: file exists)
```

### 3.2 Claude UUID pinning (exact flags)

`SessionProvider.claudeCommand(raw, sessionID, conversationExists)` (SessionProvider.swift:34-44):
- `parts = raw.split(" ", maxSplits: 1)`; if `parts[0] != "claude"` return `raw` unchanged.
- `rest = parts[1] or ""`; `words = rest.split(on any whitespace)`.
- If any word is in `{--resume, -r, --continue, -c, --session-id}` or has prefix `--resume=` or `--session-id=` return `raw` unchanged (user-managed).
- `session = sessionID.uuidString.lowercased()`.
- flag = `conversationExists ? "--resume <session>" : "--session-id <session>"`.
- result = `["claude", flag, rest]` without empty parts, joined by single space.
- Examples (SessionProviderTests:234-240 equivalent): `claude --model opus`, new => `claude --session-id <uuid> --model opus`; `claude`, existing => `claude --resume <uuid>`.
- `conversationExists` = any `~/.claude/projects/<dir>/<session>.jsonl` exists (Store.swift:437-441). `<dir>` is Claude's escaped-cwd directory; the code simply iterates every project dir.
- If `tab.provider == .claude` but `startupCommand` is nil (empty command), `start()` falls back to the literal `claude --session-id <lowercase uuid>` (Store.swift:413). Note: that fallback never uses `--resume`.
- Opening a conversation from Recent creates a tab with `provider=.claude`, `command="claude"`, `claudeSessionID=<that conversation's id>` so the pin resumes it (Store.swift:458-478).

### 3.3 Dormant vs auto-started tabs, Continue/Restart

- **Launch with `autoResume=false` (default):** every restored tab gets `TabRuntime(exited: true)` (Store.swift:113). When a tab is first selected its terminal is created with `command: ""`: a plain login shell in its directory, **no agent started** (157-162). The user presses ▶ (Start/Continue, `⇧⌘↩`).
- **With `autoResume=true`:** `startAllSessions` starts every tab with `command=nil` (full auto start: Claude with pin, Codex via app-server), selected tab first, 0.25 s apart (164-176).
- **New tabs** (New Session, New Codex/Claude/Shell, worktree session, open folder, recent conversation) always auto-start (command nil) irrespective of `autoResume`, except New Shell which passes `command: ""`.
- **`start(id)` (▶ / Start or Continue)**, Store.swift:387-423:
  1. If a live (not exited) terminal exists: if Codex with `statusState == .error` and not connected -> `restart`. Return if the shell has a child process (agent already running) or a Codex start is in flight. If the runtime provider differs from the now-resolved provider -> `restart`.
  2. If resolved provider is not Claude: live terminal => Codex: `startCodex` again with the existing cwd; otherwise type `startupCommand + "\n"`. No live terminal => `restart`.
  3. Claude: `command = startupCommand ?? "claude --session-id <uuid>"`. Live terminal: return if `busy`, else type `command + "\n"` (resumes the pinned conversation if its .jsonl exists). Exited: remove the old view, create a new terminal with that command. Busy refresh after 1.5 s.
- **`restart(id)`** (655-664): close Codex server, kill process tree, remove view, create a new terminal with `command=nil` (so full auto start including `--resume`/Codex resume).
- **`stop(id)` (Interrupt)** (282-295): Codex -> if a start is pending, kill, else `turn/interrupt` protocol (section 5.7); others: type `\u{03}` twice, 0.35 s apart ("Claude Code asks for a second Ctrl-C to exit"), the shell stays at its prompt; refresh busy after 1.5 s.
- **`kill(id)`** (298-303): close Codex, kill tree, runtime `exited=true, statusState=nil, busy=false, agentConnected=false`.
- **Kill tree:** `kill(-shellPid, SIGHUP)` (process group; shell is session leader) then `terminate()` (273-277). Linux: `killpg(pid, SIGHUP)` and then SIGTERM/SIGKILL fallback.
- **`closeTab`** (636-653): close Codex, kill tree, drop view, clear runtime, clear notification, close browser, close open subagent refs, remove tab; select sibling at the same index (or last), or first tab overall if the group became empty. Closing the last project's last tab leaves the workspace with an empty group (a new "Project N" is created only by `deleteGroup` on an empty workspace).
- **Process exit** event (`processTerminated` or failed to start): `exited=true`, status cleared, `busy=false` (Store.swift:521-522). Tab shows "Stopped" at 55% opacity.
- **"Busy"** = the shell has a child process (macOS sysctl scan for `e_ppid == shellPid`; Store.swift:364-384). Linux: compare the pty's foreground process group (`tcgetpgrp(master_fd)`) with the shell pid, or enumerate `/proc/*/stat` ppid. For Codex tabs, busy false resets `agentConnected=false` (Store.swift:368-372).
- Quit (`prepareForTermination`, 805-810): save, cancel Codex starts, shut down Codex servers, kill all trees. Confirm dialog shown if `confirmQuit` (default true) and running sessions > 0 (OmuxApp.swift:397-411): title `Quit omux?`, text `"N session(s) is/are running. Agent conversation IDs are saved so you can continue them next launch."`, buttons Quit/Cancel.

### 3.4 Codex thread IDs

- Stored in `TabItem.codexThreadID`, assigned only by the Codex server (`thread/start` response `thread.id`), "never guessed from the working directory or latest chat" (Models.swift:43). Saved immediately after `prepare` (Store.swift:255-256), and whenever a new root thread appears via `thread/started` (e.g. TUI `/clear`; CodexManager.swift:308-331, `onThreadChange` -> Store.swift:96-99).
- If `codexThreadID` is nil at start -> `thread/start`; else `thread/resume` the saved id. The Edit Session sheet offers "Start a fresh conversation on next restart" which nils it (Sheets.swift:127-130).
- Opening a Recent Codex conversation creates a tab `{command:"codex", provider:.codex, codexThreadID:<id>, name: first 60 chars of name}` (Store.swift:480-496), reusing a group whose `directory == conversation.cwd` or creating one with `provider=.codex, command="codex"`.

---

## 4. Agent status detection

### 4.1 Claude (and any program): terminal OSC 7501 "program status"

The Mac app does **not** watch transcripts, use hooks, or parse the terminal title for working/needs-you/done. It relies on SwiftTerm's decoded **OSC 7501** records (the "program status" protocol, emitted by Claude Code), delivered through `programStatusChanged(source:records:)` (TermView.swift:43-54). What the app consumes from each record `TerminalProgramStatus`:

| Field | Type | Use |
|---|---|---|
| `id` | String | empty string = the root record (the session itself); non-empty = child record (a subagent) |
| `state` | enum raw string: `idle`, `working`, `done`, `blocked`, `error` | maps 1:1 to `TabRuntime.StatusState` (Models.swift:139) |
| `kind` | optional enum raw string (comment says: `permission`, `question`, `auth`) | "Why a blocked program waits" (Models.swift:135) |
| `message` | optional String | shown as the detail ("Needs you · <message>") |
| `title` | optional String | child records only, used for matching subagents |

Selection of the root: `records.first(where: id.isEmpty) ?? records.last`; if no records at all, emit status nil (TermView.swift:48-51). All non-root records (`!id.isEmpty`) become `statusChildren` (44-47). Events are delivered on main; if called off-main they are hopped (89-95).

`Store.applyStatus` (Store.swift:539-546): sets `statusState/Kind/Detail/Children`; if state is `blocked` or `done` and the session is not being watched => `needsAttention = true`; if the state changed => `notifyStatusChange`.

Derived UI strings, `TabRuntime.statusLine(showFolder:)` (Models.swift:152-166), in order:
1. `blocked` => `"Needs you · <detail ?? kind>"` or `"Needs you"`.
2. `working` => `"Working · <detail>"` or `"Working…"`.
3. `done` => `"Done"`; `error` => `"Error · <detail>"` or `"Error"`; `idle` falls through.
4. `exited` => `"Stopped"`.
5. non-empty terminal title (OSC 0/2) => the title.
6. if `showFolder` and cwd known => cwd with `~` abbreviation.
Status colors: blocked orange, working blue, done green, error red, otherwise none (Models.swift:168-176). Dot color in rows/header: `statusColor ?? tab.color.color ?? secondary@0.35` (Sidebar.swift:117-119).

`awaitsPermission` = `statusState == .blocked && statusKind == "permission"` (Models.swift:150). This is the only condition that shows Allow/Deny for non-Codex sessions.

Other terminal events used (TermView.swift:20-55, Store.swift:508-537):
- **Title (OSC 0/2):** `refreshBusy`; stored as `runtime.title`; if the title changed and the session isn't watched => `hasActivity = true` (blue dot) ("Claude Code rewrites the title as its state changes").
- **OSC 7 cwd:** `file://` URL => path (`URL(string:)?.path ?? raw`) stored as `runtime.cwd`.
- **Bell:** if not watched => `needsAttention=true`; and always `NSSound.beep()` on main (TermView.swift:225-231).
- **Notification OSC 9/777:** section 9.
- A Codex tab **ignores** OSC 7501 status entirely ("protocol is authoritative", Store.swift:526-528).

"Watching" (`isWatching`, Store.swift:576-578): the tab is selected AND the app is active AND there is a key window. Attention is cleared (`hasActivity=false, needsAttention=false`, notification removed) when a tab becomes selected (deferred to next runloop turn, Store.swift:16-21, 586-589) and when the app becomes active (82-86).

**Linux implication (hardest item):** VTE offers no hook for unknown OSC sequences. Options, in order of preference:
1. Own the PTY: create the pty master/slave with `openpty`, spawn the shell on the slave, read master output in the app, scan for `ESC ] 7501 ; ... (BEL | ESC \)` (and OSC 9/777 if VTE lacks signals), then `vte::Terminal::feed()` the remaining bytes; forward `commit` signal bytes to master; propagate size with `TIOCSWINSZ`. Must also pass `VTE_VERSION`-style env as desired.
2. Use `vte::Pty`/`spawn_async` normally and add a second source of truth: tail `~/.claude/projects/<dir>/<session>.jsonl` (assistant `tool_use` without matching `tool_result` => working/needs-permission; last message stop => done) plus Claude `hooks` (Notification, Stop) in a generated settings overlay. Not equivalent; lower fidelity.
Document the exact OSC 7501 grammar before implementing (Q1, section 13).

### 4.2 Claude subagents (file-based, 2 s poll)

Owner: `AgentMonitor` + `AgentScanner` (Agents.swift:53-231).

**Which sessions are scanned** (poll(), 71-103): for every tab whose provider is Claude: `active = !exited && (busy || statusState in {working, blocked})`. Include if `active` or the monitor already holds agents for it. One scan at a time (`scanning` flag).

**Folder discovery** (157-170): for each directory under `~/.claude/projects/*`, check for `<dir>/<session-uuid-lowercase>/subagents` (a directory). First hit is cached forever; a miss is cached for 3 s.

**Per agent** (172-214): for each file `*.meta.json` in the folder: `id = filename minus ".meta.json"` (like `agent-<hash>`), `transcript = <id>.jsonl` in the same folder.
- `metaDate` = mtime of the meta file; `transcriptDate` = mtime of transcript (else metaDate).
- `recentlyWritten = now - transcriptDate < 1800 s`.
- Skip unless `now - metaDate < lingerBackground (120 s)` OR (`active` AND `recentlyWritten`).
- Parse meta JSON, tolerant decoding of: `agentType` (String), `description` (String), `requestShape` (String; `"background"` => background), `spawnDepth` (Int), `finished` (Bool).
- `finished = meta.finished ?? false`. If finished: keep only if `now - metaDate < (background ? 120 : 20)` seconds (`lingerBackground=120`, `lingerForeground=20`, lines 139-140). If not finished: keep only if the session is `active` and `recentlyWritten`.
- Incremental transcript progress (state per transcript path): count every `tool_use` content item in `assistant` messages (`object.type == "assistant"`, `message.content[]` items with `type=="tool_use"`), keep the last one's summary as `activity` (221-230).
- Fields: `type = agentType ?? "agent"`, `description = description ?? id`, `depth = max(1, spawnDepth ?? 1)`, `started = transcript creation date (birthtime) ?? metaDate`, `ended = finished ? metaDate : nil`.
- Result sorted by `started` ascending.

**Blocked matching with OSC 7501 children** (105-111, 94-98): for each unfinished agent, `blocked = true` if any child record with `state == .blocked` satisfies: `child.id` contains the agent id with the `"agent-"` text removed, OR `child.title` or `child.message` case-insensitively contains `agent.description`.

**Display rules:** `color`: blocked orange, finished green, else blue (27). `shortActivity`: blocked "needs you", finished "done", else first word of `activity` or "starting" (30-34). `elapsedText`: seconds since started to ended/now; `>= 3600` => `"%dh %dm"`, else `"%d:%02d"` (22-25). Foreground agents render a filled dot, background agents a ring (389-399).
Sidebar rows (403-448): selected session shows all agents; other sessions show only blocked agents; first 3 shown with `"+N more"` / `"Show less"` toggle; row indent `(min(depth,3)-1)*10`; tooltip `"<type> · <activity or starting>"`. Non-selected sessions also show `"N agent(s)"` in the status line for running (unfinished) count (Sidebar.swift:107-111). Header pill (451-481): up to 8 dots + `"N agent(s)"` (running) or `"agents done"`; click opens a 400 pt popover list (483-549) with `"Agents  N running · M done"`, rows with type chip, description, elapsed (ticks each second), activity/"Needs permission"/"Done", `"· N tool(s)"`, `"· background"`. Footer `"Click an agent to open its transcript"`. If a blocked agent's transcript is open and the session awaits permission, Allow/Deny appear in the transcript header (580-582).

### 4.3 Subagent transcript display

`AgentTranscript` (Agents.swift:289-384), opened in the Files panel top pane (FilePanel.swift:98-101). Every 1.5 s read bytes appended since `offset` (max 64 MiB per read), keep a partial last line in `remainder`, split on `0x0A`, parse each as JSON (`Transcript.newObjects`, 238-251). Events:
- `type=="user"`: if `message.content` is an array: each item `type=="tool_result"` => result `{tool_use_id, text = joined text parts (string or [{type:"text",text}] joined "\n"), is_error}`. If `message.content` is a non-empty string: first one when the view had no entries at load time => **TASK**; later ones => text.
- `type=="assistant"`: each content item: `text` (trimmed, non-empty) => text entry; `tool_use` => tool entry with `id` (or random UUID) and title = `Transcript.summary(name, input)`.
- Tool result attaches to the tool row by id: result = first line of trimmed text (or `"Done"`), truncated to 140 chars + `"…"`; error flag from `is_error`.
- Rendering: TASK card (title `TASK`, truncated to 1500 chars + `…`), text (3000 chars + `…`), tool row: dot red (error) / blue (no result yet, shown "⎿  Running…") / green; title max 3 lines; result `"⎿  <first line>"` max 2 lines (607-638). Auto-scroll to bottom on new entries.
- `Transcript.summary(name, input)` (254-268): `detail` = `input.command` if string; else basename of `input.file_path` or `input.notebook_path`; else `"\"<pattern>\""` for `input.pattern`; else the first present string of `url, query, description, prompt, path`. Newlines => spaces; if > 90 chars => first 90 + `"…"`. Result `"<Name> <detail>"` or just `<Name>`. Examples `Grep "useTheme"`, `Read src/app.tsx`, `Bash npm test`.
- Note: the **main** Claude session transcript is never read for status; only subagent transcripts and (for Recent/exists checks) the top-level `<session>.jsonl`.

### 4.4 Codex status

Push-based over the app-server protocol (section 5.5). `CodexStatus.decode` (CodexManager.swift:28-40): thread status object `{"type": ...}`:
- `"idle"` => idle
- `"active"` with `activeFlags` array: contains `"waitingOnApproval"` => blocked, kind `"approval"`, detail "Answer the approval request in Codex"; contains `"waitingOnUserInput"` => blocked, kind `"question"`, detail "Answer the question in Codex"; else working. (Test: waitingOnUserInput => blocked/`question`, not a tool approval: CodexProtocolTests:61-65.)
- `"systemError"` => error "Codex reported an error"
- `"notLoaded"` => idle with detail "Conversation unloaded"
- anything else => nil (ignored)

Effective status per tab (`publish`, 274-283): `status[root]`, but if any pending approval exists for the root or a child agent then `{state: blocked, kind: "permission", detail: approval.detail}`; delivered to `Store` via `onStatus` which calls `applyStatus` and sets `busy = (working || blocked)`, `agentConnected=false` if connection dropped (Store.swift:88-95). `startCodex` itself sets `working "Connecting to Codex…"` while preparing, and `error <localizedDescription>` on failure (246, 262).

---

## 5. Codex integration (app-server)

### 5.1 Requirements and process model

- Needs Codex CLI >= 0.165.0 (README; error text CodexConnection.swift:9). One **app-server per terminal tab** plus one shared "catalog" server for recent list/usage (`CodexManager.catalog`, CodexManager.swift:49). Servers are private to omux, loopback only, token-authenticated. Closing a tab only stops its own server.
- Each TUI and the omux protocol client connect to the same per-tab server; the TUI is started by typing a `codex resume --remote ...` line into the tab's shell (5.3).

### 5.2 Server launch (`CodexConnection.open`, CodexConnection.swift:62-132)

1. `waitForShutdown()`: if a previous child of this connection is still exiting, wait up to 100x100 ms, else error `"The previous Codex server is still stopping. Try restarting the session again."`.
2. Port: bind a TCP socket to `127.0.0.1:0`, read the assigned port, close it (race-prone but used as is; 200-218). `endpoint = "ws://127.0.0.1:<port>"`.
3. Token: `UUID().uuidString + UUID().uuidString` (two uppercase hyphenated UUID strings concatenated, 73 chars) generated when the `CodexConnection` object is created (35). Kept in memory. Linux may use any >= 32 random bytes of printable chars; it is only ever passed in env/header.
4. Digest: lowercase hex SHA-256 of the token's UTF-8 bytes (67).
5. Child process: executable `$SHELL ?? /bin/zsh`, argv `["-lc", "exec codex app-server --listen <endpoint> --ws-auth capability-token --ws-token-sha256 <digest> -c 'analytics.enabled=false'"]` (69-70). Env = (injected test env or full inherited env) with `PATH = "/opt/homebrew/bin:/usr/local/bin:" + PATH` (71-72). cwd = `$HOME`. stdin/stdout/stderr = /dev/null. Termination handler closes the connection with `notify:true` (78-83). Failure to spawn => `CodexError.unavailable`.
6. Readiness: `GET http://127.0.0.1:<port>/readyz` up to 80 times (timeout 0.3 s, no cache, 100 ms between). Success = HTTP 200. If the child exits meanwhile or after 80 tries => `unavailable` ("Couldn't connect to Codex. Install Codex CLI 0.165.0 or later and check that codex is on your login shell's PATH.").
7. WebSocket: connect to `endpoint` with header `Authorization: Bearer <token>`. Start a reader loop; each message (text or binary) is UTF-8 JSON.
8. Handshake: request `initialize` `params: {"clientInfo": {"name":"omux","title":"omux","version": <app version or "0">}}`, then **notification** `{"method":"initialized"}` (no params, no id). `isReady = true`.

`close(notify:)` (178-189): cancel reader, close socket with `goingAway`, SIGTERM the child (kept in `retiring` until it exits), fail all pending requests with `disconnected` ("The Codex connection closed. Restart this session to reconnect to its saved conversation."), call `onDisconnect` if `notify`. `disconnect` => `onStatus(tab, error, detail=disconnected text)` (CodexManager.swift:77-82).

### 5.3 Starting a Codex session (`CodexManager.prepare`, 85-115; `Store.startCodex`, 244-265)

Sequence, per tab: wait for the tab's `retiring` previous server task -> `connection.connect()` -> then:
- If the tab has a saved id: request `thread/resume` `{"threadId": <id>, "excludeTurns": true}`.
- Else: request `thread/start` `{"cwd": <session dir>}`.
- Response must contain `thread.id` (string) and the connection must have an endpoint; else error `"Codex didn't return a conversation ID"`.
- For a **new** thread: request `thread/name/set` `{"threadId": <id>, "name": <tab.name>}` ("Naming materializes a new conversation before a second client (the TUI) resumes it, including conversations with no user turn yet", 102-106).
- Register the thread; if `thread.status` decodes, publish it; kick off `refreshUsage()`.
- Return the shell command to type:
  `codex resume --remote '<endpoint>' --remote-auth-token-env OMUX_CODEX_TOKEN --no-alt-screen '<threadId>'` (113; values single-quoted via `Git.quote` = `'` + replace `'` with `'\''` + `'`). The token reaches the TUI only through the `OMUX_CODEX_TOKEN` env var set when the shell was launched.
- `Store.startCodex` types `"<setup> && <that command>\n"` when a worktree setup command is pending, else the command + `"\n"` (258-259). Then `agentConnected=true`, `busy=false`.
- Note a Codex thread is created (and named) *before* the worktree setup command runs.
- A live Codex terminal that is idle (no child process) can be started again with ▶ => `startCodex` again with the saved thread.

### 5.4 JSON-RPC framing

- Client requests: `{"id": <Int starting at 1, +1 per request>, "method": "...", "params": {...}}` (146). **No `"jsonrpc"` field.** Notification: `{"method":"initialized"}`.
- Responses: object **without** `"method"` and with integer `"id"`; `{"error": {"message": "..."}}` => `CodexError.server(message ?? "Codex request failed")`; else `result` (or `{}`) (162-171).
- Anything with a `"method"` goes to `onMessage`: server notifications (no `id`) and **server-to-client requests** (have `id` and `method`; e.g. approvals). Replies to server requests: `{"id": <same id (Int or String preserved)>, "result": {...}}` (152-154). Request ids may be integers or strings (`CodexRequestID`, 17-29).
- Each request has a 20 s deadline => `CodexError.timeout` ("Codex didn't respond in time. Try restarting this session.").
- Messages are matched to an owner tab (the connection that received them). Notifications whose `params.threadId` belongs to neither the tab's root thread nor one of its subagents are dropped (CodexManager.swift:297).

### 5.5 Methods and notifications used (complete)

**Client -> server requests**

| Method | Params | Response fields used | Where |
|---|---|---|---|
| `initialize` | `{clientInfo:{name:"omux",title:"omux",version}}` | none | CodexConnection.swift:125 |
| `thread/start` | `{cwd}` | `thread.id`, `thread.status` | CodexManager.swift:98 |
| `thread/resume` | `{threadId, excludeTurns: true}` for roots; `{threadId, excludeTurns: false}` for subagents (to read `turns`) | `thread.id`, `thread.status`, `thread.turns[]` (`id`, `status == "inProgress"`) | 96, 329, 402 |
| `thread/name/set` | `{threadId, name}`; name = tab name, or `"Codex conversation"` for a TUI-created thread without a `name` | none | 105, 327 |
| `thread/read` | `{threadId}` (integration test only) | `thread.id` | CodexConnectionTests:52 |
| `thread/list` | `{limit: min(100, remaining), sortKey: "updated_at", cursor?}` | `data[]` of `{id, cwd, name?, preview?, updatedAt (number, seconds)}`, `nextCursor` | 207-222 |
| `thread/items/list` | `{threadId, limit: 100, sortDirection: "desc"}` | `data[].item` | 190 |
| `turn/interrupt` | `{threadId, turnId}` | ack only; completion is signaled by `turn/completed` | 141 |
| `account/read` | `{refreshToken: true}` | `account` must be an object, else "Codex isn't signed in: run codex login" | 241 |
| `account/rateLimits/read` | `{excludeResetCreditDetails: true}` | `rateLimits` bucket (below) | 246 |

**Client -> server responses to server requests:** approvals => `{"id":<request id>,"result":{"decision":"accept"}}` for Allow or `{"decision":"decline"}` for Deny (CodexManager.swift:129; smoke script `accept`/`decline`).

**Server -> client requests (approvals)** `CodexApproval(message:)` (4-21): only methods `item/commandExecution/requestApproval` and `item/fileChange/requestApproval`, with `id` (Int or String), `params.threadId`, `params.turnId` required; `detail = params.command ?? params.reason ?? "Approve file changes in Codex"`. Others, e.g. `item/permissions/requestApproval`, are NOT handled and stay in the TUI (CodexProtocolTests:67-70).

**Server -> client notifications handled** (`receive`, 293-367):

| Method | Params used | Effect |
|---|---|---|
| `thread/started` | `thread.{id, parentThreadId?, source?, name?, agentNickname?, agentRole?}` | If `parentThreadId` is the tab's root or one of its agents => new subagent named `agentNickname ?? agentRole`. Else if it is a root (no parent, `source.subAgent` absent) and differs from the current root => TUI started a new conversation: clear activity, replace root id, `onThreadChange` (saved), then (async) set name `"Codex conversation"` if unnamed and `thread/resume {excludeTurns:true}` (to subscribe). |
| `item/started`, `item/completed` | `item.type == "collabAgentToolCall"`, `item.receiverThreadIds[]`, `item.prompt`, `item.agentsStates[id].status` | Create/update subagents (name = prompt prefix 160, state string from `agentsStates`) |
| `thread/status/changed` | `threadId`, `status` (decode as 4.4) | Ignore idle if the last status was done/error; else publish; for a subagent: state `running` (working) / `errored` (error) |
| `turn/started` | `threadId`, `turn.id` | record turn, clear that thread's approvals, publish working |
| `turn/completed` | `threadId`, `turn.{id,status,error.message}` | Only if `turn.id` equals the recorded turn: clear turn+approvals, remember as completed, publish `done` (or `error` with message if `status == "failed"`); subagent state `completed`/`errored`. Turn status `"interrupted"` is treated as done. |
| `serverRequest/resolved` | `requestId`, `threadId?` | Remove that approval (either client may resolve), publish idle/working |
| `account/rateLimits/updated` | `rateLimits` (sparse) | merge into quota |

**Approval acceptance rule** (298-306; tests CodexProtocolTests:72-93, 130-144, 171-191): an incoming approval is recorded only if its `turnId` is not the thread's last completed turn AND (the thread's current turn equals `turnId` OR (no current turn AND the thread's status is working/blocked)). Approvals are keyed per thread; identical request ids from two different servers/tabs are independent (103-114 tests). A new `turn/started` discards prior approvals and a late `turn/completed` for the old turn id is ignored. Child-thread approvals surface under the parent tab (`approval(for:)` = first approval of the root, else first of any agent, 120-123). After answering, the approval is removed locally and status republished (idle if no turn, else working) without waiting for `serverRequest/resolved` (133).

**Subagent sync** (`synchronizeAgent`, 371-384): after `thread/resume {excludeTurns:false}` on a child: if history has a `turns` entry with `status=="inProgress"`, adopt its id unless it was already completed or a live turn exists; else do nothing if live data exists; then publish decoded `thread.status`. Retries 5 times with `100*(attempt+1)` ms sleep (399-410). Agent finished states: `completed, errored, shutdown, interrupted, notFound` (423). Names truncated to 160; default name "Codex agent".

**Interrupt** (`interrupt`, 136-149): for each thread in `agents + root` with a known turn: `turn/interrupt`, then wait up to 10 s for that turn to clear, else timeout error. `detach` = interrupt, then close and wait for server exit (used before deleting a worktree).

**Transcript preview** (`transcript`, 187-205): items reversed to chronological; `agentMessage` => `text`; `userMessage` => join of `content[].text` with `\n`; `commandExecution` => `` ```sh\n<command or "Command">\n```\n `` + first 6000 chars of `aggregatedOutput`; `fileChange` => `"File changes · <status>"`; others skipped; blocks joined with blank line. Displayed as markdown with header `"Recent activity · up to 100 items"` and placeholder `"Waiting for the agent's transcript…"`.

**Recent conversations** (`recent(limit: 300)`): paginate with cursor (stop when no `nextCursor`, same cursor, empty page, or 300 reached). `CodexConversation` requires `id` and `cwd`; name = `name` or `preview` (non-empty) or `"Codex conversation"`; date from `updatedAt` seconds (CodexManager.swift:431-444).

**Usage limits** (`refreshUsage`, `applyLimits`, 224-272): uses any ready tab connection, else connects the catalog server. Flow: `account/read` -> `account/rateLimits/read`. `result.rateLimits.planType` (ignore `"unknown"`) -> plan, shown `"Codex <Plan with _ -> space, capitalized>"` (UsageView.swift:161-164). For keys `primary`,`secondary`: merge the sparse update field-by-field into the stored bucket (test: `{primary:{usedPercent:10,windowDurationMins:300},secondary:{usedPercent:30,windowDurationMins:10080}}` then `{primary:{usedPercent:15}}` => percents `[15,30]`, labels `["5h","7d"]`, CodexProtocolTests:116-128). A limit needs integer `usedPercent`; `windowDurationMins` default 0; label = `>=1440 ? "<min/1440>d" : >=60 ? "<min/60>h" : "<min>m"` (integer division); `resetsAt` = epoch seconds. Errors: `"Codex isn't signed in: run codex login"`, `"Codex usage unavailable"`, `"Codex usage unavailable for this account"` (when no limits).

**Integration test shape** (CodexConnectionTests): with `CODEX_HOME=<tmp>` and a config.toml (`model_provider="omux_test"`, `[model_providers.omux_test] base_url="http://127.0.0.1:1/v1" wire_api="responses" requires_openai_auth=false supports_websockets=false`), start server, `thread/start`+`thread/name/set` twice, close and reconnect, `thread/resume` both ids returns the same ids, and a second independent server keeps working after the first closes. Useful as a Rust integration test template (`scripts/codex-protocol-smoke.mjs` also exercises `accept`/`decline`/`turn/interrupt` against a fake `/v1/responses` model).

---

## 6. Usage limits (Claude)

`UsageMonitor` (UsageMonitor.swift).

1. **Credential read (Mac):** runs `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` and parses stdout as JSON `{ "claudeAiOauth": { "accessToken": "<token>", ... } }` (124-142). Exit 44 or stderr containing "could not be found" => "not found". Other non-zero => denied with stderr. JSON present but no `claudeAiOauth.accessToken` => API-key login => no plan. Only `accessToken` is used; refreshToken/expiry are not read and no refresh is attempted.
   **Linux mapping:** read `~/.claude/.credentials.json` (honor `$CLAUDE_CONFIG_DIR/.credentials.json` if set), which holds the same JSON shape (`claudeAiOauth.accessToken`, also `refreshToken`, `expiresAt`, `scopes`, `subscriptionType` expected; verify on a real machine). Missing file => "No Claude login"; present without `claudeAiOauth` => "Needs a Claude.ai plan". Optional improvement: if `expiresAt` is past, tell the user to run `claude` rather than call the API.
2. **Request:** `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, timeout 15 s (88-91). Token is never persisted or logged. Undocumented endpoint.
3. **Status mapping:** 200 => parse. 401 or 403 => short "Claude login expired", long "Claude Code's login no longer works. Run claude to sign in again, then click to check again." Other => "Usage unavailable" + "Anthropic's usage endpoint answered <code>. Click to try again." Transport error => "Usage unavailable" + "Couldn't reach Anthropic's usage endpoint: <err>. Click to try again."
   Other messages: "No Claude login" / "No Claude Code login found. Run claude, then /login with a Claude.ai plan. Click to check again."; "Needs a Claude.ai plan" / "Claude Code is signed in with an API key. Usage limits exist only for Claude.ai plans (/login in claude). Click to check again."; (Mac only) "Keychain access denied".
4. **Response:** `{"limits":[{"kind":String,"percent":Int,"resets_at":String?,"scope":{"model":{"display_name":String?}}?}]}`. `percent` must decode as Int. `resets_at` ISO-8601 with fractional seconds (`withInternetDateTime, withFractionalSeconds`; use a parser that also accepts no-fraction as a precaution). Label: `kind=="session"` => `"5h"`; `"weekly_all"` => `"Week"`; otherwise `scope.model.display_name ?? kind`. Id = `kind + (display_name ?? "")`.
5. **Refresh:** every `usageInterval` (default 300 s; options 60/300/1800/3600), immediately on appear, and on click of the error/placeholder text. Re-armed when the setting changes (UsageView.swift:201).
6. **Display** (UsageView.swift:159-197): one compact line `"5h 1%  Week 32%  Fable 35%"`, each limit with a 3 pt capsule bar (fill width = `min(percent,100)%`). Tint: `>=90` red, `>=70` orange, else accent (UsageMonitor.swift:14-16). On hover or tooltip the text becomes reset text `"<label> resets in <when>"` where seconds >= 86400 => `"<d>d <h%24>h"`, >=1h => `"<h>h <m>m"`, else `"<m>m"` (18-24). Empty limits => shows the error short text (button, tooltip = detail) or `"Claude usage…"` / `"Codex usage…"`. When the selected session is Codex the strip shows Codex limits and the plan label; every other provider shows Claude limits.

---

## 7. Git, worktrees, pull requests

### 7.1 Process wrappers (Git.swift)

- `Git.run(args, in: dir)`: executable `/usr/bin/git` (Linux: `git` from PATH), cwd `dir`, env = inherited + `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, stdin /dev/null, reads stdout then stderr to EOF, then waits (lines 324-359 of the combined listing; file lines 17-52). `Result{status,out,err}`; `message` = `err` if non-empty else `out`, trimmed. A launch failure gives status -1.
- `Git.login(cmd, in: dir)`: `$SHELL -lc <cmd>` with `GIT_TERMINAL_PROMPT=0` (so push uses the user's PATH/credential helpers).
- `Git.ghPath`: computed once via `login("command -v gh", in: $HOME)`, valid only if output starts with `/`. `Git.gh(args, in:)` returns nil if gh is absent, else runs it with env `GH_PROMPT_DISABLED=1`, `GIT_TERMINAL_PROMPT=0`.
- `Git.quote(s)` = single-quote shell quoting.
- `Tools.path(of:)` (Welcome.swift:7-14): `login("command -v <cmd>")` for `claude`/`codex`.

### 7.2 Exact git commands

| Purpose | Command (cwd) | Source |
|---|---|---|
| repo root | `git rev-parse --show-toplevel` (dir) | Git.swift:71 |
| current branch | `git symbolic-ref --quiet --short HEAD` | :76 |
| local branches | `git for-each-ref --format=%(refname:short) refs/heads` | :81 |
| dirty check | `git status --porcelain` (non-empty output) | :86 |
| create worktree, branch exists | `git worktree add <path> <branch>` (repo) | :113 |
| create worktree, new branch | `git worktree add -b <branch> <path> <base>` (repo) | :115 |
| remove worktree | `git worktree remove --force <path>` then `git branch -D <branch>` (cwd = `worktree.repo`) | :117-121 |
| commit all | `git add -A` then `git commit -m <message>` (worktree dir) | :123-127 |
| merge | check `symbolic-ref` of repo == base else error `Couldn't read the branch checked out in <repo>.` / `<repo> has “<current>” checked out. Check out “<base>” there first.`; then `git merge --no-edit <branch>` (repo) | :130-138 |
| push | `$SHELL -lc "git push -u origin '<branch>'"` (worktree dir) | :143 |
| remote URL | `git remote get-url origin` | :145 |
| ahead count (close dialog) | `git rev-list --count <base>..<branch>` (repo) | Worktrees.swift:46 |
| uncommitted count | `git status --porcelain` line count | Worktrees.swift:45, 82, 158 |
| diff base | worktree: `git merge-base HEAD <base>` (if ok); else `git rev-parse --verify --quiet HEAD` => `"HEAD"` or none | Git.swift:166-172 |
| changed files | `git diff --numstat -z --no-renames <base>` ; `git diff --name-status -z --no-renames <base>` ; `git ls-files --others --exclude-standard -z` | :175-194 |
| file diff | `git diff --no-color --no-ext-diff --no-renames <base> -- <path>` | :223 |

Worktree path: `<dirname(repo)>/<basename(repo)>.worktrees/<branch with "/" replaced by "-">` (Git.swift:99-105 equiv.); parent dir is created first. Branch slug from the session name (`Git.slug`, :90-95): lowercase; split on any char not in `[alphanumerics - _ / .]`; drop empties; join `-`; take first 48 chars; trim leading/trailing `-./`. e.g. "Fix the login bug" => `fix-the-login-bug`. The sheet enables Create only if the folder is a repo, name non-empty (trimmed), branch non-empty and has no space, base non-empty (Worktrees.swift:213-216). The branch field auto-follows the slug until the user edits it. `base` picker lists local branches, default current branch else first.

Worktree `repo` stored = `git rev-parse --show-toplevel` of the project folder (Worktrees.swift:20-28).

### 7.3 Worktree session creation and setup command

`Store.createWorktreeSession` (Worktrees.swift:14-36): off-main: `topLevel(dir)` (error `"<dir> isn't a Git repository."`; or `"This project has no folder."`), `addWorktree`, then main: `TabItem(name, directory: path, worktree: Worktree(branch, base, repo))`, `tab.provider = chosen provider (nil = project default)`, `tab.command = provider?.command` (so "claude"/"codex", nil inherits), then `addSession(tab, to:, setup: group.worktreeSetup)`.

**Setup execution** (`addSession`, Store.swift:619-634): trim setup; if non-empty:
- non-Codex: `command = "<setup> && <startupCommand>"` (startupCommand may be absent for shells => the `compactMap` leaves only setup), typed into the interactive login shell 0.3 s after start (so it runs in the worktree dir with env `OMUX_REPO=<main checkout>` plus the normal clean env). The agent only starts if setup exits 0.
- Codex: stored in `codexSetup[tab]` and typed as `"<setup> && codex resume ..."` once the app-server is ready.
- Setup text is saved on the project (`worktreeSetup`), edited in the worktree sheet or Edit Project; placeholder `cp "$OMUX_REPO/.env" . && npm install`. Hint text: "Runs in each new worktree before the session starts, and only starts it if setup succeeds. $OMUX_REPO is the main checkout, for copying files Git ignores. Saved with the project." (Worktrees.swift:318-319). `OMUX_REPO` is set for every worktree session's shell, not only at creation.
- `newTab` on a project with `useWorktrees == true` (and command != "" i.e. not New Shell) opens the worktree sheet instead of creating a plain tab, remembering the requested provider (Store.swift:600-609).

### 7.4 Close / merge / PR / cleanup flows (dialogs)

- **Close Session** on a worktree session whose folder still exists (`requestClose`, Worktrees.swift:39-75): collects `dirty` and `ahead`; if PR is merged: text `"Its pull request #N was merged."` + dirty note; else `"Its worktree on “<branch>” has nothing that isn't already in <base>."` or `"... has <facts joined by ' and '>."` where facts are `"N uncommitted file(s)"`, `"N commit(s) not in <base>"`. Title `Close “<name>”?`. Buttons: `Keep Worktree` (close tab), `Delete Worktree and Branch` (destructive), `Cancel`. Non-worktree sessions close immediately.
- **Delete** = for Codex tabs `detach` first (interrupt, close server, wait), then `closeTab`, then off-main `removeWorktree`; failures: alerts `Couldn't stop the Codex session` / `Couldn't delete the worktree` (96-115).
- **Clean up merged** (`cleanUpMergedWorktree`, 79-94): title `Delete the worktree for “<name>”?`, text `"“<branch>” was merged in #N. This closes the session and deletes its worktree and local branch."` + `" N uncommitted file(s) will be lost."`; buttons Delete Worktree and Branch / Cancel.
- **Create Pull Request** (118-135): `commitIfNeeded` (157-175): if dirty > 0 show dialog `Commit N changed file(s) first?` / `They'll be committed to “<branch>”. Uncommitted changes aren't part of a merge or pull request.` with a text field (default = session name, placeholder "Commit message", empty falls back to the session name), buttons Commit/Cancel; commit via `add -A`/`commit -m`. Then status `Pushing <branch>…` (`gitActivity`, shown in Changes footer), push through the login shell; on success open `https://github.com/<slug>/compare/<base>...<branch>?expand=1` (percent-encode each segment with URL-path-allowed minus `?` and `#`; works only for remotes starting `git@github.com:`, `ssh://git@github.com/`, `https://github.com/`, `http://github.com/`, trailing `.git` removed, Git.swift:149-160 equiv.); non-GitHub remote => info dialog `Pushed “<branch>”` / `The remote isn't on GitHub, so open the pull request on your host.` Errors: `Couldn't push “<branch>”`. Note the app does **not** call `gh pr create`.
- **Merge** (138-153): `commitIfNeeded`, status `Merging into <base>…`, `Git.merge`; success dialog `Merged “<branch>” into “<base>”` + git output; failure `Couldn't merge “<branch>”`.

### 7.5 Pull request polling (PullRequests.swift)

- Eligible sessions: tabs with a `worktree` whose directory exists. Poll when any exist or PRs are known. One in-flight poll; sessions queried **sequentially** on queue `omux.pulls`.
- Command per session (cwd = session dir): `gh pr view --json number,title,url,state,isDraft,reviewDecision,statusCheckRollup` (no branch argument so gh follows the upstream, supports fork PRs). Cadence: 60 s, on app activation, once shortly after start.
- Result handling: gh missing => none (feature invisible). Non-zero exit: stderr containing `"no pull requests found"` => `none` (PR removed from state); any other failure => `unknown` (keep previous value). Decode failure or non-http(s) `url` or unknown `state` => `unknown`.
- JSON: `number:Int, title, url, state: OPEN|CLOSED|MERGED, isDraft:Bool, reviewDecision: APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|null|""`, `statusCheckRollup[]` items either CheckRun `{name, status, conclusion, detailsUrl}` or StatusContext `{context, state, targetUrl}`.
- Check result mapping (`Raw.Check.result`, :166-181 file lines 543-557 shown above): if `state` present: `SUCCESS` => passed, `PENDING`/`EXPECTED` => pending, else failed. Else if `status != "COMPLETED"` => pending. Else conclusion `SUCCESS` => passed; `SKIPPED`/`NEUTRAL`/`STALE` => skipped; anything else => failed. Check name = `name ?? context ?? "Check"`; link = `detailsUrl ?? targetUrl` (http/https only).
- `checksResult`: any failed wins, then pending, then passed, else nil (none).
- `summary` (priority): Merged / Closed / (open:) `Checks failing` / `Changes requested` / `Checks running` / `Draft` / `Approved` / `Checks passed` / `Open`. Color: merged purple, closed secondary, failing red, changes requested orange, running blue, draft secondary, else green.
- **Attention triggers** (`needsAttention(since:)`): checks became failed (new failure), `reviewDecision` changed to CHANGES_REQUESTED or APPROVED, or state became MERGED => `Store.requestAttention(id)` (sets `needsAttention` if not watched). No notification is posted for PR changes; only the bell/badge.
- UI: sidebar badge `● #N` (colored dot + number, tooltip `#N · <summary>`); header chip `⇡ #N ● <summary>` opening a 320 pt popover: title (2 lines), facts `"#N · Draft|Open|Merged|Closed · Approved|Changes requested|Review required"`, up to 260 pt of checks (dot, name, `passed|failed|running|skipped`; click opens link), `Open on GitHub`, and for merged `Delete Worktree and Branch…`. Sidebar also shows a `Delete Worktree` button for merged PRs; context menu `Open Pull Request #N` (open) / `Delete Merged Worktree…` (merged) / `Create Pull Request…`.

### 7.6 Other repo facts

Worktree sessions: the header shows `BranchChip` (branch icon, branch, `+N −M` from Changes totals, opens Changes tab, tooltip `Changes on <branch> since <base> (⌥⌘2)`). Sidebar second line: `⎇ branch · <status> · <N agents>` + PR badge.

---

## 8. Right panel

Tabs (`RightPanel.swift`): Files (⌥⌘1), Changes (⌥⌘2, badge = changed file count for the current tab), Browser (⌥⌘3); height 28 pt, 1 px hairline below; selected tab persisted in `panelTab`. The Files panel stays mounted (hidden with opacity) so its preview/scroll persist; Changes and Browser are created on demand; the browser WKWebView lives per session in `Store.browsers`.

Root folder shown: `tab.directory ?? group.directory ?? $HOME` with `~` expanded (OmuxApp.swift:179-184).

### 8.1 Files

**Tree** (`FileNode`, FilePanel.swift:10-50): lazily loaded children; hidden files skipped (`skipsHiddenFiles`); names skipped entirely: `node_modules, .git, .build, DerivedData, __pycache__, .venv, venv`; directories first; then by name (`localizedStandardCompare`, natural sort) or by modification date descending when `filesByDate`; **max 500 entries per directory**. Whole tree invalidated on FS change (1 s coalesced; recursive FSEvents on the root) and on sort change. Linux: `notify` crate recursive watch with 1 s debounce (inotify watch count limits for huge trees: watch lazily/only expanded dirs is acceptable).

**Layout:** vertical split: top = preview (min 200), bottom = tree (min 80, ideal 180, collapsed 28). Bottom header: collapse chevron, root folder name, `Name | Date` segmented control, open-folder button. List has an optional section **"Mentioned in session"** (newest first) followed by a section named after the root. Row context menu: `Open`, `Reveal in Finder`, `Copy Path`. Selecting a file previews it (directories do nothing; selecting also closes any open subagent transcript). Dropping a file URL onto the panel previews it.

**Mentioned paths:** scan `scrollbackText()` (normal buffer incl. scrollback; terminal scrollback = 5000 lines, TermView.swift:67) with regex
`(?<![\w])(?:~|/)[\w.+@%~/-]+` (TermView.swift:213), then each match goes through `filePath(from:)` (106-116): trim spaces; `file://` URLs converted to path; must start with `/` or `~`; strip trailing characters in `.,:;)]}'"` repeatedly; expand `~`; keep only if it **exists and is a regular file**. De-duplicate; a re-mention moves the path to the end. Output oldest-first; the UI reverses. Scan cadence in section 1.3. (Rust note: lookbehind requires `fancy-regex`/PCRE2 or a manual preceding-char check on `[A-Za-z0-9_]`; `\w` in Swift is Unicode-aware.)

**Open from terminal (Cmd-click):** `requestOpenLink` (TermView.swift:98-104): if `filePath(from: link)` resolves => preview request (the right panel is opened on Files and the file shown); else the link goes to the system opener. Linux: VTE `match_add_regex` + Ctrl+click.

**Preview types** (FilePanel.swift:250-372), by lowercase extension:
- Markdown `md`, `markdown` => rendered (no size limit), `wrapCode` follows the wrap setting.
- images `png jpg jpeg heic bmp tiff tif webp svg` => scaled-to-fit image with 12 pt padding.
- media `mp4 mov m4v mp3 m4a wav aac aiff` => inline AV player.
- `pdf` => PDF view (autoscale).
- text: extensions `txt json swift py js ts tsx jsx html css yaml yml toml sh zsh log csv xml rs go c h cpp java kt rb sql env gitignore lock`, or any file whose name starts with `.`; shown only if size < 1,000,000 bytes and UTF-8; monospaced 11 pt, selectable, wrap toggle.
- everything else (and oversized/non-UTF-8 text) => Quick Look.
- Header: file name (middle-truncated), size (`ByteCountFormatter` file style), wrap toggle (text/markdown only, tooltip `Wrap lines`/`Don't wrap lines`), `Open with default app`, `Reveal in Finder`.
- Placeholder: `Select a file to preview`.
- Linux equivalents: gtk4 `Picture`/`gdk::Texture`, `gtk::Video`/`MediaFile`, poppler or WebKit pdf rendering, WebKit for svg/html, `GtkSourceView` optional for code, `pulldown-cmark` for markdown (see 8.4), fallback "Open with default app" via `gio::AppInfo::launch_default_for_uri`.

**Markdown rendering** (FilePanel.swift:378-453): block-level: headings with sizes by level `[22,18,15,13,12,12]` bold (top padding 6 for levels 1-2, else 2); code blocks monospaced 11 pt in a rounded box (primary @6% fill), horizontal scroll unless wrap; list items with bullet `•` or `N.`, indent 16 pt per level; block quotes with 3 pt left bar and secondary text; thematic break = divider; inline bold/italic/code/links; 16 pt padding; text selectable.

### 8.2 Changes

- Tracks the selected tab (`Changes.track`, Changes.swift:39-59): reset on tab/dir/worktree change. If the dir is in a git repo (`rev-parse --show-toplevel` ok) => `isRepo`, start a watcher on `dir` (1 s coalesced), refresh. Folders outside a repo are not watched. Refresh is serialized (`refreshing`/`again` flags). The base name shown: worktree base branch or `HEAD`.
- File list (`Git.changedFiles`, Git.swift:175-201): tracked changes from `diff --numstat -z` (+ `--name-status -z` for A/D/M, status letter prefix `A`=added, `D`=deleted, else modified; renames disabled) when a base commit exists, plus untracked files (`ls-files --others --exclude-standard -z`, first **300**), line count via `textLines` (file < 1,000,000 bytes, no NUL in first 8000 bytes, valid UTF-8; else binary => `added=nil`). Binary numstat `-\t-` yields nil counts => "binary". Sort by path natural order. A brand-new repo with no commit lists only untracked.
- Diff (`Git.diff`/`parseDiff`, 215-257 shown): untracked or no base => synthetic `New file` hunk plus up to 3000 lines marked added; unreadable => single info line `Binary or large file`. Else parse unified diff output (first **6000** lines), hunk header regex `^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$`, lines before the first hunk skipped, `Binary files...` => info `Binary file changed`, `+`/`-`/` ` prefixed lines classified added/removed/context with old/new numbering; `\ No newline` lines are ignored implicitly (no recognized prefix).
- UI: vertical split: diff on top (min 160), file list + footer below (min 170, ideal 220). Row: line number (36 pt right-aligned, `newNumber ?? oldNumber`), sign (`+` green, `−` red, 12 pt), text monospaced 11 pt; backgrounds: added green@13%, removed red@13%, hunk blue@8%; wrap per setting. File list row: status letter (M orange, A green, D red, U green), name, folder (head-truncated), note icon if notes, `+N −M` or `binary`. List header `N changed file(s)  vs <base>` with Refresh and Open folder; context menu `Open`, `Reveal in Finder`. Placeholders `Not a Git repository` / `Changes show up for sessions inside a Git repository.`; `No changes` / `Nothing differs from <base> yet.`
- **Review notes:** click a diff line (not hunk/info) to open an inline field `Review note` (Return = save, Esc = cancel, buttons Add/Cancel); empty text removes the note; one note per (file path, diff row index); notes held in memory per session (not persisted); bubble shows note with remove (x). Footer shows `N note(s)` + button `Send to Claude` (or `Send to Codex` when the selected provider is Codex) or hint `Click a line to leave a note`.
- **Message format sent (exact)** (`sendNotes`, Changes.swift:106-113):
  ```
  Review notes on your changes:
  - <path>:<lineNumber>: <text>
  - <path>: <text>            (when the row has no line number)
  ```
  i.e. `"Review notes on your changes:\n" + lines.joined("\n")`, each line `"- " + path + (":" + n if n) + ": " + text`. `lineNumber` = new-file number for added/context lines, old-file number for removed. Sent with `Store.sendText(text, submit: true)`: pasted into the PTY (bracketed paste `ESC[200~ ... ESC[201~` if the terminal enabled DEC mode 2004, else raw; TermView.swift:164-170) and **0.15 s later `\r`** to submit. Notes are cleared afterwards. Only works if the tab is not exited.
- Footer for worktree sessions: split button `Create PR` (primary action = create PR; menu item `Merge into <base>`), replaced by spinner + activity text during push/merge.

### 8.3 Browser

- Per-session web view (persistent default data store; inspectable). Toolbar (34 pt): Back, Forward, Reload/Stop, address field (placeholder `localhost:3000`), element picker (scope icon, disabled until a page is loaded), Open in default browser.
- `load(text)`: trim; if no `://` prepend `http://`; invalid => error `That isn't a valid address.`
- **Auto-open of local servers:** `TermView.mentionedLocalURLs` regex
  `https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s'"<>)\]]*)?` (TermView.swift:199), trailing `.,:;` trimmed, de-duplicated with last-mention-last. First time the panel is shown for a session with no page and empty address it loads the **last** mentioned URL; empty state lists up to the last 5 URLs (newest first) as links; otherwise the hint "Type an address above. Local servers this session prints, like localhost:3000, open here by themselves."
- Errors: `Couldn't load the page` + message + `Try Again`. Picking banner: `Click an element to add it to the session prompt. Esc cancels.` Notice bar after a pick: `Added <selector> to the prompt`.
- **Picker flow:** inject the script in Appendix A; on click it posts `{selector, html (outerHTML sliced to 30000 chars), css, url, x, y, width, height}` via `window.webkit.messageHandlers.omuxPick.postMessage` (Esc posts `{cancel:true}`). WebKitGTK exposes the same `window.webkit.messageHandlers.<name>` API via `webkit_user_content_manager_register_script_message_handler("omuxPick")`.
- **Output files** (`Browser.received`, :90-126): folder `<temp>/omux-picks/<unix-millis>/` (`NSTemporaryDirectory`; Linux: `$XDG_RUNTIME_DIR` or `std::env::temp_dir()`). `element.html` contents exactly:
  ```
  <!-- Picked in omux from <page url> -->
  <!-- Selector: <selector> -->
  <!-- Computed styles:
  <css>
  -->
  <outerHTML>
  ```
  (each of the first lines newline-terminated, final newline after the HTML). Screenshot: `element.png` of the element rect intersected with the view bounds (skipped if width or height < 1; failure => no screenshot).
- **Text pasted into the prompt (not submitted):** `"The <selector> element on <page>: HTML and computed styles in <path>/element.html"` + (`", screenshot at <path>/element.png"` if any) + `". "` (trailing space), via `sendText(..., submit:false)` (bracketed paste when enabled).
- Navigation start clears the error and cancels picking. The picker `stop()` removes listeners and overlay nodes.

---

## 9. Notifications

**Triggers** (all require the session NOT being watched, i.e. not (selected AND app active AND key window), Store.swift:576-578):
1. **Status change** (Store.swift:545, 550-560): only when `statusState` changed. `blocked` => if `notifyNeedsYou` (default true); `done` or `error` => if `notifyDone` (default false); `idle`/`working` never. Body = `statusLine(showFolder:false)` (e.g. "Needs you · <detail>"). Needs-attention flag is set for blocked/done regardless of notification settings.
2. **Program notification** (OSC 9 / OSC 777): `needsAttention = true`; posts if `notifyPrograms` (default true) with `subtitle = oscTitle` (else project name) and body = the message (Store.swift:530-535).
3. **Bell** (BEL): `needsAttention = true`, plus a system beep (even when watched).
4. **PR events** (7.5): only the attention flag.
Notification content (Store.swift:563-566, Notifier.swift:31-50): title = session name, subtitle = project name (or the program title), body; thread id = tab id; `userInfo.tabID`; request identifier = tab UUID (so a new one replaces the previous one for that tab). Click => `reveal(id)`: open/activate the main window and select the tab (Store.swift:569-574). Notification is removed when the tab is selected/app activates (Notifier.clear).
Authorization is requested the first time a notification is to be shown (or from Welcome > Enable notifications). Notifications only work when running from an `.app` bundle.

**Style/sound logic** (`Notifier.post`, Notifier.swift:31-50): `soundOnly = notifyStyle == "sound"`; `customSound = notifySound non-empty and != "Default"`. If `soundOnly || customSound` => omux plays the named sound itself. If `soundOnly` => no banner. Else banner posted; its system sound is the default only when no custom sound. `playSound`: `NSSound(named: name.isEmpty||"Default" ? "Glass" : name)`, fallback Glass. Sound list (Notifier.swift:20): Default, Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink. Banners are shown even when the app is in front (willPresent returns banner/list/sound). Linux: libcanberra (`ca_context_play`) with freedesktop sound-theme event names (e.g. `message-new-instant`, `complete`, `bell`, `dialog-warning`, `service-login`) mapped to a short list; `gio::Notification` via `gio::Application::send_notification(id=<tab uuid>)` with default action `app.reveal` carrying the tab id.

**OSC parsing** (`TermView.notification`, TermView.swift:181-195): payload decoded as UTF-8 (else ignored).
- **OSC 9** (iTerm2): `OSC 9 ; <text>`. Ignore if `text` empty or matches `^\d+(;|$)` (ConEmu commands such as `9;4;...` progress). Otherwise notification `(title nil, body text)`.
- **OSC 777** (Ghostty/rxvt): `OSC 777 ; notify ; <title> ; <body>`: split payload on `;` with max 2 splits keeping empty parts => exactly 3 parts, `parts[0] == "notify"`, body non-empty; title empty => nil. Body may itself contain `;`.
- Other codes ignored. SwiftTerm still draws OSC 9;4 progress itself (observer, not handler). Claude Code emits these when its notification channel is `ghostty` or `iterm2` (README). Linux/VTE: VTE >= 0.78 exposes a `notification-received` signal (verify per VTE version; otherwise use the own-PTY scanner from 4.1 which also gives OSC 7501).

**Dock badge:** `NSApp.dockTile.badgeLabel = String(count of runtime.needsAttention)` or nil when 0 (Store.swift:24-29). Counts sessions needing attention (blocked/done unseen, bell, program notification, PR attention). Sidebar row indicators: bell (orange) when `needsAttention`, blue dot when only `hasActivity`, hidden on hover (replaced by ▶/■ button). Linux: no dock badge in GNOME; options: `com.canonical.Unity.LauncherEntry` D-Bus signal (works on Dash-to-Dock/Plasma), tray/appindicator, or window title prefix `(N)`.

**Welcome sheet** checks notification authorization (Enabled / Turned off / Enable button / Play the sound) (Welcome.swift:487-511). Linux: portal `org.freedesktop.portal.Notification`, no permission prompt; show "Enabled".

---

## 10. Paste and drop

Implemented in `TermView` (TermView.swift:118-170).

**Paste (⌘V)** `paste(_:)` order of precedence:
1. Pasteboard contains **file URLs** (`urlReadingFileURLsOnly`) => paste `shellEscaped(urls) + " "` (paths joined by single spaces, trailing space).
2. Else if the pasteboard has **no string** and has an **image** => save as PNG to `<NSTemporaryDirectory>/omux-paste/image-yyyyMMdd-HHmmss.png` (local time; directory created) and paste `shellEscaped([path]) + " "`. Two images within one second collide on the file name (overwrites).
3. Else normal text paste (SwiftTerm default: bracketed-paste aware).
Pasting goes through `paste(_ text:)` => if DEC bracketed paste mode is on: `ESC[200~` + text + `ESC[201~`, else raw text (164-170).

**Drop:** a drop of file URLs onto the terminal (accepts `.copy` only if file URLs readable) focuses the terminal and pastes `shellEscaped(urls) + " "`. Dropping files/folders onto the **sidebar** opens each as a project (`openFolder(path)`, folders only; Sidebar.swift:85-93). Dropping onto the Files panel previews the file.

**Quoting** `shellEscaped` (TermView.swift:145-149): for each path, every character in the set ` '"()[]{}&;|<>$` + backtick + `\*?#~` is prefixed with a backslash (so `~` is escaped everywhere, including mid-path); other characters, including non-ASCII and `-`, unchanged; multiple paths joined with a single space; one trailing space appended by the caller.
Linux clipboard: `gdk::Clipboard` formats `text/uri-list`, `x-special/gnome-copied-files`, `GdkFileList`, `image/png` (read texture, save PNG), `text/plain`. Use `GtkDropTarget` with `GdkFileList` on the terminal widget. Override Ctrl+Shift+V (VTE's paste) and middle-click paste logic for the image/file cases.

Also: `Store.sendText` (used for notes/picks) pastes via the same bracketed logic and requires a live, non-exited terminal (Store.swift:321-328).

**Permission answering bytes (Claude):** `answerPermission` (Store.swift:332-342) writes to the PTY: **Allow = `"\r"`** (Return, picks Claude's default "Yes"); **Deny = `"\u{1b}"`** (Escape, "No, and tell Claude what to do differently"). Only when `awaitsPermission` is true and the tab's terminal exists. For Codex tabs, no PTY bytes: the approval is answered over the app-server (`{"decision":"accept"|"decline"}`, section 5.5); the Allow/Deny buttons are disabled while that answer is in flight (`answering` set; Worktrees.swift:374).

---

## 11. UI inventory

### 11.1 Windows
- **Main window** (single; `id: "main"`): default 1240x780, min 720x420, hidden title bar with traffic lights kept visible (`WindowChrome`, OmuxApp.swift:140-160), theme-driven color scheme (dark/light) and chrome background.
- **Settings window** (460 pt wide grouped form, `Settings` scene, ⌘,).
- **Sheets** (modal over the main window): Worktree sheet, Quick switcher, Recent conversations, Welcome, Edit Session, Edit Project.
- **Alerts** (NSAlert): section 7.4 plus Delete project and Quit (below), and error/info alerts.
- **Popovers:** PR checks (320 w), subagent list (400 w), Codex agents (320 w), Codex approval info (420x180 monospaced scroll).

### 11.2 Sidebar (`Sidebar.swift`)
- Top bar (28 pt, right-aligned, 14 pt spacing): `+` New session in current project (⌘T); `folder.badge.plus` Open folder as project (⌘O); `clock.arrow.circlepath` Open recent conversation (⇧⌘O); `gearshape` Settings (⌘,). 1 pt spacer, then the list, 1 px hairline, then `UsageView`.
- Flat list of rows: **project header** (name 11 pt semibold, hover chevron toggle collapse, `+` new session; tertiary color; context menu) then **session rows** (indented 10 pt) unless the project is collapsed. Native drag reorder: dragging a project row reorders projects; dragging a session places it under the project row that ends up above it (`moveRows`, Store.swift:734-763); moving across projects expands the target.
- **Session row** (Sidebar.swift:98-184): 8 pt status dot (status color, else tab color, else secondary@35%); name (inline rename field); second line: worktree sessions `⎇ <branch> · <status line> · <N agents>` + PR badge, else `<status line (with folder if showFolderPath)> · <N agents>`; Allow/Deny buttons (+ info for Codex) when awaiting permission; `Delete Worktree` button when PR merged; agent rows (Claude) or Codex agent rows; trailing indicator: on hover a `■` (interrupt) when busy or `▶` when not agent-connected (and refresh busy); else bell (needsAttention) or blue dot (hasActivity). Exited rows at 55% opacity unless hovered.
- Empty-area context menu: New Project, Open Folder as Project…, Open Recent Conversation…, New Codex Session, ---, New Session, New Shell.
- **Session context menu** (TabMenu): Rename; Edit Session…; Color > (None, Red, Orange, Yellow, Green, Mint, Teal, Cyan, Blue, Indigo, Purple, Pink, Brown, Gray); Move to > (other projects; only if >1 project); [worktree: Open Pull Request #N | Delete Merged Worktree… | Create Pull Request…; Merge into <base>; Open Worktree in Finder]; ---; Interrupt (Ctrl-C); Restart Session; Kill Session; Close Session (destructive).
- **Project context menu** (GroupMenu): New Session; New Session in Worktree…; New Shell; ---; Rename; Edit Project…; ---; Move Up; Move Down (disabled at ends); ---; Delete Project (confirm if running sessions: title `Delete “<name>”?`, text `N running session(s) will be closed.`, buttons Delete/Cancel; last project removed => a new `Project N` created).
- Inline rename: Enter or focus loss commits (blank ignored), Esc cancels. `newGroup` puts the new project in rename mode.
- Creating names: new tab `"Session <tabs.count+1>"`, new project `"Project <groups.count+1>"` with `Session 1`, folder-opened project = folder basename. `openFolder(path)` (Store.swift:444-455): folder must exist; if a project already has exactly that `directory` string => adds a new session there; else new project with one session.

### 11.3 Session header (28 pt; OmuxApp.swift:236-299)
Status dot (8), name (11 semibold), provider label (Claude Code / Codex, caption2 tertiary, only for those), status line, Allow/Deny when awaiting permission, spacer, agent pill (Claude) or Codex agents popover button (`N agents`, person.2), worktree: PR chip + branch chip, else cwd (`~` abbreviated, head-truncated); `■` interrupt if `busy`, else `▶` if not `agentConnected`; right-panel toggle (sidebar.trailing icon; ⌥⌘F).
Empty state when no session: "No session / Press ⌘T to start one."

### 11.4 Menus and shortcuts (OmuxApp.swift:301-360) with Linux proposal
Conflict key: (R) readline/terminal programs use it, (V) VTE binds it, (D) common desktop/IME/WM binding.

| Action | Mac | Proposed Linux | Conflict notes |
|---|---|---|---|
| New Session | ⌘T | Ctrl+Shift+T | Ctrl+T (R: transpose chars) so Shift variant; GNOME Terminal uses same for new tab |
| New Shell | ⇧⌘T | Ctrl+Alt+Shift+T | Ctrl+Alt+T (D: global terminal launcher) avoided |
| New Session in Worktree… | ⌥⌘T | Ctrl+Shift+B | chosen mnemonic "branch"; Ctrl+Alt+T is global |
| New Project | ⇧⌘N | Ctrl+Shift+N | (D) new window in many apps; fine, we have one window |
| New Codex Session / New Claude Code Session | none | none (menu only) | |
| Open Folder… | ⌘O | Ctrl+Shift+O | Ctrl+O (R: operate-and-get-next, vim jump back) |
| Open Recent Conversation… | ⇧⌘O | Ctrl+Alt+O | |
| Close Session | ⌘W | Ctrl+Shift+W | Ctrl+W (R: unix-word-rubout, vim window cmds) |
| Close Window | ⇧⌘W | Ctrl+Alt+W | |
| Quit | ⌘Q | Ctrl+Shift+Q | Ctrl+Q (R: flow-control XON/quoted-insert in some shells) |
| Files Panel toggle | ⌥⌘F | F9 | (GNOME sidebar convention) or Ctrl+Alt+F |
| Files / Changes / Browser tab | ⌥⌘1/2/3 | Ctrl+Alt+1/2/3 | (D) workspace switchers on some WMs (check) |
| Rename | ⌘R | F2 | Ctrl+R (R: reverse-i-search) must stay with shell |
| Edit Session… | ⌘I | Ctrl+Alt+E | Ctrl+I = Tab (R) |
| Restart Session | ⇧⌘R | Ctrl+Shift+R | (D) browser hard reload only inside Browser panel |
| Interrupt (Ctrl-C) | ⇧⌘. | Ctrl+Shift+. | Ctrl+C itself reaches the PTY; Ctrl+. is IBus emoji (D) |
| Kill Session | none | none | |
| Start or Continue Session | ⇧⌘↩ | Ctrl+Shift+Enter | |
| Jump to Session… (quick switcher) | ⌘K | Ctrl+Shift+P | Ctrl+K (R: kill-line) |
| Next / Previous Session | ⇧⌘] / ⇧⌘[ | Ctrl+PageDown / Ctrl+PageUp | (V) GNOME Terminal tab convention; VTE itself doesn't bind them |
| Session 1-9 (in current project) | ⌘1...⌘9 | Alt+1...Alt+9 | (R) Alt+digit = readline numeric argument, accepted trade-off as in GNOME Terminal |
| Settings | ⌘, | Ctrl+, | |
| Copy / Paste | ⌘C / ⌘V | Ctrl+Shift+C / Ctrl+Shift+V | (V) VTE standard; paste handler must be overridden for files/images (section 10) |
| Help > Welcome to omux… ; omux on GitHub (`https://github.com/onurozcan/omux`) | none | menu only | |

Menu structure on Mac: File (New Session, New Codex Session, New Claude Code Session, New Shell, New Session in Worktree…, New Project, ---, Open Folder…, Open Recent Conversation…; Close Session, Close Window), View additions (Files Panel, Files, Changes, Browser), Session menu (Rename, Edit Session…, Restart Session, Interrupt (Ctrl-C), Kill Session, Start or Continue Session, ---, Jump to Session…), Help (Welcome…, GitHub, Next/Previous Session, Session 1-9). Linux: a primary `GMenu` (hamburger) with the same grouping; actions registered with `gio::SimpleAction` + accelerators.

### 11.5 Sheets and settings

- **Quick switcher** (460x380): text field "Jump to session…"; filter = case-insensitive substring over `"<tab name> <project name> <terminal title>"`; shows first 15 matches (dot, name, project name secondary, status line); Enter picks first, click picks, Esc closes (Sheets.swift:4-63).
- **Recent conversations** (560x440): search "Search recent conversations…", `Recent | By folder` segmented, `Claude Code | Codex` segmented (defaults to the current session's provider), loading spinner, empty text `No <Provider> conversations found` / `No matches` / error text. Rows: prompt (1 line), `open` badge if already a session, folder (`~`-abbreviated) + relative date. Enter opens first match. By-folder groups ordered by most recent session. Claude source = section 3.x `RecentSession.load` (below); Codex source = `thread/list`.
- **Edit Session** (460): Name; Folder (+ Choose…, placeholder project dir or `~`); Command picker `Project default | Claude Code | Codex | Plain shell | Custom`; Custom command field (placeholder `claude`); when inheriting shows the project's command or `plain shell`; for Claude/Codex shows conversation id (Claude uuid lowercase; Codex id or `New conversation`) with `Start a fresh conversation on next restart`; Save/Cancel. Save mapping (Sheets.swift:168-183): inherit => `command=nil, provider=nil`; claude => `"claude"/.claude`; codex => `"codex"/.codex`; shell => `""/.shell`; custom => `command=<text>, provider=infer(text)`. Load mapping from `(provider, command)`: provider claude with command not `"claude"` => Custom; provider nil: command nil => inherit, `""` => shell, `"codex"` => codex, `"claude"` => claude, else custom (143-165).
- **Edit Project** (460): Name; Folder (+ Choose…); `New sessions` picker over Claude Code / Codex / Plain shell / Custom command; Custom command field; note `Applies when a session starts. Existing sessions keep running.`; toggle `Give new sessions their own Git worktree`; `Worktree setup` field (monospaced, placeholder `cp "$OMUX_REPO/.env" . && npm install`) + hint. Save: `command = custom ? text : provider.command`, `provider = custom ? infer(text) : provider`, `useWorktrees`, trimmed `worktreeSetup`. Load: `provider = (command == group.provider.command) ? group.provider : .custom` (Sheets.swift:186-249). Provider commands: claude=`claude`, codex=`codex`, shell/custom=`""`.
- **New Session in Worktree** (460): title + help sentence "The session works on its own branch in its own folder, so sessions don't touch each other's files."; Name (default `Session <n+1>`); Agent picker (Project default / Claude Code / Codex); Branch (monospaced, follows slug); From (base picker); Folder (computed path, informational); Setup field; toggle `Use worktrees for new sessions in <project>`; red error text; Cancel / Create (disabled until valid; spinner while running). Not-a-repo state shows an orange warning `<dir> isn't a Git repository.`
- **Welcome** (520x600): header "Welcome to omux" / "A terminal for running many Claude Code and Codex sessions side by side. A few checks before you start."; sections **Agents** (detected `claude`/`codex` path via login-shell `command -v`, with install hints `npm install -g @anthropic-ai/claude-code` / `npm install -g @openai/codex`), **Notifications**, **Usage limits** (Check now / Check again; shows `5h N% Week N%` or errors), **First project** (Open a folder…, Recent conversations…); footer "Open this again from Help › Welcome to omux." / Done.
- **Settings pane** (single grouped form): **Appearance**: Theme picker (11), Font picker (`System Mono` + installed fixed-pitch families), Font size stepper 9-24 pt. **Sidebar**: toggle `Show folder path under session name`; picker `Check Claude limits every` (1 minute / 5 minutes / 30 minutes / Hour). **Files Panel**: `Wrap long lines in file preview`. **Sessions**: `Auto-resume agent sessions at launch` (+ "Off: restored sessions stay stopped until you press ▶. Clicking one only opens its shell."), `Confirm before quitting while sessions are running` (+ "Quitting stops every session. Saved Claude Code and Codex conversations can be continued on the next launch."). **Notifications**: three toggles (`When a session needs you`, `When a session finishes`, `When a program in a session sends one`), explanation line, `Style` picker (`Banner and sound` | `Sound only`), `Sound` picker + `Play` button.

### 11.6 Themes (exact, `Theme.swift`)
Raw values / labels: `black, dark(default), graphite, midnight, dracula, nord, oneDark("One Dark"), gruvbox, solarizedDark("Solarized Dark"), light, solarizedLight("Solarized Light")`; labels otherwise capitalized raw value. `light` and `solarizedLight` use the light color scheme, others dark. Each theme: terminal background, chrome (sidebar/header/panel strips), foreground (hex RGB):

| Theme | bg | chrome | fg |
|---|---|---|---|
| black | 000000 | 0F0F0F | E6E6E6 |
| dark | 1C1C1F | 252529 | E6E6E6 |
| graphite | 2B2B2B | 363636 | E6E6E6 |
| midnight | 0D1117 | 161B22 | C9D1D9 |
| dracula | 282A36 | 21222C | F8F8F2 |
| nord | 2E3440 | 3B4252 | D8DEE9 |
| oneDark | 282C34 | 21252B | ABB2BF |
| gruvbox | 282828 | 1D2021 | EBDBB2 |
| solarizedDark | 002B36 | 073642 | 839496 |
| light | FBFBFB | EFEFF1 | 1F1F1F |
| solarizedLight | FDF6E3 | EEE8D5 | 657B83 |

Caret color = foreground (TermView.swift:85). 16-color palettes (ANSI 0-7 then bright 8-15):
- midnight: 484F58 FF7B72 3FB950 D29922 58A6FF BC8CFF 39C5CF B1BAC4 | 6E7681 FFA198 56D364 E3B341 79C0FF D2A8FF 56D4DD F0F6FC
- dracula: 21222C FF5555 50FA7B F1FA8C BD93F9 FF79C6 8BE9FD F8F8F2 | 6272A4 FF6E6E 69FF94 FFFFA5 D6ACFF FF92DF A4FFFF FFFFFF
- nord: 3B4252 BF616A A3BE8C EBCB8B 81A1C1 B48EAD 88C0D0 E5E9F0 | 4C566A BF616A A3BE8C EBCB8B 81A1C1 B48EAD 8FBCBB ECEFF4
- oneDark: 282C34 E06C75 98C379 E5C07B 61AFEF C678DD 56B6C2 ABB2BF | 5C6370 E06C75 98C379 E5C07B 61AFEF C678DD 56B6C2 FFFFFF
- gruvbox: 282828 CC241D 98971A D79921 458588 B16286 689D6A A89984 | 928374 FB4934 B8BB26 FABD2F 83A598 D3869B 8EC07C EBDBB2
- solarizedDark and solarizedLight (same): 073642 DC322F 859900 B58900 268BD2 D33682 2AA198 EEE8D5 | 002B36 CB4B16 586E75 657B83 839496 6C71C4 93A1A1 FDF6E3
- light: 000000 C91B00 00A600 9A7B00 0225C7 CA30C7 00A2B2 BFBFBF | 686868 FF6E67 2EB84A C7A500 6871FF FF77FF 1BA8B5 FFFFFF
- black, dark, graphite (same): 000000 CD3131 0DBC79 E5E510 2472C8 BC3FBC 11A8CD E5E5E5 | 666666 F14C4C 23D18B F5F543 3B8EEA D670D6 29B8DB FFFFFF

Palette values are 8-bit expanded to 16-bit by `*257`. Apply to VTE via `set_colors(fg, bg, palette)` and `set_color_cursor`. Theme change calls `apply` on every live terminal (Store.swift:799-802) and the light/dark scheme maps to `adw::StyleManager::set_color_scheme(ForceDark/ForceLight)`. UI-chrome colors use `theme.chrome` for sidebar/header/panel strips and `theme.background` for panel content; hairlines are `primary @ 8%`.

**Semantic colors** (SwiftUI system colors, approximate hexes, dark/light): blue 0A84FF/007AFF (working, running), orange FF9F0A/FF9500 (blocked), green 30D158/34C759 (done, passed, added), red FF453A/FF3B30 (error, failed, removed), purple BF5AF2/AF52DE (merged), yellow FFD60A/FFCC00 (note icon). Tab colors (`TabColor`, 14 values): none, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray, mapped to the same system palette (mint 63E6E2/00C7BE, teal 40C8E0/30B0C7, cyan 64D2FF/32ADE6, indigo 5E5CE6/5856D6, pink FF375F/FF2D55, brown AC8E68/A2845E, gray 8E8E93/8E8E93). These hexes are approximations of Apple's palette (not in the repo); Adwaita named colors can substitute.

### 11.7 Fonts
`Fonts.terminal()`: family from `fontFamily` (empty => system monospaced), size `fontSize` if > 0 else 13; if the named family cannot be loaded, fall back to system monospaced at that size (Theme.swift:93-107 region). Picker offers only fixed-pitch families. Linux: Pango `FontDescription`, default `monospace`; enumerate with `pangocairo` font map filtered by `is_monospace()`. UI text uses system font; sizes used: 10/11/12 pt captions and body (header 11 semibold).

### 11.8 App integration (Info.plist)
Bundle id `net.pf1.omux`, version 0.5.0. Declares: folder document type (viewer, alternate rank); Finder service "Open in omux" for folders (`NSMessage openFolders`); ATS exceptions allowing arbitrary web content loads and local networking (WebKitGTK needs no equivalent). Behavior: opening folders (Dock drop, `open -a omux <dir>`, service) => bring up the window and `openFolder(path)` for each (OmuxApp.swift:363-395). Linux: `.desktop` with `MimeType=inode/directory;`, `Exec=omux %F`, `GApplication` with `HANDLES_OPEN`, single instance (D-Bus activation); Nautilus "Open in omux" via the desktop-file `Actions`/`Open With`.

---

## 12. Parity checklist

Difficulty: S small, M medium, L large.

| Feature | Swift source | macOS-specific API | Proposed Linux equivalent | Diff | Notes |
|---|---|---|---|---|---|
| Workspace JSON read/write, .bak, back-compat | Models.swift:179-223, 31-119 | `JSONEncoder`, Application Support dir | `serde`+`serde_json` with custom pretty printer (sorted keys), `dirs`/XDG, atomic write via tempfile+rename | S | Replicate defaults (2.1), uppercase UUIDs, omit nulls, `OMUX_WORKSPACE_DIRECTORY` |
| Settings store | OmuxApp.swift:25-135 | `UserDefaults`, `@AppStorage` | `settings.json` (same keys) or `gio::Settings` | S | Same key names/defaults |
| Window, sidebar, headers, split panes | OmuxApp.swift, Sidebar.swift | SwiftUI `NavigationSplitView`, `HSplitView` | `adw::NavigationSplitView`/`OverlaySplitView`, `gtk::Paned`, `adw::ApplicationWindow` | M | Hidden title bar: use header-less custom title area / `adw::HeaderBar` flat |
| Terminal widget | TermView.swift | SwiftTerm `LocalProcessTerminalView` | `vte4::Terminal` + `Pty` | M | Scrollback 5000 lines; theme colors; font |
| Shell launch (clean env, login shell, typed command) | Store.swift:191-242 | `execName` login trick | `vte::Terminal::spawn_async` argv `[shell,"-l"]`, explicit env, cwd; `feed_child` for command after 0.3 s | S | Section 3.1 |
| Process-tree kill, busy detection | Store.swift:273-277, 364-384 | `kill(-pgid)`, `sysctl KERN_PROC_ALL` | `nix::killpg`, `/proc` scan or `tcgetpgrp` | S | |
| OSC 7501 program status (Claude working/needs-you/done, subagent blocked) | TermView.swift:43-54 | SwiftTerm decoder | **Own-PTY filter** feeding VTE (4.1) or VTE patch | L | Grammar unknown (Q1); highest risk |
| OSC 9/777 notifications, bell, title, OSC 7 | TermView.swift:181-195, Store.swift:508-537 | SwiftTerm OSC observer | VTE signals `window-title-changed`, `current-directory-uri-changed`, `bell`, `notification-received` (check VTE ver) else PTY scanner | M | Regex-free but needs byte-level OSC parser |
| Status model, attention, watching | Store.swift:539-596, Models.swift:121-177 | `NSApp.isActive`, key window | `gtk::Window::is_active`, same logic | S | |
| Dock badge | Store.swift:24-29 | `NSApp.dockTile.badgeLabel` | Unity LauncherEntry D-Bus / title prefix / tray | M | No GNOME-native equivalent |
| Notifications + sounds | Notifier.swift | `UNUserNotificationCenter`, `NSSound` | `gio::Notification` (portal), `libcanberra` | M | Click => app action; replace by id; sound-only mode |
| Claude pin/resume command building | SessionProvider.swift:34-44, Store.swift:427-441 | none | Port verbatim (string logic) | S | Unit-test with the 6 test vectors |
| Start/Continue/Restart/Stop/Kill semantics | Store.swift:282-303, 387-423, 655-664 | none | Port | S | Sections 3.3 |
| Subagent discovery + transcripts | Agents.swift | `FileManager`, creationDate | `std::fs`, `serde_json`, background thread + `glib::MainContext` channel; birthtime via `statx`/`metadata().created()` fallback mtime | M | Incremental JSONL reader with partial-line buffer |
| Recent Claude conversations | RecentSessions.swift | `FileHandle` | `std::fs` (read first 128 KiB per file) | S | |
| Codex app-server process + readiness + WebSocket client | CodexConnection.swift | `Process`, `URLSessionWebSocketTask`, CryptoKit | `tokio`/`async-std`, `tokio-tungstenite` (custom header), `reqwest`/raw TCP for `/readyz`, `sha2`, `rand` | M | Need async runtime bridged to GLib (`glib::spawn_future_local` + tokio thread, or `async-channel`) |
| Codex manager (threads, turns, approvals, agents, usage) | CodexManager.swift | none | Port as pure Rust state machine; port all 9 unit tests | M | Subtle ordering rules in 5.5; ideal for TDD |
| Claude usage (credential + HTTP) | UsageMonitor.swift | Keychain via `/usr/bin/security` | read `~/.claude/.credentials.json`, `reqwest` (rustls) | S | Verify file shape on Linux |
| Git / gh wrappers, diff parser | Git.swift | `Process` | `std::process::Command` | S | Env vars in 7.1 |
| Worktrees, setup command, close/merge/PR dialogs | Worktrees.swift | `NSAlert`, `NSWorkspace.open` | `adw::MessageDialog`/`AlertDialog`, `gio::AppInfo::launch_default_for_uri` | M | |
| PR monitoring | PullRequests.swift | `NotificationCenter didBecomeActive` | thread/timer 60 s + window `is-active` notify | S | |
| Changes tab (list, diff, notes) | Changes.swift | `FSEventStream` | `notify` crate, `gtk::ListView`+`TextView`/custom lines | M | Notes message format exact (8.2) |
| Files tab (tree, watcher, previews) | FilePanel.swift | `NSWorkspace.icon`, `QLPreviewView`, `PDFView`, `AVPlayerView` | `gtk::TreeListModel`/`ListView`, `gio` content-type icons, `gtk::Video`, poppler/WebKit PDF, `GtkSourceView`/plain | L | Quick Look has no equivalent: fallback `xdg-open` |
| Markdown renderer | FilePanel.swift:378-453 | `AttributedString(markdown:)` | `pulldown-cmark` -> `TextView` tags or WebKit HTML | M | |
| Mentioned paths/URLs scan + link detection | TermView.swift:106-223 | NSRegularExpression lookbehind | `fancy-regex`/`pcre2`; `vte match_add_regex` for Ctrl+click | S | |
| Browser panel + element picker | Browser.swift | `WKWebView`, `WKScriptMessageHandler`, `takeSnapshot` | `webkit6::WebView`, `UserContentManager` message handler `omuxPick`, `snapshot` API | M | JS reusable verbatim (Appendix A) |
| Paste image/files, drop files | TermView.swift:118-170 | `NSPasteboard`, `NSImage` | `gdk::Clipboard` (read_texture, `GdkFileList`), `gtk::DropTarget`, `image`/`gdk::Texture::save_to_png` | M | Quoting set in section 10 |
| Quick switcher, recent, edit sheets, welcome, settings | Sheets.swift, Welcome.swift, OmuxApp.swift | SwiftUI sheets, `NSOpenPanel` | `adw::Dialog`/`gtk::Window` modal, `gtk::FileDialog` | M | |
| Shortcuts / menus | OmuxApp.swift:301-360 | `Commands` | `gio::Action`s + `set_accels_for_action` | S | Table 11.4 |
| Themes + fonts | Theme.swift | `NSColor`, `NSFontManager` | CSS provider + VTE colors, Pango | S | Table 11.6 |
| Open folders from file manager / CLI | Info.plist, OmuxApp.swift:363-395 | NSServices, Dock | `.desktop` + `GApplication::open` | S | |
| Quit confirmation, terminate cleanup | OmuxApp.swift:397-411, Store.swift:805 | `applicationShouldTerminate` | `close-request` handler | S | |
| Session drag-reorder/move | Sidebar.swift:65, Store.swift:686-770 | `List.onMove` | `gtk::DragSource/DropTarget` on rows | M | Algorithm in `moveRows` |
| Beta channel (separate dir/id) | Models.swift:190, OmuxApp.swift:51 | bundle id suffix | app-id `net.pf1.omux.Beta`, dir `omux-beta` | S | Optional |

---

## 13. Open questions and ambiguities

1. **OSC 7501 grammar (blocker).** The decoder is inside SwiftTerm 1.99.1 (`TerminalProgramStatus`, `TerminalOscObservation`), not in this repo. The repo only shows the decoded fields (id, state in idle/working/done/blocked/error, kind in permission/question/auth, message, title) and that a record with empty id is the root. The exact byte format (separator, key=value, base64, JSON?), update semantics (does an empty record list clear?), and which Claude Code version/setting emits it must be read from SwiftTerm source or Claude Code. Without it Linux cannot reproduce Claude status. Also unclear whether `kind` has more values than the three in the comment.
2. **Claude Code on Linux credential file.** `~/.claude/.credentials.json` is assumed to contain `{"claudeAiOauth":{"accessToken":...}}`; verify, and whether the token can be expired (no refresh logic exists on Mac either; Claude Code refreshes it).
3. **Notification of hooks vs OSC.** Mac depends on Claude Code's OSC 7501 and OSC 9/777 emission settings (`/config` notification channel `ghostty`/`iterm2`). Does VTE on the target distro (>= 0.76?) expose OSC 9/777 (`notification-received`)? Confirm minimum VTE version and whether `vte4` crate binds it.
4. **Environment policy on Linux.** The Mac builds a clean environment with a hardcoded Homebrew PATH. On Linux a clean env would drop `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_*`, `SSH_AUTH_SOCK`, `DBUS_*`. Decide an allow-list (suggested in 3.1). Also whether to strip `CLAUDE_CODE_*`, `CLAUDECODE`, `ANTHROPIC_*`.
5. **`TabGroup` default quirk.** A group created in-app has `command:"claude"`, `provider:.claude`; a group decoded without those keys has `command:nil`, provider inferred (`.shell` when command nil). The app also treats `command: ""` + `provider: .shell`. Linux must keep both paths identical to avoid flipping legacy groups.
6. **`start()` Claude fallback** (`"claude --session-id <uuid>"`) never resumes; reachable only when the tab provider is Claude but its command resolves empty. Probably a latent inconsistency, port as is or normalise.
7. **Codex port race.** Port is picked by bind-then-close (TOCTOU) and Codex is given `--listen ws://127.0.0.1:<port>`; no retry on collision. Consider retry up to N times in Rust.
8. **Codex catalog server never closes** until app exit (`shutdown`), and uses `$HOME` as cwd, env inherited (not clean). Intentional? Keep.
9. **Subagent `started` uses file creation date**, which is unavailable on some Linux filesystems (statx btime); fallback to meta mtime may mis-sort/mis-compute elapsed. Could parse the first transcript line's `timestamp` instead (not done on Mac).
10. **Image paste file name collisions** within the same second (`image-yyyyMMdd-HHmmss.png`): Mac overwrites. Add milliseconds or counter on Linux? Behavior change is harmless.
11. **`mentionedPaths` Unicode `\w`.** Swift `NSRegularExpression` `\w` is Unicode-aware; PCRE2 without UCP is not. Choose `(*UCP)` or fancy-regex with Unicode default.
12. **Dock badge** has no direct Linux counterpart; confirm accepted substitute.
13. **Quick Look fallback** for office docs/fonts/gif has no Linux analogue; confirm the "open with default app" fallback is acceptable.
14. **Default Linux settings location**: assumed `~/.config/omux/settings.json` alongside `workspace.json`. The task statement said "or similar"; confirm XDG_CONFIG_HOME vs XDG_DATA_HOME for the workspace.
15. **`stop()` for non-Codex** sends Ctrl-C twice 0.35 s apart even for plain shells (harmless at a prompt, but a build run in a non-agent session is interrupted twice). Keep for parity.
16. **UI scale of non-listed things** (animations, SF Symbols names) are not specified; map SF Symbols to Adwaita symbolic icons: plus, folder-new, document-open-recent, emblem-system, media-playback-start/stop, dialog-information, view-refresh, go-previous/next, globe (`web-browser`), `find-location` (scope), `view-sidebar-end`.
17. **Test corpus to port:** `SessionProviderTests` (6 tests), `CodexProtocolTests` (7 tests), opt-in `CodexConnectionTests` (needs `OMUX_CODEX_INTEGRATION=1`). They define the behavioral contract for sections 2.1, 3.2 and 5.5 and should be translated first.

---

## Appendix A: element picker script (verbatim, Browser.swift:146-220)

Evaluate in the page when picking starts. Messages posted to handler `omuxPick`.

```js
(function () {
  if (window.__omuxPick) window.__omuxPick.stop();
  const box = document.createElement('div');
  const tag = document.createElement('div');
  box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #22d3ee;background:rgba(34,211,238,0.12);border-radius:2px;display:none';
  tag.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#22d3ee;color:#0b0b0f;font:11px ui-monospace,Menlo,monospace;padding:2px 6px;border-radius:3px;display:none';
  document.documentElement.append(box, tag);
  const name = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    const cls = [...el.classList].filter((c) => !c.includes(':')).slice(0, 3);
    if (cls.length) s += '.' + cls.join('.');
    return s;
  };
  const path = (el) => {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && parts.length < 4; n = n.parentElement) {
      if ((n === document.body || n === document.documentElement) && parts.length) break;
      parts.unshift(name(n));
      if (n.id) break;
    }
    return parts.join(' > ');
  };
  let current = null;
  const move = (e) => {
    const el = e.target;
    if (!(el instanceof Element)) return;
    current = el;
    const r = el.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
    tag.textContent = name(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    Object.assign(tag.style, { display: 'block', left: Math.max(0, r.left) + 'px', top: Math.max(0, r.top - 20) + 'px' });
  };
  const PROPS = ['display', 'position', 'box-sizing', 'width', 'height', 'margin', 'padding', 'border', 'border-radius',
    'background-color', 'background-image', 'color', 'font-family', 'font-size', 'font-weight', 'line-height',
    'letter-spacing', 'text-align', 'gap', 'flex-direction', 'justify-content', 'align-items',
    'grid-template-columns', 'box-shadow', 'opacity', 'overflow'];
  const pick = (e) => {
    e.preventDefault();
    e.stopPropagation();
    const el = current || e.target;
    const cs = getComputedStyle(el);
    const css = PROPS.map((p) => p + ': ' + cs.getPropertyValue(p))
      .filter((l) => !/: (normal|none|auto|0px|static|visible|)$/.test(l)).join(';\n');
    const r = el.getBoundingClientRect();
    stop();
    window.webkit.messageHandlers.omuxPick.postMessage({
      selector: path(el), html: el.outerHTML.slice(0, 30000), css, url: location.href,
      x: r.left, y: r.top, width: r.width, height: r.height });
  };
  const block = (e) => { e.preventDefault(); e.stopPropagation(); };
  const key = (e) => {
    if (e.key !== 'Escape') return;
    stop();
    window.webkit.messageHandlers.omuxPick.postMessage({ cancel: true });
  };
  function stop() {
    document.removeEventListener('mousemove', move, true);
    document.removeEventListener('click', pick, true);
    document.removeEventListener('mousedown', block, true);
    document.removeEventListener('mouseup', block, true);
    document.removeEventListener('keydown', key, true);
    box.remove();
    tag.remove();
    window.__omuxPick = null;
  }
  document.addEventListener('mousemove', move, true);
  document.addEventListener('click', pick, true);
  document.addEventListener('mousedown', block, true);
  document.addEventListener('mouseup', block, true);
  document.addEventListener('keydown', key, true);
  window.__omuxPick = { stop };
})();
```
Cancel from the host: evaluate `window.__omuxPick && window.__omuxPick.stop()`.

## Appendix B: Recent Claude conversations (`RecentSession.load`, RecentSessions.swift:63-96)

- Enumerate `~/.claude/projects/*/*.jsonl`, sort by file modification time descending, take the first **300**.
- File name stem must parse as a UUID (the conversation id).
- Read only the first **128 KiB**, decode UTF-8 (skip file if it fails), split on `\n`, and take the first line that decodes as `{type, cwd?, message?{content}}` with `type == "user"`, `cwd` present, and the content text (string, or blocks' `text` joined by a space) trimmed non-empty and **not starting with `<`** (skips slash-command and system messages). Newlines in the prompt become spaces. Date = file mtime.
- `tabName` = first 5 space-separated words of the prompt; if longer than 32 chars => first 32 + `"…"`; empty => `"Session"`.
- Opening one (Store.swift:458-478): if a Claude tab already has that session id => select it; else find the project whose `directory == cwd` (exact string) or create a project named by the folder basename; append a tab `{provider: claude, command: "claude", claudeSessionID: id}`, uncollapse, start it, select it.

## Appendix C: hover/tooltips and misc strings worth keeping

- Tooltips: `Interrupt (Ctrl-C)`, `Start or continue this session`, `Files panel (⌥⌘F)`, `New session in current project (⌘T)`, `Open folder as a project (⌘O)`, `Open recent conversation (⇧⌘O)`, `Settings (⌘,)`, `Subagents in this session`, `Open with default app`, `Reveal in Finder`/`Open folder in Finder` (Linux: `Show in Files`), `Click to leave a note for this session`, `Types the notes into the session and sends them`, `Push <branch> and open a pull request into <base>`, `The pull request was merged. Close this session and delete its worktree and branch.`
- Codex error strings: see 5.2 and `CodexError` (CodexConnection.swift:4-15).
- Subtitle in Codex agent list: state strings `running`, `completed`, `errored`, `shutdown`, `interrupted`, `notFound`; finished dot green, else blue.
