#!/usr/bin/env bash
set -euo pipefail

### ========= CONFIG =========
SAFE_USER="${SAFE_USER:-ubuntu}"                 # Rescue user kept untouched
APP_USER="${APP_USER:-devops}"                   # Daily admin user
TZ="${TZ:-Europe/Paris}"
NODE_MAJOR="${NODE_MAJOR:-22}"
REPO_URL="${REPO_URL:-https://github.com/p2-inc/phasetwo-containers.git}"
REPO_DIR="${REPO_DIR:-/opt/phasetwo-containers}"
SERVICE_NAME="${SERVICE_NAME:-phasetwo-keycloak}"

# SSH hardening (generally unnecessary on AWS; leave OFF)
HARDEN_SSH="${HARDEN_SSH:-no}"
CONFIRM_HARDENING="${CONFIRM_HARDENING:-no}"

# Domains / ACME email for Caddy
APP_DOMAIN="${APP_DOMAIN:-tronline.academy}"
KEYCLOAK_DOMAIN="${KEYCLOAK_DOMAIN:-auth.tronline.academy}"
ACME_EMAIL="${ACME_EMAIL:-admin@tronline.academy}"

### ========= PRECHECKS =========
id -u "$SAFE_USER" >/dev/null 2>&1 || { echo "Rescue user $SAFE_USER not found."; exit 1; }

echo "[1/10] System update & timezone..."
timedatectl set-timezone "$TZ" || true
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

### (Optional) SSH hardening — OFF by default on AWS (use SGs/NACLs)
#echo "[5/10] SSH hardening check..."
APP_AUTH_KEYS="/home/${APP_USER}/.ssh/authorized_keys"
#if [ "${HARDEN_SSH}" = "yes" ] && [ "${CONFIRM_HARDENING}" = "yes" ] && [ -s "$APP_AUTH_KEYS" ]; then
#  SSHD_CFG="/etc/ssh/sshd_config"
#  cp -a "$SSHD_CFG" "${SSHD_CFG}.bak.$(date +%s)" || true
#  grep -q '^PubkeyAuthentication' "$SSHD_CFG" || echo 'PubkeyAuthentication yes' >> "$SSHD_CFG"
#  if grep -q '^PasswordAuthentication' "$SSHD_CFG"; then
#    sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CFG"
#  else
#    echo 'PasswordAuthentication no' >> "$SSHD_CFG"
#  fi
#  if grep -q '^PermitRootLogin' "$SSHD_CFG"; then
#    sed -i 's/^PermitRootLogin .*/PermitRootLogin prohibit-password/' "$SSHD_CFG"
#  else
#    echo 'PermitRootLogin prohibit-password' >> "$SSHD_CFG"
#  fi
#  sshd -t
#  systemctl reload ssh || systemctl restart ssh
#  echo "  -> SSH hardened (key-only)."
#else
#  echo "  -> SSH hardening skipped (recommend AWS Security Groups instead)."
#fi

echo "[6/10] CloudWatch Agent (metrics/logs to AWS)..."
# Requires the instance to have IAM role with CloudWatchAgentServerPolicy
CW_DEB="/tmp/amazon-cloudwatch-agent.deb"
curl -fsSL -o "$CW_DEB" https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i "$CW_DEB"
rm -f "$CW_DEB"

cat >/opt/aws/amazon-cloudwatch-agent.json <<'CWCFG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log",
    "run_as_user": "root"
  },
  "metrics": {
    "append_dimensions": {
      "AutoScalingGroupName": "${aws:AutoScalingGroupName}",
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    },
    "metrics_collected": {
      "cpu":   { "measurement": ["cpu_usage_idle","cpu_usage_iowait","cpu_usage_system","cpu_usage_user"], "totalcpu": true },
      "disk":  { "measurement": ["used_percent"], "resources": ["*"] },
      "diskio":{ "measurement": ["io_time","write_bytes","read_bytes"] },
      "mem":   { "measurement": ["mem_used_percent","mem_available","mem_used"] },
      "net":   { "measurement": ["bytes_sent","bytes_recv","packets_sent","packets_recv"], "resources": ["*"] },
      "swap":  { "measurement": ["swap_used_percent"] },
      "procstat": [
        { "pattern": "caddy" },
        { "pattern": "keycloak" }
      ]
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/syslog", "log_group_name": "/ec2/syslog", "log_stream_name": "{instance_id}", "timestamp_format": "%b %d %H:%M:%S" }
        ]
      }
    }
  }
}
CWCFG

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop || true
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent.json

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

echo "[10/10] systemd unit for the stack..."
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

echo "============================================================"
echo "Done."
echo "Start stack:   sudo systemctl start ${SERVICE_NAME}.service"
echo "Status:        systemctl status ${SERVICE_NAME}.service"
echo ""
echo "Rescue user kept: ${SAFE_USER}"
echo "Admin user:       ${APP_USER} (passwordless sudo configured)"
echo "SSH hardening:    HARDEN_SSH=${HARDEN_SSH}, CONFIRM_HARDENING=${CONFIRM_HARDENING}"
echo "CloudWatch Agent: installed & started (requires IAM role: CloudWatchAgentServerPolicy)"
echo "============================================================"
