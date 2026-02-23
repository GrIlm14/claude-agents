# 🤖 claude-agents — Drop-In Multi-Agent Pipeline for Claude Code

A portable toolkit that turns any project into a coordinated team of AI agents with a single command. No frameworks, no dependencies — just bash, tmux, and markdown.

## What It Does

Runs multiple Claude Code instances in tmux panes, each with a dedicated role. Agents communicate through shared markdown files using an append-only protocol. An auto-orchestrator watches pipeline state and triggers each agent automatically.

## Agent Profiles

| Profile | Agents | Best For |
|---------|--------|----------|
| **2-agent** | Manager + Coder | Simple projects, saving costs |
| **3-agent** | Manager + Coder + Tester | Standard development (default) |
| **5-agent** | Manager + Coder + Tester + Security + Docs | Production-grade development |
| **6-agent** | Manager + Senior Dev + Junior Dev + Tester + Security + Docs | Team simulation |

Every role's model is configurable — use Opus for planning, Sonnet for coding, Haiku for testing, or any combination.

## Quick Start

### Install (one line)

```bash
git clone https://github.com/GrIlm14/claude-agents.git ~/claude-agents && chmod +x ~/claude-agents/setup.sh ~/claude-agents/scripts/pipeline.sh
```

### Set Up a Project

```bash
cd /path/to/any/project
~/claude-agents/setup.sh       # Creates config files
nano pipeline.env              # Optional: change agents/models/layout
./claude-pipeline auto         # Launch and go
```

That's it. Three panes open. Tell the Manager what to build. The orchestrator handles the rest.

## Prerequisites

- WSL2 (Ubuntu) on Windows, or native Linux/macOS
- tmux: `sudo apt install tmux`
- Node.js 18+: `curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs`
- Claude Code: `npm install -g @anthropic-ai/claude-code`
- Claude Pro/Max subscription or `ANTHROPIC_API_KEY`
- tmux base-index set to 0: `echo "set -g base-index 0" >> ~/.tmux.conf && echo "set -g pane-base-index 0" >> ~/.tmux.conf`

## Commands

| Command | Description |
|---------|-------------|
| `./claude-pipeline start` | Launch agents in tmux |
| `./claude-pipeline auto` | Launch + auto-orchestrator (hands-free) |
| `./claude-pipeline resume-auto` | Restart with context catch-up + auto-orchestrate |
| `./claude-pipeline resume-manual` | Restart with context catch-up (manual triggers) |
| `./claude-pipeline stop` | Kill everything |
| `./claude-pipeline pause` | Pause orchestrator (agents stay running) |
| `./claude-pipeline unpause` | Resume orchestrator |
| `./claude-pipeline status` | Show pipeline state, cycle count, context sizes |
| `./claude-pipeline logs` | Tail all context files live |
| `./claude-pipeline attach` | Reattach to tmux session |
| `./claude-pipeline clean` | Reset context files (keeps archive) |
| `./claude-pipeline nuke` | Full reset including archive |

## Configuration (pipeline.env)

All settings live in one file — `pipeline.env` in your project root:

```bash
# Agent profile: 2-agent, 3-agent, 5-agent, 6-agent, custom
AGENT_PROFILE="3-agent"

# Model per role (use aliases: opus, sonnet, haiku)
MODEL_MANAGER="opus"
MODEL_CODER="sonnet"
MODEL_TESTER="haiku"
MODEL_SECURITY="sonnet"
MODEL_DOCS="haiku"
MODEL_SENIOR_DEV="sonnet"
MODEL_JUNIOR_DEV="haiku"

# Rate limiting
CYCLE_COOLDOWN=30        # Seconds between cycles
MAX_CYCLES=0             # 0 = unlimited, or set a number to auto-pause

# Layout: horizontal, vertical, tiled
TMUX_LAYOUT="horizontal"
```

## How the Pipeline Flows

### 3-Agent (default)
```
You give Manager a goal
       │
       ▼
  Manager plans ──► Coder implements ──► Tester reviews
       ▲                                      │
       └──────────── feedback loop ◄──────────┘
```

### 5-Agent
```
  Manager ──► Coder ──► Tester ──► Security ──► Docs ──► Manager
```

### 6-Agent
```
  Manager ──► Senior Dev ──┬──► Tester ──► Security ──► Docs ──► Manager
              Junior Dev ◄─┘
```

## Stopping and Resuming

Your work persists in `.context/` files. When you need to stop and come back later:

```bash
./claude-pipeline stop           # Stop everything

# Later...
./claude-pipeline resume-auto    # Agents restart and catch up on context
```

Resume mode sends each agent a catch-up prompt that tells them to read the context files and continue from where the last session ended.

## File Structure

```
your-project/
├── .claude/
│   └── CLAUDE.md               ← Agent roles & communication protocol
├── .context/
│   ├── status.md               ← Pipeline state (watched by orchestrator)
│   ├── current-task.md         ← Active task spec
│   ├── implementation-log.md   ← Code changelog (append-only)
│   ├── test-results.md         ← Test findings (append-only)
│   ├── security-review.md      ← Security findings (append-only)
│   ├── docs-log.md             ← Documentation updates (append-only)
│   ├── decisions.md            ← Architecture decisions (append-only)
│   ├── cycle-count.txt         ← Completed cycle counter
│   └── archive/                ← Summarized old logs
├── pipeline.env                ← Configuration
└── claude-pipeline             ← CLI tool
```

## Token Cost Optimization

The architecture minimizes expensive model usage:

| Strategy | How |
|----------|-----|
| Opus only plans | Manager never writes code — just specs and reviews |
| Haiku for testing | Cheapest model handles the most repetitive work |
| Auto-archiving | Logs over 100 lines get summarized, keeping context small |
| Cycle cooldowns | Configurable pause between cycles to respect rate limits |
| Max cycle limits | Auto-pause after N cycles to prevent runaway token burn |
| Append-only logs | Agents reference by timestamp instead of duplicating content |

## Contributing

This is an open-source project and contributions are welcome! Some areas where help would be appreciated:

- **Testing on macOS/Linux** — Built and tested on WSL2, would love confirmation on native Linux and macOS
- **Additional agent profiles** — Got ideas for new team compositions? Open a PR
- **Rate limit detection** — Smarter awareness of Claude Code usage limits
- **MCP integration** — Connecting agents to external tools via Model Context Protocol
- **Web dashboard** — A browser UI to monitor pipeline state instead of terminal logs

Feel free to open issues, submit PRs, or fork and experiment. Let's build this together.

## tmux Cheat Sheet

| Action | Keys |
|--------|------|
| Navigate panes | `Ctrl+B` then arrow keys |
| Zoom one pane | `Ctrl+B` then `z` |
| Detach (keeps running) | `Ctrl+B` then `d` |
| Scroll up | `Ctrl+B` then `[` (q to exit) |

## License

MIT
