#!/bin/bash
# ============================================================
#  claude-pipeline — Control Panel
#  Runs in a tmux pane for live monitoring and manual control
# ============================================================

set -uo pipefail

PROJECT_DIR="$(pwd)"
ENV_FILE="$PROJECT_DIR/pipeline.env"
STATUS_FILE="$PROJECT_DIR/.context/status.md"
CYCLE_FILE="$PROJECT_DIR/.context/cycle-count.txt"
PAUSE_FILE="$PROJECT_DIR/.context/.orchestrator.paused"
ORCH_LOG="/tmp/claude-orchestrator.log"
LAST_CHANGE_FILE="/tmp/claude-last-status-change"
SESSION="${SESSION_NAME:-claude-agents}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Load config
AGENT_PROFILE="3-agent"
WATCHDOG_WARN=300    # 5 minutes
WATCHDOG_CRIT=600    # 10 minutes
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Track last status change time
update_change_time() {
    date +%s > "$LAST_CHANGE_FILE"
}

get_seconds_since_change() {
    if [ -f "$LAST_CHANGE_FILE" ]; then
        local last
        last=$(cat "$LAST_CHANGE_FILE")
        local now
        now=$(date +%s)
        echo $((now - last))
    else
        update_change_time
        echo "0"
    fi
}

format_duration() {
    local secs=$1
    if [ "$secs" -lt 60 ]; then
        echo "${secs}s"
    elif [ "$secs" -lt 3600 ]; then
        echo "$((secs / 60))m $((secs % 60))s"
    else
        echo "$((secs / 3600))h $((secs % 3600 / 60))m"
    fi
}

# Get current status
get_status() {
    if [ -f "$STATUS_FILE" ]; then
        head -1 "$STATUS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^`//;s/`$//;s/^"//;s/"$//;s/^#* *//' | tr -d '\r\n'
    else
        echo "NO_STATUS_FILE"
    fi
}

get_cycles() {
    if [ -f "$CYCLE_FILE" ]; then
        cat "$CYCLE_FILE" | tr -d '[:space:]'
    else
        echo "0"
    fi
}

is_paused() {
    [ -f "$PAUSE_FILE" ]
}

# Get agent list for current profile
get_agent_labels() {
    case "$AGENT_PROFILE" in
        2-agent) echo "1:Manager 2:Coder" ;;
        3-agent) echo "1:Manager 2:Coder 3:Tester" ;;
        5-agent) echo "1:Manager 2:Coder 3:Tester 4:Security 5:Docs" ;;
        6-agent) echo "1:Manager 2:Senior 3:Junior 4:Tester 5:Security 6:Docs" ;;
        *) echo "1:Manager 2:Coder 3:Tester" ;;
    esac
}

get_expected_next() {
    local status="$1"
    case "$AGENT_PROFILE" in
        3-agent)
            case "$status" in
                PLAN_READY) echo "Coder" ;;
                CODE_COMPLETE) echo "Tester" ;;
                TEST_COMPLETE:PASS) echo "Manager" ;;
                TEST_COMPLETE:FAIL) echo "Manager" ;;
                *) echo "-" ;;
            esac
            ;;
        5-agent)
            case "$status" in
                PLAN_READY) echo "Coder" ;;
                CODE_COMPLETE) echo "Tester" ;;
                TEST_COMPLETE:PASS) echo "Security" ;;
                TEST_COMPLETE:FAIL) echo "Manager" ;;
                SECURITY_PASS) echo "Docs" ;;
                SECURITY_FAIL) echo "Manager" ;;
                DOCS_COMPLETE) echo "Manager" ;;
                SKIP_SECURITY) echo "Docs" ;;
                SKIP_DOCS) echo "Manager" ;;
                *) echo "-" ;;
            esac
            ;;
        *) echo "-" ;;
    esac
}

# Send prompt to agent pane (reuse the reliable method)
send_to_agent() {
    local pane_idx="$1"
    local prompt="$2"
    local tmp_file="/tmp/claude-control-prompt-$$.txt"

    printf '%s' "$prompt" > "$tmp_file"
    tmux load-buffer "$tmp_file"
    tmux paste-buffer -t "${SESSION}:0.${pane_idx}"
    sleep 1
    tmux send-keys -t "${SESSION}:0.${pane_idx}" Enter
    rm -f "$tmp_file"
}

# Get pane index for role name
role_to_pane() {
    local target="$1"
    case "$AGENT_PROFILE" in
        2-agent)
            case "$target" in
                manager|1) echo 0 ;; coder|2) echo 1 ;;
            esac ;;
        3-agent)
            case "$target" in
                manager|1) echo 0 ;; coder|2) echo 1 ;; tester|3) echo 2 ;;
            esac ;;
        5-agent)
            case "$target" in
                manager|1) echo 0 ;; coder|2) echo 1 ;; tester|3) echo 2 ;;
                security|4) echo 3 ;; docs|5) echo 4 ;;
            esac ;;
        6-agent)
            case "$target" in
                manager|1) echo 0 ;; senior|2) echo 1 ;; junior|3) echo 2 ;;
                tester|4) echo 3 ;; security|5) echo 4 ;; docs|6) echo 5 ;;
            esac ;;
    esac
}

# ── Draw the display ────────────────────────────────────────
draw_panel() {
    clear
    local status
    status=$(get_status)
    local cycles
    cycles=$(get_cycles)
    local elapsed
    elapsed=$(get_seconds_since_change)
    local elapsed_fmt
    elapsed_fmt=$(format_duration "$elapsed")
    local next
    next=$(get_expected_next "$status")

    # Watchdog color
    local time_color="$GREEN"
    local time_icon="⏱️"
    if [ "$elapsed" -ge "$WATCHDOG_CRIT" ]; then
        time_color="$RED"
        time_icon="🚨"
    elif [ "$elapsed" -ge "$WATCHDOG_WARN" ]; then
        time_color="$YELLOW"
        time_icon="⚠️"
    fi

    # Pause state
    local pause_indicator=""
    if is_paused; then
        pause_indicator="${YELLOW} [PAUSED]${NC}"
    fi

    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}  ${MAGENTA}🎛️  PIPELINE CONTROL PANEL${NC}${pause_indicator}                              ${BOLD}║${NC}"
    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Status: ${CYAN}${BOLD}$status${NC}"
    echo -e "${BOLD}║${NC}  Next:   ${CYAN}$next${NC}    Cycle: ${CYAN}$cycles${NC}    Elapsed: ${time_color}${time_icon} ${elapsed_fmt}${NC}"
    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════╣${NC}"

    # Agent buttons
    local labels
    labels=$(get_agent_labels)
    echo -ne "${BOLD}║${NC}  "
    for label in $labels; do
        local num="${label%%:*}"
        local name="${label##*:}"
        echo -ne "[${GREEN}${num}${NC}] ${name}  "
    done
    echo ""

    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  [${GREEN}s${NC}] Skip next   [${GREEN}m${NC}] Set status   [${GREEN}c${NC}] Custom prompt      ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  [${GREEN}p${NC}] Pause/Resume [${GREEN}r${NC}] Re-trigger   [${GREEN}l${NC}] View log           ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  [${GREEN}q${NC}] Exit panel                                             ${BOLD}║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"

    if [ "$elapsed" -ge "$WATCHDOG_WARN" ]; then
        echo ""
        echo -e "${time_color}${BOLD}  ⚠️  Agent may be stuck — no status change for ${elapsed_fmt}${NC}"
        echo -e "${DIM}  Press [r] to re-trigger or [m] to set status manually${NC}"
    fi

    echo ""
    echo -ne "${DIM}  Press a key...${NC} "
}

# ── Handle skip ─────────────────────────────────────────────
handle_skip() {
    local status
    status=$(get_status)
    local skip_to=""

    case "$AGENT_PROFILE" in
        5-agent)
            case "$status" in
                TEST_COMPLETE:PASS)
                    skip_to="SKIP_SECURITY"
                    echo -e "  Skipping Security → routing to Docs"
                    ;;
                SECURITY_PASS)
                    skip_to="SKIP_DOCS"
                    echo -e "  Skipping Docs → routing to Manager"
                    ;;
                *)
                    echo -e "  ${YELLOW}Nothing to skip at current status${NC}"
                    sleep 2
                    return
                    ;;
            esac
            ;;
        3-agent)
            case "$status" in
                CODE_COMPLETE)
                    skip_to="TEST_COMPLETE:PASS"
                    echo -e "  Skipping Tester → routing to Manager"
                    ;;
                *)
                    echo -e "  ${YELLOW}Nothing to skip at current status${NC}"
                    sleep 2
                    return
                    ;;
            esac
            ;;
        *)
            echo -e "  ${YELLOW}Skip not configured for this profile${NC}"
            sleep 2
            return
            ;;
    esac

    echo -ne "  Confirm? (y/n): "
    read -r -n1 confirm
    echo ""
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "$skip_to" > "$STATUS_FILE"
        update_change_time
        echo -e "  ${GREEN}Status set to: $skip_to${NC}"
    else
        echo -e "  Cancelled"
    fi
    sleep 2
}

# ── Handle manual status ───────────────────────────────────
handle_set_status() {
    echo ""
    echo -e "  Available statuses:"
    echo -e "  ${DIM}PLAN_READY, CODE_COMPLETE, TEST_COMPLETE:PASS, TEST_COMPLETE:FAIL${NC}"
    echo -e "  ${DIM}SECURITY_PASS, SECURITY_FAIL, DOCS_COMPLETE, IDLE${NC}"
    echo -e "  ${DIM}SKIP_SECURITY, SKIP_DOCS, SKIP_TO_MANAGER${NC}"
    echo ""
    echo -ne "  Enter status: "
    read -r new_status

    if [ -n "$new_status" ]; then
        echo "$new_status" > "$STATUS_FILE"
        update_change_time
        echo -e "  ${GREEN}Status set to: $new_status${NC}"
    else
        echo -e "  Cancelled"
    fi
    sleep 2
}

# ── Handle custom prompt ───────────────────────────────────
handle_custom_prompt() {
    echo ""
    local labels
    labels=$(get_agent_labels)
    echo -e "  Send custom prompt to which agent?"
    echo -e "  $labels"
    echo -ne "  Agent number: "
    read -r -n1 agent_num
    echo ""

    local pane
    pane=$(role_to_pane "$agent_num")
    if [ -z "$pane" ]; then
        echo -e "  ${RED}Invalid agent number${NC}"
        sleep 2
        return
    fi

    echo -ne "  Prompt: "
    read -r custom_text

    if [ -n "$custom_text" ]; then
        send_to_agent "$pane" "$custom_text"
        echo -e "  ${GREEN}Sent to agent $agent_num (pane $pane)${NC}"
    else
        echo -e "  Cancelled"
    fi
    sleep 2
}

# ── Handle direct trigger ──────────────────────────────────
handle_trigger() {
    local agent_num="$1"
    local pane
    pane=$(role_to_pane "$agent_num")
    if [ -z "$pane" ]; then
        echo -e "  ${RED}Invalid agent number${NC}"
        sleep 2
        return
    fi

    # Get the role name for the identity prefix
    local role_name=""
    case "$AGENT_PROFILE" in
        2-agent)
            case "$agent_num" in 1) role_name="manager" ;; 2) role_name="coder" ;; esac ;;
        3-agent)
            case "$agent_num" in 1) role_name="manager" ;; 2) role_name="coder" ;; 3) role_name="tester" ;; esac ;;
        5-agent)
            case "$agent_num" in 1) role_name="manager" ;; 2) role_name="coder" ;; 3) role_name="tester" ;; 4) role_name="security" ;; 5) role_name="docs" ;; esac ;;
        6-agent)
            case "$agent_num" in 1) role_name="manager" ;; 2) role_name="senior" ;; 3) role_name="junior" ;; 4) role_name="tester" ;; 5) role_name="security" ;; 6) role_name="docs" ;; esac ;;
    esac

    echo -e "  Triggering ${CYAN}$role_name${NC} with default prompt..."
    local prompt="Read .claude/CLAUDE.md for the shared protocol, then read .claude/prompts/${role_name}.md for your role. Check .context/status.md and .context/current-task.md and continue your work."
    send_to_agent "$pane" "$prompt"
    update_change_time
    echo -e "  ${GREEN}Sent to pane $pane${NC}"
    sleep 2
}

# ── Handle re-trigger ──────────────────────────────────────
handle_retrigger() {
    local status
    status=$(get_status)
    local next
    next=$(get_expected_next "$status")

    if [ "$next" = "-" ]; then
        echo -e "  ${YELLOW}Can't determine which agent to re-trigger at status: $status${NC}"
        echo -ne "  Enter agent number manually: "
        read -r -n1 agent_num
        echo ""
        handle_trigger "$agent_num"
    else
        echo -e "  Re-triggering ${CYAN}$next${NC}..."
        # Re-write the same status to force orchestrator to re-trigger
        local current
        current=$(get_status)
        echo "RETRIGGER" > "$STATUS_FILE"
        sleep 1
        echo "$current" > "$STATUS_FILE"
        update_change_time
        echo -e "  ${GREEN}Orchestrator will re-trigger${NC}"
        sleep 2
    fi
}

# ── Handle pause toggle ────────────────────────────────────
handle_pause() {
    if is_paused; then
        rm -f "$PAUSE_FILE"
        echo -e "  ${GREEN}Orchestrator RESUMED${NC}"
    else
        touch "$PAUSE_FILE"
        echo -e "  ${YELLOW}Orchestrator PAUSED${NC}"
    fi
    sleep 1
}

# ── Handle log view ────────────────────────────────────────
handle_log() {
    echo ""
    echo -e "  ${BOLD}Last 15 orchestrator log entries:${NC}"
    echo ""
    if [ -f "$ORCH_LOG" ]; then
        tail -15 "$ORCH_LOG" | while read -r line; do
            echo "  $line"
        done
    else
        echo "  No log file found"
    fi
    echo ""
    echo -ne "  ${DIM}Press any key to continue...${NC}"
    read -r -n1
}

# ── Initialize ──────────────────────────────────────────────
update_change_time
LAST_STATUS=$(get_status)

# ── Main loop ───────────────────────────────────────────────
while true; do
    # Check for status change to reset watchdog
    local_status=$(get_status)
    if [ "$local_status" != "$LAST_STATUS" ]; then
        update_change_time
        LAST_STATUS="$local_status"
    fi

    draw_panel

    # Wait for input with timeout (refreshes display every 3 seconds)
    if read -r -n1 -t 3 key; then
        case "$key" in
            [1-6])
                handle_trigger "$key"
                ;;
            s|S)
                handle_skip
                ;;
            m|M)
                handle_set_status
                ;;
            c|C)
                handle_custom_prompt
                ;;
            p|P)
                handle_pause
                ;;
            r|R)
                handle_retrigger
                ;;
            l|L)
                handle_log
                ;;
            q|Q)
                echo ""
                echo -e "  ${DIM}Exiting control panel. Orchestrator still running.${NC}"
                exit 0
                ;;
        esac
    fi
done
