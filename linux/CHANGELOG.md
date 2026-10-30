# Changelog (Linux)

## 0.1.0

First Linux release. It covers the features of omux 0.6.1 for macOS:

- **Sessions:**
  - Projects and sessions in a sidebar. Sessions can be renamed, colored, dragged and moved between projects.
  - Claude Code sessions keep their pinned conversation. Restart and Continue resume it.
  - Live status (working, needs you, done) from Claude Code's OSC 7501 reports.
  - Allow and Deny from the sidebar and the header.
  - Subagents with their transcripts.
- **Codex:** managed sessions on a private app-server per session, with status, approvals, subagents, usage limits and recent conversations.
- **Worktrees:** worktree sessions with a setup command, and close, merge, push and clean-up flows. Pull request status and checks come from `gh`.
- **Panels:**
  - Files: mentioned files and previews.
  - Changes: the diff and review notes sent to the agent.
  - Browser: local servers, plus an element picker that adds the element to the prompt.
- **Notifications and attention:**
  - Desktop notifications for sessions that need you or finish, and for programs that send OSC 9 or OSC 777. Choose banner and sound, or sound only.
  - The count of sessions needing attention shows on the dock icon.
- **Input:** paste an image as a file path, and paste or drop files as shell-escaped paths. Ctrl+click opens paths and URLs.
- **Settings and desktop:**
  - 11 themes and a choice of terminal font. Settings, a welcome sheet and a keyboard shortcuts list.
  - One instance. `omux <folder>` and Files › Open With open folders as projects.
  - `.deb`, a tarball with `install.sh`, a desktop entry and AppStream metadata.
