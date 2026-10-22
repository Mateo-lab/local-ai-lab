#!/usr/bin/env bash
# ÉTAPE 8 (optionnelle) : prépare le second SSD (/data) et y déplace les données Docker.
#
#     ./8-stockage.sh disque /dev/NOM          # 1) EFFACE ce disque, le formate en ext4 et le monte sur LAB_DATA_DIR (/data)
#     ./8-stockage.sh docker                   # 2) déplace Docker (images, volumes, modèles Ollama) sur /data
#     ./8-stockage.sh etat                     # affiche l'état (disques, /data, racine Docker)
#
# Les deux étapes demandent une confirmation. "disque" est DESTRUCTIF pour le disque ciblé : lis ce qui s'affiche.
# "docker" arrête tes conteneurs ; relance ensuite ./3-demarrer.sh. Jamais de 'down -v'.
set -euo pipefail

_CONF="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lab.conf"; [ ! -f "$_CONF" ] || . "$_CONF"
DATA="${LAB_DATA_DIR:-/data}"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { echo "ERREUR : $*" >&2; exit 1; }

root_disk() { lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1; }

cmd_etat() {
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS | grep -v '^loop'
  echo
  df -h / "$DATA" 2>/dev/null || true
  echo
  echo "Racine Docker : $(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo 'Docker injoignable')"
}

cmd_disque() {
  local dev="${1:-}"
  [ -n "$dev" ] || { lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS; die "indique le disque à EFFACER, par exemple : ./8-stockage.sh disque /dev/nvme1n1 (voir la liste ci-dessus)"; }
  [ -b "$dev" ] || die "$dev n'est pas un disque. Voir : lsblk"
  [ "$(lsblk -dno TYPE "$dev")" = "disk" ] || die "$dev n'est pas un disque entier (pas une partition)."
  [ "$(basename "$dev")" != "$(root_disk)" ] || die "$dev est le disque du système. Arrêt."
  mountpoint -q "$DATA" && die "$DATA est déjà monté. Rien à faire (./8-stockage.sh etat)."

  say "Disque ciblé : $dev"
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS "$dev"
  local mp; mp="$(lsblk -nlo MOUNTPOINTS "$dev" | grep -v '^$' | head -1 || true)"
  if [ -n "$mp" ]; then
    echo; echo "Contenu actuel (monté sur $mp) :"
    df -h "$mp" | tail -1
    ls -A "$mp" | head -20
    echo "Nombre d'entrées à la racine : $(ls -A "$mp" | wc -l)"
  fi
  echo
  echo "TOUT ce qui se trouve sur $dev sera EFFACÉ, sans retour possible."
  read -r -p "Pour confirmer, tape exactement « $dev » : " ans
  [ "$ans" = "$dev" ] || { echo "Annulé."; exit 0; }

  sudo -v
  say "Démontage et effacement"
  for m in $(lsblk -nlo MOUNTPOINTS "$dev" | grep -v '^$' || true); do sudo umount "$m"; done
  sudo wipefs -a "$dev"

  say "Partition GPT + ext4"
  sudo parted -s "$dev" mklabel gpt mkpart DATA ext4 1MiB 100%
  sudo udevadm settle
  sleep 2
  local part; part="$(lsblk -nlo PATH,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
  [ -b "${part:-}" ] || die "partition introuvable après création"
  sudo mkfs.ext4 -m 1 -L DATA "$part"
  for m in $(lsblk -nlo MOUNTPOINTS "$part" | grep -v '^$' || true); do sudo umount "$m" || true; done   # montage automatique du bureau

  say "Montage sur $DATA (UUID dans /etc/fstab, démarrage possible même si le disque manque)"
  local uuid; uuid="$(sudo blkid -s UUID -o value "$part")"
  [ -n "$uuid" ] || die "UUID introuvable"
  sudo mkdir -p "$DATA"
  grep -q "UUID=$uuid" /etc/fstab || echo "UUID=$uuid $DATA ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
  sudo mount "$DATA"
  mountpoint -q "$DATA" || die "le montage de $DATA a échoué"
  sudo mkdir -p "$DATA/docker" "$DATA/backups"
  sudo chown "$USER":"$USER" "$DATA/backups"
  sudo chmod 755 "$DATA"
  say "Terminé"
  df -h "$DATA"
  echo "Étape suivante : ./8-stockage.sh docker"
}

cmd_docker() {
  mountpoint -q "$DATA" || die "$DATA n'est pas monté (lance d'abord : ./8-stockage.sh disque)."
  command -v rsync >/dev/null || { echo "→ installation de rsync"; sudo apt-get install -y rsync; }
  docker info >/dev/null 2>&1 || die "Docker ne répond pas."
  local cur; cur="$(docker info -f '{{.DockerRootDir}}')"
  [ "$cur" != "$DATA/docker" ] || { echo "Docker utilise déjà $DATA/docker. Rien à faire."; exit 0; }
  [ "$cur" = "/var/lib/docker" ] || die "Racine Docker inattendue : $cur (attendu /var/lib/docker)."

  # Docker récent : les images peuvent être stockées par containerd (/var/lib/containerd), pas seulement /var/lib/docker
  local cd_store=0
  docker info -f '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter' && cd_store=1
  local need; need=$(sudo du -sm /var/lib/docker 2>/dev/null | cut -f1)
  [ "$cd_store" = 1 ] && need=$(( need + $(sudo du -sm /var/lib/containerd 2>/dev/null | cut -f1) ))
  local free; free=$(df -m --output=avail "$DATA" | tail -1 | tr -d ' ')

  say "Plan"
  echo "  Taille à copier : ${need} Mo  ·  libre sur $DATA : ${free} Mo"
  echo "  Magasin d'images : $([ $cd_store = 1 ] && echo 'containerd (sera déplacé aussi)' || echo 'overlay2 (dans /var/lib/docker)')"
  echo "  Conteneurs actifs : $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
  [ "$free" -gt $(( need * 12 / 10 )) ] || die "pas assez de place sur $DATA"
  echo "  Les conteneurs seront arrêtés proprement, puis Docker redémarré avec data-root=$DATA/docker."
  echo "  Les anciennes données restent dans /var/lib/docker.old (suppression manuelle, plus tard)."
  read -r -p "Continuer ? [o/N] " ok; [ "$ok" = "o" ] || [ "$ok" = "O" ] || { echo "Annulé."; exit 0; }
  sudo -v

  say "Arrêt propre des conteneurs"
  local ids; ids="$(docker ps -q)"
  [ -z "$ids" ] || docker stop $ids >/dev/null
  say "Arrêt de Docker"
  sudo systemctl stop docker.socket docker
  [ "$cd_store" = 1 ] && sudo systemctl stop containerd

  say "Copie (peut durer plusieurs minutes)"
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
d["data-root"] = "$DATA/docker"          # on conserve le reste (runtime NVIDIA, etc.)
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
  # Docker ne doit jamais démarrer avant le montage de /data (sinon il recréerait un dossier vide sur la racine)
  sudo mkdir -p /etc/systemd/system/docker.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA" | sudo tee /etc/systemd/system/docker.service.d/data-mount.conf >/dev/null
  if [ "$cd_store" = 1 ]; then
    sudo mkdir -p /etc/systemd/system/containerd.service.d
    printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA" | sudo tee /etc/systemd/system/containerd.service.d/data-mount.conf >/dev/null
  fi
  sudo systemctl daemon-reload

  say "Mise de côté de l'ancien emplacement et redémarrage"
  sudo mv /var/lib/docker /var/lib/docker.old
  [ "$cd_store" = 1 ] && { sudo mv /var/lib/containerd /var/lib/containerd.old; sudo systemctl start containerd; }
  sudo systemctl start docker
  sleep 3

  say "Vérification"
  local now; now="$(docker info -f '{{.DockerRootDir}}')"
  echo "Racine Docker : $now"
  [ "$now" = "$DATA/docker" ] || die "Docker n'utilise pas $DATA/docker. Anciennes données intactes dans /var/lib/docker.old."
  echo "Volumes : $(docker volume ls -q | wc -l) · Images : $(docker image ls -q | wc -l)"
  docker volume ls --format '  {{.Name}}' | head -20
  echo
  echo "OK. Relance maintenant tes services : ./3-demarrer.sh (puis ./5-hermes.sh, ./6-langfuse.sh… au besoin)."
  echo "Quand tout fonctionne depuis plusieurs jours : sudo rm -rf /var/lib/docker.old /var/lib/containerd.old (libère de la place)."
}

case "${1:-help}" in
  disque) shift; cmd_disque "$@" ;;
  docker) cmd_docker ;;
  etat)   cmd_etat ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
