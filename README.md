# conductor

> Route your prompts to the right AI agent automatically.

conductor is a Claude Code skill that turns Claude into a CTO-mode orchestrator — it auto-routes tasks to **Codex** (code), **Gemini** (search/UI), or handles them itself (reasoning/tradeoffs), using your existing CLI subscriptions.

## How it works

- You talk to Claude as normal
- Claude routes behind the scenes: code tasks → Codex CLI, search/UI → Gemini CLI
- All agents reply in compressed caveman format to save tokens
- Errors surface immediately, loops are blocked, delegation depth capped at 1

## Install

```bash
git clone https://github.com/Sid3548/conductor
cd conductor
bash install.sh
```

## Requirements

- [Claude Code](https://claude.ai/code) CLI installed and authenticated
- [Codex CLI](https://github.com/openai/codex) (optional, for code routing)
- Gemini CLI (optional, for search/UI routing)

## What gets installed

| File | What it does |
|---|---|
| `~/.claude/CLAUDE.md` | Orchestrator rules for Claude |
| `~/.claude/settings.json` | Auto-approves agent MCP calls (no popup) |
| MCP registrations | Wires codex-delegate and gemini-delegate |

## Adding a new agent

Edit `agents.json` before running install.sh. Add an entry:

```json
{
  "name": "opencode",
  "mcp_name": "opencode-delegate",
  "mcp_cmd": ["opencode", "mcp"],
  "role": "code",
  "description": "OpenCode engineering agent.",
  "detect_cmd": "opencode"
}
```

Then re-run `bash install.sh` to register and update routing.
