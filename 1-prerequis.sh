#!/usr/bin/env bash
# STEP 1: installs Docker and the NVIDIA Container Toolkit (Ubuntu / Debian).
#
# Run it with YOUR normal user, WITHOUT "sudo" in front:
#     ./1-prerequis.sh
# It asks for your password when it needs it.
#
# Commands taken from the official Docker and NVIDIA documentation.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script with sudo or as root. Simply run: ./1-prerequis.sh" >&2
  exit 1
fi

. /etc/os-release
# Ubuntu and its derivatives (Mint, Pop!_OS...) or Debian
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
  echo "Distribution not supported by this script: ${PRETTY_NAME:-unknown}" >&2
  echo "This script handles Ubuntu and Debian." >&2
  exit 1
fi
echo "System detected: ${PRETTY_NAME} (${DOCKER_DISTRO} / ${CODENAME})"

# --- 0. The NVIDIA driver must already be installed -------------------------
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo
  echo "The NVIDIA driver is not active ('nvidia-smi' does not answer)."
  echo "Install it first, then REBOOT the machine and run this script again:"
  echo "    sudo ubuntu-drivers install     (Ubuntu)"
  echo "    sudo reboot"
  exit 1
fi
echo "→ NVIDIA driver: OK"
nvidia-smi -L

# --- 1. Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  echo "→ Docker is already installed: $(docker --version)"
else
  echo "→ Installing Docker..."
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
  echo "→ NVIDIA Container Toolkit already installed"
else
  echo "→ Installing the NVIDIA Container Toolkit..."
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

# --- 3. Allow your user to use Docker without sudo ---------------------------
sudo usermod -aG docker "$USER"

echo
echo "============================================================"
echo " Installation finished."
echo " IMPORTANT: reboot the machine now:   sudo reboot"
echo " (needed for Docker to work without sudo)"
echo " Then log in again and run:   ./2-secrets.sh"
echo "============================================================"
