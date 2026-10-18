# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue. Include the Facienda version, macOS version, and steps to reproduce.

Facienda is a beta; only the latest release gets security fixes.

## Security model

Facienda is a local, single-user Mac app. Your tasks, chats and memory live in one SQLite library in your data folder (default `~/facienda`), readable only by your account. Local storage does not mean all processing stays on the device. Facienda passes relevant task, chat and memory text to Codex or Claude for agent work and background model features, including memory learning when enabled; those providers handle inference traffic under their own account settings and policies. Facienda also checks for updates and downloads its speech model.

Agents are treated as untrusted, since a web page, email or file they read can carry instructions:

- Each task's chat gets a secret handle. Facienda's tools act only on the task whose handle they are given; they cannot answer approvals, start a task or mark it done.
- Facienda's permission rules in Claude are limited to its own task folders and pinned to your library.
- Text agents write is shown with care: no remote images, links open only web pages, mail or Facienda's own chat links, files are only revealed in Finder, and approval requests show the full command, files and access asked for.

What Facienda cannot protect against:

- **Agents with broad access.** An agent that may read any file or run any command without asking can read the library directly and send it out, bypassing Facienda's tools. This includes Codex with `danger-full-access` or approvals off, and Claude allow rules such as `Read(**)`, `Bash(curl *)` or `Bash(python *)`. Keep agents sandboxed and approvals on for work that reads untrusted content.
- **Other programs running as you.** They can read the library, chat transcripts and task handles like any of your files. The library is not encrypted; use FileVault.
