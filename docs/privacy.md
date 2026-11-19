# Privacy

omux has no telemetry. Its integrations use these network paths:

- **Usage limits.** To show your plan limits, omux reads Claude Code's login from the macOS Keychain (the `Claude Code-credentials` item, via `/usr/bin/security`) and sends it to `https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` command uses. The token is never written to disk or logged. This endpoint is undocumented and may change or stop working at any time.
- **Pull request status.** If `gh` is installed, omux runs `gh pr view` for each worktree session's branch about once a minute and when you switch back to omux. Sending failing checks to a session runs `gh run view --log-failed` for those checks. gh uses its own login; omux never reads or stores your GitHub token.
- **Updates.** About once a day, omux fetches `https://omux.app/appcast.xml` to see whether a newer version exists, and downloads the update from GitHub only when you accept it. Nothing about you or your machine is sent.
- **Codex.** omux communicates with its owned Codex app-servers over authenticated loopback WebSockets. Codex itself connects to the model provider, tools, and services configured in your Codex settings. Usage is requested through `account/rateLimits/read`; accounts without supported plan limits display an unavailable message. omux starts its app-servers with analytics disabled.

Local files omux touches:

- `~/Library/Application Support/omux/workspace.json`: your projects and sessions (plus a `.bak` copy).
- `~/.claude/projects`: read to list recent conversations, to check whether a session's conversation exists, and to show a running session's subagents and their transcripts.
- Statistics reads the Claude Code transcripts in `~/.claude/projects`, for every project on the Mac, and runs `git log` in the folders they were in to list your commits. What it read is kept in `~/Library/Application Support/omux/work-stats-v3.json`, which holds session titles, your requests and transcript paths. Nothing of it is sent anywhere. Project icons are copies kept in `~/Library/Application Support/omux/project-icons`.
- Home reads `~/.claude/projects` and `~/.codex/sessions` to count the last seven days' prompts and tokens, and keeps the counts per file in `~/Library/Caches/net.pf1.omux/home-stats-2.json`. Your to-dos are stored with the settings. A share card is made on your Mac and goes nowhere unless you copy or save it.
- Worktree sessions run `git` in your repository, and creating a pull request runs `git push` through your login shell. Nothing else is pushed or committed unless you confirm it.
- Elements picked in the browser are saved under your temporary folder (`omux-picks`) so Claude can read them.
- Settings are stored in the standard macOS preferences.
