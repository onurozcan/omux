# Privacy

omux has no telemetry. Its integrations use these network paths:

- **Usage limits.** To show your plan limits, omux reads Claude Code's login from the macOS Keychain (the `Claude Code-credentials` item, via `/usr/bin/security`) and sends it to `https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` command uses. The token is never written to disk or logged. This endpoint is undocumented and may change or stop working at any time.
- **Pull request status.** If `gh` is installed, omux runs `gh pr view` for each worktree session's branch about once a minute and when you switch back to omux. Sending failing checks to a session runs `gh run view --log-failed` for those checks. gh uses its own login; omux never reads or stores your GitHub token.
- **Updates.** About once a day, omux fetches `https://omux.app/appcast.xml` to see whether a newer version exists, and downloads the update from GitHub only when you accept it. Nothing about you or your machine is sent.
- **Codex.** omux communicates with its owned Codex app-servers over authenticated loopback WebSockets. Codex itself connects to the model provider, tools, and services configured in your Codex settings. Usage is requested through `account/rateLimits/read`; accounts without supported plan limits display an unavailable message. omux starts its app-servers with analytics disabled.

The keep-awake helper (`omux-awake`, off until you turn on Settings › Keep Awake):

- It is a launch daemon inside the app (`Contents/Library/LaunchDaemons`), registered with SMAppService once you turn Keep Awake on and approve it in System Settings › Login Items, and unregistered when you turn it off. It runs as root because `pmset -a disablesleep` needs it, and runs nothing else.
- It never uses the network. It listens only on its own XPC service and accepts connections only from omux signed by the same team, and omux only talks to a helper signed by that team.
- It keeps sleep disabled only while omux renews a two-minute lease; when omux quits, crashes or hangs, or the connection drops, the Mac can sleep again within that time. It turns sleep back on whenever it starts, including at boot, and after 12 hours in a row it turns sleep back on and refuses for 30 minutes, whatever omux asks.
- While Keep Awake is on it stays running, idle, so it can turn sleep back on at boot and after a crash (launchd restarts it). Because it resets sleep to on whenever it starts, a `pmset -a disablesleep 1` you set yourself doesn't survive it.
- It writes nothing but its log (`log show --predicate 'subsystem == "net.pf1.omux.awake"'`).

Local files omux touches:

- `~/Library/Application Support/omux/workspace.json`: your projects and sessions (plus a `.bak` copy).
- `~/.claude/projects`: read to list recent conversations, to check whether a session's conversation exists, and to show a running session's subagents and their transcripts.
- Worktree sessions run `git` in your repository, and creating a pull request runs `git push` through your login shell. Nothing else is pushed or committed unless you confirm it.
- Elements picked in the browser are saved under your temporary folder (`omux-picks`) so Claude can read them.
- Settings are stored in the standard macOS preferences.
