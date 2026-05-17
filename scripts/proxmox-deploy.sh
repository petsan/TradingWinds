#!/usr/bin/env bash
# proxmox-deploy.sh — provision a TradingAgents/TradingWinds LXC on Proxmox VE.
#
# Run this script AS ROOT on the Proxmox host (not inside an existing container).
# It will:
#   1. Download a Debian template if needed
#   2. Create an unprivileged LXC container
#   3. Install Python 3.12, git, and build tooling inside it
#   4. Clone the repo, install tradingagents with pip
#   5. Drop an .env scaffold for API keys
#   6. Print next steps (set keys, run `tradingagents`)
#
# Idempotent: re-running with the same CTID is a no-op if the container exists.
# Defaults target a modest research workload (2 vCPU, 4 GiB RAM, 16 GiB disk).
#
# Usage:
#   ./proxmox-deploy.sh                              # use defaults / env vars
#   CTID=210 HOSTNAME=tw-prod ./proxmox-deploy.sh    # override per invocation
#   ./proxmox-deploy.sh --ctid 210 --hostname tw-prod
#
# All flags have equivalent uppercase env-var names. Flags win when both are set.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults — override via env or flags
# ----------------------------------------------------------------------------
: "${CTID:=200}"
: "${HOSTNAME:=tradingwinds}"
: "${TEMPLATE_STORAGE:=local}"
: "${ROOTFS_STORAGE:=local-lvm}"
: "${BRIDGE:=vmbr0}"
: "${DISK_GB:=16}"
: "${RAM_MB:=4096}"
: "${SWAP_MB:=512}"
: "${CORES:=2}"
: "${OS_TEMPLATE:=debian-12-standard}"
: "${REPO_URL:=https://github.com/petsan/TradingWinds.git}"
: "${REPO_BRANCH:=main}"
: "${UNPRIVILEGED:=1}"
: "${NESTING:=0}"             # set 1 if you plan to run Docker inside the LXC
: "${PASSWORD:=}"             # if empty, root login is disabled; use `pct enter`
: "${SSH_KEY_FILE:=}"         # optional path to an authorized_keys-style file
: "${TIMEZONE:=UTC}"

usage() {
  cat <<'USAGE'
proxmox-deploy.sh — provision a TradingAgents LXC on Proxmox VE.

Flags (all optional; matching uppercase env vars also work):
  --ctid <id>              Container ID (default: 200)
  --hostname <name>        LXC hostname (default: tradingwinds)
  --template-storage <s>   Storage holding the OS template (default: local)
  --rootfs-storage <s>     Storage for the container disk (default: local-lvm)
  --bridge <br>            Network bridge (default: vmbr0)
  --disk-gb <n>            Disk size in GiB (default: 16)
  --ram-mb <n>             RAM in MiB (default: 4096)
  --swap-mb <n>            Swap in MiB (default: 512)
  --cores <n>              vCPU cores (default: 2)
  --os-template <name>     Template name prefix (default: debian-12-standard)
  --repo-url <url>         Git URL to clone (default: this fork)
  --repo-branch <ref>      Branch/tag to check out (default: main)
  --privileged             Create a privileged container (default: unprivileged)
  --nesting                Enable LXC nesting (needed for Docker-in-LXC)
  --password <pw>          Set the container's root password
  --ssh-key-file <path>    File of SSH public keys to authorize for root
  --timezone <tz>          IANA timezone (default: UTC)
  -h, --help               Show this help

Examples:
  ./proxmox-deploy.sh --ctid 210 --hostname tw-prod --ram-mb 8192 --cores 4
  CTID=211 REPO_BRANCH=v0.2.5 ./proxmox-deploy.sh
USAGE
}

# ----------------------------------------------------------------------------
# Flag parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
    --rootfs-storage) ROOTFS_STORAGE="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --disk-gb) DISK_GB="$2"; shift 2 ;;
    --ram-mb) RAM_MB="$2"; shift 2 ;;
    --swap-mb) SWAP_MB="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --os-template) OS_TEMPLATE="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --repo-branch) REPO_BRANCH="$2"; shift 2 ;;
    --privileged) UNPRIVILEGED=0; shift ;;
    --nesting) NESTING=1; shift ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --ssh-key-file) SSH_KEY_FILE="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: must run as root on the Proxmox host." >&2
  exit 1
fi

for cmd in pct pveam pvesm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found. Is this a Proxmox VE host?" >&2
    exit 1
  fi
done

log() { printf '[proxmox-deploy] %s\n' "$*"; }

# ----------------------------------------------------------------------------
# Step 1: Locate or download the OS template
# ----------------------------------------------------------------------------
log "Refreshing template index"
pveam update >/dev/null

# Find the newest matching template name in the index
TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
  | awk -v t="$OS_TEMPLATE" '$2 ~ "^"t {print $2}' \
  | sort -V | tail -n1)

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo "Error: no template matching '$OS_TEMPLATE' available on this host." >&2
  echo "Run 'pveam available --section system' to see options." >&2
  exit 1
fi

TEMPLATE_PATH="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE_NAME"

if ! pvesm list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
  log "Downloading template $TEMPLATE_NAME to $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
  log "Template $TEMPLATE_NAME already present on $TEMPLATE_STORAGE"
fi

# ----------------------------------------------------------------------------
# Step 2: Create the container (skip if it already exists)
# ----------------------------------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  log "Container $CTID already exists; skipping create. Will re-run provisioning steps inside."
  CREATED=0
else
  log "Creating CT $CTID ($HOSTNAME) on $ROOTFS_STORAGE"
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_PATH"
    --hostname "$HOSTNAME"
    --cores "$CORES"
    --memory "$RAM_MB"
    --swap "$SWAP_MB"
    --rootfs "$ROOTFS_STORAGE:$DISK_GB"
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,firewall=1"
    --onboot 1
    --start 0
    --unprivileged "$UNPRIVILEGED"
    --features "nesting=$NESTING"
    --timezone "$TIMEZONE"
  )

  [[ -n "$PASSWORD" ]] && CREATE_ARGS+=(--password "$PASSWORD")
  [[ -n "$SSH_KEY_FILE" ]] && CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY_FILE")

  pct create "${CREATE_ARGS[@]}"
  CREATED=1
fi

log "Starting CT $CTID"
pct start "$CTID" >/dev/null 2>&1 || true   # already-running is fine

# Wait for DHCP / network to settle before running apt
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 1
done

# ----------------------------------------------------------------------------
# Step 3: Install OS-level dependencies inside the container
# ----------------------------------------------------------------------------
log "Installing OS packages inside CT $CTID"
pct exec "$CTID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git build-essential \
    python3 python3-venv python3-pip python3-dev \
    pkg-config libffi-dev libssl-dev tzdata
  apt-get clean
  rm -rf /var/lib/apt/lists/*
'

# ----------------------------------------------------------------------------
# Step 4: Create the app user and clone the repo
# ----------------------------------------------------------------------------
log "Creating tradingagents user and cloning repo (branch: $REPO_BRANCH)"
pct exec "$CTID" -- bash -c "
  set -euo pipefail
  if ! id -u tradingagents >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash tradingagents
  fi
  install -d -o tradingagents -g tradingagents /home/tradingagents/app
  if [ ! -d /home/tradingagents/app/.git ]; then
    sudo -u tradingagents git clone --branch '$REPO_BRANCH' --depth 1 '$REPO_URL' /home/tradingagents/app
  else
    cd /home/tradingagents/app && sudo -u tradingagents git fetch --depth 1 origin '$REPO_BRANCH' && sudo -u tradingagents git checkout -B '$REPO_BRANCH' FETCH_HEAD
  fi
"

# ----------------------------------------------------------------------------
# Step 5: Install the package in a venv
# ----------------------------------------------------------------------------
log "Installing tradingagents into a venv"
pct exec "$CTID" -- sudo -u tradingagents bash -c '
  set -euo pipefail
  cd /home/tradingagents/app
  if [ ! -d .venv ]; then
    python3 -m venv .venv
  fi
  . .venv/bin/activate
  pip install --quiet --upgrade pip
  pip install --quiet .
'

# ----------------------------------------------------------------------------
# Step 6: Drop an .env scaffold if the user has not created one
# ----------------------------------------------------------------------------
log "Ensuring .env scaffold exists"
pct exec "$CTID" -- sudo -u tradingagents bash -c '
  set -euo pipefail
  cd /home/tradingagents/app
  if [ ! -f .env ] && [ -f .env.example ]; then
    cp .env.example .env
    chmod 600 .env
  fi
'

# ----------------------------------------------------------------------------
# Step 7: Convenience launcher on root PATH
# ----------------------------------------------------------------------------
pct exec "$CTID" -- bash -c '
  set -euo pipefail
  cat > /usr/local/bin/tradingagents <<EOF
#!/bin/sh
exec sudo -u tradingagents -H bash -c ". /home/tradingagents/app/.venv/bin/activate && cd /home/tradingagents/app && exec tradingagents \"\$@\"" -- "\$@"
EOF
  chmod 0755 /usr/local/bin/tradingagents
'

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
IP=$(pct exec "$CTID" -- bash -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)

cat <<EOF

============================================================
TradingAgents LXC ready.

  CTID      : $CTID
  Hostname  : $HOSTNAME
  Address   : ${IP:-<not yet assigned>}
  Repo      : $REPO_URL ($REPO_BRANCH)
  Install   : /home/tradingagents/app (.venv)

Next steps:
  1. Edit API keys:
       pct exec $CTID -- nano /home/tradingagents/app/.env
  2. Launch the CLI:
       pct exec $CTID -- tradingagents
     or enter the container first:
       pct enter $CTID
       tradingagents

To re-deploy from a fresh branch later:
  REPO_BRANCH=<branch> $0 --ctid $CTID
============================================================
EOF
