#!/usr/bin/env python3
"""Builds the comparison pages (site/<slug>.html), sitemap.xml and robots.txt.

Run after editing the data below: python3 scripts/build-pages.py
Facts about other tools come from their own READMEs and sites; keep them fair and current.
"""
import html, json, pathlib, datetime

root = pathlib.Path(__file__).resolve().parent.parent
site = root / "site"
BASE = "https://omux.app"
TODAY = datetime.date.today().isoformat()

OMUX_FEATURES = [
    ("Projects with sessions under them, in a sidebar", "yes"),
    ("Shows whether each agent is working, needs you or is done", "yes"),
    ("Allow or Deny an agent's permission request without switching to it", "yes"),
    ("Lists a session's subagents and opens their transcripts", "yes"),
    ("Resumes each Claude Code and Codex conversation after a relaunch", "yes"),
    ("Git worktree per session, with pull request status and merge", "yes"),
    ("Files, Changes (diff with review notes) and Browser panels", "yes"),
    ("Claude and Codex plan usage limits in the sidebar", "yes"),
    ("Split panes: up to six sessions side by side per project, layouts saved", "yes"),
    ("An omux command line: list, status, send, new, close and wait on sessions", "yes"),
    ("macOS notifications with sound", "yes"),
]

PAGES = [
    {
        "slug": "terminal-alternative",
        "other": "Terminal",
        "other_url": "https://support.apple.com/guide/terminal/welcome/mac",
        "title": "Terminal alternative for Claude Code and Codex on macOS: omux",
        "meta": "Terminal alternative for running Claude Code and Codex: omux is a native macOS app that keeps every agent session in a sidebar with live status, Allow/Deny buttons, subagents, worktrees and conversations that resume. What Terminal and iTerm2 still do better, and where omux is.",
        "h1": "Terminal alternative for running Claude Code and Codex on your Mac",
        "intro": [
            "Terminal, and iTerm2 for many people, is where Claude Code and Codex run by default: a tab per session, and you cycle through them to see which one has stopped to ask something. It works until the third or fourth session.",
            "omux keeps the terminal and changes the thing around it. Each session is still a real terminal, but it lives under a project in a sidebar that shows whether the agent is working, waiting on you or done, with Allow and Deny right there. This page sets out what you keep, what you gain and what you give up.",
        ],
        "rows": [
            ("What it is", "A session manager for coding agents, with a terminal in each session", "A general-purpose terminal"),
            ("Runs on", "macOS", "Ships with macOS; iTerm2 is a free download"),
            ("Knows what the agent is doing", "Yes: working, needs you, done, read from the agents' own signals", "No: a tab is a tab, and a bell at best"),
            ("Answer a permission prompt", "Allow and Deny buttons under the session, from anywhere", "Find the tab and type"),
            ("Subagents", "Listed under the session, transcripts in the side panel", "Not visible unless the agent prints them"),
            ("Conversations after a relaunch", "Each session resumes its exact Claude or Codex conversation", "Reopen the tab and run claude --resume by hand"),
            ("Git worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Manual"),
            ("Diff, files and browser next to the agent", "Built-in panels, with review notes sent to the agent", "Other apps"),
            ("Notifications", "When a session you aren't looking at needs you, with a sound", "Bell notifications only"),
            ("Split panes, profiles, tmux integration", "Panes per project, up to six sessions; no profiles", "Yes, especially in iTerm2"),
            ("Everyday shell work", "A plain shell session works, but it's not the focus", "Its whole purpose"),
            ("Price and license", "Free, MIT", "Terminal is part of macOS; iTerm2 is free, GPL"),
        ],
        "better_other": [
            "Most of your terminal time is ordinary shell work, not agents.",
            "You want split panes, profiles, triggers, or tmux integration.",
            "You're happy with one or two agent sessions and a tab for each.",
        ],
        "better_omux": [
            "You run several Claude Code or Codex sessions and want to see which one needs you without cycling tabs.",
            "You'd rather click Allow than hunt for the session that's asking.",
            "You want each session to come back after a relaunch, with its own worktree and its diff beside it.",
        ],
        "faq": [
            ("Do I stop using Terminal or iTerm2?", "No. Keep them for shell work. omux is for the sessions that run an agent; a plain shell session in omux is a normal login shell too, so you can do both in one window if you prefer."),
            ("Does omux use its own terminal engine?", "It uses SwiftTerm, an open-source terminal emulator written in Swift. Claude Code and Codex render in it exactly as they do in Terminal."),
            ("Can omux import my Terminal or iTerm2 profile?", "No. omux has its own themes and font settings in its preferences."),
        ],
    },
    {
        "slug": "tmux-alternative",
        "other": "tmux",
        "other_url": "https://github.com/tmux/tmux",
        "title": "tmux alternative for Claude Code and Codex: omux, a native Mac app",
        "meta": "tmux alternative for running many Claude Code and Codex sessions: omux is a native macOS app with projects, live agent status, Allow/Deny from the sidebar, worktrees and conversations that resume. Where tmux still wins, and where omux is better.",
        "h1": "tmux alternative for running many Claude Code and Codex sessions",
        "intro": [
            "tmux is the tool most people reach for when they run several Claude Code or Codex sessions at once: one window per project, split panes, detach and come back later. It works, and it works everywhere.",
            "omux takes a different approach. It's a native macOS app built for exactly this job, so instead of remembering which pane holds which agent, you get a sidebar of projects and sessions that shows which agent is working, which one is waiting on you, and buttons to answer it. This page is a fair look at where each one fits.",
        ],
        "rows": [
            ("Runs on", "macOS only", "macOS, Linux, BSD, anywhere with a terminal"),
            ("Interface", "Native macOS window with a sidebar and panels", "Keyboard-driven, inside any terminal"),
            ("Knows what the agent is doing", "Yes: status from Claude Code's and Codex's own signals, no screen scraping", "No: a pane is a pane"),
            ("Answer a permission prompt", "Allow and Deny buttons under the session, without switching to it", "Switch to the pane and type"),
            ("Subagents", "Listed under the session, transcripts in the side panel", "Not visible unless the agent prints them"),
            ("Conversations after a restart", "Each session resumes its exact Claude or Codex conversation", "Sessions are gone when the server stops, unless you add a resurrect plugin and resume by hand"),
            ("Git worktrees and pull requests", "One worktree per session, PR status in the sidebar, merge and clean up", "Manual"),
            ("Diff, files and browser next to the agent", "Built-in panels", "Other tools in other panes"),
            ("Split panes", "Yes: a resizable canvas per project, up to six sessions", "Yes, any layout"),
            ("Detach and reattach", "No: sessions live as long as the app runs", "Yes, the server keeps running"),
            ("Remote machines over SSH", "No", "Yes, tmux runs on the remote end"),
            ("Scripting", "Yes: the omux command lists, steers and waits on sessions over a local socket", "Full CLI, scriptable"),
            ("Price and license", "Free, MIT", "Free, ISC"),
        ],
        "better_other": [
            "You work on Linux, over SSH, or on a remote box: tmux runs where the shell runs.",
            "You rely on detach and reattach, or on custom pane layouts and keybindings.",
            "You script your sessions, or drive them from other tools.",
        ],
        "better_omux": [
            "You run several Claude Code or Codex sessions on a Mac and want to see at a glance which one needs you.",
            "You'd rather click Allow than hunt for the pane that's asking.",
            "You want each session's conversation back after a restart, its own worktree, and the diff and files beside it, without setting any of that up.",
        ],
        "faq": [
            ("Can I use omux and tmux together?", "Yes. A plain shell session in omux is a normal login shell, so you can run tmux inside it. omux's agent-aware features apply to sessions that run Claude Code or Codex directly."),
            ("Does omux replace tmux for remote work?", "No. omux runs sessions on your Mac only. For agents on remote machines, tmux or a tool like herdr is the better fit."),
            ("Does omux need Claude Code or Codex to be installed?", "For agent sessions, yes: Claude Code as claude, and optionally the Codex CLI as codex. Plain shell sessions work without either."),
        ],
    },
    {
        "slug": "cmux-alternative",
        "other": "cmux",
        "other_url": "https://github.com/manaflow-ai/cmux",
        "title": "cmux alternative: omux, a native Mac terminal built around Claude Code and Codex",
        "meta": "cmux alternative for AI coding agents: omux is a native macOS app built around Claude Code and Codex, with status from the agents themselves, Allow/Deny buttons, subagents, worktrees with pull request status and conversations that resume. What cmux does better, and what omux does better.",
        "h1": "cmux alternative built around Claude Code and Codex",
        "intro": [
            "cmux and omux want the same thing: a Mac terminal that makes running many coding agents bearable. Both are native Swift apps, both are free and open source, and both light up when an agent needs you.",
            "They differ in what they're built around. cmux is a general terminal, rendered by libghostty, with workspaces, split panes, SSH, an in-app browser with an automation API, and a CLI and socket API that scripts can drive. omux is narrower on purpose: it's a session manager for Claude Code and Codex, and it reads their own signals to show status, permissions, subagents and usage limits.",
        ],
        "rows": [
            ("Runs on", "macOS", "macOS"),
            ("Built with", "SwiftUI and SwiftTerm", "Swift and AppKit on libghostty; reads your Ghostty config"),
            ("Organizing work", "Projects, each with sessions; optional worktree per session", "Workspaces with vertical tabs showing branch, directory, ports and PR status"),
            ("Agent needs attention", "Status from Claude Code's and Codex's own protocols: working, needs you, done, and what it's doing", "Notification rings and a notification panel, fed by OSC 9/99/777 and the cmux notify CLI"),
            ("Answer a permission prompt", "Allow and Deny buttons in the sidebar and header; Codex approvals show the command", "Jump to the pane"),
            ("Subagents", "Listed per session with transcripts; Codex child agents too", "Claude Code Teams mode, teammates as native splits"),
            ("Conversations after a restart", "Each session resumes its exact Claude or Codex conversation", "Layout, directories and saved session ids restored; supported agents resume"),
            ("Pull requests", "PR status per worktree session, create, merge, clean up", "PR status shown in the sidebar"),
            ("Side panels", "Files, Changes (diff with review notes sent to the agent) and Browser", "In-app browser with a scriptable automation API"),
            ("Usage limits", "Claude and Codex plan limits in the sidebar", "No"),
            ("Split panes", "Yes: split right and down on a per-project canvas, dividerless, layouts saved", "Yes, right and down"),
            ("Remote machines over SSH", "No", "Yes, cmux ssh"),
            ("Scripting", "Yes: omux CLI over a local socket, scoped so an agent can only steer sessions it started", "CLI and Unix socket API"),
            ("Updates", "In-app, signed, notarized", "In-app via Sparkle, DMG and Homebrew"),
            ("License", "MIT", "GPL-3.0 for the app"),
        ],
        "better_other": [
            "You want SSH workspaces, a browser automation API, or Ghostty rendering.",
            "You already use Ghostty and want its rendering and config.",
            "You run agents beyond Claude Code and Codex and want them all treated the same way.",
        ],
        "better_omux": [
            "Your sessions are Claude Code and Codex, and you want status, permissions and subagents read from the agents themselves rather than from notifications.",
            "You want a worktree per session with the pull request's state, the diff and review notes right there.",
            "You like a smaller, MIT-licensed app whose CLI is scoped so agents can only touch what they started.",
        ],
        "faq": [
            ("Which is more mature?", "cmux has a broader feature set and a larger community. omux is newer and focused; check both changelogs and pick the one whose direction matches how you work."),
            ("Can omux read Ghostty themes?", "No. omux has its own themes and font settings. cmux reads your Ghostty configuration."),
            ("Does omux have a CLI?", "Yes, since 0.9: omux list, status, screen, send, new, close and wait, over a per-launch Unix socket. It is scoped: a session can only steer sessions it started, and the whole thing can be switched off in Settings."),
        ],
    },
    {
        "slug": "warp-alternative",
        "other": "Warp",
        "other_url": "https://www.warp.dev",
        "title": "Warp alternative: omux, a free native Mac app for your own Claude Code and Codex",
        "meta": "Warp alternative for running coding agents: omux is a free, MIT-licensed native macOS app that hosts the Claude Code and Codex sessions you already pay for, with no account, no credits and no telemetry. Where Warp is better, and where omux is.",
        "h1": "Warp alternative: run your own Claude Code and Codex, without a platform",
        "intro": [
            "Warp has grown from a modern terminal into an agent platform: its own coding agent, cloud agents triggered from issues and Slack, factories defined as code, and pricing per agent run. If you want that whole stack, Warp is the product for it.",
            "omux is the opposite shape. It doesn't bring an agent, a cloud or a login. It's a native macOS window that runs the Claude Code and Codex sessions you already have, many at a time, and makes them easy to watch and answer. This page is for people deciding between those two shapes.",
        ],
        "rows": [
            ("What it is", "A session manager for Claude Code and Codex", "A terminal plus an agent platform with its own agent and cloud runs"),
            ("Runs on", "macOS", "macOS, Linux, Windows"),
            ("Account required", "No", "Sign-in for AI features"),
            ("Pricing", "Free, MIT; you pay only your Claude or Codex plan", "Usage-based, priced per agent run; free tier with limits"),
            ("Whose agent", "Yours: Claude Code and Codex as installed, with their own logins", "Warp's agent, plus bring-your-own agents such as Claude Code and Codex"),
            ("Agent status and permissions", "Working, needs you, done; Allow and Deny from the sidebar; subagents listed", "Agent UI inside Warp; third-party CLI agents run as programs in the terminal"),
            ("Conversations after a restart", "Each session resumes its exact conversation", "Warp's own agent sessions persist; CLI agents depend on the agent"),
            ("Git worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Not a worktree manager"),
            ("Cloud and background agents", "No", "Yes: cloud runs, triggers from Slack, Linear and GitHub, factories"),
            ("Telemetry", "None", "Collected, with settings to limit it"),
            ("Terminal features", "A terminal per session, split panes per project; no blocks or completions", "Rich: blocks, completions, command search, split panes"),
        ],
        "better_other": [
            "You want an AI terminal with completions, blocks and an agent of its own, on any platform.",
            "You want agents that run in the cloud, kick off from issues or chat, and produce pull requests while you sleep.",
            "Your team wants one managed, billed platform rather than individual subscriptions.",
        ],
        "better_omux": [
            "You already pay for Claude Code or Codex and want a calm place to run many sessions of them on your Mac.",
            "You don't want another account, credit balance or telemetry.",
            "You care about seeing which session needs you and answering it in one click, with the diff and files beside it.",
        ],
        "faq": [
            ("Does omux include an AI agent?", "No. It runs Claude Code and Codex, which you install and sign in to yourself. omux never sees your prompts or your API keys."),
            ("Can omux run agents in the cloud?", "No. Sessions run on your Mac. For cloud or scheduled agents, Warp and similar platforms are built for that."),
            ("Is omux really free?", "Yes. It's MIT-licensed and the app has no paid tier. Your only cost is the Claude or Codex plan you use with it."),
        ],
    },
    {
        "slug": "herdr-alternative",
        "other": "herdr",
        "other_url": "https://github.com/ogulcancelik/herdr",
        "title": "herdr alternative: omux, a native macOS app for Claude Code and Codex sessions",
        "meta": "herdr alternative with a native macOS interface: omux runs Claude Code and Codex sessions in a window with status, Allow/Deny buttons, subagent transcripts, worktrees and pull request status. Where herdr's TUI and remote machines win, and where omux is better.",
        "h1": "herdr alternative with a native macOS interface",
        "intro": [
            "herdr is a terminal multiplexer made for coding agents: one Rust binary, a background server that keeps terminals alive, panes marked working, blocked or idle, and a socket API that lets agents spawn and wait on each other. It runs in whatever terminal you already use, on several machines at once.",
            "omux solves the same visibility problem with a window instead of a TUI. It's macOS only and has no server or API, but it shows status, permissions, subagents, diffs and pull requests for Claude Code and Codex sessions in a sidebar and panels you click. Which one fits depends on where your agents run and how you like to look at them.",
        ],
        "rows": [
            ("Runs on", "macOS, as a native app", "macOS, Linux and Windows, inside any terminal"),
            ("Interface", "Sidebar, session header and side panels", "Terminal UI with keyboard and mouse"),
            ("Agents supported", "Claude Code and Codex, with provider-specific integration; plain shells too", "Claude Code, Codex, Cursor, OpenCode, Grok and others"),
            ("Agent status", "Working, needs you, done, plus what it's doing and its subagents", "Working, blocked or idle per pane"),
            ("Answer a permission prompt", "Allow and Deny buttons without switching", "Switch to the pane"),
            ("Conversations after a restart", "Each session resumes its exact conversation", "Layouts restored; supported agent sessions resume"),
            ("Detach and reattach", "No", "Yes, terminals persist in a background server"),
            ("Remote machines", "No", "Yes, local and SSH machines in one list"),
            ("Agents controlling the multiplexer", "Yes: the omux CLI lets a session start, send to and wait on its own child sessions", "Yes, CLI and socket API; agents can spawn panes and wait on each other"),
            ("Git worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Not built in"),
            ("Diff, files and browser", "Built-in panels, review notes sent to the agent", "Other tools"),
            ("Usage limits", "Claude and Codex plan limits in the sidebar", "No"),
            ("License", "MIT", "Apache-2.0"),
        ],
        "better_other": [
            "Your agents run on Linux or remote machines, or you need to detach and reattach.",
            "You want agents on different machines orchestrating each other through one API.",
            "You run a mix of agent CLIs beyond Claude Code and Codex.",
        ],
        "better_omux": [
            "You work on a Mac and prefer a window with a sidebar, notifications and panels to a TUI.",
            "You want Allow and Deny buttons, subagent transcripts and the diff next to the session.",
            "You want worktrees and pull request status handled for you.",
        ],
        "faq": [
            ("Can I run herdr inside omux?", "Yes, in a plain shell session, though you'd then have two layers doing similar jobs. Use omux's own sessions for Claude Code and Codex to get its status and permission buttons."),
            ("Does omux work over SSH?", "No. Sessions run locally. herdr is a better fit for remote machines."),
            ("Which has fewer moving parts?", "omux: it's one app with no server and no API. herdr runs a background server so terminals outlive the client."),
        ],
    },
]

PAGES += [
    {
        "slug": "t3-code-alternative",
        "other": "T3 Code",
        "other_url": "https://t3.codes",
        "title": "T3 Code alternative: omux, a native Mac app for Claude Code and Codex sessions",
        "meta": "T3 Code alternative for running coding agents: omux is a 5 MB native macOS app that keeps Claude Code and Codex sessions in a sidebar with live status, Allow/Deny buttons, subagents, split panes, worktrees and pull request status. Where T3 Code's mobile apps and branch-per-thread flow win, and where omux is better.",
        "h1": "T3 Code alternative: a native Mac terminal instead of a control plane",
        "intro": [
            "T3 Code is the open-source control plane for coding agents from T3 Tools: a desktop app, a web app and iOS and Android apps that drive Claude Code, Codex, Antigravity, OpenCode, Cursor and Grok through their SDKs. Every thread gets its own branch, and a button commits, pushes and opens a pull request with a generated title. It's free, MIT-licensed and moving fast.",
            "omux is smaller and closer to the metal. It's one native Swift window, about 5 MB, that runs the real Claude Code and Codex terminals side by side under projects, reads their own signals for status, and puts Allow and Deny in the sidebar. No server, no Electron, no reimplemented chat view. This page is a fair look at which shape fits you.",
        ],
        "rows": [
            ("What it is", "A session manager with a real terminal per Claude Code or Codex session", "A control plane that drives agent harnesses through their SDKs, one chat-style thread per task"),
            ("Runs on", "macOS, native Swift, about 5 MB", "macOS, Windows and Linux desktop (Electron), web, iOS and Android"),
            ("Agents", "Claude Code and Codex, plus plain shells", "Claude Code, Codex, Antigravity, OpenCode, Cursor and Grok, with more added often"),
            ("How you see the agent", "Its own terminal UI, exactly as in Terminal", "A thread view rendered by T3 Code; a terminal is available too"),
            ("Agent status", "Yes: working, needs you, done, read from the agents' own signals", "Yes: per thread, with push notifications on the phone apps"),
            ("Answer a permission prompt", "Allow and Deny buttons in the sidebar and header, without switching", "Yes, inside the thread"),
            ("Subagents", "Listed under the session with transcripts", "Shown inside the thread"),
            ("Git", "Optional worktree per session, pull request status, merge and clean up", "A branch per thread, one-button commit, push and PR with generated titles; draft and stacked PRs"),
            ("Diff review", "Changes panel with review notes sent to the agent", "Inline diff review before pushing"),
            ("Split panes", "Yes: a resizable canvas per project, up to six sessions", "No"),
            ("From your phone", "No", "Yes: native iOS and Android apps that reach your machine"),
            ("Scripting", "Yes: omux CLI over a local socket", "Not a focus"),
            ("Maturity", "Young, small and focused", "Early by its own description, with a large community"),
            ("Price and license", "Free, MIT", "Free, MIT"),
        ],
        "better_other": [
            "You want to check on and steer agents from your phone, or from a browser on another machine.",
            "You run agents beyond Claude Code and Codex and want them all in one place.",
            "You like the branch-per-thread flow with generated pull requests and stacked PRs built in.",
        ],
        "better_omux": [
            "You want the real terminal UI of Claude Code and Codex, not a rendering of it, with status and permissions read from the agents themselves.",
            "You want a 5 MB native app with no server and no Electron, and split panes so several sessions share one project view.",
            "You prefer a worktree per session with the pull request's state and the diff right next to the agent.",
        ],
        "faq": [
            ("Is T3 Code a terminal?", "Not primarily. It talks to agents through their SDKs and shows each task as a thread, with a terminal available when you need one. omux is the other way round: every session is a terminal first, with the sidebar and panels built around it."),
            ("Can I use omux and T3 Code together?", "Yes. They don't interfere, since each starts its own agent processes. Many people keep a desktop tool for focused work and a phone app for checking in."),
            ("Which one is more mature?", "T3 Code has the larger community and ships often, and its own site says to expect bugs. omux is a younger, smaller project with a narrower scope. Read both changelogs and pick the one whose direction matches your work."),
        ],
    },
    {
        "slug": "vscode-alternative",
        "other": "VS Code",
        "other_url": "https://code.visualstudio.com",
        "title": "VS Code alternative for running Claude Code and Codex sessions: omux",
        "meta": "VS Code alternative for agent sessions: omux is a 5 MB native macOS app that runs Claude Code and Codex in real terminals, side by side, with live status, Allow/Deny buttons, subagents, split panes and worktrees. Where VS Code's Agents window, Copilot and extensions win, and where omux is better.",
        "h1": "VS Code alternative for running Claude Code and Codex sessions",
        "intro": [
            "VS Code has grown far past autocomplete. Its Agents window manages sessions across projects with Copilot, Claude and Codex as harnesses, sessions can work in their own worktree, and cloud sessions and automations are in preview. If you live in VS Code, it's a capable home for agents.",
            "omux isn't an editor. It's a native window for the sessions themselves: the real Claude Code and Codex terminals, under projects in a sidebar, with status read from the agents' own signals and Allow and Deny one click away. This page is for people who run their agents in the terminal and want a better place to run many of them.",
        ],
        "rows": [
            ("What it is", "A session manager for Claude Code and Codex", "A code editor with agents built in"),
            ("Runs on", "macOS", "macOS, Windows, Linux and the web"),
            ("Agents", "Claude Code and Codex, each in its own terminal", "Copilot, Claude and Codex harnesses in the Agents window; the integrated terminal runs anything"),
            ("Account", "No: only your Claude or Codex login", "GitHub account; a Copilot plan, a provider account or your own API key"),
            ("Agent status", "Yes: working, needs you, done, plus what it's doing, in the sidebar", "Yes: a session list in the Agents window"),
            ("Answer a permission prompt", "Allow and Deny from the sidebar and header, without switching", "Confirm in the chat or terminal"),
            ("Subagents", "Listed under the session with transcripts", "Depends on the harness"),
            ("Conversations after a restart", "Each session resumes its exact conversation", "Session history for Copilot sessions; terminal agents resume by hand"),
            ("Worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Yes: a session can edit in a worktree; pull requests through GitHub"),
            ("Cloud and scheduled agents", "No", "Yes: cloud sessions and automations, in preview"),
            ("Split panes", "Yes: a canvas per project, up to six sessions", "Yes: editor groups and terminal splits"),
            ("Editing code", "No: open files in your editor from the Files panel", "Its whole purpose"),
            ("Extensions", "No", "Tens of thousands"),
            ("Size and feel", "About 5 MB, native Swift", "Electron, a few hundred MB"),
            ("Price and license", "Free, MIT", "Free, MIT for the open-source core; Copilot plans are paid"),
        ],
        "better_other": [
            "You edit in VS Code anyway and want agents next to your files, tests and debugger.",
            "You want Copilot, cloud sessions, automations, or agents on Windows and Linux.",
            "You lean on extensions for the rest of your workflow.",
        ],
        "better_omux": [
            "You run Claude Code and Codex as terminals and want to see which of eight sessions needs you without hunting through tabs.",
            "You'd rather click Allow in a sidebar than find the right chat or terminal.",
            "You want something small and native that stays out of the way of your editor.",
        ],
        "faq": [
            ("Can I use omux with VS Code?", "Yes. omux runs the agents; VS Code edits the files. The Files panel in omux opens any file in your default editor, and the Changes panel shows the diff without leaving the agent."),
            ("Does omux replace Copilot?", "No. omux has no agent of its own and no completions. It hosts the Claude Code and Codex sessions you already have."),
            ("Why not run Claude Code in the VS Code terminal?", "That works well for one or two sessions. omux is for when you have many: it shows each one's status from the agent's own signals, lists subagents, puts Allow and Deny in the sidebar, and brings every conversation back after a relaunch."),
        ],
    },
    {
        "slug": "cursor-alternative",
        "other": "Cursor",
        "other_url": "https://cursor.com",
        "title": "Cursor alternative for running Claude Code and Codex: omux, free and native",
        "meta": "Cursor alternative for agent work: omux is a free, MIT-licensed native macOS app that runs the Claude Code and Codex sessions you already pay for, side by side, with live status, Allow/Deny buttons, subagents, split panes and worktrees. No account, no credits. Where Cursor's editor, parallel cloud agents and models win, and where omux is better.",
        "h1": "Cursor alternative: run your own Claude Code and Codex, without credits",
        "intro": [
            "Cursor is an AI editor with its own agent runtime: the editor, Composer and a menu of frontier models, parallel agents that run in the cloud for hours, Bugbot for review, automations, and plans from a free tier up to Ultra. It's a platform, and a strong one if you want everything on one bill.",
            "omux is a 5 MB window that runs the Claude Code and Codex you already have. No model menu, no credits, no account, no telemetry. The sessions sit under projects in a sidebar, show their status from the agents' own signals, and take Allow and Deny from one click. This page is for people who moved their agent work to the terminal and want to run many sessions without losing track.",
        ],
        "rows": [
            ("What it is", "A session manager for Claude Code and Codex", "An AI code editor with its own agent, models and cloud"),
            ("Runs on", "macOS", "macOS, Windows and Linux; web and mobile for cloud agents"),
            ("Account and billing", "None; you pay only your Claude or Codex plan", "Cursor account; a free tier and paid plans by usage, with third-party models billed separately"),
            ("Whose agent", "Claude Code and Codex as installed, with their own logins", "Cursor's agent with Composer and third-party models; a CLI as well"),
            ("Many agents at once", "Yes: sessions under projects, split panes per project", "Yes: parallel agents and cloud agents"),
            ("Agent status", "Working, needs you, done, read from the agents' own signals", "Task states in the editor and its planning view"),
            ("Answer a permission prompt", "Allow and Deny from the sidebar", "In the agent panel"),
            ("Subagents", "Listed under the session with transcripts", "Depends on the model and mode"),
            ("Conversations after a restart", "Each session resumes its exact conversation", "Chats persist in the editor"),
            ("Worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Worktrees for parallel agents; pull requests from cloud agents"),
            ("Code review", "Changes panel with notes sent back to the agent", "Bugbot on GitHub and the diff view in the editor"),
            ("Editing code", "No", "Its whole purpose"),
            ("Telemetry", "None", "Collected, with a privacy mode"),
            ("Price and license", "Free, MIT", "Proprietary; free tier and paid plans"),
        ],
        "better_other": [
            "You want an editor and an agent in one product, with a choice of models on one bill.",
            "You want cloud agents that keep working for hours and come back with a pull request.",
            "You work on Windows or Linux.",
        ],
        "better_omux": [
            "You already pay for Claude Code or Codex and want a calm place to run many sessions of them on a Mac.",
            "You don't want another account, credit balance or telemetry.",
            "You want to see which session needs you and answer it in one click, with the diff and files beside it.",
        ],
        "faq": [
            ("Can I use omux and Cursor together?", "Yes. Cursor stays your editor; omux runs the terminal sessions. The Files panel in omux opens files in whatever editor you set as default."),
            ("Does omux have its own model or agent?", "No. It runs Claude Code and Codex, which you install and sign in to yourself. omux never sees your prompts or keys."),
            ("Does omux cost anything?", "No. It's MIT-licensed, the app has no paid tier, and there are no credits. Your only cost is the Claude or Codex plan you use with it."),
        ],
    },
    {
        "slug": "antigravity-alternative",
        "other": "Antigravity",
        "other_url": "https://antigravity.google",
        "title": "Antigravity alternative: omux, a native Mac app for Claude Code and Codex",
        "meta": "Google Antigravity alternative for running coding agents: omux is a 5 MB native macOS app for Claude Code and Codex sessions, with live status, Allow/Deny buttons, subagents, split panes and worktrees, and no Google account. Where Antigravity's Agent Manager, browser agents and Gemini win, and where omux is better.",
        "h1": "Antigravity alternative: your own Claude Code and Codex in one native window",
        "intro": [
            "Google Antigravity is an agent-first platform on one harness: an IDE with an Agent Manager, a desktop app that runs local agents in parallel with projects and scheduled messages, a CLI with background subagents, a Python SDK, and artifacts such as task lists, screenshots and recordings that agents hand back as evidence. It's free for individuals, built around Gemini, and signed in with a Google account.",
            "omux is one small window for the agents you already chose. It runs the real Claude Code and Codex terminals side by side, reads their own signals for status, and puts Allow and Deny in the sidebar. No account, no quotas of its own, nothing to learn beyond the agents you use. This page compares the two shapes fairly.",
        ],
        "rows": [
            ("What it is", "A session manager for Claude Code and Codex", "An agent platform: IDE, app, CLI and SDK on one harness"),
            ("Runs on", "macOS", "macOS, Windows and Linux"),
            ("Account", "No", "Google account"),
            ("Whose agent", "Claude Code and Codex, with their own logins", "Google's harness, built around Gemini models"),
            ("Many agents at once", "Yes: sessions under projects, split panes per project", "Yes: the Agent Manager and the app run local agents in parallel"),
            ("Agent status", "Working, needs you, done, from the agents' own signals", "An inbox of agent runs with artifacts to review"),
            ("Answer a permission prompt", "Allow and Deny from the sidebar", "In the agent's thread"),
            ("Browser", "A browser panel for you; agents don't drive it", "Yes: browser-in-the-loop agents for frontend work"),
            ("Artifacts and verification", "Changes panel with review notes sent to the agent", "Agents produce task lists, screenshots and recordings"),
            ("Scheduled agents", "No", "Yes: recurring messages in the app"),
            ("Conversations after a restart", "Each session resumes its exact conversation", "Conversations persist in the app"),
            ("Worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Workspaces; git through the IDE"),
            ("Editing code", "No", "A full IDE, forked from VS Code"),
            ("Price and license", "Free, MIT", "Free for individuals with quotas; paid Google AI plans raise them; proprietary"),
        ],
        "better_other": [
            "You want Gemini and Google's harness, with an IDE, an app, a CLI and an SDK that share one brain.",
            "You want agents that drive a browser and hand back screenshots and recordings as proof.",
            "You want scheduled, recurring agent runs.",
        ],
        "better_omux": [
            "You want to keep Claude Code and Codex exactly as they are, with their own logins and plans.",
            "You don't want a Google account or another set of quotas between you and your agents.",
            "You prefer a 5 MB native window with real terminals to a platform.",
        ],
        "faq": [
            ("Can omux run Antigravity?", "Not as an agent session. omux integrates with Claude Code and Codex. A plain shell session in omux can run the Antigravity CLI, but without status, permissions or subagents."),
            ("Does omux need an account?", "No. Only the agents do: Claude Code and Codex sign in on their own, and omux never sees those credentials."),
            ("Is omux free?", "Yes. MIT-licensed, no paid tier, no credits."),
        ],
    },
    {
        "slug": "devin-alternative",
        "other": "Devin",
        "other_url": "https://devin.ai",
        "title": "Devin alternative: omux, a native Mac app for your own Claude Code and Codex",
        "meta": "Devin alternative for hands-on agent work: omux is a free, MIT-licensed native macOS app that runs Claude Code and Codex sessions side by side, with live status, Allow/Deny buttons, subagents, split panes and worktrees. Where Devin's cloud engineer, Slack handoff and Devin Desktop win, and where omux is better.",
        "h1": "Devin alternative: run your own agents on your Mac, in the open",
        "intro": [
            "Devin from Cognition is an autonomous software engineer. You assign it a task from chat, Slack, Linear, Jira or GitHub, it works on its own cloud machine and comes back with a pull request. Since the Windsurf acquisition it also ships Devin Desktop, an editor, with a free tier, paid plans and team seats.",
            "omux is the hands-on end of the spectrum. The Claude Code and Codex sessions run on your Mac, in your checkout, and you watch, answer and steer them in a sidebar that shows which one needs you. Nothing leaves your machine except what the agents themselves send. This page is for deciding how much of the loop you want to hold.",
        ],
        "rows": [
            ("What it is", "A session manager for Claude Code and Codex on your Mac", "A cloud software engineer, plus an editor (Devin Desktop)"),
            ("Where the agent runs", "On your Mac, in your checkout", "Devin's cloud machines, or locally in Devin Desktop"),
            ("Whose agent", "Claude Code and Codex, with their own logins", "Devin, on frontier and open models chosen in the app"),
            ("Account and billing", "None; you pay only your Claude or Codex plan", "Cognition account; free tier, Pro, Max, Teams and Enterprise"),
            ("Start a task", "Type in the terminal, or use the omux CLI", "Chat, Slack, Linear, Jira or GitHub"),
            ("Many agents at once", "Yes: sessions under projects, split panes per project", "Yes: parallel cloud sessions, up to a plan limit"),
            ("Agent status", "Working, needs you, done, from the agents' own signals", "A session list with progress in Devin's app"),
            ("Answer a permission prompt", "Allow and Deny from the sidebar", "Devin asks in its chat when unsure"),
            ("Subagents", "Listed under the session with transcripts", "Not exposed"),
            ("Worktrees and pull requests", "One worktree per session, PR status, merge and clean up", "Devin opens the pull request from its machine"),
            ("Code review", "Changes panel with notes sent to the agent", "Review the PR on GitHub; Devin can review too"),
            ("Works while you're away", "Sessions run as long as your Mac and omux are open", "Yes: cloud sessions continue"),
            ("Editing code", "No", "Devin Desktop"),
            ("Price and license", "Free, MIT", "Proprietary; free tier and paid plans from about $20 a month"),
        ],
        "better_other": [
            "You want to hand off tasks from Slack or an issue tracker and get a pull request back without watching.",
            "You want agents on cloud machines that keep going when your laptop is closed.",
            "Your team wants one managed platform with seats, admin controls and analytics.",
        ],
        "better_omux": [
            "You want to steer the work as it happens, in the terminal, with the diff beside the agent.",
            "You already pay for Claude Code or Codex and don't want a second platform or account.",
            "You want the code to stay on your machine, and the tool to be free and open source.",
        ],
        "faq": [
            ("Is omux an autonomous engineer?", "No. It's the window you run your own agents in. Claude Code and Codex do the work; omux shows their status, permissions, subagents, diffs and pull requests, and keeps every session's conversation across relaunches."),
            ("Can I use omux and Devin together?", "Yes. Many people hand well-specified tasks to a cloud agent and keep interactive work local. They don't overlap."),
            ("Does omux upload my code anywhere?", "No. omux has no server and no telemetry. The agents talk to their own providers as they would in any terminal."),
        ],
    },
]

GLANCE = {'terminal-alternative': [('Ships with macOS', False, True), ('Agent status and Allow/Deny', True, False), ('Subagent transcripts', True, False), ('Resumes agent conversations', True, False), ('Worktrees and pull requests', True, False), ('Notifications when an agent needs you', True, 'partial'), ('Split panes and profiles', 'partial', True), ('Free and open source', True, 'partial')], 'tmux-alternative': [('Native macOS app', True, False), ('Runs on Linux and over SSH', False, True), ('Agent status and Allow/Deny', True, False), ('Resumes agent conversations', True, 'partial'), ('Worktrees and pull requests', True, False), ('Split panes', True, True), ('Detach and reattach', False, True), ('Free and open source', True, True)], 'cmux-alternative': [('Native macOS app', True, True), ("Status from the agents' own protocols", True, False), ('Allow/Deny buttons', True, False), ('Subagent transcripts', True, 'partial'), ('Worktrees with PR merge and cleanup', True, 'partial'), ('Split panes', True, True), ('SSH workspaces', False, True), ('CLI and socket API', True, True), ('Free and open source', True, True)], 'warp-alternative': [('No account or credits', True, False), ('Runs your own Claude Code and Codex', True, True), ('Agent status and Allow/Deny', True, 'partial'), ('Worktrees and pull requests', True, False), ('Cloud and scheduled agents', False, True), ('Cross-platform', False, True), ('No telemetry', True, False), ('Free and open source', True, 'partial')], 'herdr-alternative': [('Native macOS window', True, False), ('Linux, Windows and remote machines', False, True), ('Agent status', True, True), ('Allow/Deny buttons', True, False), ('Subagent transcripts', True, False), ('Detach and reattach', False, True), ('Agents controlling the tool via API', 'partial', True), ('Worktrees and pull requests', True, False), ('Free and open source', True, True)]}

def esc(s): return html.escape(s, quote=False)

GLANCE.update({
    't3-code-alternative': [('Native macOS app', True, False), ('Real terminal per session', True, 'partial'), ('Agent status', True, True), ('Allow/Deny from the sidebar', True, True), ('Split panes', True, False), ('Branch per task with one-click PR', 'partial', True), ('iOS and Android apps', False, True), ('Windows and Linux', False, True), ('Free and open source', True, True)],
    'vscode-alternative': [('Native macOS app', True, False), ('Claude Code and Codex in real terminals', True, True), ('Status without switching', True, 'partial'), ('Allow/Deny buttons', True, False), ('Split panes', True, True), ('Code editor and extensions', False, True), ('Cloud sessions and automations', False, True), ('Windows and Linux', False, True), ('Free and open source', True, True)],
    'cursor-alternative': [('No account or credits', True, False), ('Runs your own Claude Code and Codex', True, 'partial'), ('Agent status and Allow/Deny', True, 'partial'), ('Split panes', True, True), ('Worktrees and pull requests', True, True), ('Cloud agents', False, True), ('Code editor', False, True), ('No telemetry', True, False), ('Free and open source', True, False)],
    'antigravity-alternative': [('Native macOS app', True, 'partial'), ('No account', True, False), ('Runs your own Claude Code and Codex', True, False), ('Agent status and Allow/Deny', True, 'partial'), ('Split panes', True, True), ('Agents that drive a browser', False, True), ('Scheduled agents', False, True), ('Full IDE', False, True), ('Free and open source', True, 'partial')],
    'devin-alternative': [('Runs on your Mac, code stays local', True, 'partial'), ('No account', True, False), ('Runs your own Claude Code and Codex', True, False), ('Agent status and Allow/Deny', True, 'partial'), ('Split panes', True, False), ('Keeps working when your laptop is closed', False, True), ('Start tasks from Slack or Linear', False, True), ('Worktrees and pull requests', True, True), ('Free and open source', True, False)],
})

# "Where the agent lives": the other tool's stack, top to bottom. omux's side is the same on every page.
SHAPES = {
    'terminal-alternative': ['Terminal or iTerm2', 'A tab per agent', 'You, cycling through tabs'],
    'tmux-alternative': ['Any terminal', 'tmux server with panes and windows', 'You, switching panes'],
    'cmux-alternative': ['Native Mac window on libghostty', 'Workspaces, splits and notifications', 'Your own agents'],
    'warp-alternative': ['Warp terminal', "Warp's agent and cloud runs", 'Warp account and credits'],
    'herdr-alternative': ['Any terminal, as a TUI', 'herdr server, local and SSH machines', 'Your own agents'],
    't3-code-alternative': ['Electron desktop, web, iOS and Android', 'T3 Code server on your machine', 'Agent SDKs: Claude Code, Codex, Cursor, Grok…'],
    'vscode-alternative': ['VS Code (Electron)', 'Agents window: Copilot, Claude and Codex harnesses', 'GitHub account, Copilot plan or API key'],
    'cursor-alternative': ['Cursor editor (VS Code fork)', "Cursor's agent: Composer and other models", 'Cursor account, plans and credits'],
    'antigravity-alternative': ['Antigravity IDE, app and CLI', "Google's harness on Gemini", 'Google account and AI plan quotas'],
    'devin-alternative': ['Slack, Linear, GitHub or Devin Desktop', "Devin on Cognition's cloud machines", 'Cognition account and plan'],
}

FACTS = [("5 MB", "native Swift app, no Electron"), ("0", "accounts, credits or telemetry"), ("6", "sessions side by side per project"), ("MIT", "free and open source")]

def shape_html(p):
    other = SHAPES[p["slug"]]
    nodes = '<div class="shape-arrow">↓</div>'.join(f'<div class="shape-node">{esc(n)}</div>' for n in other)
    chips = ('<span class="chip"><i class="dot working"></i>Claude Code</span>'
             '<span class="chip"><i class="dot needs"></i>Claude Code</span>'
             '<span class="chip"><i class="dot working"></i>Codex</span>'
             '<span class="chip"><i class="dot done"></i>Codex</span>'
             '<span class="chip chip-shell">shell</span>')
    return f'''<div class="shape" aria-label="Where the agent lives">
      <div class="shape-col shape-other">
        <div class="shape-title">{esc(p["other"])}</div>
        {nodes}
      </div>
      <div class="shape-col shape-omux">
        <div class="shape-title">omux</div>
        <div class="shape-node">The native agentic development platform for the Mac, about 5 MB</div>
        <div class="shape-arrow">↓</div>
        <div class="shape-chips">{chips}</div>
        <div class="shape-arrow">↓</div>
        <div class="shape-node">The real Claude Code and Codex, on your own plans</div>
      </div>
    </div>
    <p class="shape-legend"><i class="dot working"></i> working <i class="dot needs"></i> needs you <i class="dot done"></i> done</p>'''

def facts_html():
    return '<ul class="facts" aria-label="omux in numbers">' + "".join(f'<li><strong>{esc(a)}</strong><span>{esc(b)}</span></li>' for a, b in FACTS) + '</ul>'


def head_html(title, meta, canonical, extra=""):
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <meta name="description" content="{html.escape(meta)}">
  <link rel="canonical" href="{canonical}">
  <meta name="theme-color" content="#0F0F0F">
  <meta name="color-scheme" content="dark">
  <!-- Google tag (gtag.js) -->
  <script async src="https://www.googletagmanager.com/gtag/js?id=G-TYCLVPPKHP"></script>
  <script>
    window.dataLayer = window.dataLayer || [];
    function gtag(){{dataLayer.push(arguments);}}
    gtag('js', new Date());
    gtag('config', 'G-TYCLVPPKHP');
  </script>
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="omux">
  <meta property="og:url" content="{canonical}">
  <meta property="og:title" content="{html.escape(title)}">
  <meta property="og:description" content="{html.escape(meta)}">
  <meta property="og:image" content="{BASE}/social-preview.png">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="apple-touch-icon.png">
  <link rel="stylesheet" href="style.css?v=8">
{extra}</head>'''

HEADER = '''<header class="site-header">
  <div class="container header-row">
    <a class="brand" href="/" aria-label="omux home">
      <img src="favicon.svg" alt="" width="28" height="28">
      <span>omux</span>
    </a>
    <nav class="site-nav" aria-label="Primary">
      <a href="/#features">Features</a>
      <a href="/#install">Install</a>
      <a href="https://github.com/onurozcan/omux">GitHub</a>
      <a class="btn btn-small btn-primary" href="https://github.com/onurozcan/omux/releases/latest" data-download>Download</a>
    </nav>
  </div>
</header>'''

def footer_html(current=None):
    links = "".join(f'<a href="/{p["slug"]}">{esc(p["other"])} alternative</a>' for p in PAGES if p["slug"] != current)
    return f'''<footer class="site-footer">
  <div class="container">
    <nav class="footer-links" aria-label="Footer">
      <a href="https://github.com/onurozcan/omux">GitHub</a>
      <a href="https://github.com/onurozcan/omux/releases">Releases</a>
      <a href="/changelog">Changelog</a>
      <a href="https://github.com/onurozcan/omux/issues">Issues</a>
      <a href="https://github.com/onurozcan/omux/blob/main/LICENSE">MIT license</a>
    </nav>
    <nav class="footer-links footer-compare" aria-label="Comparisons">
      <span class="muted">Compare:</span>{links}
    </nav>
    <p class="fineprint">omux is the native agentic development platform for the Mac: a 5 MB terminal that runs fleets of Claude Code and Codex sessions. omux is an independent project, not affiliated with or endorsed by Anthropic or OpenAI. Claude and Claude Code are trademarks of Anthropic; Codex is a trademark of OpenAI. Other product names belong to their owners; comparisons reflect their public documentation as of {TODAY} and may be out of date.</p>
  </div>
</footer>'''

MARK = {True: '<span class="mark yes" aria-label="yes">✓</span>', False: '<span class="mark no" aria-label="no">✕</span>',
        "partial": '<span class="mark partial" aria-label="partly">~</span>'}

def cell(text):
    """Table cells that start with Yes or No get a mark in front."""
    for word, key in (("Yes", True), ("No", False)):
        if text == word or text.startswith(word + ":") or text.startswith(word + ","):
            rest = text[len(word):].lstrip(":, ")
            return MARK[key] + (f" {esc(rest)}" if rest else "")
    return esc(text)

def glance_html(p):
    rows = "".join(f'<div class="glance-row"><span class="glance-label">{esc(l)}</span>{MARK[o]}{MARK[t]}</div>\n' for l, o, t in GLANCE[p["slug"]])
    return f'''<div class="glance" role="table" aria-label="At a glance">
      <div class="glance-row glance-head" role="row"><span class="glance-label">At a glance</span><span>omux</span><span>{esc(p["other"])}</span></div>
{rows}    </div>'''

def page_html(p):
    canonical = f"{BASE}/{p['slug']}"
    faq_ld = {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
        {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in p["faq"]]}
    crumbs_ld = {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "omux", "item": BASE + "/"},
        {"@type": "ListItem", "position": 2, "name": f"{p['other']} alternative", "item": canonical}]}
    extra = f'  <script type="application/ld+json">{json.dumps(faq_ld)}</script>\n  <script type="application/ld+json">{json.dumps(crumbs_ld)}</script>\n'
    rows = "".join(f"<tr><th scope=\"row\">{esc(f)}</th><td>{cell(o)}</td><td>{cell(t)}</td></tr>\n" for f, o, t in p["rows"])
    intro = "".join(f"<p class=\"lede\">{esc(x)}</p>\n" for x in p["intro"])
    better_other = "".join(f"<li>{esc(x)}</li>" for x in p["better_other"])
    better_omux = "".join(f"<li>{esc(x)}</li>" for x in p["better_omux"])
    faq = "".join(f"<details><summary>{esc(q)}</summary><p>{esc(a)}</p></details>\n" for q, a in p["faq"])
    others = ", ".join(f'<a href="/{q["slug"]}">{esc(q["other"])} alternative</a>' for q in PAGES if q["slug"] != p["slug"])
    return f'''{head_html(p["title"], p["meta"], canonical, extra)}
<body>

{HEADER}

<main class="section compare">
  <div class="container narrow">
    <nav class="crumbs" aria-label="Breadcrumb"><a href="/">omux</a> › {esc(p["other"])} alternative</nav>
    <h1>{esc(p["h1"])}</h1>
{intro}
    <div class="cta-row">
      <a class="btn btn-primary" href="https://github.com/onurozcan/omux/releases/latest" data-download>Download omux for macOS</a>
      <a class="btn btn-secondary" href="{p["other_url"]}" rel="nofollow noopener">About {esc(p["other"])}</a>
    </div>

{glance_html(p)}

    {facts_html()}

    <figure class="shot compare-shot">
      <img src="shots/hero.png" srcset="shots/hero.png 1600w, shots/hero@2x.png 2400w" sizes="(min-width: 800px) 760px, calc(100vw - 32px)" width="1600" height="985" loading="lazy" alt="omux with eight projects in the sidebar, a Claude Code conversation in the transcript view, a Codex session waiting on Allow or Deny, and the Changes panel showing a diff">
      <figcaption>omux: projects and sessions on the left, the agent in the middle, its diff on the right. The session that needs you shows Allow and Deny.</figcaption>
    </figure>

    <h2>Where the agent lives</h2>
{shape_html(p)}

    <h2>Side by side</h2>
    <div class="table-wrap">
    <table class="compare-table">
      <thead><tr><th scope="col"></th><th scope="col">omux</th><th scope="col">{esc(p["other"])}</th></tr></thead>
      <tbody>
{rows}      </tbody>
    </table>
    </div>

    <h2>A closer look at omux</h2>
    <div class="gallery">
        <figure class="shot">
          <img src="shots/approval.png" srcset="shots/approval.png 1600w, shots/approval@2x.png 2400w" sizes="(min-width: 800px) 760px, calc(100vw - 32px)" width="1600" height="985" loading="lazy" alt="A Codex session asking to run npm outdated, with Allow and Deny in the transcript and in the sidebar">
          <figcaption>Every approval is a card. Allow or Deny from the transcript or the sidebar, or tell the agent what to do instead.</figcaption>
        </figure>
        <figure class="shot">
          <img src="shots/codex.png" srcset="shots/codex.png 1600w, shots/codex@2x.png 2400w" sizes="(min-width: 800px) 760px, calc(100vw - 32px)" width="1600" height="985" loading="lazy" alt="A Codex session's reply with a code block, next to the file it changes">
          <figcaption>Codex replies stream in as they're written, with code blocks you can copy and files you can open.</figcaption>
        </figure>
        <figure class="shot">
          <img src="shots/panes.png" srcset="shots/panes.png 1600w, shots/panes@2x.png 2400w" sizes="(min-width: 800px) 760px, calc(100vw - 32px)" width="1600" height="985" loading="lazy" alt="A Claude Code session and a Codex session side by side in one project, with the diff on the right">
          <figcaption>Sessions side by side: drop one onto another to split the pane.</figcaption>
        </figure>
        <figure class="shot">
          <img src="shots/editor.png" srcset="shots/editor.png 1600w, shots/editor@2x.png 2400w" sizes="(min-width: 800px) 760px, calc(100vw - 32px)" width="1600" height="985" loading="lazy" alt="The Files panel editing server.ts next to the conversation, with ⌘S to save">
          <figcaption>Edit files in the Files panel, with syntax colors and ⌘S to save, while the agent keeps working.</figcaption>
        </figure>
        <figure class="shot">
          <img src="shots/picker.png" srcset="shots/picker.png 1600w, shots/picker@2x.png 2400w" sizes="(min-width: 800px) 760px, calc(100vw - 32px)" width="1600" height="985" loading="lazy" alt="The agent and model picker: Claude Code models and Codex models in one menu">
          <figcaption>Switch a session between Claude Code and Codex, or change the model, from the compose box. The conversation is handed over.</figcaption>
        </figure>
    </div>

    <div class="split">
      <div class="card pick pick-other">
        <h2><span class="pick-icon" aria-hidden="true">→</span> Pick {esc(p["other"])} if</h2>
        <ul>{better_other}</ul>
      </div>
      <div class="card pick pick-omux">
        <h2><span class="pick-icon" aria-hidden="true">★</span> Pick omux if</h2>
        <ul>{better_omux}</ul>
      </div>
    </div>

    <h2>What omux does for every session</h2>
    <ul class="checklist">
{"".join(f"      <li>{esc(f)}</li>{chr(10)}" for f, _ in OMUX_FEATURES)}    </ul>

    <h2>Questions</h2>
{faq}
    <p class="muted">Also compared: {others}. Facts about {esc(p["other"])} come from its public documentation as of {TODAY}; if something is out of date, <a href="https://github.com/onurozcan/omux/issues">open an issue</a>.</p>
  </div>
</main>

{footer_html(p["slug"])}
<script src="main.js?v=2" defer></script>
</body>
</html>
'''

for p in PAGES:
    (site / f"{p['slug']}.html").write_text(page_html(p))

urls = [("", "1.0", "weekly"), ("changelog", "0.7", "weekly")] + [(p["slug"], "0.8", "monthly") for p in PAGES]
sitemap = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "".join(
    f"  <url><loc>{BASE}/{u}</loc><lastmod>{TODAY}</lastmod><changefreq>{c}</changefreq><priority>{pr}</priority></url>\n" for u, pr, c in urls) + "</urlset>\n"
(site / "sitemap.xml").write_text(sitemap)
(site / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}/sitemap.xml\n")
print("wrote", ", ".join(p["slug"] + ".html" for p in PAGES), "sitemap.xml robots.txt")
