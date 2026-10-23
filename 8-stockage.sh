#!/usr/bin/env bash
# STEP 8 (optional): prepares the second SSD (/data) and moves Docker's data to it.
#
#     ./8-stockage.sh disk /dev/NAME           # 1) ERASES this disk, formats it as ext4 and mounts it on LAB_DATA_DIR (/data)
#     ./8-stockage.sh docker                   # 2) moves Docker (images, volumes, Ollama models) to /data
#     ./8-stockage.sh status                   # shows the state (disks, /data, Docker root)
#
# Both steps ask for a confirmation. "disk" is DESTRUCTIVE for the target disk: read what is shown.
# "docker" stops your containers; then run ./3-demarrer.sh again. Never 'down -v'.
# (The former French sub-commands "disque" and "etat" still work.)
set -euo pipefail

_CONF="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lab.conf"; [ ! -f "$_CONF" ] || . "$_CONF"
DATA="${LAB_DATA_DIR:-/data}"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

root_disk() { lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1; }

cmd_etat() {
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS | grep -v '^loop'
  echo
  df -h / "$DATA" 2>/dev/null || true
  echo
  echo "Docker root: $(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo 'Docker unreachable')"
}

cmd_disque() {
  local dev="${1:-}"
  [ -n "$dev" ] || { lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS; die "give the disk to ERASE, for example: ./8-stockage.sh disk /dev/nvme1n1 (see the list above)"; }
  [ -b "$dev" ] || die "$dev is not a disk. See: lsblk"
  [ "$(lsblk -dno TYPE "$dev")" = "disk" ] || die "$dev is not a whole disk (not a partition)."
  [ "$(basename "$dev")" != "$(root_disk)" ] || die "$dev is the system disk. Stopping."
  mountpoint -q "$DATA" && die "$DATA is already mounted. Nothing to do (./8-stockage.sh status)."

  say "Target disk: $dev"
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS "$dev"
  local mp; mp="$(lsblk -nlo MOUNTPOINTS "$dev" | grep -v '^$' | head -1 || true)"
  if [ -n "$mp" ]; then
    echo; echo "Current content (mounted on $mp):"
    df -h "$mp" | tail -1
    ls -A "$mp" | head -20
    echo "Number of entries at the root: $(ls -A "$mp" | wc -l)"
  fi
  echo
  echo "EVERYTHING on $dev will be ERASED, with no way back."
  read -r -p "To confirm, type exactly \"$dev\": " ans
  [ "$ans" = "$dev" ] || { echo "Cancelled."; exit 0; }

  sudo -v
  say "Unmounting and erasing"
  for m in $(lsblk -nlo MOUNTPOINTS "$dev" | grep -v '^$' || true); do sudo umount "$m"; done
  sudo wipefs -a "$dev"

  say "GPT partition + ext4"
  sudo parted -s "$dev" mklabel gpt mkpart DATA ext4 1MiB 100%
  sudo udevadm settle
  sleep 2
  local part; part="$(lsblk -nlo PATH,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
  [ -b "${part:-}" ] || die "partition not found after creation"
  sudo mkfs.ext4 -m 1 -L DATA "$part"
  for m in $(lsblk -nlo MOUNTPOINTS "$part" | grep -v '^$' || true); do sudo umount "$m" || true; done   # automatic mount by the desktop

  say "Mounting on $DATA (UUID in /etc/fstab, boot still possible if the disk is missing)"
  local uuid; uuid="$(sudo blkid -s UUID -o value "$part")"
  [ -n "$uuid" ] || die "UUID not found"
  sudo mkdir -p "$DATA"
  grep -q "UUID=$uuid" /etc/fstab || echo "UUID=$uuid $DATA ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
  sudo mount "$DATA"
  mountpoint -q "$DATA" || die "mounting $DATA failed"
  sudo mkdir -p "$DATA/docker" "$DATA/backups"
  sudo chown "$USER":"$USER" "$DATA/backups"
  sudo chmod 755 "$DATA"
  say "Done"
  df -h "$DATA"
  echo "Next step: ./8-stockage.sh docker"
}

cmd_docker() {
  mountpoint -q "$DATA" || die "$DATA is not mounted (run first: ./8-stockage.sh disk)."
  command -v rsync >/dev/null || { echo "→ installing rsync"; sudo apt-get install -y rsync; }
  docker info >/dev/null 2>&1 || die "Docker does not answer."
  local cur; cur="$(docker info -f '{{.DockerRootDir}}')"
  [ "$cur" != "$DATA/docker" ] || { echo "Docker already uses $DATA/docker. Nothing to do."; exit 0; }
  [ "$cur" = "/var/lib/docker" ] || die "Unexpected Docker root: $cur (expected /var/lib/docker)."

  # Recent Docker: images may be stored by containerd (/var/lib/containerd), not only in /var/lib/docker
  local cd_store=0
  docker info -f '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter' && cd_store=1
  local need; need=$(sudo du -sm /var/lib/docker 2>/dev/null | cut -f1)
  [ "$cd_store" = 1 ] && need=$(( need + $(sudo du -sm /var/lib/containerd 2>/dev/null | cut -f1) ))
  local free; free=$(df -m --output=avail "$DATA" | tail -1 | tr -d ' ')

  say "Plan"
  echo "  Size to copy: ${need} MB  ·  free on $DATA: ${free} MB"
  echo "  Image store: $([ $cd_store = 1 ] && echo 'containerd (will be moved too)' || echo 'overlay2 (in /var/lib/docker)')"
  echo "  Running containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
  [ "$free" -gt $(( need * 12 / 10 )) ] || die "not enough room on $DATA"
  echo "  The containers will be stopped cleanly, then Docker restarted with data-root=$DATA/docker."
  echo "  The old data stays in /var/lib/docker.old (to delete by hand, later)."
  read -r -p "Continue? [y/N] " ok; [[ "$ok" =~ ^([yYoO]|yes|oui)$ ]] || { echo "Cancelled."; exit 0; }
  sudo -v

  say "Stopping the containers cleanly"
  local ids; ids="$(docker ps -q)"
  [ -z "$ids" ] || docker stop $ids >/dev/null
  say "Stopping Docker"
  sudo systemctl stop docker.socket docker
  [ "$cd_store" = 1 ] && sudo systemctl stop containerd

  say "Copying (can take several minutes)"
  sudo rsync -aHAX --numeric-ids --info=progress2 /var/lib/docker/ "$DATA/docker/"
  if [ "$cd_store" = 1 ]; then
    sudo mkdir -p "$DATA/containerd"
    sudo rsync -aHAX --numeric-ids --info=progress2 /var/lib/containerd/ "$DATA/containerd/"
  fi

  say "Configuration"
  sudo mkdir -p /etc/docker
  sudo python3 - <<PY
import json, os
p = "/etc/docker/daemon.json"
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
d["data-root"] = "$DATA/docker"          # keep the rest (NVIDIA runtime, etc.)
json.dump(d, open(p, "w"), indent=2)
PY
  if [ "$cd_store" = 1 ]; then
    sudo mkdir -p /etc/containerd
    [ -f /etc/containerd/config.toml ] || sudo touch /etc/containerd/config.toml
    sudo cp -a /etc/containerd/config.toml /etc/containerd/config.toml.bak
    if sudo grep -Eq '^root *=' /etc/containerd/config.toml; then
      sudo sed -i -E "s|^root *=.*|root = \"$DATA/containerd\"|" /etc/containerd/config.toml
    else
      { echo "root = \"$DATA/containerd\""; sudo cat /etc/containerd/config.toml; } | sudo tee /etc/containerd/config.toml.new >/dev/null
      sudo mv /etc/containerd/config.toml.new /etc/containerd/config.toml
    fi
  fi
  # Docker must never start before /data is mounted (otherwise it would recreate an empty folder on the root disk)
  sudo mkdir -p /etc/systemd/system/docker.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA" | sudo tee /etc/systemd/system/docker.service.d/data-mount.conf >/dev/null
  if [ "$cd_store" = 1 ]; then
    sudo mkdir -p /etc/systemd/system/containerd.service.d
    printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA" | sudo tee /etc/systemd/system/containerd.service.d/data-mount.conf >/dev/null
  fi
  sudo systemctl daemon-reload

  say "Setting the old location aside and restarting"
  sudo mv /var/lib/docker /var/lib/docker.old
  [ "$cd_store" = 1 ] && { sudo mv /var/lib/containerd /var/lib/containerd.old; sudo systemctl start containerd; }
  sudo systemctl start docker
  sleep 3

  say "Check"
  local now; now="$(docker info -f '{{.DockerRootDir}}')"
  echo "Docker root: $now"
  [ "$now" = "$DATA/docker" ] || die "Docker does not use $DATA/docker. Old data intact in /var/lib/docker.old."
  echo "Volumes: $(docker volume ls -q | wc -l) · Images: $(docker image ls -q | wc -l)"
  docker volume ls --format '  {{.Name}}' | head -20
  echo
  echo "OK. Now restart your services: ./3-demarrer.sh (then ./5-hermes.sh, ./6-langfuse.sh… if needed)."
  echo "Once everything has worked for several days: sudo rm -rf /var/lib/docker.old /var/lib/containerd.old (frees space)."
}

case "${1:-help}" in
  disk|disque) shift; cmd_disque "$@" ;;
  docker) cmd_docker ;;
  status|etat) cmd_etat ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
