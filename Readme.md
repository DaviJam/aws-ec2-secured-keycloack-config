# PhaseTwo Keycloak + Caddy + CockroachDB POC Environment

This repository contains a reusable setup script and Docker configuration for deploying a **secure, self-hosted Keycloak instance** (based on [PhaseTwo Containers](https://github.com/p2-inc/phasetwo-containers)) with **Caddy reverse proxy** (for automatic HTTPS) and **CockroachDB** as the backend database.

It is designed for **Ubuntu 22.04+ / 24.04+ EC2 instances** and provides a hardened, reproducible, on-premise Keycloak stack suitable for proof-of-concepts or internal development environments.

---

## 🚀 Features

- **Fully automated setup** with one script (`setup.sh`)
- **Safe multi-user model**
  - Keeps `ubuntu` (AWS default) as rescue user
  - Creates `devops` (or custom user) as main admin
  - Passwordless `sudo` via `/etc/sudoers.d/`
- **Docker-based stack**
  - Keycloak (PhaseTwo image) + CockroachDB + Node demo app
  - Caddy reverse proxy with automatic Let's Encrypt certificates
- **Security hardening**
  - Optional SSH hardening (key-only auth)
  - UFW firewall configured automatically
  - Fail2ban with your IP whitelisted
- **Systemd integration** for managing the full stack as a service
- **Safe defaults** — you can always log in via `ubuntu` even if SSH rules break

---

## 🧩 Architecture Overview

```
┌────────────────────────────────────────────┐
│  Ubuntu 24 EC2 Instance                    │
│                                            │
│  ┌───────────────┐     ┌──────────────┐    │
│  │ Caddy (443/80)│<──▶│  Keycloak     │    │
│  │ auto-HTTPS    │    │  (auth.*)     │    │
│  └───────────────┘    └──────┬────────┘    │
│         ▲                    │             │
│         │                    ▼             │
│   app.tronline.academy   CockroachDB        │
│   (static Node demo)     (v23.2.x)          │
└────────────────────────────────────────────┘
```

---

## ⚙️ Prerequisites

- Ubuntu 22.04+ (tested on 24.04 LTS)
- SSH key-based access (AWS EC2 or equivalent)
- Domain names pointing to your instance:
  - `tronline.academy` (for your app)
  - `auth.tronline.academy` (for Keycloak)
- Port 80/443 open in your AWS Security Group

---

## 🧰 Usage

### 1️⃣ Clone the repository

```bash
git clone https://github.com/your-org/phasetwo-keycloak-env.git
cd phasetwo-keycloak-env
```

### 2️⃣ Review and run the setup

```bash
sudo ./setup.sh
```

The script will:

- Create the `devops` user (or `$APP_USER`)
- Install Docker, Node.js, UFW, and Fail2ban
- Configure passwordless sudo for the admin user
- Clone the PhaseTwo repo and generate `Caddyfile` + `docker-compose.override.yml`
- Register a systemd service named `phasetwo-keycloak`

### 3️⃣ Start the stack

```bash
sudo systemctl start phasetwo-keycloak.service
sudo systemctl status phasetwo-keycloak.service
```

Check Caddy logs if HTTPS fails initially (Let's Encrypt may need DNS propagation).

### 4️⃣ Access your services

| Service             | URL                           | Notes                        |
| ------------------- | ----------------------------- | ---------------------------- |
| Demo App            | https://tronline.academy      | Static demo served via Caddy |
| Keycloak (PhaseTwo) | https://auth.tronline.academy | Use admin:admin by default   |
| CockroachDB         | localhost:26257               | Internal only                |

---

## 🔒 Optional SSH Hardening

To disable password authentication globally (safe only if `devops` SSH works):

```bash
sudo CONFIRM_HARDENING=yes ./setup.sh
```

This will:

- Disable password login
- Keep root accessible via key only
- Leave `ubuntu` untouched (AWS rescue access still works)

---

## 🧠 Configuration Summary

| Variable            | Default                  | Description                             |
| ------------------- | ------------------------ | --------------------------------------- |
| `APP_USER`          | `devops`                 | Admin user to create for daily use      |
| `SAFE_USER`         | `ubuntu`                 | Rescue user kept for AWS console access |
| `APP_DOMAIN`        | `tronline.academy`       | Main app domain                         |
| `KEYCLOAK_DOMAIN`   | `auth.tronline.academy`  | Keycloak subdomain                      |
| `ACME_EMAIL`        | `admin@tronline.academy` | Email for Let's Encrypt                 |
| `NODE_MAJOR`        | `22`                     | Node.js version for app container       |
| `ENABLE_FAIL2BAN`   | `yes`                    | Enables Fail2ban protection             |
| `HARDEN_SSH`        | `yes`                    | Prepares for key-only SSH mode          |
| `CONFIRM_HARDENING` | `no`                     | Must be `yes` to apply SSH hardening    |

---

## 🧯 Troubleshooting

- **Locked out after hardening:**  
  Use AWS EC2 *Serial Console* or *Session Manager* and run:

  ```bash
  sudo ufw disable
  sudo sed -i 's/^PasswordAuthentication no/#PasswordAuthentication yes/' /etc/ssh/sshd_config
  sudo systemctl restart ssh
  ```

- **Caddy certificate fails:**  
  Check DNS A records for both domains and re-run:

  ```bash
  docker compose restart caddy
  ```

- **Keycloak doesn’t start:**  
  Inspect logs:

  ```bash
  docker compose logs keycloak
  ```

---

## 🧩 File Structure

```
.
├── setup.sh                       # Full environment setup script
├── Dockerfile                     # Extended Keycloak (PhaseTwo) build
├── docker-compose.yml              # Base compose from PhaseTwo repo
├── docker-compose.override.yml     # Generated override (Caddy + App)
├── Caddyfile                       # Reverse proxy + TLS config
└── README.md                      # Documentation (this file)
```

---

## 🧰 Future Enhancements

- Add **Kong Gateway OSS** integration
- Add **monitoring stack** (Prometheus + Grafana)
- Parameterize via `.env` file
- Support automatic DNS record validation (ACME DNS challenge)

---

## 📜 License

MIT — provided as-is, with no warranty.  
Based on open-source work from [PhaseTwo](https://github.com/p2-inc/phasetwo-containers).

---

**Author:** *DaviJam / David G. James*  
**Purpose:** Internal DevOps POC environment for Tronline / PhaseTwo integration.
