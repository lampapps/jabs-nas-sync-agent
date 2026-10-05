#!/usr/bin/env bash
# =============================================================================
# nas_sync.sh — Bidirectional NAS sync over NFS / Tailscale
# =============================================================================
#
# TOPOLOGY
#   NAS1 is mounted via NFS, same LAN as this client (no WAN hop).
#   NAS2 is remote, reachable over Tailscale, and is NOT mounted — rsync
#   talks directly to its ADM "Rsync Server" daemon over the Tailscale
#   tunnel, so delta-transfer applies to the WAN hop instead of raw NFS I/O.
#
# SYNC MODEL
#   Bidirectional — configured as two independent sets of one-way pairs:
#     NAS1 → NAS2  (NAS1_TO_NAS2_PAIRS)
#     NAS2 → NAS1  (NAS2_TO_NAS1_PAIRS)
#   Each pair is an exact mirror (--delete).  Files removed from the source
#   are removed from the destination on the next run.
#
# USAGE
#   Run manually:   ./nas_sync.sh
#   Dry run:        ./nas_sync.sh --dry-run
#   Debug/verbose:  ./nas_sync.sh --debug
#   Both:           ./nas_sync.sh --dry-run --debug
#   Deep check:     ./nas_sync.sh check-deep [--pair NAME]
#   Stop run:       ./nas_sync.sh stop
#   Cron (nightly): see README.md
#
# INTEGRITY CHECKS
#   After every successful (or partial) sync, sync_pair() runs a low-cost
#   quick verify: an rsync --dry-run comparison against size/mtime only (no
#   file content is read). Any remaining differences are logged and reported
#   to JABS, but never fail the already-completed sync. Controlled by
#   VERIFY_AFTER_SYNC in nas_sync.conf (default true).
#   For a thorough (slow) check that reads and compares actual file content,
#   run manually: ./nas_sync.sh check-deep [--pair NAME]
#
# REQUIREMENTS
#   The following commands must be available on the CLIENT machine running
#   this script:
#
#   rsync        — file sync engine
#                  Debian/Ubuntu : sudo apt install rsync
#                  RHEL/Fedora   : sudo dnf install rsync
#
#   flock        — prevents concurrent runs (part of util-linux, usually
#                  pre-installed; package name: util-linux)
#
#   mountpoint   — detects live NFS mounts (part of util-linux)
#
#   df           — free space check (part of coreutils, always present)
#
#   stat         — NFS accessibility check (part of coreutils, always present)
#
#   bc           — floating-point MB/s display in log output
#                  Debian/Ubuntu : sudo apt install bc
#                  RHEL/Fedora   : sudo dnf install bc
#
#   tee          — concurrent log + stdout (part of coreutils, always present)
#
#   curl         — Uptime Kuma telemetry pings (usually pre-installed)
#                  Debian/Ubuntu : sudo apt install curl
#                  RHEL/Fedora   : sudo dnf install curl
#
#   readlink     — resolves SCRIPT_DIR at runtime (part of coreutils)
#
#   python3      — only required if JABS_DASHBOARD_URL is set (see below).
#                  Used to run jabs_client.py, which reports sync activity
#                  to a JABS dashboard's Agent Monitoring API.
#                  Debian/Ubuntu : sudo apt install python3
#                  RHEL/Fedora   : sudo dnf install python3
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Reported to the JABS dashboard as this agent's version; bump when you
# change this script.
readonly SCRIPT_VERSION="0.3.0"

# Resolve the directory this script lives in (works regardless of cwd)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# COLOR OUTPUT / PRINT HELPERS
# (kept consistent with dashboard/jabs-dashboard.sh and
#  file_backup_agent/jabs-agent.sh — see AGENTS.md "Bash Launcher Scripts")
# ─────────────────────────────────────────────────────────────────────────────
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m' # No Color

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_header()  { echo -e "${BLUE}[NAS Sync]${NC} $1"; }
print_section() { echo -e "${CYAN}[SECTION]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE COMMANDS (setup|logs|reset|help)
# nas_sync.sh has no background server, so start/stop/restart/status don't
# apply here (see AGENTS.md) — the script's default (no subcommand) behavior
# is to run the sync itself, same as always, so cron invocations and
# --dry-run/--debug flags keep working unchanged.
# ─────────────────────────────────────────────────────────────────────────────

cmd_setup() {
    print_section "NAS Sync Agent Setup"

    local conf_file="${SCRIPT_DIR}/nas_sync.conf"
    local conf_example="${SCRIPT_DIR}/nas_sync.conf.example"
    if [[ -f "${conf_file}" ]]; then
        print_status "Config already exists (skipped): ${conf_file}"
    elif [[ -f "${conf_example}" ]]; then
        cp "${conf_example}" "${conf_file}"
        print_status "Created ${conf_file} from nas_sync.conf.example"
    else
        print_error "Missing template: ${conf_example}"
        return 1
    fi

    local log_dir="${SCRIPT_DIR}/logs"
    if [[ ! -d "${log_dir}" ]]; then
        mkdir -p "${log_dir}"
        print_status "Created log directory: ${log_dir}"
    else
        print_status "Log directory already exists (skipped): ${log_dir}"
    fi

    print_status "Checking required commands..."
    local missing=()
    for cmd in rsync flock mountpoint df stat bc tee curl readlink; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_warning "Missing commands: ${missing[*]} (see the header of this script for install instructions)"
    else
        print_status "All required commands are available."
    fi

    print_status "Setup complete!"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  1. Edit: ${CYAN}${conf_file}${NC}"
    echo "  2. Create the NAS2 rsync module password file (chmod 600) at the path"
    echo "     set by NAS2_RSYNC_PASSWORD_FILE in that config"
    echo "  3. (Optional) Configure JABS_DASHBOARD_URL/JABS_AGENT_KEY in that file to report to a dashboard"
    echo -e "  4. Test:   ${CYAN}$0 --dry-run --debug${NC}"
    echo -e "  5. Run:    ${CYAN}$0${NC}"
    echo -e "  6. Add a CRON job for nightly runs (see: ${CYAN}$0 help${NC})"
}

cmd_logs() {
    local log_dir="${SCRIPT_DIR}/logs"
    local latest
    latest="$(ls -t "${log_dir}"/nas_sync_*.log 2>/dev/null | head -1 || true)"
    if [[ -n "${latest}" ]]; then
        print_status "Showing latest log (Press Ctrl+C to exit): ${latest}"
        tail -f "${latest}"
    else
        print_error "No log files found in: ${log_dir}"
        return 1
    fi
}

cmd_stop() {
    local pid_file="${SCRIPT_DIR}/nas_sync.pid"
    if [[ ! -f "${pid_file}" ]]; then
        print_error "No PID file found (${pid_file}) — is a sync running?"
        return 1
    fi
    local pid
    pid="$(<"${pid_file}")"
    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        print_warning "PID file is stale (process ${pid:-unknown} not running) — removing it"
        rm -f "${pid_file}"
        return 1
    fi
    print_status "Sending graceful stop (SIGTERM) to running sync (pid ${pid})..."
    kill -TERM "${pid}"
    print_status "rsync will finish its current file and exit; --partial keeps progress for the next run."
}

cmd_reset() {
    print_section "NAS Sync Agent Reset"

    print_status "Clearing logs..."
    local log_dir="${SCRIPT_DIR}/logs"
    if [[ -d "${log_dir}" ]]; then
        rm -f "${log_dir}"/*.log
        print_status "Logs cleared"
    else
        print_status "No logs directory found (skipped)"
    fi

    print_status "Clearing lock file..."
    local lock_file="${SCRIPT_DIR}/nas_sync.lock"
    if [[ -f "${lock_file}" ]]; then
        rm -f "${lock_file}"
        print_status "Lock file cleared"
    else
        print_status "No lock file found (skipped)"
    fi

    print_status "Reset complete."
}

cmd_help() {
    cat << EOF
${BOLD}NAS Sync Agent Launcher${NC}

${BOLD}USAGE:${NC}
  $0 [--dry-run] [--debug]
  $0 {setup|logs|reset|stop|check-deep|help}

${BOLD}COMMANDS:${NC}
  ${DIM}(no args)${NC}   Run the bidirectional sync (default cron invocation)
  ${YELLOW}--dry-run${NC}   Simulate the sync without writing changes
  ${YELLOW}--debug${NC}     Verbose logging
  ${CYAN}setup${NC}       Create nas_sync.conf from the example, create logs/, check deps
  ${CYAN}logs${NC}        Follow the most recent run's log
  ${CYAN}reset${NC}       Reset app (clear logs, lock file)
  ${CYAN}stop${NC}        Gracefully stop a currently running sync (like STOP_HOUR, but on demand)
  ${CYAN}check-deep${NC}  Manually verify pairs by comparing file content (slow, reads all data); add --pair NAME to check one pair only
  ${CYAN}help${NC}        Show this help message

${BOLD}DIRECTORIES:${NC}
  Script:      ${SCRIPT_DIR}
  Config:      ${SCRIPT_DIR}/nas_sync.conf
  Logs:        ${SCRIPT_DIR}/logs

${BOLD}SETUP:${NC}
  1. Run: ${CYAN}$0 setup${NC}
  2. Edit: ${SCRIPT_DIR}/nas_sync.conf
  3. Test: ${CYAN}$0 --dry-run --debug${NC}
  4. Add CRON job: crontab -e
     ${DIM}0 23 * * * ${SCRIPT_DIR}/nas_sync.sh${NC}

${BOLD}INTEGRITY CHECKS:${NC}
  A low-cost quick verify (size/mtime only, no data read) runs automatically
  after every sync when VERIFY_AFTER_SYNC=true (default) in nas_sync.conf.
  For a thorough but slow check that reads and compares file content, run:
     ${CYAN}$0 check-deep${NC}
     ${CYAN}$0 check-deep --pair backups${NC}   (substring-matches a pair's label)

${BOLD}EXAMPLES:${NC}
  ${DIM}# Initial setup${NC}
  $0 setup

  ${DIM}# Dry run with verbose output${NC}
  $0 --dry-run --debug

  ${DIM}# Real run${NC}
  $0

  ${DIM}# Follow logs${NC}
  $0 logs

  ${DIM}# Reset app state${NC}
  $0 reset

  ${DIM}# Gracefully stop a currently running sync${NC}
  $0 stop

  ${DIM}# Deep content check of all pairs (slow)${NC}
  $0 check-deep

  ${DIM}# Deep content check of one pair only${NC}
  $0 check-deep --pair backups

EOF
    echo -e "${BOLD}COPY/PASTE COMMANDS${NC} ${DIM}(this host)${NC}:"
    echo ""
    echo -e "  ${DIM}Run sync manually:${NC}"
    echo -e "    ${CYAN}${SCRIPT_DIR}/nas_sync.sh${NC}"
    echo ""
    echo -e "  ${DIM}Dry run (no changes written):${NC}"
    echo -e "    ${CYAN}${SCRIPT_DIR}/nas_sync.sh --dry-run --debug${NC}"
    echo ""
    echo -e "  ${DIM}CRON entry (nightly at 23:00):${NC}"
    echo -e "    ${DIM}0 23 * * * ${SCRIPT_DIR}/nas_sync.sh${NC}"
    echo ""
}

case "${1:-}" in
    setup) cmd_setup; exit $? ;;
    logs)  cmd_logs;  exit $? ;;
    reset) cmd_reset; exit $? ;;
    stop)  cmd_stop;  exit $? ;;
    help|-h|--help) cmd_help; exit 0 ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

# Load local config (gitignored — contains secrets and site-specific values).
# Copy nas_sync.conf.example → nas_sync.conf and fill in your values.
CONF_FILE="${SCRIPT_DIR}/nas_sync.conf"
if [[ ! -f "${CONF_FILE}" ]]; then
    echo "ERROR: ${CONF_FILE} not found." >&2
    echo "       Copy nas_sync.conf.example to nas_sync.conf and edit it." >&2
    echo "       Or run: $0 setup" >&2
    exit 1
fi
# shellcheck source=nas_sync.conf.example
source "${CONF_FILE}"

# Paths derived from SCRIPT_DIR (not user-configurable)
LOCK_FILE="${SCRIPT_DIR}/nas_sync.lock"
PID_FILE="${SCRIPT_DIR}/nas_sync.pid"
LOG_DIR="${SCRIPT_DIR}/logs"
JABS_CLIENT="${SCRIPT_DIR}/jabs_client.py"

# Defaults for JABS settings, so a nas_sync.conf from before this feature
# existed still loads fine (JABS reporting simply stays disabled).
JABS_AGENT_VERSION="${SCRIPT_VERSION}"
# JABS_DASHBOARD_URL is the current name; JABS_SERVER_URL still works as a
# deprecated alias for configs written before the Dashboard rename.
: "${JABS_DASHBOARD_URL:=${JABS_SERVER_URL:-}}"
: "${JABS_AGENT_KEY:=}"
: "${JABS_TIMEOUT:=10}"
: "${JOB_NAME:=NAS Sync}"

# Optional: cron expression matching this script's crontab entry, reported
# to the dashboard for the "Next Event" column. Purely advisory — this
# script still only runs whenever cron actually invokes it.
: "${JOB_CRON:=}"

# Default for the post-sync quick verify, so a nas_sync.conf from before this
# feature existed still loads fine (quick verify simply stays on by default).
: "${VERIFY_AFTER_SYNC:=true}"

# Defaults for optional in-transit compression, so a nas_sync.conf from
# before this feature existed still loads fine (compression stays off).
: "${RSYNC_COMPRESS:=false}"
: "${RSYNC_COMPRESS_LEVEL:=}"
: "${RSYNC_SKIP_COMPRESS:=}"

# ── Advanced rsync flags ───────────────────────────────────────────────────
# rsync -avh --progress --partial --append-verify --bwlimit=4500 /mnt/nas-unas/backups/video-archive/ /mnt/nas-kpf/jof/video-archive/
# Applied to every sync.  Adjust with care.
RSYNC_BASE_OPTS=(
    --archive                   # -rlptgoD  (recursive + preserve everything)
    --no-owner                  # don't try to preserve owner (NFS uid mismatch)
    --no-group                  # don't try to preserve group (NFS gid mismatch)
    --delete                    # exact mirror; remove dest-only files
    --delete-excluded           # also purge excluded files from dest
    --partial                   # keep partial transfers; resume later
    --force                     # delete non-empty dirs when replaced by files
    --partial-dir=".rsync-partial"  # stage partials in a hidden subfolder
    --sparse                    # handle sparse files efficiently
    --human-readable            # human-readable sizes in output
    --timeout=300               # abandon stalled connections after 5 min
    --no-motd                   # suppress rsync MOTD
)

# Files / dirs to exclude from every sync (glob patterns)
RSYNC_EXCLUDES=(
    ".rsync-partial/"
    ".DS_Store"
    "Thumbs.db"
    "*.tmp"
    "*.part"
    "lost+found/"
    "#Recycle/"
    ".Trash*/"
)

# Built from RSYNC_COMPRESS/_LEVEL/_SKIP_COMPRESS (see nas_sync.conf);
# appended to every rsync command in sync_pair().
RSYNC_COMPRESS_OPTS=()
if [[ "${RSYNC_COMPRESS}" == "true" ]]; then
    RSYNC_COMPRESS_OPTS+=(--compress)
    [[ -n "${RSYNC_COMPRESS_LEVEL}" ]] && RSYNC_COMPRESS_OPTS+=("--compress-level=${RSYNC_COMPRESS_LEVEL}")
    [[ -n "${RSYNC_SKIP_COMPRESS}" ]] && RSYNC_COMPRESS_OPTS+=("--skip-compress=${RSYNC_SKIP_COMPRESS}")
fi

# ─────────────────────────────────────────────────────────────────────────────
# END OF CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

# ── Script metadata ────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="${LOG_DIR}/nas_sync_${RUN_TIMESTAMP}.log"

# Cumulative counters
TOTAL_PAIRS=0
FAILED_PAIRS=0
SKIPPED_PAIRS=0
declare -a PAIR_RESULTS=()

# Deadline state (populated in main once STOP_HOUR is evaluated)
DEADLINE_EPOCH=0
DEADLINE_REACHED=false

# Manual-stop state. STOP_REQUESTED is set by _handle_stop_signal() (see
# below); RSYNC_PID tracks the currently-running rsync (or its `timeout`
# wrapper) so that handler can forward the signal to it immediately instead
# of waiting for rsync to notice on its own.
STOP_REQUESTED=false
RSYNC_PID=""

# In-flight job tracking. Set by sync_pair() around each pair's rsync call,
# cleared once that pair is finalized. Lets the EXIT trap report a pair as
# "stopped" on the dashboard if the whole script is killed mid-sync (e.g. an
# external deadline/timeout mechanism), not just this script's own STOP_HOUR
# handling — otherwise that job would stay stuck at status='running' forever.
CURRENT_RUN_ID=""
CURRENT_JOB_LABEL=""
CURRENT_JOB_START_EPOCH=0

# Shared by every pair in one script invocation (set once in main()) so the
# dashboard can group all pairs into a single "job run" via --job-run-id.
JOB_RUN_ID=""

# Dry-run and debug flags
DRY_RUN=false
DEBUG=false
for _arg in "$@"; do
    case "${_arg}" in
        --dry-run|-n) DRY_RUN=true ;;
        --debug|-v)   DEBUG=true  ;;
        *)
            echo "ERROR: Unknown argument: ${_arg}" >&2
            echo "       Usage: $0 [--dry-run] [--debug]" >&2
            exit 1
            ;;
    esac
done
unset _arg


# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "${LOG_DIR}"

# Tee all output to the log file and to stdout
exec > >(tee -a "${LOG_FILE}") 2>&1

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()  { log "INFO  $*"; }
debug() { $DEBUG && log "DEBUG $*" || true; }
warn()  { log "WARNING $*"; }
err()   { log "ERROR $*" >&2; }
die()   { err "$*"; uptime_kuma_ping "down" "$*"; exit 1; }

# Tracks whether the script reached its own clean shutdown.
# The EXIT trap uses this to detect unexpected termination.
_COMPLETED=false

# EXIT trap — fires on any exit, including uncaught signals (not SIGKILL).
# Sends an Uptime Kuma down ping when the script is killed or aborted before
# a complete/down ping was sent.
_exit_trap() {
    local rc=$?
    ${_COMPLETED:-false} && return   # normal shutdown — already pinged/reported
    ${DRY_RUN:-false}    && return   # test run — never pings Uptime Kuma or JABS
    local msg="unexpected exit"
    [[ $rc -ne 0 ]] && msg="unexpected exit (code ${rc})"
    err "Script terminated unexpectedly — sending Uptime Kuma down ping"
    uptime_kuma_ping "down" "${msg}"

    # If a pair was mid-sync when this process was killed (e.g. an external
    # deadline/timeout mechanism, not this script's own STOP_HOUR handling),
    # finalize its dashboard job as "stopped" instead of leaving it stuck at
    # status='running' forever (stale spinner, and never picked up by the
    # digest email since it never got a completed_at timestamp).
    if [[ -n "${CURRENT_RUN_ID:-}" ]]; then
        local duration=$(( $(date +%s) - ${CURRENT_JOB_START_EPOCH:-$(date +%s)} ))
        jabs_event --event-type "backup_complete" --status "stopped" --stage "Stopped" \
            --message "${CURRENT_JOB_LABEL} interrupted by unexpected script termination (resumes next run)" \
            --run-id "${CURRENT_RUN_ID}" --job-name "${JOB_NAME}" \
            --target-id "${CURRENT_JOB_LABEL}" --target-label "${CURRENT_JOB_LABEL}" \
            --backup-type "sync" --duration-seconds "${duration}" \
            --files-backed-up 0 --bytes-backed-up 0 \
            --error-message "${CURRENT_JOB_LABEL} interrupted by unexpected script termination (resumes next run)"
    fi
}
trap '_exit_trap' EXIT

# Manual stop (`./nas_sync.sh stop`, or any plain `kill <pid>`, sends TERM).
# Mirrors STOP_HOUR's graceful-stop behavior but on demand: forward the
# signal straight to the in-flight rsync (or its `timeout` wrapper, which
# itself forwards on to rsync) so the current file finishes and --partial
# saves progress, rather than letting bash defer the trap until rsync exits
# on its own. If no rsync is running right now, the main loop checks
# STOP_REQUESTED and stops before starting the next pair.
_handle_stop_signal() {
    STOP_REQUESTED=true
    if [[ -n "${RSYNC_PID}" ]]; then
        warn "Stop requested — forwarding SIGTERM to running rsync (pid ${RSYNC_PID})"
        kill -TERM "${RSYNC_PID}" 2>/dev/null || true
    else
        warn "Stop requested — will stop before starting the next pair"
    fi
}
trap '_handle_stop_signal' TERM INT


# ─────────────────────────────────────────────────────────────────────────────
# UPTIME KUMA
# ─────────────────────────────────────────────────────────────────────────────

# uptime_kuma_ping <up|down> [message]
# Sends a push heartbeat to an Uptime Kuma push monitor.  Silently skips if
# UPTIME_KUMA_URL is empty, curl is unavailable, or the script is in dry-run
# mode (test runs must not pollute the monitor's heartbeat history).
uptime_kuma_ping() {
    [[ -z "${UPTIME_KUMA_URL:-}" ]] && return 0
    ${DRY_RUN:-false} && return 0   # never ping Uptime Kuma during dry runs
    command -v curl &>/dev/null || { warn "curl not found; skipping Uptime Kuma ping"; return 0; }

    local status="$1"
    local msg="${2:-}"
    local encoded_msg
    encoded_msg="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${msg}" 2>/dev/null || echo "${msg// /+}")"

    # Strip any query string the user may have copied from Uptime Kuma's UI
    local base_url="${UPTIME_KUMA_URL%%\?*}"
    local url="${base_url}?status=${status}&msg=${encoded_msg}&ping="

    curl --silent --location --max-time 10 "${url}" >/dev/null 2>&1 \
        || warn "Uptime Kuma ping failed (status=${status})"
}


# ─────────────────────────────────────────────────────────────────────────────
# JABS AGENT MONITORING
# ─────────────────────────────────────────────────────────────────────────────
# Reports sync activity to a JABS dashboard's Agent Monitoring API (see
# AGENT_API_GUIDE.md). Disabled entirely when JABS_DASHBOARD_URL is empty.
#
# Design note: unlike a versioned backup agent, each configured pair here is
# an ongoing *mirror* rather than a rotating set of dated archives. So each
# pair gets exactly one stable target_id (derived from its label) that
# is reused/updated on every run, rather than a new dated set per run.
#
# The dashboard purges its own job records on a universal, dashboard-side
# retention schedule (see the dashboard's README.md Retention Purge section)
# — this script has no API to tell the dashboard when to purge records, and
# LOG_RETENTION_DAYS below only controls this script's own local log files.

jabs_enabled() { [[ -n "${JABS_DASHBOARD_URL}" ]]; }

# generate_uuid  →  prints a UUID (for run_id). Only called when JABS is
# enabled, so python3's availability has already been confirmed by then.
generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || date +%s%N
    fi
}

# jabs_event [--flag value]...
# Thin wrapper around jabs_client.py's `event` subcommand. Fire-and-forget:
# no-ops when JABS is disabled, and any failure (bad response, network
# error, missing python3) is logged as a warning and never aborts the
# calling sync. During --dry-run, events are still sent (so a dry run shows
# up on the dashboard for testing) but the message is prefixed "[DRY RUN]",
# matching local_sync_agent/snapshot_agent's convention. Extra args are
# passed straight through to jabs_client.py — see its --help for the full
# list of event fields.
jabs_event() {
    jabs_enabled || return 0

    local args=("$@")
    if ${DRY_RUN:-false}; then
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "--message" ]]; then
                args[$((i + 1))]="[DRY RUN] ${args[$((i + 1))]}"
                break
            fi
        done
    fi

    local output
    if ! output="$(python3 "${JABS_CLIENT}" event \
            --server-url "${JABS_DASHBOARD_URL}" \
            --agent-key "${JABS_AGENT_KEY}" \
            --version "${JABS_AGENT_VERSION}" \
            --agent-type "NAS Sync" \
            --timeout "${JABS_TIMEOUT}" \
            "${args[@]}" 2>&1)"; then
        warn "JABS event failed to send: ${output}"
        return 0
    fi
    [[ -n "${output}" ]] && debug "JABS: ${output}"
    return 0
}


# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

# parse_rsync_bytes <stats-line>  →  prints the raw byte count as an integer.
# RSYNC_BASE_OPTS enables --human-readable, so rsync's --stats lines report
# sizes like "Total transferred file size: 5.24M bytes" instead of a plain
# integer. This converts that back to bytes (K/M/G/T are all 1024-based,
# matching rsync's --human-readable formatting). Falls back to "0" if the
# line is missing or unparsable.
parse_rsync_bytes() {
    local line="$1"
    line="${line//,/}"
    local num
    num="$(grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?' <<< "${line}" | head -1)"
    [[ -z "${num}" ]] && { echo 0; return; }
    local suffix="${num: -1}"
    local mult=1
    case "${suffix}" in
        K) mult=1024;             num="${num%K}" ;;
        M) mult=$((1024**2));     num="${num%M}" ;;
        G) mult=$((1024**3));     num="${num%G}" ;;
        T) mult=$((1024**4));     num="${num%T}" ;;
    esac
    echo "scale=0; (${num}*${mult})/1" | bc
}

# parse_rsync_progress_line LINE  →  prints "PERCENT BYTES_PER_SEC" (space
# separated) on a match, or returns 1 on a non-matching line. Matches
# --info=progress2's overall-progress line, e.g.:
#   "      1,234,567  43%   12.34MB/s    0:00:10 (xfr#5, to-chk=120/200)"
parse_rsync_progress_line() {
    local line="$1"
    if [[ "${line}" =~ ([0-9]+)%[[:space:]]+([0-9.]+)(B|KB|MB|GB|TB)/s ]]; then
        local percent="${BASH_REMATCH[1]}"
        local rate_value="${BASH_REMATCH[2]}"
        local rate_unit="${BASH_REMATCH[3]}"
        local mult=1
        case "${rate_unit}" in
            KB) mult=1024 ;;
            MB) mult=$((1024**2)) ;;
            GB) mult=$((1024**3)) ;;
            TB) mult=$((1024**4)) ;;
        esac
        local bps
        bps="$(echo "scale=0; (${rate_value}*${mult})/1" | bc)"
        echo "${percent} ${bps}"
        return 0
    fi
    return 1
}

# watch_rsync_progress RUN_ID LABEL  →  reads rsync's --info=progress2
# lines from stdin (one per line, after \r→\n translation), throttling both
# the local log (10%-decile crossings) and the JABS progress POST (~5s
# wall-clock) independently. Best-effort: a parse miss on any line is simply
# skipped, never aborts the sync.
watch_rsync_progress() {
    local run_id="$1" label="$2"
    local last_post=0 last_decile=-1
    local line parsed percent bps decile now
    while IFS= read -r line; do
        parsed="$(parse_rsync_progress_line "${line}")" || continue
        percent="${parsed%% *}"
        bps="${parsed##* }"
        decile=$(( percent / 10 ))
        if (( decile > last_decile )); then
            last_decile=${decile}
            info "Progress: ${label} ${percent}%"
        fi
        now="$(date +%s)"
        if (( now - last_post >= 5 )); then
            last_post=${now}
            jabs_event --event-type "heartbeat" --message "Sync in progress" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --backup-type "sync" \
                --percent-complete "${percent}" --bytes-per-second "${bps}"
        fi
    done
}


check_dependencies() {
    local missing=()
    for cmd in rsync flock df mountpoint; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if jabs_enabled; then
        command -v python3 &>/dev/null || missing+=("python3 (required by JABS_DASHBOARD_URL)")
        command -v tee &>/dev/null || missing+=("tee (required for JABS progress reporting)")
        command -v stdbuf &>/dev/null || missing+=("stdbuf (required for JABS progress reporting)")
        [[ -f "${JABS_CLIENT}" ]] || die "JABS_DASHBOARD_URL is set but ${JABS_CLIENT} is missing"
        [[ -z "${JABS_AGENT_KEY}" ]] && die "JABS_DASHBOARD_URL is set but JABS_AGENT_KEY is empty — register this agent on the dashboard's Agents page and set its API key"
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi

    [[ -f "${NAS2_RSYNC_PASSWORD_FILE}" ]] || die "NAS2_RSYNC_PASSWORD_FILE (${NAS2_RSYNC_PASSWORD_FILE}) not found — create it with the rsync module password (chmod 600)"
    local _nas2_pw_perm
    _nas2_pw_perm="$(stat -c '%a' "${NAS2_RSYNC_PASSWORD_FILE}" 2>/dev/null || echo '')"
    [[ -n "${_nas2_pw_perm}" && "${_nas2_pw_perm}" != "600" ]] && warn "NAS2_RSYNC_PASSWORD_FILE permissions are ${_nas2_pw_perm}, expected 600 — run: chmod 600 ${NAS2_RSYNC_PASSWORD_FILE}"

    debug "Dependency check passed"
}

# nas2_target SUBDIR  →  prints the rsync daemon address for a module
# subpath. Double-colon syntax keeps the password out of the command line;
# it's supplied separately via --password-file (see sync_pair()).
nas2_target() {
    echo "${NAS2_RSYNC_USER}@${NAS2_RSYNC_HOST}::${NAS2_RSYNC_MODULE}/$1"
}

# Verify NAS2's rsync daemon module is reachable and the configured
# credentials are accepted. Lists the module root (no data transferred);
# dies on failure, matching check_nfs_mount's fail-fast style.
check_rsync_daemon() {
    local target
    target="$(nas2_target '')"
    if ! rsync --password-file="${NAS2_RSYNC_PASSWORD_FILE}" --contimeout=10 --list-only "${target}" &>/dev/null; then
        die "NAS2 rsync daemon (${target}) is unreachable or rejected the configured credentials"
    fi
    debug "NAS2 rsync daemon OK: ${target}"
}

# Verify a path is a live NFS mount (not just a local directory).
# Falls back to a basic mountpoint check if /proc/mounts isn't available.
check_nfs_mount() {
    local mount_point="$1"
    local label="$2"

    if ! mountpoint -q "${mount_point}"; then
        die "${label} (${mount_point}) is not mounted"
    fi

    # Extra check: make sure it is actually NFS/NFS4, not a stale bind-mount
    if [[ -r /proc/mounts ]]; then
        if ! grep -qE "\s${mount_point}\s+(nfs|nfs4)\s" /proc/mounts; then
            warn "${label} (${mount_point}) is mounted but does NOT appear to be NFS — continuing anyway"
        fi
    fi

    # Accessibility check: attempt a quick stat of the mount root
    if ! stat "${mount_point}" &>/dev/null; then
        die "${label} (${mount_point}) is mounted but not accessible (NFS timeout?)"
    fi

    debug "${label} mount OK: ${mount_point}"
}

# Verify there is enough free space on a destination mount
check_free_space() {
    local dest_mount="$1"
    local label="$2"

    [[ "${MIN_FREE_BYTES}" -eq 0 ]] && return 0

    # df --output=avail returns KiB
    local avail_kib
    avail_kib=$(df --output=avail "${dest_mount}" 2>/dev/null | tail -n1 | tr -d ' ') || {
        warn "Could not determine free space on ${label}; skipping check"
        return 0
    }
    local avail_bytes=$(( avail_kib * 1024 ))

    if [[ ${avail_bytes} -lt ${MIN_FREE_BYTES} ]]; then
        local avail_gib=$(( avail_bytes / 1024 / 1024 / 1024 ))
        local min_gib=$(( MIN_FREE_BYTES / 1024 / 1024 / 1024 ))
        warn "${label} has only ${avail_gib} GiB free (minimum ${min_gib} GiB)"
        return 1
    fi

    local avail_gib=$(( avail_bytes / 1024 / 1024 / 1024 ))
    debug "${label} free space OK: ${avail_gib} GiB available"
    return 0
}


# ─────────────────────────────────────────────────────────────────────────────
# RSYNC RUNNER
# ─────────────────────────────────────────────────────────────────────────────

# build_exclude_args  →  prints --exclude=... flags for each pattern
build_exclude_args() {
    for pat in "${RSYNC_EXCLUDES[@]}"; do
        printf '%s\n' "--exclude=${pat}"
    done
}

# count_rsync_diffs CMD_ARRAY_NAME  →  runs an rsync --dry-run --itemize-changes
# command and prints the count of changed (non-directory) items. rsync's
# itemize output prefixes each changed item with an 11-char code (e.g.
# ">f.st....... file.txt"); an already-in-sync tree prints nothing.
_count_rsync_diffs() {
    "$@" 2>/dev/null | grep -cE '^[<>ch.].{9} ' || true
}

# verify_pair_quick SRC DST LABEL  →  low-cost post-sync check: compares size
# and mtime only (no file content is read), so it costs about the same as the
# sync's own directory-listing pass. Prints the mismatch count; never reads
# data and never fails the calling sync.
verify_pair_quick() {
    local src="$1" dst="$2" label="$3"
    local -a cmd=(rsync --archive --no-owner --no-group --dry-run --itemize-changes \
        --contimeout=10 "--password-file=${NAS2_RSYNC_PASSWORD_FILE}")
    while IFS= read -r excl_arg; do
        cmd+=("${excl_arg}")
    done < <(build_exclude_args)
    cmd+=("${src%/}/")
    cmd+=("${dst%/}/")

    local diff_count
    diff_count="$(_count_rsync_diffs "${cmd[@]}")"
    if [[ "${diff_count}" -gt 0 ]]; then
        warn "Verify (quick): ${diff_count} item(s) still differ after sync: ${label}"
    else
        debug "Verify (quick) OK: ${label}"
    fi
    echo "${diff_count}"
}

# check_pair_deep SRC DST LABEL  →  thorough (slow) manual check: reads and
# compares actual file content via rsync --checksum. Only ever invoked by the
# check-deep subcommand, never automatically.
check_pair_deep() {
    local src="$1" dst="$2" label="$3"

    # Only a local path side can be existence-checked ahead of time; a
    # remote rsync-daemon target ("::" syntax) is skipped here — rsync
    # itself reports a clear error if the module/subpath is wrong.
    if [[ "${src}" != *"::"* && ! -d "${src}" ]]; then
        warn "Deep check skipped: ${label} (source missing)"
        return 0
    fi
    if [[ "${dst}" != *"::"* && ! -d "${dst}" ]]; then
        warn "Deep check skipped: ${label} (dest missing)"
        return 0
    fi

    info "Deep check (reads all data, slow): ${label}"
    local -a cmd=(rsync --archive --no-owner --no-group --dry-run --checksum --itemize-changes \
        --contimeout=10 "--password-file=${NAS2_RSYNC_PASSWORD_FILE}")
    while IFS= read -r excl_arg; do
        cmd+=("${excl_arg}")
    done < <(build_exclude_args)
    cmd+=("${src%/}/")
    cmd+=("${dst%/}/")

    local diff_count
    diff_count="$(_count_rsync_diffs "${cmd[@]}")"
    if [[ "${diff_count}" -eq 0 ]]; then
        info "Deep check OK: ${label} (0 mismatched files)"
    else
        warn "Deep check found ${diff_count} mismatched file(s): ${label}"
    fi
}

# run_check_deep [--pair SUBSTRING]  →  runs check_pair_deep across all
# configured pairs, or only those whose label contains SUBSTRING.
run_check_deep() {
    local filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pair) filter="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    check_nfs_mount "${NAS1_MOUNT}" "NAS1"
    check_rsync_daemon

    local ran_any=false
    for pair in "${NAS1_TO_NAS2_PAIRS[@]}"; do
        local src_sub="${pair%%:*}" dst_sub="${pair##*:}"
        local label="NAS1:${src_sub} → NAS2:${dst_sub}"
        [[ -n "${filter}" && "${label}" != *"${filter}"* ]] && continue
        check_pair_deep "${NAS1_MOUNT}/${src_sub}" "$(nas2_target "${dst_sub}")" "${label}"
        ran_any=true
    done
    for pair in "${NAS2_TO_NAS1_PAIRS[@]}"; do
        local src_sub="${pair%%:*}" dst_sub="${pair##*:}"
        local label="NAS2:${src_sub} → NAS1:${dst_sub}"
        [[ -n "${filter}" && "${label}" != *"${filter}"* ]] && continue
        check_pair_deep "$(nas2_target "${src_sub}")" "${NAS1_MOUNT}/${dst_sub}" "${label}"
        ran_any=true
    done

    if ! ${ran_any}; then
        err "No pairs matched --pair \"${filter}\""
        return 1
    fi
    return 0
}

# sync_pair SOURCE_DIR DEST_DIR LABEL BWLIMIT_KB
#   Returns 0 on success, non-zero on failure.
sync_pair() {
    local src="$1"
    local dst="$2"
    local label="$3"
    local bwlimit="$4"

    debug "────────────────────────────────────────"
    info "Syncing: ${label}"
    debug "  Source : ${src}"
    debug "  Dest   : ${dst}"
    debug "  BW cap : ${bwlimit} KB/s ($( echo "scale=1; ${bwlimit}/1024" | bc ) MB/s)"
    $DRY_RUN && debug "  Mode   : DRY RUN (no changes will be made)"

    # Ensure source exists and is readable (skip the check for a remote
    # rsync-daemon target — "::" syntax — since there's no local path to stat)
    if [[ "${src}" != *"::"* && ! -d "${src}" ]]; then
        warn "Source directory does not exist: ${src} — skipping"
        PAIR_RESULTS+=("SKIP  ${label}  (source missing)")
        (( SKIPPED_PAIRS++ )) || true
        return 0
    fi

    # Ensure destination parent exists; create it if necessary. Skipped for a
    # remote rsync-daemon target ("::" syntax) — the module root already
    # exists on NAS2 and rsync creates subpaths under it as needed.
    # mkdir is run even in dry-run mode: it is an idempotent prerequisite,
    # not a sync change, and skipping it causes rsync to fail on new pairs.
    if [[ "${dst}" != *"::"* && ! -d "${dst}" ]]; then
        info "Creating destination directory: ${dst}"
        mkdir -p "${dst}" || {
            err "Failed to create destination: ${dst}"
            PAIR_RESULTS+=("FAIL  ${label}  (cannot create dest)")
            (( FAILED_PAIRS++ )) || true
            return 1
        }
    fi

    # ── JABS: one run_id per pair per run; correlates start/complete events ──
    local run_id=""
    jabs_enabled && run_id="$(generate_uuid)"

    # Track this pair as "in flight" so the EXIT trap can finalize it as
    # "stopped" if the whole script gets killed before we reach one of the
    # normal completion points below (cleared right before every return).
    if jabs_enabled; then
        CURRENT_RUN_ID="${run_id}"
        CURRENT_JOB_LABEL="${label}"
        CURRENT_JOB_START_EPOCH="$(date +%s)"
    fi

    # job_name is one constant value for the whole script run; target_id/
    # target_label stay the per-pair label so the dashboard shows each pair
    # as its own sub-target under that single job name.
    jabs_event \
        --event-type "heartbeat" \
        --message "Starting sync: ${label}" \
        --stage "Starting sync" \
        --run-id "${run_id}" \
        --job-run-id "${JOB_RUN_ID}" \
        --job-name "${JOB_NAME}" \
        --backup-type "sync" \
        --target-id "${label}" \
        --target-label "${label}" \
        --source "${src}" \
        --destination "${dst}" \
        --sync true

    # Assemble the rsync command
    local -a cmd=(rsync)
    cmd+=("${RSYNC_BASE_OPTS[@]}")
    cmd+=("${RSYNC_COMPRESS_OPTS[@]}")
    cmd+=("--bwlimit=${bwlimit}")
    cmd+=("--contimeout=10" "--password-file=${NAS2_RSYNC_PASSWORD_FILE}")  # NAS2 is always one side of every pair
    cmd+=(--stats)   # always collected: parsed below to report file/byte counts to JABS
    jabs_enabled && cmd+=(--info=progress2)

    $DRY_RUN && cmd+=(--dry-run)

    # Add exclude args
    while IFS= read -r excl_arg; do
        cmd+=("${excl_arg}")
    done < <(build_exclude_args)

    # Trailing slash on source: sync CONTENTS of src into dst
    cmd+=("${src%/}/")
    cmd+=("${dst%/}/")

    debug "Command: ${cmd[*]}"
    debug "────────────────────────────────────────"

    # ── Deadline / timeout ──────────────────────────────────────────────────
    # If STOP_HOUR is set, wrap rsync with `timeout <remaining_seconds>` so it
    # is sent SIGTERM at the deadline.  rsync exits cleanly on SIGTERM and the
    # partial file is preserved (--partial) for the next run to resume.
    # rsync stderr is routed through our warn() logger so signal messages are
    # timestamped and prefixed rather than appearing as raw unformatted lines.
    local stats_file
    stats_file="$(mktemp "${LOG_DIR}/.rsync_stats.XXXXXX")"
    local start_epoch
    start_epoch="$(date +%s)"

    local exit_code=0
    local _remaining=0
    if [[ "${DEADLINE_EPOCH}" -gt 0 ]]; then
        _remaining=$(( DEADLINE_EPOCH - $(date +%s) ))
        if (( _remaining <= 0 )); then
            info "Deadline reached — skipping ${label} (will resume next run)"
            PAIR_RESULTS+=("STOP  ${label}  (deadline — resumes next run)")
            (( SKIPPED_PAIRS++ )) || true
            DEADLINE_REACHED=true
            rm -f "${stats_file}"
            local duration=$(( $(date +%s) - start_epoch ))
            # Finalized as "stopped" (not left running) so the dashboard
            # doesn't show a stale spinner; resumes fresh on the next run.
            jabs_event --event-type "backup_complete" --status "stopped" --stage "Stopped" \
                --message "Deadline reached before job could start (resumes next run)" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up 0 --bytes-backed-up 0 \
                --error-message "Deadline reached before ${label} could start (resumes next run)"
            CURRENT_RUN_ID=""
            return 0
        fi
        debug "Deadline in ${_remaining}s — passing to timeout"
    fi

    # Set up rsync's stdout/stderr destinations and capture the reader PIDs
    # so we can wait on exactly those processes below — a bare `wait` would
    # also block on the whole-script `exec > >(tee ...)` logger started at
    # startup, which never exits until the script itself does.
    local out_pid="" err_pid=""
    if jabs_enabled; then
        exec 3> >(stdbuf -oL tr '\r' '\n' | tee "${stats_file}" | watch_rsync_progress "${run_id}" "${label}")
        out_pid=$!
    else
        exec 3>"${stats_file}"
    fi
    exec 4> >(while IFS= read -r _l; do warn "rsync: ${_l}"; done)
    err_pid=$!

    local -a run_cmd=("${cmd[@]}")
    if [[ "${DEADLINE_EPOCH}" -gt 0 ]]; then
        run_cmd=(timeout --kill-after=5 "${_remaining}" "${cmd[@]}")
    fi

    # Backgrounded (rather than run synchronously) so a trapped TERM/INT
    # (manual stop, see _handle_stop_signal) interrupts `wait` immediately
    # instead of being deferred until rsync exits on its own.
    "${run_cmd[@]}" >&3 2>&4 &
    RSYNC_PID=$!

    wait "${RSYNC_PID}" || exit_code=$?
    # An interrupted `wait` returns early with a synthetic 128+signum status
    # before rsync has actually exited; keep waiting until it's truly gone so
    # exit_code reflects rsync's real exit status (20 on signal receipt).
    while (( exit_code > 128 )) && kill -0 "${RSYNC_PID}" 2>/dev/null; do
        wait "${RSYNC_PID}" || exit_code=$?
    done
    RSYNC_PID=""

    # Close our copies of fd 3/4 so the readers see EOF, then wait only on
    # those specific reader PIDs so stats_file is fully written before it's
    # grepped below.
    exec 3>&- 4>&-
    [[ -n "${out_pid}" ]] && wait "${out_pid}" 2>/dev/null
    wait "${err_pid}" 2>/dev/null

    # rsync's --stats output is verbose; only the summary line is worth
    # keeping in the log, and it needs our timestamp/level prefix like every
    # other log line rather than being dumped raw.
    local total_size_line
    total_size_line="$(grep -m1 '^total size is' "${stats_file}" 2>/dev/null || true)"
    [[ -n "${total_size_line}" ]] && info "${total_size_line}"

    local end_epoch
    end_epoch="$(date +%s)"
    local duration=$(( end_epoch - start_epoch ))

    # Pull file/byte counts out of the --stats block for JABS reporting.
    # Falls back to 0 if a line is missing (e.g. rsync version differences).
    # NOTE: RSYNC_BASE_OPTS includes --human-readable, so rsync prints sizes
    # like "5.24M bytes" instead of a raw byte count. parse_rsync_bytes()
    # below converts that back to a real byte count; without it this used to
    # silently truncate to just the leading digit(s) (e.g. "5"), which could
    # end up looking identical to (or nowhere near) the files-transferred
    # count.
    local files_transferred bytes_transferred
    files_transferred="$(grep -m1 'Number of regular files transferred:' "${stats_file}" 2>/dev/null | grep -oE '[0-9,]+' | tr -d ',')"
    bytes_transferred="$(parse_rsync_bytes "$(grep -m1 'Total transferred file size:' "${stats_file}" 2>/dev/null)")"
    rm -f "${stats_file}"
    : "${files_transferred:=0}"
    : "${bytes_transferred:=0}"

    case ${exit_code} in
        0)
            info "SUCCESS: ${label}"
            PAIR_RESULTS+=("OK    ${label}")
            jabs_event --event-type "backup_complete" --status "success" \
                --message "Sync complete" --stage "Completed" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up "${files_transferred}" \
                --bytes-backed-up "${bytes_transferred}"
            ;;
        23|24)
            # 23 = partial transfer (some files skipped due to errors)
            # 24 = partial transfer (some source files vanished mid-run)
            warn "PARTIAL: ${label} — some files were skipped (rsync exit ${exit_code})"
            PAIR_RESULTS+=("WARNING  ${label}  (partial, exit ${exit_code})")
            jabs_event --event-type "backup_complete" --status "success" \
                --message "Sync complete with warnings (rsync exit ${exit_code}, some files skipped)" \
                --stage "Completed (partial)" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up "${files_transferred}" \
                --bytes-backed-up "${bytes_transferred}"
            ;;
        20)
            # rsync received SIGTERM/SIGINT/SIGHUP — either a manual stop
            # (./nas_sync.sh stop) or some other external signal; treated the
            # same as a deadline stop either way (resumes next run).
            local stop_msg
            if ${STOP_REQUESTED}; then
                stop_msg="${label} stopped manually (partial transfer saved; resumes next run)"
                warn "STOPPED: ${stop_msg}"
                PAIR_RESULTS+=("STOP  ${label}  (manual stop — resumes next run)")
            else
                stop_msg="${label} interrupted (partial transfer saved; resumes next run)"
                warn "INTERRUPTED: ${stop_msg}"
                PAIR_RESULTS+=("STOP  ${label}  (interrupted — resumes next run)")
            fi
            (( SKIPPED_PAIRS++ )) || true
            DEADLINE_REACHED=true
            # Finalized as "stopped" (not left running) so the dashboard
            # doesn't show a stale spinner; resumes fresh on the next run.
            jabs_event --event-type "backup_complete" --status "stopped" --stage "Stopped" \
                --message "${stop_msg}" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up "${files_transferred}" \
                --bytes-backed-up "${bytes_transferred}" \
                --error-message "${stop_msg}"
            ;;
        124)
            # timeout sent SIGTERM at the deadline; rsync saved the partial file
            warn "DEADLINE: ${label} — rsync stopped at deadline (partial transfer saved; will resume next run)"
            PAIR_RESULTS+=("STOP  ${label}  (deadline — resumes next run)")
            (( SKIPPED_PAIRS++ )) || true
            DEADLINE_REACHED=true
            # Finalized as "stopped" (not left running) so the dashboard
            # doesn't show a stale spinner; resumes fresh on the next run.
            jabs_event --event-type "backup_complete" --status "stopped" --stage "Stopped" \
                --message "Job stopped at deadline (partial transfer saved; resumes next run)" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up "${files_transferred}" \
                --bytes-backed-up "${bytes_transferred}" \
                --error-message "Job stopped at deadline (partial transfer saved; resumes next run)"
            ;;
        *)
            err "FAILED: ${label} — rsync exit code ${exit_code}"
            PAIR_RESULTS+=("FAIL  ${label}  (exit ${exit_code})")
            (( FAILED_PAIRS++ )) || true
            jabs_event --event-type "error" --status "failed" \
                --message "Sync failed: ${label}" --stage "Error" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --error-code "${exit_code}" \
                --error-message "rsync exit code ${exit_code}"
            CURRENT_RUN_ID=""
            return 1
            ;;
    esac

    if [[ "${VERIFY_AFTER_SYNC}" == "true" ]] && ! $DRY_RUN && [[ ${exit_code} -eq 0 || ${exit_code} -eq 23 || ${exit_code} -eq 24 ]]; then
        local mismatch_count
        mismatch_count="$(verify_pair_quick "${src}" "${dst}" "${label}")"
        if [[ "${mismatch_count}" -gt 0 ]]; then
            jabs_event --event-type "heartbeat" --status "success" \
                --message "Sync completed but quick verify found ${mismatch_count} differing item(s)" \
                --stage "Verify (quick)" \
                --run-id "${run_id}" --job-name "${JOB_NAME}" --target-id "${label}" \
                --target-label "${label}" --backup-type "sync"
        fi
    fi

    CURRENT_RUN_ID=""
    return 0
}


# ─────────────────────────────────────────────────────────────────────────────
# LOG ROTATION
# ─────────────────────────────────────────────────────────────────────────────

rotate_logs() {
    find "${LOG_DIR}" -maxdepth 1 -name "nas_sync_*.log" \
        -mtime "+${LOG_RETENTION_DAYS}" -delete \
        && debug "Old logs pruned (>${LOG_RETENTION_DAYS} days)"
}


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    RUN_START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    RUN_START_EPOCH="$(date +%s)"

    info "════════════════════════════════════════════════════════"
    info "nas_sync.sh  started at ${RUN_START_TIME}"
    info "Log: ${LOG_FILE}"
    $DRY_RUN && info "*** DRY RUN MODE — no changes will be written ***"
    info "════════════════════════════════════════════════════════"

    # ── Uptime Kuma — no start ping needed ────────────────────────────────
    # Uptime Kuma push monitors only need a final status ping (up/down).
    # The exit trap sends a down ping on unexpected termination.
    # die() calls uptime_kuma_ping "down" automatically on preflight failures.

    # ── Deadline setup ──────────────────────────────────────────────────────
    # Calculate the absolute epoch for STOP_HOUR.  If that hour has already
    # passed today, target tomorrow (handles cron jobs that start just before
    # midnight and must run through to e.g. 08:00 the next morning).
    # Each rsync call is wrapped with `timeout <remaining_seconds>` so it is
    # sent SIGTERM at the deadline.  rsync exits cleanly and --partial keeps
    # the incomplete file so the next run resumes automatically.
    DEADLINE_EPOCH=0
    DEADLINE_REACHED=false
    if [[ -n "${STOP_HOUR:-}" && "${STOP_HOUR}" =~ ^[0-9]+$ && "${STOP_HOUR}" -lt 24 ]]; then
        local _stop_today
        _stop_today=$(date -d "today ${STOP_HOUR}:00:00" +%s)
        if (( _stop_today <= RUN_START_EPOCH )); then
            DEADLINE_EPOCH=$(date -d "tomorrow ${STOP_HOUR}:00:00" +%s)
        else
            DEADLINE_EPOCH=${_stop_today}
        fi
        local _secs=$(( DEADLINE_EPOCH - RUN_START_EPOCH ))
        local _dl_fmt; printf -v _dl_fmt '%dh %02dm' $(( _secs/3600 )) $(( (_secs%3600)/60 ))
        info "Deadline : $(date -d "@${DEADLINE_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z')  (${_dl_fmt} from now)"
    fi

    # ── Dependency check ───────────────────────────────────────────────────
    check_dependencies

    # ── JABS — bare heartbeat ────────────────────────────────────────────────
    # No event_type/target_id → server just records host online + version,
    # without touching any backup job. Sent once per run regardless of
    # whether any pairs end up running. JOB_CRON (if set) reports this
    # script's crontab schedule for the dashboard's "Next Event" column.
    jabs_event --message "nas_sync run started" --job-name "${JOB_NAME}" --cron-schedule "${JOB_CRON}"

    # One ID shared by every pair in this invocation, distinct from each
    # pair's own run_id — lets the dashboard group all pairs into a single
    # "job run" and use its earliest start, not any one pair's.
    JOB_RUN_ID="$(generate_uuid)"

    # ── Acquire exclusive lock ─────────────────────────────────────────────
    # flock releases automatically when file descriptor 200 is closed (exit).
    exec 200>"${LOCK_FILE}"
    if ! flock --nonblock 200; then
        die "Another instance of ${SCRIPT_NAME} is already running (lock: ${LOCK_FILE})"
    fi
    debug "Lock acquired: ${LOCK_FILE}"

    # PID file for `./nas_sync.sh stop` (or a plain `kill`) to target.
    # Written after the lock so it always reflects the one instance that
    # actually won the lock; removed on normal completion below.
    echo $$ > "${PID_FILE}"

    # ── Connectivity verification ───────────────────────────────────────────
    check_nfs_mount "${NAS1_MOUNT}" "NAS1"
    check_rsync_daemon

    # ── Process NAS1 → NAS2 pairs ─────────────────────────────────────────
    if [[ ${#NAS1_TO_NAS2_PAIRS[@]} -gt 0 ]]; then
        info ""
        info "━━━ NAS1 → NAS2 (${#NAS1_TO_NAS2_PAIRS[@]} pair(s)) ━━━━━━━━━━━━━━━━━━━━━━━━"

        # No free-space pre-check here: NAS2 is a remote rsync-daemon target
        # (not a local mount), so df isn't available for it.
        for pair in "${NAS1_TO_NAS2_PAIRS[@]}"; do
            local src_sub="${pair%%:*}"
            local dst_sub="${pair##*:}"
            local src="${NAS1_MOUNT}/${src_sub}"
            local dst
            dst="$(nas2_target "${dst_sub}")"
            local label="NAS1:${src_sub} → NAS2:${dst_sub}"
            (( TOTAL_PAIRS++ )) || true

            sync_pair "${src}" "${dst}" "${label}" "${BWLIMIT_NAS1_TO_NAS2}" || true
            if $DEADLINE_REACHED || $STOP_REQUESTED; then
                if $STOP_REQUESTED; then
                    info "Stop requested — stopping NAS1→NAS2 loop"
                else
                    info "Deadline reached — stopping NAS1→NAS2 loop"
                fi
                break
            fi
        done
    fi

    # ── Process NAS2 → NAS1 pairs ─────────────────────────────────────────
    if [[ ${#NAS2_TO_NAS1_PAIRS[@]} -gt 0 ]]; then
        info ""
        info "━━━ NAS2 → NAS1 (${#NAS2_TO_NAS1_PAIRS[@]} pair(s)) ━━━━━━━━━━━━━━━━━━━━━━━━"

        local nas1_space_ok=true
        check_free_space "${NAS1_MOUNT}" "NAS1 (destination)" || nas1_space_ok=false

        for pair in "${NAS2_TO_NAS1_PAIRS[@]}"; do
            local src_sub="${pair%%:*}"
            local dst_sub="${pair##*:}"
            local src
            src="$(nas2_target "${src_sub}")"
            local dst="${NAS1_MOUNT}/${dst_sub}"
            local label="NAS2:${src_sub} → NAS1:${dst_sub}"
            (( TOTAL_PAIRS++ )) || true

            if ! $nas1_space_ok; then
                warn "Skipping ${label} — NAS1 low on space"
                PAIR_RESULTS+=("SKIP  ${label}  (dest low space)")
                (( SKIPPED_PAIRS++ )) || true
                continue
            fi

            sync_pair "${src}" "${dst}" "${label}" "${BWLIMIT_NAS2_TO_NAS1}" || true
            if $DEADLINE_REACHED || $STOP_REQUESTED; then
                if $STOP_REQUESTED; then
                    info "Stop requested — stopping NAS2→NAS1 loop"
                else
                    info "Deadline reached — stopping NAS2→NAS1 loop"
                fi
                break
            fi
        done
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    local elapsed=$(( $(date +%s) - RUN_START_EPOCH ))
    local elapsed_fmt
    printf -v elapsed_fmt '%dh %02dm %02ds' \
        $(( elapsed / 3600 )) $(( (elapsed % 3600) / 60 )) $(( elapsed % 60 ))

    info ""
    info "════════════════════════════════════════════════════════"
    local run_stopped_early=false
    { $DEADLINE_REACHED || $STOP_REQUESTED; } && run_stopped_early=true
    if $run_stopped_early; then
        if $STOP_REQUESTED; then
            info "Run stopped manually"
        else
            info "Run stopped at deadline (STOP_HOUR=${STOP_HOUR:-unset})"
        fi
    else
        info "Run complete"
    fi
    info "  Duration    : ${elapsed_fmt}"
    info "  Total pairs : ${TOTAL_PAIRS}"
    info "  Failed      : ${FAILED_PAIRS}"
    info "  Skipped     : ${SKIPPED_PAIRS}"
    for r in "${PAIR_RESULTS[@]}"; do
        info "  ${r}"
    done
    info "  Log         : ${LOG_FILE}"
    info "════════════════════════════════════════════════════════"

    # ── Log rotation ────────────────────────────────────────────────────────
    rotate_logs

    # ── Uptime Kuma final ping ───────────────────────────────────────────────
    local final_status="OK"
    [[ ${FAILED_PAIRS} -gt 0 ]] && final_status="FAILED (${FAILED_PAIRS} pair(s))"
    [[ ${SKIPPED_PAIRS} -gt 0 && ${FAILED_PAIRS} -eq 0 ]] && final_status="OK (${SKIPPED_PAIRS} skipped)"
    if $run_stopped_early; then
        if $STOP_REQUESTED; then
            final_status="STOPPED MANUALLY — ${final_status}"
        else
            final_status="STOPPED AT DEADLINE — ${final_status}"
        fi
    fi
    $DRY_RUN && final_status="DRY RUN — ${final_status}"

    local uk_status="up"
    [[ ${FAILED_PAIRS} -gt 0 ]] && uk_status="down"
    uptime_kuma_ping "${uk_status}" "${final_status} | pairs: ${TOTAL_PAIRS}, failed: ${FAILED_PAIRS}, skipped: ${SKIPPED_PAIRS}"

    rm -f "${PID_FILE}"
    _COMPLETED=true   # disarm the EXIT trap

    # Exit non-zero if any pair failed so cron/monitoring can catch it
    [[ ${FAILED_PAIRS} -eq 0 ]]
}

if [[ "${1:-}" == "check-deep" ]]; then
    shift
    # Manual diagnostic command — never treat its exit code as an unexpected
    # crash (that would fire the EXIT trap's Uptime Kuma "down" ping).
    _COMPLETED=true
    run_check_deep "$@"
    exit $?
fi

main "$@"
