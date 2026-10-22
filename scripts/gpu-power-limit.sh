#!/usr/bin/env bash
# Limite de puissance du GPU, PERMANENTE (service systemd qui l'applique à chaque démarrage).
#
#     scripts/gpu-power-limit.sh status            # limite actuelle, bornes, service installé ou non
#     scripts/gpu-power-limit.sh install [WATTS]   # installe le service (défaut : 300 W)
#     scripts/gpu-power-limit.sh remove            # retire le service et remet la limite d'origine
#
# Pourquoi 300 W ? Mesuré sur ta 3090 (qwen3.8:27b) : -9 % de vitesse de génération mais -10 % d'énergie par token
# (voir docs/performance.md). Mesure toi-même avec `lab bench power-sweep` avant de changer.
set -euo pipefail

UNIT=gpu-power-limit.service
UNIT_PATH=/etc/systemd/system/$UNIT
NVS="$(command -v nvidia-smi || true)"
[ -n "$NVS" ] || { echo "nvidia-smi introuvable (pilote NVIDIA non installé ?)" >&2; exit 1; }

q() { "$NVS" --query-gpu="$1" --format=csv,noheader,nounits | head -1 | tr -d ' '; }

status() {
  echo "Limite actuelle : $(q power.limit) W   (défaut : $(q power.default_limit) W, bornes : $(q power.min_limit)-$(q power.max_limit) W)"
  echo "Consommation    : $(q power.draw) W   état : $(q pstate)"
  if systemctl cat "$UNIT" >/dev/null 2>&1; then
    echo "Service         : installé ($(systemctl is-enabled "$UNIT" 2>/dev/null || true)), $(grep -m1 -- '-pl' "$UNIT_PATH" | sed 's/^ExecStart=//')"
  else
    echo "Service         : non installé (la limite est perdue au redémarrage)"
  fi
}

case "${1:-status}" in
  status) status ;;
  install)
    W="${2:-300}"
    [[ "$W" =~ ^[0-9]+$ ]] || { echo "Valeur invalide : $W" >&2; exit 1; }
    MIN="$(q power.min_limit | cut -d. -f1)"; MAX="$(q power.max_limit | cut -d. -f1)"
    { [ "$W" -ge "$MIN" ] && [ "$W" -le "$MAX" ]; } || { echo "$W W hors bornes du GPU ($MIN-$MAX W)." >&2; exit 1; }
    sudo -v
    sudo tee "$UNIT_PATH" >/dev/null <<UNITEOF
[Unit]
Description=Limite de puissance du GPU (${W} W)
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
