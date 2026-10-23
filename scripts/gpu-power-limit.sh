#!/usr/bin/env bash
# PERMANENT GPU power limit (systemd service that applies it at every boot).
#
#     scripts/gpu-power-limit.sh status            # current limit, bounds, service installed or not
#     scripts/gpu-power-limit.sh install [WATTS]   # installs the service (default: 300 W)
#     scripts/gpu-power-limit.sh remove            # removes the service and restores the original limit
#
# Why 300 W? Measured on the reference RTX 3090 (qwen3.8:27b): about -7 % generation speed but -7 % energy per token
# (see docs/performance.md). Measure on your own card with `lab bench power-sweep` before changing it.
set -euo pipefail

UNIT=gpu-power-limit.service
UNIT_PATH=/etc/systemd/system/$UNIT
NVS="$(command -v nvidia-smi || true)"
[ -n "$NVS" ] || { echo "nvidia-smi not found (NVIDIA driver not installed?)" >&2; exit 1; }

q() { "$NVS" --query-gpu="$1" --format=csv,noheader,nounits | head -1 | tr -d ' '; }

status() {
  echo "Current limit: $(q power.limit) W   (default: $(q power.default_limit) W, bounds: $(q power.min_limit)-$(q power.max_limit) W)"
  echo "Power draw   : $(q power.draw) W   state: $(q pstate)"
  if systemctl cat "$UNIT" >/dev/null 2>&1; then
    echo "Service      : installed ($(systemctl is-enabled "$UNIT" 2>/dev/null || true)), $(grep -m1 -- '-pl' "$UNIT_PATH" | sed 's/^ExecStart=//')"
  else
    echo "Service      : not installed (the limit is lost at reboot)"
  fi
}

case "${1:-status}" in
  status) status ;;
  install)
    W="${2:-300}"
    [[ "$W" =~ ^[0-9]+$ ]] || { echo "Invalid value: $W" >&2; exit 1; }
    MIN="$(q power.min_limit | cut -d. -f1)"; MAX="$(q power.max_limit | cut -d. -f1)"
    { [ "$W" -ge "$MIN" ] && [ "$W" -le "$MAX" ]; } || { echo "$W W is outside the GPU's bounds ($MIN-$MAX W)." >&2; exit 1; }
    sudo -v
    sudo tee "$UNIT_PATH" >/dev/null <<UNITEOF
[Unit]
Description=GPU power limit (${W} W)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NVS -pm 1
ExecStart=$NVS -pl $W
ExecStop=$NVS -pl $(q power.default_limit | cut -d. -f1)

[Install]
WantedBy=multi-user.target
UNITEOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$UNIT"
    echo; status ;;
  remove)
    sudo -v
    sudo systemctl disable --now "$UNIT" 2>/dev/null || true
    sudo rm -f "$UNIT_PATH"
    sudo systemctl daemon-reload
    sudo "$NVS" -pl "$(q power.default_limit | cut -d. -f1)" >/dev/null
    echo; status ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
