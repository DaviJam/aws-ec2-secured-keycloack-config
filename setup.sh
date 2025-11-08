#!/usr/bin/env bash
set -euo pipefail

### ========= CONFIG =========
SAFE_USER="${SAFE_USER:-ubuntu}"                 # Rescue user kept untouched
APP_USER="${APP_USER:-devops}"                   # Daily admin user
NODE_MAJOR="${NODE_MAJOR:-22}"
REPO_URL="${REPO_URL:-https://github.com/p2-inc/phasetwo-containers.git}"
REPO_DIR="${REPO_DIR:-/opt/phasetwo-containers}"
SERVICE_NAME="${SERVICE_NAME:-phasetwo-keycloak}"

# Domains / ACME email for Caddy
APP_DOMAIN="${APP_DOMAIN:-tronline.academy}"
KEYCLOAK_DOMAIN="${KEYCLOAK_DOMAIN:-auth.tronline.academy}"
ACME_EMAIL="${ACME_EMAIL:-admin@tronline.academy}"

### ========= PRECHECKS =========
id -u "$SAFE_USER" >/dev/null 2>&1 || { echo "Rescue user $SAFE_USER not found."; exit 1; }

echo "[1/10] System update & timezone..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release git jq unzip \
  build-essential software-properties-common unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "[2/10] Docker Engine + Compose plugin..."
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
chmod a+r /etc/apt/keyrings/docker.gpg
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "[3/10] Create admin user '${APP_USER}' (keep '${SAFE_USER}' as rescue)..."
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$APP_USER"
fi
usermod -aG sudo,docker "$APP_USER" || true
mkdir -p "/home/${APP_USER}/.ssh"
if [ -s "/home/${SAFE_USER}/.ssh/authorized_keys" ]; then
  cp "/home/${SAFE_USER}/.ssh/authorized_keys" "/home/${APP_USER}/.ssh/" || true
fi
chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}/.ssh"
chmod 700 "/home/${APP_USER}/.ssh"
[ -f "/home/${APP_USER}/.ssh/authorized_keys" ] && chmod 600 "/home/${APP_USER}/.ssh/authorized_keys"

echo "[3b/10] Configure passwordless sudo for '${APP_USER}'..."
echo "${APP_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
chmod 440 "/etc/sudoers.d/90-${APP_USER}"
visudo -cf "/etc/sudoers.d/90-${APP_USER}"

echo "[4/10] Node.js ${NODE_MAJOR}.x (for helper tools/app dev)..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs
npm i -g pnpm@latest yarn@latest || true

echo "[7/10] Clone/update PhaseTwo containers repo..."
mkdir -p "$(dirname "$REPO_DIR")"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch --all --prune
  git -C "$REPO_DIR" switch main || git -C "$REPO_DIR" checkout main || true
  git -C "$REPO_DIR" pull --ff-only || true
else
  git clone "$REPO_URL" "$REPO_DIR"
fi
chown -R "$APP_USER":"$APP_USER" "$REPO_DIR"

echo "[8/10] Write docker-compose.override.yml (Caddy + App + network overrides)..."
cat > "${REPO_DIR}/docker-compose.override.yml" <<'EOF'
networks:
  web:
    driver: bridge

volumes:
  caddy_data:
    driver: local
  caddy_config:
    driver: local

services:
  app:
    image: node:22-alpine
    working_dir: /srv/app
    command: sh -c "npx --yes serve -l 3000 -s /srv/app || (mkdir -p /srv/app && printf '<h1>tronline.academy</h1>' > /srv/app/index.html && npx --yes serve -l 3000 -s /srv/app)"
    networks: [web]

  keycloak:
    environment:
      KC_HOSTNAME: auth.tronline.academy
      KC_PROXY: edge
      KC_HOSTNAME_STRICT: "false"
      KC_HTTP_ENABLED: "true"
      KC_HTTP_RELATIVE_PATH: /
    networks: [web]
    ports: []   # hide direct exposure; use Caddy
    depends_on:
      - cockroach

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    networks: [web]
    ports:
      - "80:80"
      - "443:443"
    environment:
      ACME_AGREE: "true"
    volumes:
      - caddy_data:/data
      - caddy_config:/config
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    depends_on:
      - app
      - keycloak
EOF
chown "$APP_USER":"$APP_USER" "${REPO_DIR}/docker-compose.override.yml"

echo "[9/10] Write Caddyfile..."
cat > "${REPO_DIR}/Caddyfile" <<EOF
{
  email ${ACME_EMAIL}
}

${APP_DOMAIN} {
  encode gzip
  reverse_proxy app:3000
}

${KEYCLOAK_DOMAIN} {
  encode gzip
  reverse_proxy keycloak:8080
  header {
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
  }
}
EOF
chown "$APP_USER":"$APP_USER" "${REPO_DIR}/Caddyfile"

# Pre-pull images (non-fatal)
sudo -u "$APP_USER" docker compose -f "${REPO_DIR}/docker-compose.yml" -f "${REPO_DIR}/docker-compose.override.yml" pull || true

echo "============================================================"
echo "Done."
echo "Start stack:   sudo systemctl start ${SERVICE_NAME}.service"
echo "Status:        systemctl status ${SERVICE_NAME}.service"
echo ""
echo "Rescue user kept: ${SAFE_USER}"
echo "Admin user:       ${APP_USER} (passwordless sudo configured)"
echo "============================================================"
