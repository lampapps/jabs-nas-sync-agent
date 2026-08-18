#!/usr/bin/env bash
# =============================================================================
# nas_sync.sh — Bidirectional NAS sync over NFS / Tailscale
# =============================================================================
#
# TOPOLOGY
#   Client (this machine) has both NAS devices mounted via NFS.
#   NAS1 is on the same LAN as this client.
#   NAS2 is remote, reachable over Tailscale.
#   rsync reads/writes NFS mount points locally; all WAN traffic flows over
#   the Tailscale tunnel between the two NAS devices' host ISPs.
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
#   Cron (nightly): see README.md
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
#   python3      — only required if JABS_SERVER_URL is set (see below).
#                  Used to run jabs_client.py, which reports sync activity
#                  to a JABS dashboard's Agent Monitoring API.
#                  Debian/Ubuntu : sudo apt install python3
#                  RHEL/Fedora   : sudo dnf install python3
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Resolve the directory this script lives in (works regardless of cwd)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# COLOR OUTPUT / PRINT HELPERS
# (kept consistent with dashboard/jabs-dashboard.sh and
#  file_backup_agent/jabs-agent.sh — see AGENTS.md "Bash Launcher Scripts")
# ─────────────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
    echo "Next steps:"
    echo "  1. Edit: ${conf_file}"
    echo "  2. (Optional) Configure JABS_SERVER_URL/JABS_AGENT_KEY in that file to report to a dashboard"
    echo "  3. Test:   $0 --dry-run --debug"
    echo "  4. Run:    $0"
    echo "  5. Add a CRON job for nightly runs (see: $0 help)"
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
NAS Sync Agent Launcher

USAGE:
  $0 [--dry-run] [--debug]
  $0 {setup|logs|reset|help}

COMMANDS:
  (no args)    - Run the bidirectional sync (default cron invocation)
  --dry-run    - Simulate the sync without writing changes
  --debug      - Verbose logging
  setup        - Create nas_sync.conf from the example, create logs/, check deps
  logs         - Follow the most recent run's log
  reset        - Reset app (clear logs, lock file)
  help         - Show this help message

DIRECTORIES:
  Script:      ${SCRIPT_DIR}
  Config:      ${SCRIPT_DIR}/nas_sync.conf
  Logs:        ${SCRIPT_DIR}/logs

SETUP:
  1. Run: $0 setup
  2. Edit: ${SCRIPT_DIR}/nas_sync.conf
  3. Test: $0 --dry-run --debug
  4. Add CRON job: crontab -e
     0 23 * * * ${SCRIPT_DIR}/nas_sync.sh

EXAMPLES:
  # Initial setup
  $0 setup

  # Dry run with verbose output
  $0 --dry-run --debug

  # Real run
  $0

  # Follow logs
  $0 logs

  # Reset app state
  $0 reset

EOF
    echo "COPY/PASTE COMMANDS (this host):"
    echo ""
    echo "  Run sync manually:"
    echo "    ${SCRIPT_DIR}/nas_sync.sh"
    echo ""
    echo "  Dry run (no changes written):"
    echo "    ${SCRIPT_DIR}/nas_sync.sh --dry-run --debug"
    echo ""
    echo "  CRON entry (nightly at 23:00):"
    echo "    0 23 * * * ${SCRIPT_DIR}/nas_sync.sh"
    echo ""
}

case "${1:-}" in
    setup) cmd_setup; exit $? ;;
    logs)  cmd_logs;  exit $? ;;
    reset) cmd_reset; exit $? ;;
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
LOG_DIR="${SCRIPT_DIR}/logs"
JABS_CLIENT="${SCRIPT_DIR}/jabs_client.py"

# Defaults for JABS settings, so a nas_sync.conf from before this feature
# existed still loads fine (JABS reporting simply stays disabled).
: "${JABS_SERVER_URL:=}"
: "${JABS_AGENT_KEY:=}"
: "${JABS_HOSTNAME:=$(hostname)}"
: "${JABS_IP_ADDRESS:=}"
: "${JABS_AGENT_VERSION:=1.0.0}"
: "${JABS_TIMEOUT:=10}"

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

# Dry-run and debug flags
DRY_RUN=false
DEBUG=false
for _arg in "$@"; do
    case "${_arg}" in
        --dry-run|-n) DRY_RUN=true ;;
        --debug|-v)   DEBUG=true  ;;
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
warn()  { log "WARN  $*"; }
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
    ${_COMPLETED:-false} && return   # normal shutdown — already pinged
    ${DRY_RUN:-false}    && return   # test run — never pings Uptime Kuma
    local msg="unexpected exit"
    [[ $rc -ne 0 ]] && msg="unexpected exit (code ${rc})"
    err "Script terminated unexpectedly — sending Uptime Kuma down ping"
    uptime_kuma_ping "down" "${msg}"
}
trap '_exit_trap' EXIT


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
# AGENT_API_GUIDE.md). Disabled entirely when JABS_SERVER_URL is empty.
#
# Design note: unlike a versioned backup agent, each configured pair here is
# an ongoing *mirror* rather than a rotating set of dated archives. So each
# pair gets exactly one stable backup_set_id (derived from its label) that
# is reused/updated on every run, rather than a new dated set per run.
#
# The dashboard purges its own job records on a universal, dashboard-side
# retention schedule (see the dashboard's README.md Retention Purge section)
# — this script has no API to tell the dashboard when to purge records, and
# LOG_RETENTION_DAYS below only controls this script's own local log files.

jabs_enabled() { [[ -n "${JABS_SERVER_URL}" ]]; }

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
# no-ops when JABS is disabled or during --dry-run, and any failure (bad
# response, network error, missing python3) is logged as a warning and never
# aborts the calling sync. Extra args are passed straight through to
# jabs_client.py — see its --help for the full list of event fields.
jabs_event() {
    jabs_enabled || return 0
    if ${DRY_RUN:-false}; then
        debug "JABS (dry-run, not sent): $*"
        return 0
    fi

    local output
    if ! output="$(python3 "${JABS_CLIENT}" event \
            --server-url "${JABS_SERVER_URL}" \
            --agent-key "${JABS_AGENT_KEY}" \
            --hostname "${JABS_HOSTNAME}" \
            --ip-address "${JABS_IP_ADDRESS}" \
            --version "${JABS_AGENT_VERSION}" \
            --agent-type "NAS Sync" \
            --timeout "${JABS_TIMEOUT}" \
            "$@" 2>&1)"; then
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

check_dependencies() {
    local missing=()
    for cmd in rsync flock df mountpoint; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if jabs_enabled; then
        command -v python3 &>/dev/null || missing+=("python3 (required by JABS_SERVER_URL)")
        [[ -f "${JABS_CLIENT}" ]] || die "JABS_SERVER_URL is set but ${JABS_CLIENT} is missing"
        [[ -z "${JABS_AGENT_KEY}" ]] && die "JABS_SERVER_URL is set but JABS_AGENT_KEY is empty — register this agent on the dashboard's Hosts page and set its API key"
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
    debug "Dependency check passed"
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

    # Ensure source exists and is readable
    if [[ ! -d "${src}" ]]; then
        warn "Source directory does not exist: ${src} — skipping"
        PAIR_RESULTS+=("SKIP  ${label}  (source missing)")
        (( SKIPPED_PAIRS++ )) || true
        return 0
    fi

    # Ensure destination parent exists; create it if necessary.
    # mkdir is run even in dry-run mode: it is an idempotent prerequisite,
    # not a sync change, and skipping it causes rsync to fail on new pairs.
    if [[ ! -d "${dst}" ]]; then
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

    # backup_set_name is a display label; for nas_sync_agent this is the
    # same as the stable per-pair job_name/backup_set_id, since this is an
    # ongoing mirror (not a dated set) — there is only ever one backup set
    # per pair, and it should always group under that one label on the
    # dashboard.
    jabs_event \
        --event-type "heartbeat" \
        --message "Starting sync: ${label}" \
        --stage "Starting sync" \
        --run-id "${run_id}" \
        --job-name "${label}" \
        --backup-type "sync" \
        --backup-set-id "${label}" \
        --backup-set-name "${label}" \
        --source "${src}" \
        --destination "${dst}" \
        --sync true

    # Assemble the rsync command
    local -a cmd=(rsync)
    cmd+=("${RSYNC_BASE_OPTS[@]}")
    cmd+=("--bwlimit=${bwlimit}")
    cmd+=(--stats)   # always collected: parsed below to report file/byte counts to JABS

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
    if [[ "${DEADLINE_EPOCH}" -gt 0 ]]; then
        local _remaining=$(( DEADLINE_EPOCH - $(date +%s) ))
        if (( _remaining <= 0 )); then
            info "Deadline reached — skipping ${label} (will resume next run)"
            PAIR_RESULTS+=("STOP  ${label}  (deadline — resumes next run)")
            (( SKIPPED_PAIRS++ )) || true
            DEADLINE_REACHED=true
            rm -f "${stats_file}"
            jabs_event --event-type "heartbeat" --stage "Stopped" \
                --message "Deadline reached before ${label} could start (resumes next run)" \
                --run-id "${run_id}" --job-name "${label}" --backup-set-id "${label}"
            return 0
        fi
        debug "Deadline in ${_remaining}s — passing to timeout"
        timeout --kill-after=5 "${_remaining}" "${cmd[@]}" \
            > "${stats_file}" \
            2> >(while IFS= read -r _l; do warn "rsync: ${_l}"; done) || exit_code=$?
    else
        "${cmd[@]}" \
            > "${stats_file}" \
            2> >(while IFS= read -r _l; do warn "rsync: ${_l}"; done) || exit_code=$?
    fi

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
                --run-id "${run_id}" --job-name "${label}" --backup-set-id "${label}" \
                --backup-set-name "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up "${files_transferred}" \
                --bytes-backed-up "${bytes_transferred}"
            ;;
        23|24)
            # 23 = partial transfer (some files skipped due to errors)
            # 24 = partial transfer (some source files vanished mid-run)
            warn "PARTIAL: ${label} — some files were skipped (rsync exit ${exit_code})"
            PAIR_RESULTS+=("WARN  ${label}  (partial, exit ${exit_code})")
            jabs_event --event-type "backup_complete" --status "success" \
                --message "Sync complete with warnings (rsync exit ${exit_code}, some files skipped)" \
                --stage "Completed (partial)" \
                --run-id "${run_id}" --job-name "${label}" --backup-set-id "${label}" \
                --backup-set-name "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --files-backed-up "${files_transferred}" \
                --bytes-backed-up "${bytes_transferred}"
            ;;
        20)
            # rsync received SIGTERM/SIGINT/SIGHUP — treated as a deadline stop
            # (only reaches here if rsync exits with 20 before timeout can return 124)
            warn "INTERRUPTED: ${label} — rsync received a signal (partial transfer saved; will resume next run)"
            PAIR_RESULTS+=("STOP  ${label}  (interrupted — resumes next run)")
            (( SKIPPED_PAIRS++ )) || true
            DEADLINE_REACHED=true
            # Not finalized as complete/error — the job stays "running" on the
            # dashboard until a future run finishes it (a resumable pause).
            jabs_event --event-type "heartbeat" --stage "Stopped" \
                --message "${label} interrupted (partial transfer saved; resumes next run)" \
                --run-id "${run_id}" --job-name "${label}" --backup-set-id "${label}"
            ;;
        124)
            # timeout sent SIGTERM at the deadline; rsync saved the partial file
            warn "DEADLINE: ${label} — rsync stopped at deadline (partial transfer saved; will resume next run)"
            PAIR_RESULTS+=("STOP  ${label}  (deadline — resumes next run)")
            (( SKIPPED_PAIRS++ )) || true
            DEADLINE_REACHED=true
            jabs_event --event-type "heartbeat" --stage "Stopped" \
                --message "${label} stopped at deadline (partial transfer saved; resumes next run)" \
                --run-id "${run_id}" --job-name "${label}" --backup-set-id "${label}"
            ;;
        *)
            err "FAILED: ${label} — rsync exit code ${exit_code}"
            PAIR_RESULTS+=("FAIL  ${label}  (exit ${exit_code})")
            (( FAILED_PAIRS++ )) || true
            jabs_event --event-type "error" --status "failed" \
                --message "Sync failed: ${label}" --stage "Error" \
                --run-id "${run_id}" --job-name "${label}" --backup-set-id "${label}" \
                --backup-set-name "${label}" --backup-type "sync" \
                --duration-seconds "${duration}" \
                --error-code "${exit_code}" \
                --error-message "rsync exit code ${exit_code}"
            return 1
            ;;
    esac
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
    # No event_type/backup_set_id → server just records host online + version,
    # without touching any backup job. Sent once per run regardless of
    # whether any pairs end up running.
    jabs_event --message "nas_sync run started"

    # ── Acquire exclusive lock ─────────────────────────────────────────────
    # flock releases automatically when file descriptor 200 is closed (exit).
    exec 200>"${LOCK_FILE}"
    if ! flock --nonblock 200; then
        die "Another instance of ${SCRIPT_NAME} is already running (lock: ${LOCK_FILE})"
    fi
    debug "Lock acquired: ${LOCK_FILE}"

    # ── Mount verification ─────────────────────────────────────────────────
    check_nfs_mount "${NAS1_MOUNT}" "NAS1"
    check_nfs_mount "${NAS2_MOUNT}" "NAS2"

    # Total expected pairs — used for progress messages
    local total_expected=$(( ${#NAS1_TO_NAS2_PAIRS[@]} + ${#NAS2_TO_NAS1_PAIRS[@]} ))

    # ── Process NAS1 → NAS2 pairs ─────────────────────────────────────────
    if [[ ${#NAS1_TO_NAS2_PAIRS[@]} -gt 0 ]]; then
        info ""
        info "━━━ NAS1 → NAS2 (${#NAS1_TO_NAS2_PAIRS[@]} pair(s)) ━━━━━━━━━━━━━━━━━━━━━━━━"

        # Free space check on destination (NAS2)
        local nas2_space_ok=true
        check_free_space "${NAS2_MOUNT}" "NAS2 (destination)" || nas2_space_ok=false

        for pair in "${NAS1_TO_NAS2_PAIRS[@]}"; do
            local src_sub="${pair%%:*}"
            local dst_sub="${pair##*:}"
            local src="${NAS1_MOUNT}/${src_sub}"
            local dst="${NAS2_MOUNT}/${dst_sub}"
            local label="NAS1:${src_sub} → NAS2:${dst_sub}"
            (( TOTAL_PAIRS++ )) || true

            if ! $nas2_space_ok; then
                warn "Skipping ${label} — NAS2 low on space"
                PAIR_RESULTS+=("SKIP  ${label}  (dest low space)")
                (( SKIPPED_PAIRS++ )) || true
                continue
            fi

            sync_pair "${src}" "${dst}" "${label}" "${BWLIMIT_NAS1_TO_NAS2}" || true
            $DEADLINE_REACHED && { info "Deadline reached — stopping NAS1→NAS2 loop"; break; }
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
            local src="${NAS2_MOUNT}/${src_sub}"
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
            $DEADLINE_REACHED && { info "Deadline reached — stopping NAS2→NAS1 loop"; break; }
        done
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    local elapsed=$(( $(date +%s) - RUN_START_EPOCH ))
    local elapsed_fmt
    printf -v elapsed_fmt '%dh %02dm %02ds' \
        $(( elapsed / 3600 )) $(( (elapsed % 3600) / 60 )) $(( elapsed % 60 ))

    info ""
    info "════════════════════════════════════════════════════════"
    $DEADLINE_REACHED && info "Run stopped at deadline (STOP_HOUR=${STOP_HOUR:-unset})" \
                      || info "Run complete"
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
    $DEADLINE_REACHED && final_status="STOPPED AT DEADLINE — ${final_status}"
    $DRY_RUN && final_status="DRY RUN — ${final_status}"

    local uk_status="up"
    [[ ${FAILED_PAIRS} -gt 0 ]] && uk_status="down"
    uptime_kuma_ping "${uk_status}" "${final_status} | pairs: ${TOTAL_PAIRS}, failed: ${FAILED_PAIRS}, skipped: ${SKIPPED_PAIRS}"

    _COMPLETED=true   # disarm the EXIT trap

    # Exit non-zero if any pair failed so cron/monitoring can catch it
    [[ ${FAILED_PAIRS} -eq 0 ]]
}

main "$@"
