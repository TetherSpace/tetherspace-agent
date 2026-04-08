#!/usr/bin/env bash
# ============================================================================
# TetherSpace Node Bootstrap Script
# ============================================================================
# Onboards a bare-metal GPU node into a TetherSpace tenant cluster.
# This script is IDEMPOTENT — safe to re-run on a partially provisioned node.
#
# Pipeline:
#   1. Pre-flight checks (root, NVIDIA drivers)
#   2. HeGM core setup (system deps, CNI plugins, CRI-O >= v1.34.6, CRIU >= v4.2)
#   3. K3s installation with custom CRI-O socket
#   4. Karmada agent join
#   5. TetherSpace agent systemd service
#
# Usage:
#   curl -sfL https://get.tetherspace.io/install.sh | bash
#
#   Optional overrides:
#     TETHERSPACE_TOKEN="<token>" TETHERSPACE_RELAY="<relay-url>" bash
# ============================================================================

set -euo pipefail

# ── Configuration (override via environment) ────────────────────────────────

TETHERSPACE_TOKEN="${TETHERSPACE_TOKEN:-}"
TETHERSPACE_RELAY="${TETHERSPACE_RELAY:-}"
TETHERSPACE_API="${TETHERSPACE_API:-https://api.tetherspace.io}"

HEGM_VERSION="${HEGM_VERSION:-0.1.0}"
AGENT_VERSION="${AGENT_VERSION:-0.1.0}"
K3S_VERSION="${K3S_VERSION:-v1.34.2+k3s1}"

# Component versions — override via environment if needed
CRIO_VERSION="${CRIO_VERSION:-1.34.6}"       # exact version installed via static binary
CRIU_VERSION="${CRIU_VERSION:-4.2}"          # built from source if not present
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.6.2}"

INSTALL_DIR="/opt/tetherspace"
HEGM_DIR="${INSTALL_DIR}/hegm"
CRIO_SOCKET="/var/run/crio/crio.sock"
CNI_BIN_DIR="/opt/cni/bin"
CNI_NET_DIR="/etc/cni/net.d"
K3S_CNI_NET_DIR="/var/lib/rancher/k3s/agent/etc/cni/net.d"
K3S_CNI_FLANNEL_CONF="/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist"
K3S_CNI_BIN_DIR="/var/lib/rancher/k3s/data/current/bin"
# The upstream CNI bandwidth plugin is currently unstable in this environment
# (panic in cmdCheck). Keep it disabled unless explicitly enabled.
ENABLE_CNI_BANDWIDTH_PLUGIN="${ENABLE_CNI_BANDWIDTH_PLUGIN:-false}"
CONFIG_DIR="/etc/tetherspace"
LOG_FILE="/var/log/tetherspace-install.log"

# ── Logging ─────────────────────────────────────────────────────────────────

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'
readonly CYAN='\033[0;36m'

DEBUG="false"

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
    printf "${CYAN}┃${NC}  ${MAGENTA} .----. ${NC}   ${GREEN}TetherSpace Node Bootstrap${NC}                     ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}| .--. |${NC}   ${CYAN}Zero-Trust Tunnel | HeGM Runtime${NC}               ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}| |__| |${NC}   ${CYAN}Telemetry | GPU Stateful Migration${NC}             ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}|  __  |${NC}   ${GREEN}Cloud-Native BYOC ML Onboarding${NC}                ${CYAN}┃${NC}\n"
    printf "${CYAN}┃${NC}  ${MAGENTA}'-____-'${NC}                                                  ${CYAN}┃${NC}\n"
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
    local width=40
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
    local width=40
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
    # Ensure no stale spinner is left running.
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
    local width=28
    local filled=$(( cur * width / total ))
    local empty=$(( width - filled ))
    local bar_done
    local bar_todo
    bar_done="$(printf "%${filled}s" "" | tr ' ' '#')"
    bar_todo="$(printf "%${empty}s" "" | tr ' ' '-')"

    printf "[STEP]  %s/%s %s\n" "${cur}" "${total}" "${title}" >> "${LOG_FILE}"

    # Mark previous step as done before drawing the next one.
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

# ── Helpers ─────────────────────────────────────────────────────────────────

command_exists() {
    command -v "$1" &>/dev/null
}

ensure_dir() {
    [[ -d "$1" ]] || mkdir -p "$1"
}

# Returns 0 (true) if version $1 >= version $2 (uses sort -V).
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug)
                DEBUG="true"
                shift
                ;;
            -h|--help)
                cat <<'EOF'
TetherSpace install script

Usage:
  sudo ./install.sh [--debug]

Options:
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

run_pipe() {
    local cmd="$1"
    if [[ "${DEBUG}" == "true" ]]; then
        bash -o pipefail -c "${cmd}"
        return
    fi

    if ! bash -o pipefail -c "${cmd}" >> "${LOG_FILE}" 2>&1; then
        log_error "Command failed: ${cmd}"
        log_error "Showing last 40 lines from ${LOG_FILE}:"
        tail -n 40 "${LOG_FILE}" >&2 || true
        return 1
    fi
}

# ── Step 1: Pre-flight Checks ──────────────────────────────────────────────

preflight_checks() {
    log_step "1/5" "Pre-flight checks"

    # Must be root
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root (or with sudo)."
    fi
    log_info "Running as root — OK"

    # NVIDIA drivers (optional — node may not have GPUs yet)
    if command_exists nvidia-smi && nvidia-smi &>/dev/null; then
        local gpu_count
        gpu_count="$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -1)"
        log_info "Detected ${gpu_count} NVIDIA GPU(s)"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | while IFS= read -r line; do
            log_info "  GPU: ${line}"
        done
    else
        log_warn "nvidia-smi not found or not functional — GPU features will be unavailable until drivers are installed"
    fi

    # Basic system utilities
    for cmd in curl systemctl awk grep; do
        if ! command_exists "${cmd}"; then
            die "Required command '${cmd}' not found."
        fi
    done
    log_info "System utilities present — OK"

    # Ensure install directories
    ensure_dir "${INSTALL_DIR}"
    ensure_dir "${HEGM_DIR}"
    ensure_dir "${CONFIG_DIR}"

    log_info "Pre-flight checks passed"
}

# ── Step 2: HeGM Core Setup (System Deps, CNI, CRI-O, CRIU) ────────────────

_install_system_deps() {
    local marker="${INSTALL_DIR}/.deps-installed"
    if [[ -f "${marker}" ]]; then
        log_info "System dependencies already installed — skipping"
        return 0
    fi
    log_info "Installing system build dependencies..."
    run_cmd apt-get update -qq
    run_cmd apt-get install -y --no-install-recommends \
        apt-transport-https ca-certificates gnupg lsb-release \
        build-essential git pkg-config \
        libprotobuf-dev libprotobuf-c-dev \
        protobuf-c-compiler protobuf-compiler python3-protobuf \
        libbsd-dev libcap-dev libnl-3-dev libnet-dev libaio-dev \
        libgpgme-dev libdrm-dev libbpf-dev libseccomp-dev \
        iproute2 iptables
    date -Iseconds > "${marker}"
    log_info "System dependencies installed"
}

_install_cni_plugins() {
    local marker="${INSTALL_DIR}/.cni-installed-${CNI_PLUGINS_VERSION}"
    local cni_ok="true"
    if [[ ! -x "${CNI_BIN_DIR}/bridge" || ! -x "${CNI_BIN_DIR}/host-local" || ! -x "${CNI_BIN_DIR}/loopback" ]]; then
        cni_ok="false"
    fi
    if [[ ! -f "${CNI_NET_DIR}/00-loopback.conflist" ]]; then
        cni_ok="false"
    fi
    if [[ -f "${marker}" && "${cni_ok}" == "true" ]]; then
        log_info "CNI plugins ${CNI_PLUGINS_VERSION} already installed — skipping"
        return 0
    fi
    if [[ -f "${marker}" && "${cni_ok}" != "true" ]]; then
        log_warn "CNI marker exists but required files are missing; repairing CNI installation"
    fi
    log_info "Installing CNI plugins ${CNI_PLUGINS_VERSION}..."
    ensure_dir "${CNI_BIN_DIR}"
    ensure_dir "${CNI_NET_DIR}"
    run_pipe "curl -sfL https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz | tar -xz -C ${CNI_BIN_DIR}"
    # Bootstrap loopback config so CRI-O accepts pod start requests
    # before K3s flannel writes its full CNI config.
    cat > "${CNI_NET_DIR}/00-loopback.conflist" <<'CNIEOF'
{
  "cniVersion": "1.0.0",
  "name": "loopback",
  "plugins": [{ "type": "loopback" }]
}
CNIEOF
    date -Iseconds > "${marker}"
    log_info "CNI plugins installed at ${CNI_BIN_DIR}"
}

_install_crio() {
    if command_exists crio; then
        local cur_ver
        cur_ver="$(crio --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")"
        if version_gte "${cur_ver}" "${CRIO_VERSION}"; then
            log_info "CRI-O ${cur_ver} already installed (>= ${CRIO_VERSION}) — skipping"
            return 0
        fi
        log_info "Installed CRI-O ${cur_ver} < ${CRIO_VERSION}, upgrading..."
        # Purge any existing package-managed install to avoid conflicts
        run_cmd apt-get purge -y cri-o cri-o-runc || true
        rm -f /usr/bin/crio /usr/bin/crun /usr/libexec/crio/conmon 2>/dev/null || true
    fi

    local tarball="cri-o.amd64.v${CRIO_VERSION}.tar.gz"
    local url="https://storage.googleapis.com/cri-o/artifacts/${tarball}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local archive="${tmp_dir}/${tarball}"
    log_info "Downloading CRI-O v${CRIO_VERSION} static binary..."
    run_cmd curl -fL --retry 3 -o "${archive}" "${url}"

    # Verify we actually got a gzip archive and not an error page
    if ! file "${archive}" | grep -q 'gzip compressed'; then
        log_error "Downloaded file is not a valid gzip archive. Contents:"
        head -5 "${archive}" | tee -a "${LOG_FILE}" || true
        die "CRI-O download failed — check the URL or version: ${url}"
    fi

    log_info "Extracting CRI-O v${CRIO_VERSION}..."
    run_cmd tar -xz -C "${tmp_dir}" -f "${archive}"

    log_info "Installing CRI-O v${CRIO_VERSION}..."
    local crio_installer
    crio_installer="$(find "${tmp_dir}" -maxdepth 3 -type f -name install.sh | head -1 || true)"
    if [[ -n "${crio_installer}" ]]; then
        # Some CRI-O release archives ship an install.sh helper.
        pushd "$(dirname "${crio_installer}")" > /dev/null
        run_cmd env PREFIX=/usr bash ./install.sh
        popd > /dev/null
    else
        # Fallback path: tarball layout with prebuilt binaries and configs
        # but no installer script (e.g., cri-o/bin, cri-o/etc, cri-o/contrib).
        local crio_root
        crio_root="$(find "${tmp_dir}" -maxdepth 2 -type d -name cri-o | head -1 || true)"
        if [[ -z "${crio_root}" ]]; then
            log_error "CRI-O root directory not found in extracted archive layout."
            find "${tmp_dir}" -maxdepth 3 -type d | tee -a "${LOG_FILE}" || true
            die "Unsupported CRI-O tarball structure for ${CRIO_VERSION}"
        fi

        log_info "CRI-O install.sh not found; using manual installation fallback"

        ensure_dir /usr/bin
        ensure_dir /usr/local/bin
        ensure_dir /usr/libexec/crio
        ensure_dir /etc/crio

        # Install all provided runtime binaries.
        if [[ ! -d "${crio_root}/bin" ]]; then
            die "CRI-O archive missing bin/ directory: ${crio_root}/bin"
        fi
        find "${crio_root}/bin" -maxdepth 1 -type f -exec install -m 755 {} /usr/bin/ \;

        # Install default CRI-O config if present.
        if [[ -f "${crio_root}/etc/crio.conf" ]]; then
            install -m 644 "${crio_root}/etc/crio.conf" /etc/crio/crio.conf
        fi
        if [[ -d "${crio_root}/etc/crio" ]]; then
            cp -a "${crio_root}/etc/crio/." /etc/crio/
        fi

        # Install systemd unit from archive if available, else create minimal unit.
        if [[ -f "${crio_root}/contrib/systemd/crio.service" ]]; then
            install -m 644 "${crio_root}/contrib/systemd/crio.service" /etc/systemd/system/crio.service
        elif [[ -f "${crio_root}/contrib/crio.service" ]]; then
            install -m 644 "${crio_root}/contrib/crio.service" /etc/systemd/system/crio.service
        else
            cat > /etc/systemd/system/crio.service <<'EOF'
[Unit]
Description=CRI-O daemon
Documentation=https://cri-o.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/crio
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        fi
    fi

    local installed_ver
    installed_ver="$(crio --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")"
    if ! version_gte "${installed_ver}" "${CRIO_VERSION}"; then
        die "CRI-O post-install version ${installed_ver} does not meet required ${CRIO_VERSION}"
    fi

    # Some distro/systemd units reference /usr/local/bin/crio while
    # static installs place the binary in /usr/bin/crio.
    if [[ -x "/usr/bin/crio" && ! -e "/usr/local/bin/crio" ]]; then
        ensure_dir "/usr/local/bin"
        ln -s "/usr/bin/crio" "/usr/local/bin/crio"
        log_info "Created compatibility symlink: /usr/local/bin/crio -> /usr/bin/crio"
    fi

    # Cleanup temporary extraction directory explicitly. Avoid RETURN traps,
    # which can leak outside the function under set -u.
    rm -rf "${tmp_dir}"

    log_info "CRI-O ${installed_ver} installed"

    # Drop-in config: cgroup manager + CNI paths
    ensure_dir /etc/crio/crio.conf.d
    cat > /etc/crio/crio.conf.d/10-tetherspace.conf <<EOF
# TetherSpace HeGM — CRI-O runtime overrides
[crio.runtime]
cgroup_manager = "systemd"

[crio.network]
network_dir = "${CNI_NET_DIR}"
plugin_dirs = ["${CNI_BIN_DIR}", "${K3S_CNI_BIN_DIR}", "/usr/lib/cni", "/usr/libexec/cni"]
EOF
}


_reconcile_cni_for_crio() {
    # CRI-O should use flannel as the primary network once k3s has generated it.
    # If 00-loopback remains first, pods get 127.0.0.1 and cluster networking breaks.
    ensure_dir "${CNI_NET_DIR}"

    if [[ -f "${K3S_CNI_FLANNEL_CONF}" ]]; then
                if [[ "${ENABLE_CNI_BANDWIDTH_PLUGIN}" == "true" ]]; then
                        cp "${K3S_CNI_FLANNEL_CONF}" "${CNI_NET_DIR}/10-flannel.conflist"
                        log_info "Synced flannel CNI config (with bandwidth plugin)"
                else
                        # Write sanitized config without bandwidth plugin to avoid
                        # CNI panic in meta/bandwidth on pod sandbox CHECK.
                        cat > "${CNI_NET_DIR}/10-flannel.conflist" <<'EOF'
{
    "name":"cbr0",
    "cniVersion":"1.0.0",
    "plugins":[
        {
            "type":"flannel",
            "delegate":{
                "hairpinMode":true,
                "forceAddress":true,
                "isDefaultGateway":true
            }
        },
        {
            "type":"portmap",
            "capabilities":{
                "portMappings":true
            }
        }
    ]
}
EOF
                        log_info "Wrote sanitized flannel CNI config (bandwidth plugin disabled)"
                fi

        if [[ -f "${CNI_NET_DIR}/00-loopback.conflist" ]]; then
            mv "${CNI_NET_DIR}/00-loopback.conflist" "${CNI_NET_DIR}/99-loopback.conflist"
            log_info "Demoted bootstrap loopback CNI to 99-loopback.conflist"
        fi
    else
        log_warn "Flannel CNI config not found at ${K3S_CNI_FLANNEL_CONF} yet"
    fi
}

_configure_containers_registries() {
    # Configure image short-name policy for CRI-O to avoid
    # ImageInspectError with unqualified image references.
    # Some hosts ship malformed /etc/containers/registries.conf files;
    # write a known-good baseline config and keep a backup once.
    ensure_dir /etc/containers
    if [[ -f /etc/containers/registries.conf && ! -f /etc/containers/registries.conf.tetherspace.bak ]]; then
        cp /etc/containers/registries.conf /etc/containers/registries.conf.tetherspace.bak
    fi
    cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
short-name-mode = "disabled"
EOF

    # Keep a drop-in too for transparency and future overrides.
    ensure_dir /etc/containers/registries.conf.d
    cat > /etc/containers/registries.conf.d/99-tetherspace.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
short-name-mode = "disabled"
EOF

    # Ensure crictl talks to CRI-O directly for diagnostics.
    cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/crio/crio.sock
image-endpoint: unix:///run/crio/crio.sock
timeout: 10
debug: false
EOF

    log_info "Configured containers registries short-name policy (disabled, docker.io-only)"
}

_install_criu() {
    if command_exists criu; then
        local cur_ver
        cur_ver="$(criu --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "0.0")"
        if version_gte "${cur_ver}" "${CRIU_VERSION}"; then
            log_info "CRIU ${cur_ver} already installed (>= ${CRIU_VERSION}) — skipping build"
            return 0
        fi
        log_info "Installed CRIU ${cur_ver} < ${CRIU_VERSION}, rebuilding from source..."
    fi

    local marker="${INSTALL_DIR}/.criu-built-${CRIU_VERSION}"
    if [[ -f "${marker}" ]]; then
        log_info "CRIU ${CRIU_VERSION} build marker present — skipping"
        return 0
    fi

    log_info "Building CRIU v${CRIU_VERSION} from source (this takes several minutes)..."
    local build_dir="/tmp/criu-${CRIU_VERSION}"
    rm -rf "${build_dir}"
    run_pipe "curl -sfL https://github.com/checkpoint-restore/criu/archive/refs/tags/v${CRIU_VERSION}.tar.gz | tar -xz -C /tmp"
    pushd "${build_dir}" > /dev/null
    run_cmd make -j"$(nproc)" WERROR=0 criu
    run_cmd install -m 755 criu/criu /usr/local/bin/criu
    popd > /dev/null
    rm -rf "${build_dir}"

    log_info "CRIU $(criu --version | head -1) installed"
    date -Iseconds > "${marker}"
}

_apply_hegm_overlay() {
    local marker="${HEGM_DIR}/.overlay-installed-${HEGM_VERSION}"
    if [[ -f "${marker}" ]]; then
        log_info "HeGM overlay v${HEGM_VERSION} already applied — skipping"
        return 0
    fi
    # In production: replace upstream binaries with GPU-checkpoint-patched builds:
    #   curl -sfL "${TETHERSPACE_API}/artifacts/hegm/${HEGM_VERSION}/crio" -o /usr/bin/crio
    #   curl -sfL "${TETHERSPACE_API}/artifacts/hegm/${HEGM_VERSION}/criu" -o /usr/local/bin/criu
    #   chmod 755 /usr/bin/crio /usr/local/bin/criu
    log_info "[MOCK] Applying HeGM GPU-checkpoint extensions over CRI-O and CRIU..."
    log_info "  (In production: download signed HeGM overlay from ${TETHERSPACE_API})"
    date -Iseconds > "${marker}"
    log_info "HeGM overlay applied (mock)"
}

setup_hegm() {
    log_step "2/5" "HeGM core setup (system deps, CNI, CRI-O, CRIU)"

    _install_system_deps
    _install_cni_plugins
    _install_crio
    _configure_containers_registries
    _install_criu
    _apply_hegm_overlay

    # Normalize CRI-O binary path for unit files from mixed package origins.
    local crio_bin
    crio_bin="$(command -v crio || true)"
    if [[ -z "${crio_bin}" ]]; then
        die "crio binary not found in PATH after install"
    fi
    if [[ ! -e "/usr/local/bin/crio" ]]; then
        ensure_dir "/usr/local/bin"
        ln -s "${crio_bin}" "/usr/local/bin/crio"
        log_info "Ensured /usr/local/bin/crio points to ${crio_bin}"
    fi

    # CRI-O must be running before K3s starts so the kubelet can connect
    log_info "Starting CRI-O service..."
    local crio_unit="crio.service"
    if systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "cri-o.service"; then
        crio_unit="cri-o.service"
    elif systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "crio.service"; then
        crio_unit="crio.service"
    fi

    run_cmd systemctl daemon-reload
    if ! systemctl enable "${crio_unit}" >> "${LOG_FILE}" 2>&1; then
        log_warn "systemctl enable ${crio_unit} failed (likely alias conflict); continuing with start"
    fi
    run_cmd systemctl reset-failed "${crio_unit}" || true
    if ! run_cmd systemctl restart "${crio_unit}"; then
        die "Failed to start ${crio_unit}. Check: journalctl -u ${crio_unit}"
    fi

    log_info "Waiting for CRI-O socket at ${CRIO_SOCKET}..."
    local retries=0
    local max_retries=90
    local socket_found="false"
    while [[ "${retries}" -lt "${max_retries}" ]]; do
        if [[ -S "/var/run/crio/crio.sock" || -S "/run/crio/crio.sock" ]]; then
            socket_found="true"
            break
        fi

        # If unit already failed, surface logs immediately instead of waiting.
        if systemctl is-failed --quiet "${crio_unit}"; then
            log_error "${crio_unit} entered failed state before socket creation"
            journalctl -u "${crio_unit}" -n 80 --no-pager | tee -a "${LOG_FILE}" || true
            die "CRI-O failed to start. See log output above."
        fi

        retries=$((retries + 1))
        sleep 1
    done

    if [[ "${socket_found}" != "true" ]]; then
        log_error "CRI-O socket not available after ${max_retries}s"
        systemctl status "${crio_unit}" --no-pager | tee -a "${LOG_FILE}" || true
        journalctl -u "${crio_unit}" -n 120 --no-pager | tee -a "${LOG_FILE}" || true
        die "CRI-O socket not available after ${max_retries}s — check unit logs above"
    fi
    log_info "CRI-O is running"

    # Reconcile CRI-O CNI configs on every run (important after re-installs).
    _reconcile_cni_for_crio
}

# ── Step 3: K3s Installation ────────────────────────────────────────────────

install_k3s() {
    log_step "3/5" "K3s installation (${K3S_VERSION}, CRI-O runtime)"

    if command_exists k3s; then
        local installed_version
        installed_version="$(k3s --version 2>/dev/null | awk '{print $3}' | head -1)"
        log_info "K3s already installed (${installed_version}) — skipping"
        return 0
    fi

    # Prevent any pre-installed containerd from conflicting with CRI-O
    run_cmd systemctl stop containerd || true
    run_cmd systemctl disable containerd || true

    log_info "Installing K3s ${K3S_VERSION} with CRI-O socket..."

    # CRITICAL: --container-runtime-endpoint bypasses K3s's embedded containerd
    # and routes all CRI calls to our HeGM-capable CRI-O instance.
    run_pipe "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${K3S_VERSION}' sh -s - --container-runtime-endpoint='unix://${CRIO_SOCKET}' --system-default-registry='docker.io' --kubelet-arg='container-runtime-endpoint=unix://${CRIO_SOCKET}' --kubelet-arg='runtime-request-timeout=10m' --kubelet-arg='cgroup-driver=systemd' --disable=traefik --disable=servicelb --write-kubeconfig-mode=644 --node-label='tetherspace.io/node=true' --node-label='tetherspace.io/hegm-version=${HEGM_VERSION}'"

    # Wait for the node to become Ready.
    # The flannel DaemonSet (hostNetwork) starts first and writes the CNI config;
    # regular pods can network only after that — typically takes 2-3 minutes.
    log_info "Waiting for K3s node to become Ready (flannel CNI may take ~3 min)..."
    local retries=0
    local max_retries=72  # 6 minutes max
    while true; do
        # Continuously reconcile CNI while waiting for node readiness.
        _reconcile_cni_for_crio

        local node_status
        node_status="$(k3s kubectl get node "$(hostname)" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || echo "unavailable")"
        if [[ "${node_status}" == "True" ]]; then
            break
        fi
        retries=$((retries + 1))
        if [[ "${retries}" -ge "${max_retries}" ]]; then
            log_error "Node not Ready after $((max_retries * 5))s. Last conditions:"
            k3s kubectl describe node "$(hostname)" 2>/dev/null \
                | awk '/Conditions:/,/Addresses:/' | head -20 || true
            die "K3s node did not become Ready. Check: journalctl -u k3s"
        fi
        if (( retries % 6 == 0 )); then
            local msg
            msg="$(k3s kubectl get node "$(hostname)" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' \
                2>/dev/null || echo "API not yet available")"
            log_info "  Still waiting (${retries}/${max_retries} × 5s): ${msg}"
        fi
        sleep 5
    done

    log_info "K3s installed and node is Ready"
}

# ── Step 4: Karmada Agent Join ──────────────────────────────────────────────

setup_karmada_agent() {
    log_step "4/5" "Karmada agent setup"

    local marker="${INSTALL_DIR}/.karmada-joined"

    if [[ -f "${marker}" ]]; then
        log_info "Karmada agent already joined — skipping"
        return 0
    fi

    # --- Mock: In production, this would: ---
    #   1. Download the karmada-agent binary
    #   2. Apply the karmada-agent RBAC + Deployment into the local cluster
    #   3. Register with the Cloud Control Plane's karmada-apiserver
    #
    # Example real commands:
    #   curl -sfL "${TETHERSPACE_API}/artifacts/karmada-agent" -o /usr/local/bin/karmada-agent
    #   karmadactl join <cluster-name> \
    #     --cluster-kubeconfig=/etc/rancher/k3s/k3s.yaml \
    #     --karmada-apiserver=<karmada-api-endpoint> \
    #     --token="${TETHERSPACE_TOKEN}"

    log_info "Registering local cluster with Cloud Karmada Control Plane..."
    log_info "[MOCK] karmadactl join tetherspace-node-$(hostname) \\"
    log_info "         --cluster-kubeconfig=/etc/rancher/k3s/k3s.yaml \\"
    log_info "         --karmada-apiserver=${TETHERSPACE_API} \\"
    log_info "         --token=<redacted>"

    # Simulate the registration by writing a marker
    date -Iseconds > "${marker}"
    log_info "Karmada agent joined (mock)"
}

# ── Step 5: TetherSpace Agent ───────────────────────────────────────────────

setup_tetherspace_agent() {
    log_step "5/5" "TetherSpace agent setup"

    local agent_bin="${INSTALL_DIR}/tetherspace-agent"
    local marker="${INSTALL_DIR}/.agent-installed-${AGENT_VERSION}"

    if [[ -f "${marker}" ]]; then
        log_info "TetherSpace agent v${AGENT_VERSION} already installed — skipping"
        return 0
    fi

    # --- Mock download of agent binary ---
    log_info "Downloading tetherspace-agent v${AGENT_VERSION}..."
    cat > "${agent_bin}" <<'MOCK'
#!/usr/bin/env bash
# MOCK: TetherSpace agent binary (replace with compiled Go binary)
echo "tetherspace-agent: mock binary — real agent built from cmd/tetherspace-agent"
sleep infinity
MOCK
    chmod 755 "${agent_bin}"

    # --- Agent configuration ---
    cat > "${CONFIG_DIR}/agent.json" <<EOF
{
  "node_id": "$(hostname)-$(date +%s)",
  "tenant_id": "pending-assignment",
  "relay": {
    "endpoint": "${TETHERSPACE_RELAY}",
    "auth_token": "${TETHERSPACE_TOKEN}",
    "reconnect_interval": 5000000000,
    "max_reconnect_backoff": 300000000000,
    "heartbeat_interval": 30000000000
  },
  "k3s": {
    "kubeconfig": "/etc/rancher/k3s/k3s.yaml",
    "watch_namespaces": ["default", "tetherspace-workloads"]
  },
  "hegm": {
    "crio_socket_path": "${CRIO_SOCKET}",
    "criu_binary_path": "/usr/local/bin/criu",
    "flush_timeout": 120000000000
  },
  "telemetry": {
    "push_endpoint": "${TETHERSPACE_API}/v1/telemetry",
    "scrape_interval": 10000000000
  }
}
EOF
    chmod 600 "${CONFIG_DIR}/agent.json"

    # --- Systemd unit ---
    cat > /etc/systemd/system/tetherspace-agent.service <<EOF
[Unit]
Description=TetherSpace Edge Agent
Documentation=https://docs.tetherspace.io/agent
After=network-online.target k3s.service crio.service
Wants=network-online.target
Requires=k3s.service

[Service]
Type=simple
ExecStart=${agent_bin} --config ${CONFIG_DIR}/agent.json
Restart=always
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
LimitNOFILE=65536

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/tetherspace ${CONFIG_DIR}
PrivateTmp=true

# Environment
Environment=GOMAXPROCS=4
Environment=GOTRACEBACK=crash

[Install]
WantedBy=multi-user.target
EOF

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable tetherspace-agent.service
    run_cmd systemctl start tetherspace-agent.service

    # Verify it started
    if systemctl is-active --quiet tetherspace-agent.service; then
        log_info "tetherspace-agent.service is running"
    else
        log_warn "tetherspace-agent.service failed to start — check: journalctl -u tetherspace-agent"
    fi

    date -Iseconds > "${marker}"
    log_info "TetherSpace agent setup complete"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    echo "" > "${LOG_FILE}"  # Reset log file
    tui_banner
    log_info "TetherSpace node bootstrap starting ($(date -Iseconds))"
    log_info "Relay: ${TETHERSPACE_RELAY}"

    preflight_checks
    setup_hegm
    install_k3s
    setup_karmada_agent
    setup_tetherspace_agent

    log_info ""
    log_info "╔═══════════════════════════════════════════════════╗"
    log_info "║  TetherSpace node onboarding complete!            ║"
    log_info "║                                                   ║"
    log_info "║  Agent logs:  journalctl -fu tetherspace-agent    ║"
    log_info "║  K3s status:  k3s kubectl get nodes               ║"
    log_info "║  GPU check:   nvidia-smi                          ║"
    log_info "║  Uninstall:   sudo ./uninstall.sh                 ║"
    log_info "║  Full wipe:   sudo ./uninstall.sh --full --yes    ║"
    log_info "╚═══════════════════════════════════════════════════╝"

    tui_stop_spinner "o"
    tui_notify_final "OK" "TetherSpace node onboarding completed successfully"
}

main "$@"
