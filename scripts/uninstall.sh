#!/usr/bin/env bash
# ============================================================================
# TetherSpace Node Uninstall Script
# ============================================================================
# Idempotent uninstaller for TetherSpace components.
#
# Modes:
#   default    Remove only TetherSpace-specific artifacts and services.
#   --full     Also remove K3s, CRI-O, CRIU, and CNI plugin artifacts.
#
# Usage:
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --full --yes
# ============================================================================

set -euo pipefail

INSTALL_DIR="/opt/tetherspace"
CONFIG_DIR="/etc/tetherspace"
LOG_FILE="/var/log/tetherspace-uninstall.log"
CRIO_SOCKET="/var/run/crio/crio.sock"
CNI_BIN_DIR="/opt/cni/bin"
CNI_NET_DIR="/etc/cni/net.d"

FULL_UNINSTALL="false"
ASSUME_YES="false"
DEBUG="false"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'
readonly CYAN='\033[0;36m'

TUI_ENABLED="false"
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    TUI_ENABLED="true"
fi
TUI_STATUS_ROW=8
TUI_LAST_PERCENT=0
TUI_STATUS_TEXT="Initializing"
SPINNER_PID=""

tui_cleanup() {
    tui_stop_spinner " "
    if [[ "${TUI_ENABLED}" == "true" ]]; then
        if [[ "${DEBUG}" != "true" ]]; then
            tput cup $((TUI_STATUS_ROW + 3)) 0 2>/dev/null || true
            printf "\n"
        fi
        tput cnorm 2>/dev/null || true
    fi
}
trap tui_cleanup EXIT

tui_banner() {
    if [[ "${TUI_ENABLED}" != "true" ]]; then
        return 0
    fi
    tput civis 2>/dev/null || true
    clear
    printf "${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA} .----. ${NC}   ${GREEN}TetherSpace Node Uninstall${NC}               ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}| .--. |${NC}   ${CYAN}Service Cleanup | Runtime Teardown${NC}       ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}| |__| |${NC}   ${CYAN}CNI/K3s/CRI-O Safe Removal${NC}                ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}|  __  |${NC}   ${GREEN}Clean and Safe Deprovisioning${NC}              ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}'-____-'${NC}                                               ${CYAN}┃${NC}\n"
    printf "${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}\n"
    printf "\n"
}

tui_total_progress_bar() {
    if [[ "${TUI_ENABLED}" != "true" ]]; then
        return 0
    fi
    local cur="$1"
    local total="$2"
    local title="$3"
    local width=36
    local target_percent=$(( cur * 100 / total ))
    local p
    local text="Step ${cur}/${total}: ${title}"

    for ((p=TUI_LAST_PERCENT; p<=target_percent; p++)); do
        local filled=$(( p * width / 100 ))
        local done_bar
        local todo_bar
        done_bar="$(printf "%${filled}s" "" | tr ' ' '=')"
        todo_bar="$(printf "%$((width - filled))s" "" | tr ' ' '.')"
        tui_render_status " " "${p}" "${text}"
        sleep 0.004
    done

    TUI_LAST_PERCENT="${target_percent}"
    TUI_STATUS_TEXT="${text}"
}

tui_render_status() {
    if [[ "${TUI_ENABLED}" != "true" ]]; then
        return 0
    fi
    local icon="$1"
    local percent="$2"
    local text="$3"
    local width=36
    local filled=$(( percent * width / 100 ))
    local done_bar
    local todo_bar
    done_bar="$(printf "%${filled}s" "" | tr ' ' '=')"
    todo_bar="$(printf "%$((width - filled))s" "" | tr ' ' '.')"

    tput sc 2>/dev/null || true
    tput cup "${TUI_STATUS_ROW}" 0 2>/dev/null || true
    printf "\033[K${CYAN}[%s] [%s%s]${NC} %3d%%  %s" "${icon}" "${done_bar}" "${todo_bar}" "${percent}" "${text}"
    tput rc 2>/dev/null || true
}

tui_start_spinner() {
    if [[ "${TUI_ENABLED}" != "true" || "${DEBUG}" == "true" ]]; then
        return 0
    fi
    tui_stop_spinner " "
    (
        local chars='|/-\\'
        local i=0
        while true; do
            local icon="${chars:i%4:1}"
            tui_render_status "${icon}" "${TUI_LAST_PERCENT}" "${TUI_STATUS_TEXT}"
            i=$((i + 1))
            sleep 0.08
        done
    ) &
    SPINNER_PID="$!"
}

tui_stop_spinner() {
    local final_icon="${1:- }"
    if [[ -n "${SPINNER_PID}" ]]; then
        kill "${SPINNER_PID}" 2>/dev/null || true
        wait "${SPINNER_PID}" 2>/dev/null || true
        SPINNER_PID=""
    fi
    if [[ "${TUI_ENABLED}" == "true" && "${DEBUG}" != "true" ]]; then
        tui_render_status "${final_icon}" "${TUI_LAST_PERCENT}" "${TUI_STATUS_TEXT}"
    fi
}

tui_notify_final() {
    local status="$1"
    local message="$2"

    if [[ "${TUI_ENABLED}" == "true" && "${DEBUG}" != "true" ]]; then
        local icon="[OK]"
        local color="${GREEN}"
        if [[ "${status}" != "OK" ]]; then
            icon="[FAIL]"
            color="${RED}"
        fi

        tput cup $((TUI_STATUS_ROW + 1)) 0 2>/dev/null || true
        printf "\033[K${color}%s %s${NC}\n" "${icon}" "${message}"
        tput cup $((TUI_STATUS_ROW + 2)) 0 2>/dev/null || true
    else
        if [[ "${status}" == "OK" ]]; then
            printf "${GREEN}[OK]${NC} %s\n" "${message}"
        else
            printf "${RED}[FAIL]${NC} %s\n" "${message}" >&2
        fi
    fi
}

log_info()  {
    printf "[INFO]  %s\n" "$*" >> "${LOG_FILE}"
    if [[ "${DEBUG}" == "true" ]]; then
        printf "${GREEN}[INFO]${NC}  %s\n" "$*"
    fi
}
log_warn()  {
    printf "[WARN]  %s\n" "$*" >> "${LOG_FILE}"
    if [[ "${DEBUG}" == "true" ]]; then
        printf "${YELLOW}[WARN]${NC}  %s\n" "$*"
    fi
}
log_error() {
    printf "[ERROR] %s\n" "$*" >> "${LOG_FILE}"
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}
log_step()  {
    local step="$1"
    local title="$2"
    local cur="${step%/*}"
    local total="${step#*/}"
    local width=24
    local filled=$(( cur * width / total ))
    local empty=$(( width - filled ))
    local bar_done
    local bar_todo
    bar_done="$(printf "%${filled}s" "" | tr ' ' '#')"
    bar_todo="$(printf "%${empty}s" "" | tr ' ' '-')"

    printf "[STEP]  %s/%s %s\n" "${cur}" "${total}" "${title}" >> "${LOG_FILE}"

    tui_stop_spinner "o"

    if [[ "${TUI_ENABLED}" == "true" && "${DEBUG}" != "true" ]]; then
        tui_total_progress_bar "${cur}" "${total}" "${title}"
        tui_start_spinner
    else
        printf "\n${BLUE}[${bar_done}${bar_todo}] Step %s/%s${NC}  %s\n" "${cur}" "${total}" "${title}"
        tui_total_progress_bar "${cur}" "${total}" "${title}"
    fi
}

die() {
    tui_stop_spinner "x"
    tui_notify_final "FAIL" "$*"
    log_error "$*"
    exit 1
}

command_exists() {
    command -v "$1" &>/dev/null
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root (or with sudo)."
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)
                FULL_UNINSTALL="true"
                shift
                ;;
            --yes|-y)
                ASSUME_YES="true"
                shift
                ;;
                        --debug)
                                DEBUG="true"
                                shift
                                ;;
            -h|--help)
                cat <<'EOF'
TetherSpace uninstall script

Usage:
    sudo ./uninstall.sh [--full] [--yes] [--debug]

Options:
  --full       Remove K3s, CRI-O, CRIU, CNI plugin artifacts and runtime configs.
  --yes, -y    Do not prompt for confirmation.
    --debug      Print verbose [INFO] logs to console.
  -h, --help   Show this help.
EOF
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

run_cmd() {
    if [[ "${DEBUG}" == "true" ]]; then
        "$@"
        return
    fi

    if ! "$@" >> "${LOG_FILE}" 2>&1; then
        log_error "Command failed: $*"
        log_error "Showing last 40 lines from ${LOG_FILE}:"
        tail -n 40 "${LOG_FILE}" >&2 || true
        return 1
    fi
}

confirm_if_needed() {
    if [[ "${ASSUME_YES}" == "true" ]]; then
        return 0
    fi

    if [[ "${FULL_UNINSTALL}" == "true" ]]; then
        echo
        read -r -p "This will remove K3s/CRI-O/CRIU/CNI as well. Continue? [y/N] " ans
        [[ "${ans}" =~ ^[Yy]$ ]] || die "Aborted by user"
    fi
}

stop_disable_service() {
    local unit="$1"
    if systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "${unit}"; then
        run_cmd systemctl stop "${unit}" || true
        run_cmd systemctl disable "${unit}" || true
        log_info "Stopped/disabled ${unit}"
    fi
}

remove_file_if_exists() {
    local p="$1"
    if [[ -e "${p}" || -L "${p}" ]]; then
        rm -rf "${p}"
        log_info "Removed ${p}"
    fi
}

remove_tetherspace_components() {
    if [[ "${FULL_UNINSTALL}" == "true" ]]; then
        log_step "1/2" "Removing TetherSpace services and files"
    else
        log_step "1/1" "Removing TetherSpace services and files"
    fi

    stop_disable_service "tetherspace-agent.service"
    remove_file_if_exists "/etc/systemd/system/tetherspace-agent.service"

    # Remove runtime artifacts/config
    remove_file_if_exists "${INSTALL_DIR}/tetherspace-agent"
    remove_file_if_exists "${CONFIG_DIR}/agent.json"

    # Keep directories if other files are present; remove only known markers.
    remove_file_if_exists "${INSTALL_DIR}/.karmada-joined"
    remove_file_if_exists "${INSTALL_DIR}/.agent-installed-0.1.0"
    remove_file_if_exists "${INSTALL_DIR}/.deps-installed"

    run_cmd systemctl daemon-reload
    log_info "TetherSpace component removal complete"
}

remove_full_stack() {
    log_step "2/2" "Removing full runtime stack (K3s, CRI-O, CRIU, CNI)"

    # K3s
    stop_disable_service "k3s.service"
    if [[ -x "/usr/local/bin/k3s-uninstall.sh" ]]; then
        run_cmd /usr/local/bin/k3s-uninstall.sh || true
        log_info "Ran k3s-uninstall.sh"
    else
        log_warn "k3s-uninstall.sh not found; skipping automated K3s cleanup"
    fi

    # CRI-O (both common unit names)
    stop_disable_service "crio.service"
    stop_disable_service "cri-o.service"

    # Remove unit files and aliases if present
    remove_file_if_exists "/etc/systemd/system/crio.service"
    remove_file_if_exists "/etc/systemd/system/cri-o.service"

    # Remove CRI-O binaries and configs
    remove_file_if_exists "/usr/bin/crio"
    remove_file_if_exists "/usr/local/bin/crio"
    remove_file_if_exists "/usr/bin/crun"
    remove_file_if_exists "/usr/libexec/crio"
    remove_file_if_exists "/etc/crio"
    remove_file_if_exists "${CRIO_SOCKET}"

    # Try package purge in case CRI-O was package-installed
    run_cmd apt-get purge -y cri-o cri-o-runc || true
    run_cmd apt-get autoremove -y || true

    # CRIU
    remove_file_if_exists "/usr/local/bin/criu"

    # CNI plugin artifacts installed by this bootstrap
    remove_file_if_exists "${CNI_BIN_DIR}"
    remove_file_if_exists "${CNI_NET_DIR}/00-loopback.conflist"

    # HeGM markers and dirs
    remove_file_if_exists "${INSTALL_DIR}/hegm"

    run_cmd systemctl daemon-reload
    run_cmd systemctl reset-failed || true
    log_info "Full stack removal complete"
}

main() {
    : > "${LOG_FILE}"
    parse_args "$@"
    require_root
    confirm_if_needed
    tui_banner

    log_info "TetherSpace uninstall starting ($(date -Iseconds))"
    if [[ "${FULL_UNINSTALL}" == "true" ]]; then
        log_warn "Mode: FULL uninstall"
    else
        log_info "Mode: agent-only uninstall"
    fi

    remove_tetherspace_components

    if [[ "${FULL_UNINSTALL}" == "true" ]]; then
        remove_full_stack
    fi

    log_info ""
    log_info "╔═══════════════════════════════════════════════════╗"
    log_info "║  TetherSpace uninstall complete                   ║"
    log_info "║                                                   ║"
    log_info "║  Log file: /var/log/tetherspace-uninstall.log    ║"
    log_info "╚═══════════════════════════════════════════════════╝"

    tui_stop_spinner "o"
    tui_notify_final "OK" "TetherSpace uninstall completed successfully"
}

main "$@"
