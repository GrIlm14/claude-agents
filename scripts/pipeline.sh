#!/bin/bash
# ============================================================
#  claude-pipeline v3 — Multi-Agent Pipeline CLI
# ============================================================
#  Commands:
#    start             Launch agents in tmux
#    auto              Launch + auto-orchestrator + control panel
#    resume-auto       Relaunch with context catch-up + auto
#    resume-manual     Relaunch with context catch-up (manual)
#    stop              Kill tmux session and orchestrator
#    pause             Pause the orchestrator
#    unpause           Resume the orchestrator
#    status            Show pipeline state, cycle count, context sizes
#    logs              Tail all context files live
#    clean             Reset .context/ (keeps archive)
#    nuke              Full reset including archive
#    attach            Reattach to tmux session
#    doctor            Run preflight checks
#    help              Show help
#
#  Flags:
#    --debug           Verbose output for troubleshooting
#    --yolo            Enable --dangerously-skip-permissions on all agents
# ============================================================

set -euo pipefail

PROJECT_DIR="$(pwd)"
ENV_FILE="$PROJECT_DIR/pipeline.env"
ORCHESTRATOR_PID_FILE="$PROJECT_DIR/.context/.orchestrator.pid"
PAUSE_FILE="$PROJECT_DIR/.context/.orchestrator.paused"
CYCLE_FILE="$PROJECT_DIR/.context/cycle-count.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse global flags ──────────────────────────────────────
DEBUG=false
YOLO=false
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=true ;;
        --yolo)  YOLO=true ;;
    esac
done

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

log_info()  { echo -e "${GREEN}✅${NC} $1"; }
log_warn()  { echo -e "${YELLOW}⚠️${NC}  $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }
log_step()  { echo -e "${CYAN}──${NC} $1"; }
log_debug() { if $DEBUG; then echo -e "${CYAN}[DEBUG]${NC} $1"; fi; }

# ── Load Configuration ──────────────────────────────────────
load_config() {
    # Defaults
    AGENT_PROFILE="3-agent"
    MODEL_MANAGER="opus"
    MODEL_CODER="sonnet"
    MODEL_TESTER="haiku"
    MODEL_SECURITY="sonnet"
    MODEL_DOCS="haiku"
    MODEL_SENIOR_DEV="sonnet"
    MODEL_JUNIOR_DEV="haiku"
    POLL_INTERVAL=5
    CYCLE_COOLDOWN=30
    MAX_CYCLES=0
    TMUX_LAYOUT="horizontal"
    SESSION_NAME="claude-agents"
    ARCHIVE_THRESHOLD=100
    ARCHIVE_KEEP_LINES=20
    SKIP_PERMISSIONS=false
    CUSTOM_AGENTS=()

    if [ -f "$ENV_FILE" ]; then
        log_debug "Loading config from $ENV_FILE"
        source "$ENV_FILE"
    else
        log_debug "No pipeline.env found, using defaults"
    fi

    # --yolo flag overrides config
    if $YOLO; then
        SKIP_PERMISSIONS=true
    fi

    SESSION="$SESSION_NAME"
    export SESSION_NAME
}

load_config

# ── Agent Profile Definitions ───────────────────────────────
get_agents() {
    case "$AGENT_PROFILE" in
        2-agent)
            echo "manager:$MODEL_MANAGER:Manager / Architect:🏗️"
            echo "coder:$MODEL_CODER:Coder:💻"
            ;;
        3-agent)
            echo "manager:$MODEL_MANAGER:Manager / Architect:🏗️"
            echo "coder:$MODEL_CODER:Coder:💻"
            echo "tester:$MODEL_TESTER:Tester / Reviewer:🧪"
            ;;
        5-agent)
            echo "manager:$MODEL_MANAGER:Manager / Architect:🏗️"
            echo "coder:$MODEL_CODER:Coder:💻"
            echo "tester:$MODEL_TESTER:Tester / Reviewer:🧪"
            echo "security:$MODEL_SECURITY:Security Analyst:🔒"
            echo "docs:$MODEL_DOCS:Docs Writer:📝"
            ;;
        6-agent)
            echo "manager:$MODEL_MANAGER:Manager / Architect:🏗️"
            echo "senior:$MODEL_SENIOR_DEV:Senior Developer:👨‍💻"
            echo "junior:$MODEL_JUNIOR_DEV:Junior Developer:🧑‍💻"
            echo "tester:$MODEL_TESTER:Tester / Reviewer:🧪"
            echo "security:$MODEL_SECURITY:Security Analyst:🔒"
            echo "docs:$MODEL_DOCS:Docs Writer:📝"
            ;;
        custom)
            for agent in "${CUSTOM_AGENTS[@]}"; do
                echo "$agent"
            done
            ;;
        *)
            log_error "Unknown AGENT_PROFILE: $AGENT_PROFILE"
            exit 1
            ;;
    esac
}

get_agent_count() {
    get_agents | wc -l
}

check_prereqs() {
    if [ ! -f ".claude/CLAUDE.md" ]; then
        log_error "No .claude/CLAUDE.md found. Run setup.sh first."
        exit 1
    fi
    if [ ! -d ".context" ]; then
        log_error "No .context/ directory found. Run setup.sh first."
        exit 1
    fi
}

# ── Reliable tmux prompt sender ─────────────────────────────
send_prompt() {
    local target="$1"
    local prompt_text="$2"
    local tmp_file="/tmp/claude-agent-prompt-$$.txt"

    log_debug "Sending prompt to $target: ${prompt_text:0:80}..."

    printf '%s' "$prompt_text" > "$tmp_file"
    tmux load-buffer "$tmp_file"
    tmux paste-buffer -t "$target"
    sleep 1
    tmux send-keys -t "$target" Enter
    rm -f "$tmp_file"
}

# ── Identity Prompt Builder ─────────────────────────────────
# Reads the role file and builds the identity prefix
get_role_prompt() {
    local role="$1"
    local role_file="$PROJECT_DIR/.claude/prompts/${role}.md"

    if [ -f "$role_file" ]; then
        # Use the first paragraph as the identity reminder
        echo "YOUR ROLE: Read .claude/prompts/${role}.md — you are ONLY the ${role}. Stay in your role. Do not perform other agents' work."
    else
        # Fallback to inline identity
        case "$role" in
            manager)  echo "ROLE: You are ONLY the Manager/Architect. You NEVER write code, test code, or do implementation. Your ONLY outputs are task specs and decisions." ;;
            coder)    echo "ROLE: You are ONLY the Coder. Implement the spec. Log to implementation-log.md. Set status to CODE_COMPLETE when done." ;;
            tester)   echo "ROLE: You are ONLY the Tester. Review code and run tests. Report to test-results.md. You MUST set status to TEST_COMPLETE:PASS or TEST_COMPLETE:FAIL." ;;
            security) echo "ROLE: You are ONLY the Security Analyst. Audit for vulnerabilities. Report to security-review.md. You MUST set status to SECURITY_PASS or SECURITY_FAIL." ;;
            docs)     echo "ROLE: You are ONLY the Docs Writer. Update documentation. Log to docs-log.md. You MUST set status to DOCS_COMPLETE." ;;
            senior)   echo "ROLE: You are ONLY the Senior Developer. Implement complex tasks or review junior code." ;;
            junior)   echo "ROLE: You are ONLY the Junior Developer. Implement simple tasks exactly as specified." ;;
            *)        echo "" ;;
        esac
    fi
}

# ── Cycle Counter ───────────────────────────────────────────
get_cycle_count() {
    if [ -f "$CYCLE_FILE" ]; then
        cat "$CYCLE_FILE" | tr -d '[:space:]'
    else
        echo "0"
    fi
}

increment_cycle() {
    local count
    count=$(get_cycle_count)
    echo $((count + 1)) > "$CYCLE_FILE"
}

# ── TMUX Layout Helper ─────────────────────────────────────
apply_layout() {
    local target_window="${1:-${SESSION}:0}"
    case "$TMUX_LAYOUT" in
        horizontal) tmux select-layout -t "$target_window" even-horizontal ;;
        vertical)   tmux select-layout -t "$target_window" even-vertical ;;
        tiled)      tmux select-layout -t "$target_window" tiled ;;
        *)          tmux select-layout -t "$target_window" even-horizontal ;;
    esac
}

# ── Claude Code launch command ──────────────────────────────
get_claude_cmd() {
    local model="$1"
    local cmd="claude --model $model"
    if $SKIP_PERMISSIONS; then
        cmd="$cmd --dangerously-skip-permissions"
    fi
    echo "$cmd"
}

# ── DOCTOR ──────────────────────────────────────────────────
cmd_doctor() {
    echo ""
    echo -e "${BOLD}🩺 Pipeline Doctor — Preflight Checks${NC}"
    echo ""

    local issues=0

    # Check tmux
    if command -v tmux &>/dev/null; then
        local tmux_ver
        tmux_ver=$(tmux -V 2>/dev/null || echo "unknown")
        log_info "tmux: installed ($tmux_ver)"

        # Check base-index
        local base_idx
        base_idx=$(tmux show-options -g base-index 2>/dev/null | awk '{print $2}' || echo "unknown")
        if [ "$base_idx" = "0" ]; then
            log_info "tmux base-index: 0 (correct)"
        else
            log_error "tmux base-index: $base_idx (should be 0)"
            echo "       Fix: echo 'set -g base-index 0' >> ~/.tmux.conf && tmux kill-server"
            issues=$((issues + 1))
        fi

        local pane_base
        pane_base=$(tmux show-options -g pane-base-index 2>/dev/null | awk '{print $2}' || echo "unknown")
        if [ "$pane_base" = "0" ]; then
            log_info "tmux pane-base-index: 0 (correct)"
        else
            log_error "tmux pane-base-index: $pane_base (should be 0)"
            echo "       Fix: echo 'set -g pane-base-index 0' >> ~/.tmux.conf && tmux kill-server"
            issues=$((issues + 1))
        fi
    else
        log_error "tmux: not installed"
        echo "       Fix: sudo apt install tmux"
        issues=$((issues + 1))
    fi

    # Check Node.js
    if command -v node &>/dev/null; then
        local node_ver
        node_ver=$(node --version)
        local node_major
        node_major=$(echo "$node_ver" | sed 's/v//' | cut -d. -f1)
        if [ "$node_major" -ge 18 ]; then
            log_info "Node.js: $node_ver (OK)"
        else
            log_warn "Node.js: $node_ver (recommend 18+)"
        fi
    else
        log_error "Node.js: not installed"
        echo "       Fix: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs"
        issues=$((issues + 1))
    fi

    # Check Claude Code
    if command -v claude &>/dev/null; then
        log_info "Claude Code: installed"
    else
        log_error "Claude Code: not installed"
        echo "       Fix: npm install -g @anthropic-ai/claude-code"
        issues=$((issues + 1))
    fi

    # Check project structure
    echo ""
    echo -e "${BOLD}Project Structure:${NC}"

    if [ -f ".claude/CLAUDE.md" ]; then
        log_info ".claude/CLAUDE.md exists"
    else
        log_warn ".claude/CLAUDE.md missing — run setup.sh"
        issues=$((issues + 1))
    fi

    if [ -d ".claude/prompts" ]; then
        local prompt_count
        prompt_count=$(find .claude/prompts -name "*.md" | wc -l)
        log_info ".claude/prompts/ exists ($prompt_count role files)"
    else
        log_warn ".claude/prompts/ missing — run setup.sh"
        issues=$((issues + 1))
    fi

    if [ -d ".context" ]; then
        log_info ".context/ exists"
    else
        log_warn ".context/ missing — run setup.sh"
        issues=$((issues + 1))
    fi

    if [ -f "pipeline.env" ]; then
        log_info "pipeline.env exists (profile: $AGENT_PROFILE)"
    else
        log_warn "pipeline.env missing — run setup.sh"
        issues=$((issues + 1))
    fi

    # Check status file
    if [ -f ".context/status.md" ]; then
        local status
        status=$(head -1 .context/status.md | tr -d '[:space:]')
        log_info "Pipeline status: $status"
    fi

    # Check permissions setting
    echo ""
    echo -e "${BOLD}Configuration:${NC}"
    echo "  Agent profile: $AGENT_PROFILE ($(get_agent_count) agents)"
    echo "  Layout: $TMUX_LAYOUT"
    echo "  Cooldown: ${CYCLE_COOLDOWN}s"
    echo "  Max cycles: $MAX_CYCLES"
    if $SKIP_PERMISSIONS; then
        log_warn "Skip permissions: ${YELLOW}ENABLED${NC} (agents auto-accept all operations)"
    else
        log_info "Skip permissions: disabled"
    fi

    # Summary
    echo ""
    if [ "$issues" -eq 0 ]; then
        log_info "${GREEN}All checks passed!${NC}"
    else
        log_error "${RED}$issues issue(s) found. Fix them before running the pipeline.${NC}"
    fi
    echo ""
}

# ── START ───────────────────────────────────────────────────
cmd_start() {
    check_prereqs

    local agent_count
    agent_count=$(get_agent_count)
    local no_attach=false
    local with_panel=false

    for arg in "$@"; do
        case "$arg" in
            --no-attach) no_attach=true ;;
            --panel)     with_panel=true ;;
        esac
    done

    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 0.5

    echo ""
    echo -e "${BOLD}🤖 Launching Multi-Agent Pipeline${NC}"
    echo -e "   Project:  ${CYAN}$(basename "$PROJECT_DIR")${NC}"
    echo -e "   Profile:  ${CYAN}$AGENT_PROFILE${NC} ($agent_count agents)"
    echo -e "   Layout:   ${CYAN}$TMUX_LAYOUT${NC}"
    if $SKIP_PERMISSIONS; then
        echo -e "   Perms:    ${YELLOW}--dangerously-skip-permissions ENABLED${NC}"
    fi
    echo ""

    # Create session with first pane
    tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR"
    sleep 1
    log_debug "Created tmux session: $SESSION"

    # Create additional agent panes
    local i=1
    while [ $i -lt "$agent_count" ]; do
        tmux split-window -h -t "${SESSION}:0" -c "$PROJECT_DIR"
        sleep 0.5
        log_debug "Created pane $i"
        i=$((i + 1))
    done

    # Apply layout to agent panes
    apply_layout "${SESSION}:0"
    sleep 0.5

    # Launch Claude Code in each agent pane FIRST
    local pane_idx=0
    local claude_cmd
    while IFS=: read -r role model label emoji; do
        claude_cmd=$(get_claude_cmd "$model")
        log_debug "Launching pane $pane_idx: $role ($model) cmd: $claude_cmd"

        tmux send-keys -t "${SESSION}:0.${pane_idx}" "clear" Enter
        sleep 0.3
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo ''" Enter
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo '  $emoji ═══════════════════════════════════'" Enter
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo '  $emoji  ${label^^}'" Enter
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo '  $emoji  Model: $model'" Enter
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo '  $emoji  Role: $role'" Enter
        if $SKIP_PERMISSIONS; then
            tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo '  $emoji  Perms: AUTO-ACCEPT'" Enter
        fi
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo '  $emoji ═══════════════════════════════════'" Enter
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "echo ''" Enter
        sleep 0.3
        tmux send-keys -t "${SESSION}:0.${pane_idx}" "$claude_cmd" Enter
        pane_idx=$((pane_idx + 1))
    done < <(get_agents)

    # Initialize cycle counter
    if [ ! -f "$CYCLE_FILE" ]; then
        echo "0" > "$CYCLE_FILE"
    fi

    # Record start time for watchdog
    date +%s > /tmp/claude-last-status-change

    # Create control panel as full-width bottom pane AFTER agents are set up
    if $with_panel; then
        # Select the first pane, then split the entire window vertically
        # This creates a full-width pane at the bottom
        tmux select-pane -t "${SESSION}:0.0"
        tmux split-window -v -f -t "${SESSION}:0.0" -c "$PROJECT_DIR" -l 12
        sleep 0.5

        # The new pane is now the last one
        local panel_pane=$agent_count
        log_debug "Created control panel at pane $panel_pane"

        local panel_script="$PROJECT_DIR/.claude/control-panel.sh"
        if [ -f "$panel_script" ]; then
            tmux send-keys -t "${SESSION}:0.${panel_pane}" "bash $panel_script" Enter
        else
            tmux send-keys -t "${SESSION}:0.${panel_pane}" "echo 'Control panel not found at $panel_script'" Enter
        fi
    fi

    log_info "Agents launched in tmux session: $SESSION"
    echo ""

    if ! $no_attach; then
        tmux attach -t "$SESSION"
    fi
}

# ── RESUME ──────────────────────────────────────────────────
cmd_resume() {
    local mode="${1:-auto}"
    check_prereqs

    local start_args="--no-attach"
    if [ "$mode" = "auto" ]; then
        start_args="$start_args --panel"
    fi

    cmd_start $start_args

    echo ""
    echo -e "${BOLD}📖 Sending catch-up prompts to all agents...${NC}"
    echo ""

    local agent_count
    agent_count=$(get_agent_count)
    local wait_time=$((agent_count * 5 + 5))
    echo "   Waiting ${wait_time}s for all agents to load..."
    sleep "$wait_time"

    local pane_idx=0
    while IFS=: read -r role model label emoji; do
        local identity
        identity=$(get_role_prompt "$role")
        local catchup_prompt="$identity You are resuming a previous session. Read .claude/CLAUDE.md for the shared protocol, then read .claude/prompts/${role}.md for your specific role. Then read .context/status.md and .context/current-task.md to see where we left off."

        case "$role" in
            manager)
                catchup_prompt="$catchup_prompt Also read .context/decisions.md, .context/implementation-log.md, and .context/test-results.md for project history. Continue from the current state — write the next task spec or address pending feedback. Do NOT implement anything yourself."
                ;;
            coder|senior|junior)
                catchup_prompt="$catchup_prompt Also read .context/implementation-log.md for recent work. If status is PLAN_READY, start implementing."
                ;;
            tester)
                catchup_prompt="$catchup_prompt Also read .context/test-results.md for history. If status is CODE_COMPLETE, start reviewing. Remember to set TEST_COMPLETE:PASS or TEST_COMPLETE:FAIL when done."
                ;;
            security)
                catchup_prompt="$catchup_prompt Also read .context/security-review.md for history. If status is TEST_COMPLETE:PASS, start security review. You MUST set SECURITY_PASS or SECURITY_FAIL when done."
                ;;
            docs)
                catchup_prompt="$catchup_prompt Also read .context/docs-log.md for history. If status is SECURITY_PASS or SKIP_SECURITY, update documentation. Set DOCS_COMPLETE when done."
                ;;
        esac

        log_step "Sending catch-up to $label (pane $pane_idx)..."
        log_debug "Prompt: ${catchup_prompt:0:100}..."
        send_prompt "${SESSION}:0.${pane_idx}" "$catchup_prompt"
        sleep 2

        pane_idx=$((pane_idx + 1))
    done < <(get_agents)

    log_info "All agents caught up!"
    echo ""

    if [ "$mode" = "auto" ]; then
        _start_orchestrator
        log_info "Auto-orchestrator started"
        echo "   Logs: tail -f /tmp/claude-orchestrator.log"
    else
        echo "   Manual mode — trigger agents yourself."
    fi

    echo ""
    tmux attach -t "$SESSION"
}

# ── AUTO-ORCHESTRATE ────────────────────────────────────────
cmd_auto() {
    check_prereqs

    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        cmd_start --no-attach --panel
    fi

    _start_orchestrator

    echo ""
    log_info "Auto-orchestrator running"
    echo "   Logs: tail -f /tmp/claude-orchestrator.log"
    echo ""

    tmux attach -t "$SESSION"
}

_start_orchestrator() {
    if [ -f "$ORCHESTRATOR_PID_FILE" ]; then
        kill "$(cat "$ORCHESTRATOR_PID_FILE")" 2>/dev/null || true
        rm -f "$ORCHESTRATOR_PID_FILE"
    fi
    rm -f "$PAUSE_FILE"

    _run_orchestrator &
    local ORCH_PID=$!
    echo "$ORCH_PID" > "$ORCHESTRATOR_PID_FILE"
    log_debug "Orchestrator started with PID: $ORCH_PID"
}

_run_orchestrator() {
    local STATUS_FILE="$PROJECT_DIR/.context/status.md"
    local LAST_STATUS=""
    local LOG_FILE="/tmp/claude-orchestrator.log"

    echo "[$(date '+%H:%M:%S')] Orchestrator started for: $PROJECT_DIR" > "$LOG_FILE"
    echo "[$(date '+%H:%M:%S')] Profile: $AGENT_PROFILE | Cooldown: ${CYCLE_COOLDOWN}s | Max: $MAX_CYCLES | Yolo: $SKIP_PERMISSIONS" >> "$LOG_FILE"

    while true; do
        if [ -f "$PAUSE_FILE" ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        if [ ! -f "$STATUS_FILE" ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        CURRENT_STATUS=$(head -1 "$STATUS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^`//;s/`$//;s/^"//;s/"$//;s/^#* *//' | tr -d '\r\n')

        if [ "$CURRENT_STATUS" = "$LAST_STATUS" ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        echo "[$(date '+%H:%M:%S')] Status: $LAST_STATUS → $CURRENT_STATUS" >> "$LOG_FILE"
        LAST_STATUS="$CURRENT_STATUS"

        # Update watchdog timestamp
        date +%s > /tmp/claude-last-status-change

        case "$AGENT_PROFILE" in
            2-agent) _orchestrate_2agent "$CURRENT_STATUS" "$LOG_FILE" ;;
            3-agent) _orchestrate_3agent "$CURRENT_STATUS" "$LOG_FILE" ;;
            5-agent) _orchestrate_5agent "$CURRENT_STATUS" "$LOG_FILE" ;;
            6-agent) _orchestrate_6agent "$CURRENT_STATUS" "$LOG_FILE" ;;
            custom)  _orchestrate_3agent "$CURRENT_STATUS" "$LOG_FILE" ;;
        esac

        sleep "$POLL_INTERVAL"
    done
}

# ── Orchestrator prompt helper ──────────────────────────────
trigger_agent() {
    local pane="$1"
    local role="$2"
    local task_prompt="$3"
    local log="$4"

    local identity
    identity=$(get_role_prompt "$role")
    send_prompt "${SESSION}:0.${pane}" "$identity $task_prompt"
}

# ── 2-Agent Orchestration ──────────────────────────────────
_orchestrate_2agent() {
    local status="$1"
    local log="$2"

    case "$status" in
        PLAN_READY)
            echo "[$(date '+%H:%M:%S')] → Triggering Coder" >> "$log"
            trigger_agent 1 "coder" "A new task is ready. Read .claude/prompts/coder.md for your role. Read .context/current-task.md and implement the spec exactly. Log to .context/implementation-log.md. Set status to CODE_COMPLETE when done." "$log"
            ;;
        CODE_COMPLETE)
            _apply_cooldown "$log"
            increment_cycle
            local count=$(get_cycle_count)
            echo "[$(date '+%H:%M:%S')] ✅ Cycle $count → Triggering Manager" >> "$log"
            _check_max_cycles "$count" "$log"
            trigger_agent 0 "manager" "Code complete (cycle $count). Read .claude/prompts/manager.md for your role. Review .context/implementation-log.md. Write the next task spec to .context/current-task.md and set PLAN_READY. Do NOT implement anything. Archive logs over $ARCHIVE_THRESHOLD lines." "$log"
            ;;
        IDLE) echo "[$(date '+%H:%M:%S')] Pipeline idle" >> "$log" ;;
        PLANNING:*|IMPLEMENTING:*) echo "[$(date '+%H:%M:%S')] Working: $status" >> "$log" ;;
    esac
}

# ── 3-Agent Orchestration ──────────────────────────────────
_orchestrate_3agent() {
    local status="$1"
    local log="$2"

    case "$status" in
        PLAN_READY)
            echo "[$(date '+%H:%M:%S')] → Triggering Coder" >> "$log"
            trigger_agent 1 "coder" "A new task is ready. Read .claude/prompts/coder.md for your role. Read .context/current-task.md and implement exactly. Log to .context/implementation-log.md. Set status to CODE_COMPLETE when done." "$log"
            ;;
        CODE_COMPLETE)
            echo "[$(date '+%H:%M:%S')] → Triggering Tester" >> "$log"
            trigger_agent 2 "tester" "Code ready. Read .claude/prompts/tester.md for your role. Read .context/implementation-log.md for changes. Test against spec in .context/current-task.md. Write to .context/test-results.md. You MUST set TEST_COMPLETE:PASS or TEST_COMPLETE:FAIL." "$log"
            ;;
        TEST_COMPLETE:PASS)
            _apply_cooldown "$log"
            increment_cycle
            local count=$(get_cycle_count)
            echo "[$(date '+%H:%M:%S')] ✅ Cycle $count (PASS) → Manager" >> "$log"
            _check_max_cycles "$count" "$log"
            trigger_agent 0 "manager" "Tests passed (cycle $count). Read .claude/prompts/manager.md. Review .context/test-results.md. Write next task spec or set IDLE. Archive logs over $ARCHIVE_THRESHOLD lines. Do NOT implement anything." "$log"
            ;;
        TEST_COMPLETE:FAIL)
            _apply_cooldown "$log"
            increment_cycle
            local count=$(get_cycle_count)
            echo "[$(date '+%H:%M:%S')] ❌ Cycle $count (FAIL) → Manager" >> "$log"
            _check_max_cycles "$count" "$log"
            trigger_agent 0 "manager" "Tests failed (cycle $count). Read .claude/prompts/manager.md. Read .context/test-results.md. Update .context/current-task.md with fix instructions. Set PLAN_READY. Do NOT fix code yourself." "$log"
            ;;
        REVISION_NEEDED)
            echo "[$(date '+%H:%M:%S')] → Triggering Coder (revision)" >> "$log"
            trigger_agent 1 "coder" "Revisions requested. Read .claude/prompts/coder.md. Re-read .context/current-task.md for updated instructions. Implement fixes. Log to .context/implementation-log.md. Set CODE_COMPLETE." "$log"
            ;;
        IDLE) echo "[$(date '+%H:%M:%S')] Pipeline idle" >> "$log" ;;
        PLANNING:*|IMPLEMENTING:*|TESTING:*) echo "[$(date '+%H:%M:%S')] Working: $status" >> "$log" ;;
    esac
}

# ── 5-Agent Orchestration ──────────────────────────────────
_orchestrate_5agent() {
    local status="$1"
    local log="$2"

    case "$status" in
        PLAN_READY)
            echo "[$(date '+%H:%M:%S')] → Triggering Coder" >> "$log"
            trigger_agent 1 "coder" "New task ready. Read .claude/prompts/coder.md. Read .context/current-task.md and implement. Log to .context/implementation-log.md. Set CODE_COMPLETE." "$log"
            ;;
        CODE_COMPLETE)
            echo "[$(date '+%H:%M:%S')] → Triggering Tester" >> "$log"
            trigger_agent 2 "tester" "Code ready. Read .claude/prompts/tester.md. Review .context/implementation-log.md against spec. Write to .context/test-results.md. MUST set TEST_COMPLETE:PASS or TEST_COMPLETE:FAIL." "$log"
            ;;
        TEST_COMPLETE:PASS)
            echo "[$(date '+%H:%M:%S')] → Triggering Security" >> "$log"
            trigger_agent 3 "security" "Code passed tests. Read .claude/prompts/security.md. Review .context/implementation-log.md for vulnerabilities. Write to .context/security-review.md. MUST set SECURITY_PASS or SECURITY_FAIL. Do NOT set SECURITY_REVIEW." "$log"
            ;;
        TEST_COMPLETE:FAIL)
            echo "[$(date '+%H:%M:%S')] → Manager (tests failed)" >> "$log"
            trigger_agent 0 "manager" "Tests failed. Read .claude/prompts/manager.md. Read .context/test-results.md. Update task spec. Set PLAN_READY. Do NOT fix code." "$log"
            ;;
        SECURITY_PASS)
            echo "[$(date '+%H:%M:%S')] → Triggering Docs" >> "$log"
            trigger_agent 4 "docs" "Security passed. Read .claude/prompts/docs.md. Update documentation from .context/implementation-log.md and .context/decisions.md. Log to .context/docs-log.md. MUST set DOCS_COMPLETE." "$log"
            ;;
        SECURITY_FAIL)
            echo "[$(date '+%H:%M:%S')] → Manager (security failed)" >> "$log"
            trigger_agent 0 "manager" "Security failed. Read .claude/prompts/manager.md. Read .context/security-review.md. Update task spec with fixes. Set PLAN_READY. Do NOT fix code." "$log"
            ;;
        SKIP_SECURITY)
            echo "[$(date '+%H:%M:%S')] → Skipping Security → Triggering Docs" >> "$log"
            trigger_agent 4 "docs" "Security review skipped for this task. Read .claude/prompts/docs.md. Update documentation. Log to .context/docs-log.md. MUST set DOCS_COMPLETE." "$log"
            ;;
        SKIP_DOCS)
            _apply_cooldown "$log"
            increment_cycle
            local count=$(get_cycle_count)
            echo "[$(date '+%H:%M:%S')] ✅ Cycle $count (skip docs) → Manager" >> "$log"
            _check_max_cycles "$count" "$log"
            trigger_agent 0 "manager" "Cycle $count done (docs skipped). Read .claude/prompts/manager.md. Archive logs if needed. Write next task or set IDLE. Do NOT implement." "$log"
            ;;
        SKIP_TO_MANAGER)
            echo "[$(date '+%H:%M:%S')] → Skip to Manager" >> "$log"
            trigger_agent 0 "manager" "Pipeline routed to you directly. Read .claude/prompts/manager.md. Check .context/status.md context and decide next steps. Write task spec or set IDLE." "$log"
            ;;
        DOCS_COMPLETE)
            _apply_cooldown "$log"
            increment_cycle
            local count=$(get_cycle_count)
            echo "[$(date '+%H:%M:%S')] ✅ Cycle $count complete → Manager" >> "$log"
            _check_max_cycles "$count" "$log"
            trigger_agent 0 "manager" "Full cycle $count done. Read .claude/prompts/manager.md. Archive logs over $ARCHIVE_THRESHOLD lines. Write next task spec or set IDLE. Do NOT implement." "$log"
            ;;
        IDLE) echo "[$(date '+%H:%M:%S')] Pipeline idle" >> "$log" ;;
    esac
}

# ── 6-Agent Orchestration ──────────────────────────────────
_orchestrate_6agent() {
    local status="$1"
    local log="$2"

    case "$status" in
        PLAN_READY)
            echo "[$(date '+%H:%M:%S')] → Triggering Senior Dev" >> "$log"
            trigger_agent 1 "senior" "New task. Read .claude/prompts/senior.md. Read .context/current-task.md. If COMPLEX, implement. If SIMPLE, set JUNIOR_IMPLEMENTING. Log to .context/implementation-log.md." "$log"
            ;;
        JUNIOR_IMPLEMENTING*)
            echo "[$(date '+%H:%M:%S')] → Triggering Junior Dev" >> "$log"
            trigger_agent 2 "junior" "Simple task delegated. Read .claude/prompts/junior.md. Read .context/current-task.md. Implement exactly. Log to .context/implementation-log.md. Set SENIOR_REVIEW." "$log"
            ;;
        SENIOR_REVIEW)
            echo "[$(date '+%H:%M:%S')] → Senior Dev reviewing" >> "$log"
            trigger_agent 1 "senior" "Junior code ready. Read .claude/prompts/senior.md. Review .context/implementation-log.md. If good, set CODE_COMPLETE. If needs fixes, set JUNIOR_IMPLEMENTING." "$log"
            ;;
        CODE_COMPLETE)
            echo "[$(date '+%H:%M:%S')] → Triggering Tester" >> "$log"
            trigger_agent 3 "tester" "Code ready. Read .claude/prompts/tester.md. Test and review. Write to .context/test-results.md. MUST set TEST_COMPLETE:PASS or TEST_COMPLETE:FAIL." "$log"
            ;;
        TEST_COMPLETE:PASS)
            echo "[$(date '+%H:%M:%S')] → Triggering Security" >> "$log"
            trigger_agent 4 "security" "Tests passed. Read .claude/prompts/security.md. Audit for vulnerabilities. Write to .context/security-review.md. MUST set SECURITY_PASS or SECURITY_FAIL." "$log"
            ;;
        TEST_COMPLETE:FAIL)
            echo "[$(date '+%H:%M:%S')] → Manager (failed)" >> "$log"
            trigger_agent 0 "manager" "Tests failed. Read .claude/prompts/manager.md. Read .context/test-results.md. Update spec. Set PLAN_READY. Do NOT fix code." "$log"
            ;;
        SECURITY_PASS)
            echo "[$(date '+%H:%M:%S')] → Triggering Docs" >> "$log"
            trigger_agent 5 "docs" "Security passed. Read .claude/prompts/docs.md. Update docs. Log to .context/docs-log.md. MUST set DOCS_COMPLETE." "$log"
            ;;
        SECURITY_FAIL)
            echo "[$(date '+%H:%M:%S')] → Manager (security failed)" >> "$log"
            trigger_agent 0 "manager" "Security failed. Read .claude/prompts/manager.md. Read .context/security-review.md. Update spec. Set PLAN_READY. Do NOT fix code." "$log"
            ;;
        SKIP_SECURITY)
            echo "[$(date '+%H:%M:%S')] → Skip Security → Docs" >> "$log"
            trigger_agent 5 "docs" "Security skipped. Read .claude/prompts/docs.md. Update docs. MUST set DOCS_COMPLETE." "$log"
            ;;
        SKIP_DOCS|SKIP_TO_MANAGER)
            echo "[$(date '+%H:%M:%S')] → Skip to Manager" >> "$log"
            trigger_agent 0 "manager" "Pipeline skipped to you. Read .claude/prompts/manager.md. Decide next steps." "$log"
            ;;
        DOCS_COMPLETE)
            _apply_cooldown "$log"
            increment_cycle
            local count=$(get_cycle_count)
            echo "[$(date '+%H:%M:%S')] ✅ Cycle $count → Manager" >> "$log"
            _check_max_cycles "$count" "$log"
            trigger_agent 0 "manager" "Cycle $count done. Read .claude/prompts/manager.md. Archive logs. Plan next or set IDLE. Do NOT implement." "$log"
            ;;
        IDLE) echo "[$(date '+%H:%M:%S')] Pipeline idle" >> "$log" ;;
    esac
}

# ── Cooldown & Cycle Limits ─────────────────────────────────
_apply_cooldown() {
    local log="$1"
    if [ "$CYCLE_COOLDOWN" -gt 0 ]; then
        echo "[$(date '+%H:%M:%S')] ⏸️  Cooldown: ${CYCLE_COOLDOWN}s..." >> "$log"
        sleep "$CYCLE_COOLDOWN"
    fi
}

_check_max_cycles() {
    local count="$1"
    local log="$2"
    if [ "$MAX_CYCLES" -gt 0 ] && [ "$count" -ge "$MAX_CYCLES" ]; then
        echo "[$(date '+%H:%M:%S')] 🛑 Max cycles ($MAX_CYCLES) reached — pausing" >> "$log"
        touch "$PAUSE_FILE"
        echo "0" > "$CYCLE_FILE"
    fi
}

# ── STOP ────────────────────────────────────────────────────
cmd_stop() {
    echo ""
    echo -e "${BOLD}🛑 Stopping Pipeline${NC}"

    if [ -f "$ORCHESTRATOR_PID_FILE" ]; then
        local PID
        PID=$(cat "$ORCHESTRATOR_PID_FILE")
        if kill "$PID" 2>/dev/null; then
            log_info "Orchestrator stopped (PID: $PID)"
        fi
        rm -f "$ORCHESTRATOR_PID_FILE"
    else
        log_step "No orchestrator running"
    fi

    rm -f "$PAUSE_FILE"

    if tmux kill-session -t "$SESSION" 2>/dev/null; then
        log_info "tmux session '$SESSION' killed"
    else
        log_step "No tmux session running"
    fi
    echo ""
}

# ── PAUSE / UNPAUSE ────────────────────────────────────────
cmd_pause() {
    touch "$PAUSE_FILE"
    log_info "Orchestrator paused. Use 'unpause' to resume."
}

cmd_unpause() {
    rm -f "$PAUSE_FILE"
    log_info "Orchestrator unpaused."
}

# ── STATUS ──────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -e "${BOLD}📊 Pipeline Status${NC}"
    echo ""

    echo -e "   ${BOLD}Configuration:${NC}"
    echo -e "      Profile:  $AGENT_PROFILE ($(get_agent_count) agents)"
    echo -e "      Layout:   $TMUX_LAYOUT"
    echo -e "      Cooldown: ${CYCLE_COOLDOWN}s"
    echo -e "      Max cycles: $([ "$MAX_CYCLES" -gt 0 ] && echo "$MAX_CYCLES" || echo "unlimited")"
    echo -e "      Permissions: $(if $SKIP_PERMISSIONS; then echo "${YELLOW}auto-accept${NC}"; else echo "normal"; fi)"
    echo ""

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        log_info "tmux session: ${GREEN}RUNNING${NC} ($(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l) panes)"
    else
        log_warn "tmux session: ${RED}NOT RUNNING${NC}"
    fi

    if [ -f "$ORCHESTRATOR_PID_FILE" ] && kill -0 "$(cat "$ORCHESTRATOR_PID_FILE")" 2>/dev/null; then
        if [ -f "$PAUSE_FILE" ]; then
            log_warn "Orchestrator: ${YELLOW}PAUSED${NC}"
        else
            log_info "Orchestrator: ${GREEN}RUNNING${NC}"
        fi
    else
        log_step "Orchestrator: not running"
    fi

    local cycles
    cycles=$(get_cycle_count)
    echo ""
    echo -e "   Cycles: ${BOLD}${CYAN}$cycles${NC}"

    if [ -f ".context/status.md" ]; then
        echo -e "   Status: ${BOLD}${CYAN}$(head -1 .context/status.md | tr -d '[:space:]')${NC}"
    fi

    echo ""
    echo -e "   ${BOLD}Context files:${NC}"
    for f in .context/*.md .context/*.txt; do
        if [ -f "$f" ]; then
            local LINES
            LINES=$(wc -l < "$f")
            local WARN=""
            [ "$LINES" -gt "$ARCHIVE_THRESHOLD" ] && WARN=" ${YELLOW}(needs archiving)${NC}"
            echo -e "      $(basename "$f"): ${LINES} lines${WARN}"
        fi
    done

    [ -d ".context/archive" ] && echo "      archive/: $(find .context/archive -name "*.md" 2>/dev/null | wc -l) files"

    echo ""
    echo -e "   ${BOLD}Agents:${NC}"
    local pane_idx=0
    while IFS=: read -r role model label emoji; do
        echo -e "      Pane $pane_idx: $emoji $label ($model)"
        pane_idx=$((pane_idx + 1))
    done < <(get_agents)
    echo ""
}

# ── LOGS ────────────────────────────────────────────────────
cmd_logs() {
    echo -e "${BOLD}📜 Tailing context files (Ctrl+C to stop)${NC}"
    echo ""
    tail -f .context/*.md .context/*.txt 2>/dev/null
}

# ── CLEAN ───────────────────────────────────────────────────
cmd_clean() {
    echo ""
    read -rp "🧹 Reset all .context/ files? Archive will be kept. (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy] ]] && echo "Cancelled." && return

    echo "IDLE" > .context/status.md
    echo "0" > "$CYCLE_FILE"
    echo -e "# Current Task\n\n_No active task._" > .context/current-task.md
    echo -e "# Implementation Log\n\n_Append-only._" > .context/implementation-log.md
    echo -e "# Test Results\n\n_Append-only._" > .context/test-results.md
    echo -e "# Architecture Decisions\n\n_Append-only._" > .context/decisions.md
    echo -e "# Security Review\n\n_Append-only._" > .context/security-review.md
    echo -e "# Documentation Log\n\n_Append-only._" > .context/docs-log.md
    rm -f "$PAUSE_FILE" "$ORCHESTRATOR_PID_FILE"

    log_info "Context files reset."
    echo ""
}

# ── NUKE ────────────────────────────────────────────────────
cmd_nuke() {
    echo ""
    echo -e "${RED}${BOLD}⚠️  This will delete ALL context including archives.${NC}"
    read -rp "Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" != "yes" ] && echo "Cancelled." && return

    cmd_stop
    rm -rf .context/archive/*
    cmd_clean
    log_info "Full reset complete."
    echo ""
}

# ── ATTACH ──────────────────────────────────────────────────
cmd_attach() {
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux attach -t "$SESSION"
    else
        log_error "No active session. Run: ./claude-pipeline start"
    fi
}

# ── HELP ────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo -e "${BOLD}claude-pipeline v3${NC} — Multi-Agent Claude Code Pipeline"
    echo ""
    echo "Commands:"
    echo -e "  ${GREEN}start${NC}             Launch agents in tmux"
    echo -e "  ${GREEN}auto${NC}              Launch + orchestrator + control panel"
    echo -e "  ${GREEN}resume-auto${NC}       Restart with catch-up + auto"
    echo -e "  ${GREEN}resume-manual${NC}     Restart with catch-up (manual)"
    echo -e "  ${GREEN}stop${NC}              Kill everything"
    echo -e "  ${GREEN}pause${NC}             Pause orchestrator"
    echo -e "  ${GREEN}unpause${NC}           Resume orchestrator"
    echo -e "  ${GREEN}status${NC}            Show pipeline state"
    echo -e "  ${GREEN}logs${NC}              Tail context files"
    echo -e "  ${GREEN}attach${NC}            Reattach to tmux"
    echo -e "  ${GREEN}clean${NC}             Reset context (keeps archive)"
    echo -e "  ${GREEN}nuke${NC}              Full reset"
    echo -e "  ${GREEN}doctor${NC}            Run preflight checks"
    echo -e "  ${GREEN}help${NC}              Show this help"
    echo ""
    echo "Flags:"
    echo -e "  ${YELLOW}--debug${NC}           Verbose output"
    echo -e "  ${YELLOW}--yolo${NC}            Auto-accept all agent permissions"
    echo ""
    echo "Profiles: 2-agent, 3-agent, 5-agent, 6-agent, custom"
    echo "Config:   pipeline.env"
    echo ""
}

# ── MAIN ────────────────────────────────────────────────────
# Strip flags from args for command parsing
CMD="${1:-help}"
case "$CMD" in
    start)          shift; cmd_start "$@" ;;
    auto)           cmd_auto ;;
    resume-auto)    cmd_resume "auto" ;;
    resume-manual)  cmd_resume "manual" ;;
    stop)           cmd_stop ;;
    pause)          cmd_pause ;;
    unpause)        cmd_unpause ;;
    status)         cmd_status ;;
    logs)           cmd_logs ;;
    attach)         cmd_attach ;;
    clean)          cmd_clean ;;
    nuke)           cmd_nuke ;;
    doctor)         cmd_doctor ;;
    help|-h|--help) cmd_help ;;
    *)
        log_error "Unknown command: $CMD"
        cmd_help
        exit 1
        ;;
esac
