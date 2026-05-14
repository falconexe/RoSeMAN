#!/usr/bin/env bash
# =============================================================
# RoSeMAN — one-command installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/falconexe/RoSeMAN/docker/scripts/install.sh | bash
#
# Or with custom options:
#   ROSEMAN_DIR=/opt/roseman MONGO_PASSWORD=mypass bash install.sh
# =============================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────
REPO_URL="https://github.com/falconexe/RoSeMAN.git"
BRANCH="docker"
INSTALL_DIR="${ROSEMAN_DIR:-$HOME/roseman}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"
APP_PORT="${APP_PORT:-3000}"
MONGO_PORT="${MONGO_PORT:-27017}"


# ── Step 1: Check OS ─────────────────────────────────────────
info "Checking prerequisites..."

if [[ "$(uname -s)" != "Linux" ]]; then
    error "This script only supports Linux."
fi

ARCH=$(uname -m)
info "Architecture: ${ARCH}"

# ── Step 2: Install Docker if needed ──────────────────────────
if command -v docker &>/dev/null && docker info &>/dev/null; then
    info "Docker is already installed."
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    info "Docker installed successfully."
fi

# Ensure current user is in docker group
if ! id -nG "$(whoami)" | grep -qw docker; then
    info "Adding user $(whoami) to docker group..."
    sudo usermod -aG docker "$(whoami)"
    warn "You may need to log out and back in for group changes to take effect."
    warn "If the script fails after this, re-run it after re-login."
fi

# Check Docker Compose plugin
if ! docker compose version &>/dev/null; then
    error "Docker Compose plugin not found. Please install it: https://docs.docker.com/compose/install/"
fi

info "Docker Compose: $(docker compose version --short)"

# ── Step 3: Clone / update repository ────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Updating existing installation at ${INSTALL_DIR}..."
    git -C "${INSTALL_DIR}" pull || true
else
    info "Cloning RoSeMAN repository (branch: ${BRANCH})..."
    git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}"

# ── Step 4: Create .env files ─────────────────────────────────
# Generate a random MongoDB password if not provided
if [[ -z "${MONGO_PASSWORD}" ]]; then
    MONGO_PASSWORD=$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32)
fi

# .env (main config + REST API)
if [[ -f .env ]]; then
    warn ".env already exists — keeping existing file."
else
    info "Creating .env with generated MongoDB password..."
    sed \
        -e "s|secret|${MONGO_PASSWORD}|g" \
        -e "s|^PORT=3000|PORT=${APP_PORT}|" \
        .env.example > .env
fi

# .env.polkadot
if [[ -f .env.polkadot ]]; then
    warn ".env.polkadot already exists — keeping existing file."
else
    info "Creating .env.polkadot..."
    cp .env.polkadot.example .env.polkadot
fi

# .env.kusama
if [[ -f .env.kusama ]]; then
    warn ".env.kusama already exists — keeping existing file."
else
    info "Creating .env.kusama..."
    cp .env.kusama.example .env.kusama
fi

# ── Step 5: Create dump directory ─────────────────────────────
mkdir -p dump

# ── Step 6: Pull images and start services ────────────────────
info "Pulling Docker images (this may take a few minutes)..."
docker compose pull

info "Starting RoSeMAN services..."
docker compose up -d

# ── Step 7: Health check ──────────────────────────────────────
info "Waiting for services to become healthy..."
MAX_WAIT=120
ELAPSED=0

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    if docker compose ps --format json 2>/dev/null | jq -e '.Health == "healthy"' &>/dev/null; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "."
done
echo ""

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  RoSeMAN is running!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "  REST API:   ${GREEN}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${APP_PORT}/api${NC}"
echo -e "  Metrics:    ${GREEN}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${APP_PORT}/metrics${NC}"
echo ""
echo -e "  Config dir:  ${INSTALL_DIR}"
echo -e "  MongoDB:    admin / ${MONGO_PASSWORD}"
echo ""
echo -e "  Useful commands:"
echo -e "    ${INSTALL_DIR} && docker compose logs -f    # view logs"
echo -e "    cd ${INSTALL_DIR} && docker compose down    # stop services"
echo -e "    cd ${INSTALL_DIR} && docker compose up -d   # start services"
echo ""
