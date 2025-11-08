#!/usr/bin/env bash
set -euo pipefail

### ========= CONFIG =========
SAFE_USER="${SAFE_USER:-ubuntu}"                 # Rescue user kept untouched
APP_USER="${APP_USER:-devops}"                   # Daily admin user to create/use
TZ="${TZ:-Europe/Paris}"
NODE_MAJOR="${NODE_MAJOR:-22}"
REPO_URL="${REPO_URL:-https://github.com/p2-inc/phasetwo-containers.git}"
REPO_DIR="${REPO_DIR:-/opt/phasetwo-containers}"
SERVICE_NAME="${SERVICE_NAME:-phasetwo-keycloak}"

# Security toggles
OPEN_HTTP="${OPEN_HTTP:-yes}"                    # open 80/443 in UFW
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-yes}"
HARDEN_SSH="${HARDEN_SSH:-yes}"                  # policy, gated by CONFIRM_HARDENING
CONFIRM_HARDENING="${CONFIRM_HARDENING:-no}"     # must be "yes" to touch sshd

# Domains / ACME email
APP_DOMAIN="${APP_DOMAIN:-tronline.academy}"
KEYCLOAK_DOMAIN="${KEYCLOAK_DOMAIN:-auth.tronline.academy}"
ACME_EMAIL="${ACME_EMAIL:-admin@tronline.academy}"

### ========= PRECHECKS =========
id -u "$SAFE_USER" >/dev/null 2>&1 || { echo "Rescue user $SAFE_USER not found."; exit 1; }

echo "[1/12] System update & timezone..."
timedatectl set-timezone "$TZ" || true
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "[2/12] Base packages..."
apt-get install -y ca-certificates curl gnupg lsb-release git ufw jq unzip \
  build-essential software-properties-common unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "[3/12] Docker Engine + Compose plugin..."
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

echo "[4/12] Create/prepare admin user '${APP_USER}' (keep '${SAFE_USER}' as rescue)..."
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$APP_USER"
fi
usermod -aG sudo,docker "$APP_USER" || true

# SSH key for APP_USER: copy from SAFE_USER if present
mkdir -p "/home/${APP_USER}/.ssh"
if [ -s "/home/${SAFE_USER}/.ssh/authorized_keys" ]; then
  cp "/home/${SAFE_USER}/.ssh/authorized_keys" "/home/${APP_USER}/.ssh/" || true
fi
chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}/.ssh"
chmod 700 "/home/${APP_USER}/.ssh"
[ -f "/home/${APP_USER}/.ssh/authorized_keys" ] && chmod 600 "/home/${APP_USER}/.ssh/authorized_keys"

# Passwordless sudo for APP_USER (drop-in file, validated, correct perms)
echo "[4b/12] Configure passwordless sudo for '${APP_USER}'..."
echo "${APP_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
chmod 440 "/etc/sudoers.d/90-${APP_USER}"
visudo -cf "/etc/sudoers.d/90-${APP_USER}"

echo "[5/12] Node.js ${NODE_MAJOR}.x..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs
npm i -g pnpm@latest yarn@latest pm2@latest || true

### -------- Stage UFW rules (enable later) --------
echo "[6/12] UFW rule staging (not enabling yet)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Detect SSH port and public IP
SSH_PORT="$(ss -tnlp 2>/dev/null | awk '/sshd/ && /LISTEN/ {print $4}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | head -n1 || true)"
[ -z "${SSH_PORT:-}" ] && SSH_PORT=22
PUB_IP="$(curl -4s https://ifconfig.me || curl -4s https://api.ipify.org || true)"

# Allow OpenSSH and explicit port; whitelist current IP
ufw app list 2>/dev/null | grep -q "OpenSSH" && ufw allow OpenSSH
ufw allow "${SSH_PORT}"/tcp
[ -n "$PUB_IP" ] && ufw allow from "$PUB_IP" to any port "${SSH_PORT}" proto tcp
[ "$OPEN_HTTP" = "yes" ] && ufw allow 80/tcp && ufw allow 443/tcp

### -------- Fail2ban with ignoreip --------
echo "[7/12] Fail2ban..."
if [ "$ENABLE_FAIL2BAN" = "yes" ]; then
  apt-get install -y fail2ban
  IGNORE_IPS="127.0.0.1/8"
  [ -n "$PUB_IP" ] && IGNORE_IPS="$IGNORE_IPS $PUB_IP"
  cat >/etc/fail2ban/jail.local <<JAIL
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 6
backend  = systemd
banaction = iptables-multiport
ignoreip = ${IGNORE_IPS}

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
JAIL
  systemctl enable --now fail2ban
else
  echo "  -> fail2ban not installed."
fi

### -------- SSH hardening (explicitly confirmed only) --------
echo "[8/12] SSH hardening (only if CONFIRM_HARDENING=yes and ${APP_USER} has authorized_keys)..."
APP_AUTH_KEYS="/home/${APP_USER}/.ssh/authorized_keys"
if [ "$HARDEN_SSH" = "yes" ] && [ "$CONFIRM_HARDENING" = "yes" ] && [ -s "$APP_AUTH_KEYS" ]; then
  SSHD_CFG="/etc/ssh/sshd_config"
  cp -a "$SSHD_CFG" "${SSHD_CFG}.bak.$(date +%s)" || true

  # Safe global hardening; keep rescue usability
  if grep -q '^PasswordAuthentication' "$SSHD_CFG"; then
    sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CFG"
  else
    echo 'PasswordAuthentication no' >> "$SSHD_CFG"
  fi
  if grep -q '^PermitRootLogin' "$SSHD_CFG"; then
    sed -i 's/^PermitRootLogin .*/PermitRootLogin prohibit-password/' "$SSHD_CFG"
  else
    echo 'PermitRootLogin prohibit-password' >> "$SSHD_CFG"
  fi
  grep -q '^PubkeyAuthentication yes' "$SSHD_CFG" || echo 'PubkeyAuthentication yes' >> "$SSHD_CFG"

  sshd -t
  systemctl reload ssh || systemctl restart ssh
  echo "  -> SSH hardened (password auth disabled; root via key only)."
else
  echo "  -> Skipped SSH hardening."
fi

### -------- Clone + Caddy/Compose files --------
echo "[9/12] Clone/update PhaseTwo containers..."
mkdir -p "$(dirname "$REPO_DIR")"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch --all --prune
  git -C "$REPO_DIR" switch main || git -C "$REPO_DIR" checkout main || true
  git -C "$REPO_DIR" pull --ff-only || true
else
  git clone "$REPO_URL" "$REPO_DIR"
fi
chown -R "$APP_USER":"$APP_USER" "$REPO_DIR"

echo "[10/12] Write docker-compose.override.yml (Caddy + App + network overrides)..."
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

echo "[11/12] Write Caddyfile..."
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

echo "[12/12] Create/refresh systemd unit: ${SERVICE_NAME}.service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PhaseTwo Keycloak + Caddy stack (docker compose)
Requires=docker.service
After=docker.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes
User=${APP_USER}
Group=${APP_USER}
TimeoutStartSec=420

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

# Pre-pull images (non-fatal)
sudo -u "$APP_USER" docker compose -f "${REPO_DIR}/docker-compose.yml" -f "${REPO_DIR}/docker-compose.override.yml" pull || true

### -------- Enable UFW LAST --------
echo "[FINAL] Enabling UFW..."
ufw --force enable
ufw status verbose || true

echo "============================================================"
echo "Done."
echo "Start stack:   sudo systemctl start ${SERVICE_NAME}.service"
echo "Status:        systemctl status ${SERVICE_NAME}.service"
echo "Rescue user kept: ${SAFE_USER}"
echo "Admin user:       ${APP_USER}"
echo "SSH hardening applied? HARDEN_SSH=${HARDEN_SSH}, CONFIRM_HARDENING=${CONFIRM_HARDENING}"
echo "Detected SSH port: ${SSH_PORT}  | Your IP: ${PUB_IP:-unknown}"
echo "============================================================"
