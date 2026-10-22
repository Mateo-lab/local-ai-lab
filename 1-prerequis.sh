#!/usr/bin/env bash
# ÉTAPE 1 : installe Docker et le NVIDIA Container Toolkit (Ubuntu / Debian).
#
# Lance-le avec TON utilisateur normal, SANS "sudo" devant :
#     ./1-prerequis.sh
# Il te demandera ton mot de passe quand il en a besoin.
#
# Commandes reprises de la documentation officielle de Docker et de NVIDIA.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Ne lance pas ce script avec sudo ni en root. Lance simplement : ./1-prerequis.sh" >&2
  exit 1
fi

. /etc/os-release
# Ubuntu et ses dérivés (Mint, Pop!_OS...) ou Debian
DOCKER_DISTRO=""
CODENAME=""
case "${ID:-}" in
  ubuntu) DOCKER_DISTRO=ubuntu; CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}" ;;
  debian) DOCKER_DISTRO=debian; CODENAME="$VERSION_CODENAME" ;;
  *)
    case "${ID_LIKE:-}" in
      *ubuntu*) DOCKER_DISTRO=ubuntu; CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}" ;;
      *debian*) DOCKER_DISTRO=debian; CODENAME="${DEBIAN_CODENAME:-$VERSION_CODENAME}" ;;
    esac ;;
esac
if [ -z "$DOCKER_DISTRO" ] || [ -z "$CODENAME" ]; then
  echo "Distribution non prise en charge par ce script : ${PRETTY_NAME:-inconnue}" >&2
  echo "Ce script gère Ubuntu et Debian. Dis-moi quelle distribution tu utilises." >&2
  exit 1
fi
echo "Système détecté : ${PRETTY_NAME} (${DOCKER_DISTRO} / ${CODENAME})"

# --- 0. Le pilote NVIDIA doit déjà être installé ---------------------------
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo
  echo "Le pilote NVIDIA n'est pas actif ('nvidia-smi' ne répond pas)."
  echo "Installe-le d'abord, puis REDÉMARRE la machine et relance ce script :"
  echo "    sudo ubuntu-drivers install     (Ubuntu)"
  echo "    sudo reboot"
  exit 1
fi
echo "→ Pilote NVIDIA : OK"
nvidia-smi -L

# --- 1. Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  echo "→ Docker est déjà installé : $(docker --version)"
else
  echo "→ Installation de Docker..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_DISTRO}
Suites: ${CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo systemctl enable --now docker

# --- 2. NVIDIA Container Toolkit ---------------------------------------------
if command -v nvidia-ctk >/dev/null 2>&1; then
  echo "→ NVIDIA Container Toolkit déjà installé"
else
  echo "→ Installation du NVIDIA Container Toolkit..."
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg2
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
fi
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# --- 3. Autoriser ton utilisateur à utiliser Docker sans sudo -----------------
sudo usermod -aG docker "$USER"

echo
echo "============================================================"
echo " Installation terminée."
echo " IMPORTANT : redémarre la machine maintenant :   sudo reboot"
echo " (c'est nécessaire pour que Docker fonctionne sans sudo)"
echo " Ensuite, reconnecte-toi et lance :   ./2-secrets.sh"
echo "============================================================"
