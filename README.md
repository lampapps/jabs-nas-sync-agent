# nas_sync — Bidirectional NAS Sync over NFS / Tailscale

Nightly rsync job that mirrors directories between two NAS devices.  
The script runs on a **client machine** that has both NAS devices mounted via NFS.

Written by Claude Sonnet 4.6

---

## Topology

```
         ┌─────────────────────────────┐
         │       Tailscale network     │
         │                             │
  LAN ◄──┤  Client (runs nas_sync.sh)  │
  NFS    │  - NAS1 mounted at /mnt/nas1│◄── NFS (LAN, fast)
         │  - NAS2 mounted at /mnt/nas2│◄── NFS (over Tailscale, WAN)
         │                             │
         └─────────────────────────────┘
```

- **NAS1** — same physical LAN as the client; NFS traffic stays local.  
- **NAS2** — remote site; NFS traffic crosses the Tailscale tunnel between the
  two ISP uplinks.  The `BWLIMIT_NAS1_TO_NAS2` / `BWLIMIT_NAS2_TO_NAS1` settings
  cap rsync's throughput per direction to protect both ISP connections.

---

## Files

| File | Purpose |
|------|---------|
| `nas_sync.sh` | Main sync script |
| `nas_sync.conf` | Your local config — **gitignored, never committed** |
| `nas_sync.conf.example` | Safe config template committed to the repo |
| `jabs_client.py` | Standalone HTTP client for the JABS Agent Monitoring API (see below); called by `nas_sync.sh`, requires `python3` |

The JABS Agent Monitoring API itself (endpoints, auth, payload fields) is
documented in `AGENTS_API_GUIDE.md` at the root of the main `jabs_dev`
project — that file lives outside this repo since `nas_sync_agent` is
versioned independently.

---

## Quick Start

### 1. Prerequisites

```bash
# Debian / Ubuntu
sudo apt install rsync util-linux bc curl

# RHEL / Fedora
sudo dnf install rsync util-linux bc curl
```

Ensure both NAS devices are reachable over Tailscale and NFS-exported before
continuing.

### 2. Configure NFS mounts

Add entries to `/etc/fstab` on the client so both NAS devices mount at boot.
Replace IP addresses with Tailscale addresses (100.x.x.x) for the remote NAS.

```
# /etc/fstab — example entries
nas1-lan.local:/export/data   /mnt/nas1  nfs  defaults,_netdev,nofail,soft,timeo=30  0 0
100.x.x.x:/export/data        /mnt/nas2  nfs  defaults,_netdev,nofail,soft,timeo=60  0 0
```

> **`nofail`** — allows the system to boot even if the NFS mount is temporarily
> unavailable.  
> **`soft,timeo=`** — NFS operations time out instead of hanging forever; the
> script will detect and report the failure.

Mount them now:

```bash
sudo mount /mnt/nas1
sudo mount /mnt/nas2
```

### 3. Create `nas_sync.conf`

```bash
cp nas_sync.conf.example nas_sync.conf
```

Then edit `nas_sync.conf` and set your values:

| Variable | Description |
|---|---|
| `NAS1_MOUNT` | Local mount point for NAS1 |
| `NAS2_MOUNT` | Local mount point for NAS2 |
| `BWLIMIT_NAS1_TO_NAS2` | rsync bandwidth cap **NAS1→NAS2** in **KB/s** (limit by NAS1 upload speed) |
| `BWLIMIT_NAS2_TO_NAS1` | rsync bandwidth cap **NAS2→NAS1** in **KB/s** (limit by NAS2 upload speed) |
| `MIN_FREE_BYTES` | Minimum free space required on destination before syncing |
| `STOP_HOUR` | Hard stop hour in 24-hour local time (e.g. `8` = 08:00). rsync is sent SIGTERM at this time and `--partial` saves progress for the next run to resume. Set to `""` to disable. |
| `LOG_RETENTION_DAYS` | How many days of logs to keep (default `30`) |
| `UPTIME_KUMA_URL` | Uptime Kuma push monitor URL (set to `""` to disable) |
| `NAS1_TO_NAS2_PAIRS` | Array of `"src_subdir:dst_subdir"` pairs synced **NAS1→NAS2** |
| `NAS2_TO_NAS1_PAIRS` | Array of `"src_subdir:dst_subdir"` pairs synced **NAS2→NAS1** |

> `nas_sync.conf` is listed in `.gitignore` and will never be accidentally committed.
> `nas_sync.conf.example` (no real values) is committed as a reference.

#### Bandwidth sizing guide

| `BWLIMIT_*` value | Approx throughput |
|---|---|
| `5120` | ~5 MB/s / ~40 Mbps |
| `10240` | ~10 MB/s / ~80 Mbps |
| `25600` | ~25 MB/s / ~200 Mbps |
| `51200` | ~50 MB/s / ~400 Mbps |

Set this *below* the slower of your two ISP uplink speeds to leave headroom for
other traffic.

### 4. Make the script executable

```bash
chmod +x nas_sync.sh
```

### 5. Test with a dry run

```bash
./nas_sync.sh --dry-run
```

No data will be moved.  Review the output and the log in the `logs/` directory.

### 6. Run once for real

```bash
./nas_sync.sh
```

### 7. Install the nightly cron job

Edit your crontab:

```bash
crontab -e
```

Add a line like this.  The example below starts the sync at 23:00 and relies on
`STOP_HOUR=8` in `nas_sync.conf` to stop it by 08:00 — even if it hasn't
finished.  The next nightly run will resume automatically:

```
# Run NAS sync nightly at 23:00; STOP_HOUR=8 in nas_sync.conf stops it by 08:00
0 23 * * * /path/to/nas_rsync/nas_sync.sh
```

If you don't need a hard stop, a simpler daytime/off-peak schedule also works:

```
# Run once daily at 02:30 AM with no deadline
30 2 * * * /path/to/nas_rsync/nas_sync.sh
```

Verify it was saved:

```bash
crontab -l
```

Cron output is appended to `logs/cron.log` alongside the per-run timestamped log.

---

## How it works

1. **Dependency check** — verifies `rsync`, `flock`, `df`, `mountpoint` are available.
2. **Lock** — acquires an exclusive `flock` on `nas_sync.lock` (alongside the
   script) so concurrent cron overlaps are prevented.
3. **Mount verification** — confirms each NFS mount is alive with `mountpoint -q`
   and a `stat` call; aborts early on stale/missing mounts.
4. **Free space check** — skips a sync direction if the destination has less than
   `MIN_FREE_BYTES` free.
5. **Deadline setup** — if `STOP_HOUR` is set, converts it to an absolute epoch
   (automatically rolls to tomorrow when the script starts before midnight and the
   stop hour is the following morning, e.g. start 23:00 / stop 08:00).
6. **rsync pairs** — runs each configured pair in order, applying:
   - `--archive` (recursive + full metadata preservation)
   - `--delete` (exact mirror)
   - `--partial --partial-dir` (resume interrupted transfers on next run)
   - `--sparse` (efficient handling of sparse files)
   - `--bwlimit` (ISP protection)
   - `--timeout` (abandon stalled connections after 5 min)
   - `timeout <remaining_seconds>` wrapper (enforces `STOP_HOUR` deadline)
7. **Result tracking** — exit codes 23/24 (partial transfer) are treated as
   warnings, not failures; exit code 124 (deadline timeout) is logged as a soft
   stop and does not increment `FAILED_PAIRS`; all other non-zero codes
   increment `FAILED_PAIRS`.
8. **Log rotation** — deletes log files older than `LOG_RETENTION_DAYS` (default 30).
9. **Uptime Kuma heartbeats** — sends a push heartbeat to an Uptime Kuma push monitor:
   - `up` — on clean finish, with pair summary (also used for deadline stops)
   - `down` — if any pair fails or a fatal error occurs, with the error message
   The exit trap sends a `down` heartbeat on unexpected termination (e.g. SIGKILL).
   Set `UPTIME_KUMA_URL=""` to disable.
10. **Exit code** — exits non-zero if any pair failed, so cron monitoring tools
    can also catch failures independently.

---

## Logs

Logs are written to the `logs/` subdirectory alongside the script:

```
logs/
├── nas_sync_20260224_023001.log   # per-run timestamped log
├── nas_sync_20260225_023002.log
└── ...
```

Tail the latest run:

```bash
ls -t logs/nas_sync_*.log | head -1 | xargs tail -f
```

---

## JABS agent monitoring (optional)

`nas_sync.sh` can report each sync pair to a JABS dashboard as a monitored
job, via `jabs_client.py` (a small stdlib-only Python HTTP client — no
`pip install` needed).

Enable it in `nas_sync.conf`:

```bash
JABS_SERVER_URL="http://jabs-server:5001"
JABS_AGENT_KEY=""                # paste the key from the dashboard here
JABS_HOSTNAME="$(hostname)"      # informational only, shown on the Hosts page
JABS_IP_ADDRESS="192.168.1.50"   # informational only
JABS_AGENT_VERSION="1.0.0"
JABS_TIMEOUT=10
```

Before the first run, register this agent on the JABS dashboard's Hosts
page — the API has no self-registration. Registering generates a unique
API key; paste it into `JABS_AGENT_KEY`. Every request is authenticated by
that key alone (sent as the `X-API-Key` header) — `JABS_HOSTNAME`/
`JABS_IP_ADDRESS` are stored for display only and don't need to match
anything. This also means multiple agents (e.g. this script plus a backup
agent) can safely run on the same machine, each with its own key.

**How pairs map to JABS jobs:** each configured `NAS1_TO_NAS2_PAIRS` /
`NAS2_TO_NAS1_PAIRS` entry is reported as one job, identified by its label
(e.g. `NAS1:backups → NAS2:backups`). Unlike a versioned backup agent, a
mirror sync doesn't produce rotating dated archives, so each pair uses one
stable `backup_set_id` that's simply updated on every run rather than a new
one per day — there's nothing to reconcile via `sync-job-sets`, since there's
only ever one "set" per pair. Every run sends:

- a start event when the pair begins,
- a completion event (`backup_complete` or `error`) when it finishes, with
  duration and file/byte counts pulled from rsync's `--stats` output,
- or, if the pair is stopped by `STOP_HOUR` or a signal before finishing, a
  plain progress event — the job is left "running" on the dashboard rather
  than marked complete or failed, since it will resume on the next run.

A bare heartbeat (host online + agent version, no job) is also sent once at
the very start of each run.

Reporting is fire-and-forget and best-effort: it's skipped entirely during
`--dry-run`, and any failure (server unreachable, bad response, `python3`
missing) is logged as a warning but never fails the sync itself. Set
`JABS_SERVER_URL=""` to disable it completely.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| "not mounted" error | `mountpoint /mnt/nas1` and `mount` — is the NFS share up? |
| "not NFS" warning | `/proc/mounts`: the script warns but continues |
| Stalled transfers | Increase `--timeout`; check Tailscale connectivity (`tailscale ping`) |
| High WAN usage | Lower `BWLIMIT_NAS1_TO_NAS2` / `BWLIMIT_NAS2_TO_NAS1`; units are KB/s, not Mbps |
| Uptime Kuma not pinging | Verify `curl` is installed; test manually: `curl "${UPTIME_KUMA_URL}?status=up&msg=test&ping="` |
| Partial transfers (exit 23/24) | Permissions or vanished files; check the log for specifics |
| Lock not released | `rm nas_sync.lock` if you are certain no run is active |
| Run stops before finishing | Expected if `STOP_HOUR` is set — the next cron run resumes automatically via `--partial` |
| `STOP_HOUR` not taking effect | Ensure the value is a plain integer (0–23) with no quotes; check the log for the "Deadline :" line |
| JABS events not showing up | Confirm `python3` is installed; confirm `JABS_AGENT_KEY` is set and matches a key generated on the JABS dashboard's Hosts page (missing key -> `401`, invalid/disabled key -> `403`, logged as a `WARN`) |

---

## Security notes

- NFS traffic between the client and NAS2 (remote) travels **inside the
  Tailscale WireGuard tunnel** — it is encrypted in transit.
- NFS traffic between the client and NAS1 (LAN) is unencrypted on the local
  network (normal NFS behaviour).
- The script does **not** store credentials; authentication is handled by NFS
  export rules and Tailscale ACLs.
