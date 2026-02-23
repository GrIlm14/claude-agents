# Multi-Agent Pipeline — Shared Protocol

This project uses a multi-agent pipeline coordinated through shared `.context/` files.
Each agent has a dedicated role defined in its own file at `.claude/prompts/ROLE.md`.

**Read your role file first. You must stay within your role at all times.**

---

## Communication Protocol

All inter-agent communication happens through `.context/` files. **Never overwrite log files — always append.**

### File Purposes

| File | Writer(s) | Reader(s) | Purpose |
|------|-----------|-----------|---------|
| `current-task.md` | Manager | All devs, Tester | Active task specification |
| `implementation-log.md` | Coder(s) | Tester, Security, Manager | What was built and where |
| `test-results.md` | Tester | Manager | Test/review findings |
| `security-review.md` | Security | Manager | Security audit findings |
| `docs-log.md` | Docs | Manager | Documentation updates |
| `decisions.md` | Manager | All | Architecture Decision Records |
| `status.md` | All | Orchestrator | Current pipeline state (overwrite) |
| `cycle-count.txt` | Orchestrator | Orchestrator | Completed cycle counter |
| `archive/` | Manager | All | Compressed history |

### Append-Only Log Format

Every entry in a log file MUST follow this exact format:

```markdown
---
## [TIMESTAMP] AGENT_ROLE — Brief Title

**Task**: TASK-XXX
**Status**: STARTED | COMPLETED | BLOCKED | FAILED

Body of the entry here. Be specific and concise.

**Files touched**: list of file paths
**Next**: What should happen next in the pipeline
```

To generate a timestamp, run: `date -u +"%Y-%m-%dT%H:%M:%S"`

### Status Protocol

`status.md` is a **single-line file** that gets overwritten (exception to append rule).
**CRITICAL**: When you finish your work, you MUST update status.md. The pipeline cannot continue without this.

#### Core States:
- `IDLE` — No active work
- `PLANNING:description` — Manager writing spec
- `PLAN_READY` — Spec written, waiting for coder
- `IMPLEMENTING:description` — Coder working
- `CODE_COMPLETE` — Code done, waiting for tester
- `TESTING:description` — Tester reviewing
- `TEST_COMPLETE:PASS` — Tests passed
- `TEST_COMPLETE:FAIL` — Tests failed, needs revision
- `REVISION_NEEDED` — Revised spec ready for coder

#### Extended States (5+ agents):
- `SECURITY_PASS` — Security cleared
- `SECURITY_FAIL` — Security issues found
- `DOCS_COMPLETE` — Documentation updated

#### Skip States (set by Manager or human operator):
- `SKIP_SECURITY` — Skip security review, go to docs
- `SKIP_DOCS` — Skip docs, return to manager
- `SKIP_TO_MANAGER` — Return directly to manager

---

## Token Management Rules

### For Manager:
1. When any `.context/*.md` log file exceeds the configured threshold:
   - Read the full file
   - Write a concise summary to `.context/archive/YYYY-MM-DD-filename.md`
   - Replace the original with only the last N lines plus a header:
     `# [filename] (Trimmed — see .context/archive/ for history)`
2. Apply to: `implementation-log.md`, `test-results.md`, `decisions.md`, `security-review.md`, `docs-log.md`
3. **Never archive**: `current-task.md`, `status.md`, or `cycle-count.txt`

### For All Agents:
- Keep log entries concise — 5-15 lines per entry
- Reference previous entries by timestamp, don't repeat content
- If you need old context, check `.context/archive/`

---

## Git Conventions

- Coders commit after each task: `git commit -m "TASK-XXX: brief description"`
- Tester, Security, and Docs do NOT commit code changes
- Manager commits architecture docs: `git commit -m "ARCH: decision description"`
- Docs writer commits documentation: `git commit -m "DOCS: what was documented"`

---

## Project-Specific Notes

<!-- ═══ EDIT THIS SECTION FOR YOUR PROJECT ═══ -->

**Tech Stack**: <!-- e.g., React + TypeScript, FastAPI, PostgreSQL -->
**Code Style**: <!-- e.g., ESLint + Prettier, Black -->
**Test Framework**: <!-- e.g., Vitest, pytest -->
**Build Command**: <!-- e.g., npm run build -->
**Test Command**: <!-- e.g., npm test, pytest -->
**Lint Command**: <!-- e.g., npm run lint -->
