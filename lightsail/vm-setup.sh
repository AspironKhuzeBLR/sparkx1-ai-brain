#!/usr/bin/env bash
# One-shot VM setup for Sparks AI Brain on a Lightsail (Ubuntu) instance.
#
# On a fresh VM:
#   sudo apt-get update && sudo apt-get install -y git
#   git clone https://github.com/AspironKhuzeBLR/sparkx1-ai-brain.git
#   cd sparkx1-ai-brain
#   export GEMINI_API_KEY=your_real_key
#   export SERVICE_API_KEY=your_real_key
#   bash lightsail/vm-setup.sh                      # -> live on http://<VM-IP>
#   DOMAIN=api.example.com bash lightsail/vm-setup.sh   # -> live on https://DOMAIN
#
# Re-running is safe: pulls latest code, reinstalls deps, restarts everything.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_USER="$(whoami)"
SERVICE=sparkx1
DOMAIN="${DOMAIN:-}"
CERT_EMAIL="${CERT_EMAIL:-admin@${DOMAIN:-example.com}}"

echo "==> App dir: $APP_DIR (user: $RUN_USER)"

# ---------- 1. System packages ----------
echo "==> Installing system packages..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip nginx curl

# ---------- 2. Keys / .env ----------
if [ ! -f "$APP_DIR/.env" ]; then
  if [ -z "${GEMINI_API_KEY:-}" ] || [ -z "${SERVICE_API_KEY:-}" ]; then
    echo "!! No .env found and GEMINI_API_KEY / SERVICE_API_KEY not exported."
    read -rp "Enter GEMINI_API_KEY: " GEMINI_API_KEY
    read -rp "Enter SERVICE_API_KEY: " SERVICE_API_KEY
  fi
  cat > "$APP_DIR/.env" <<EOF
GEMINI_API_KEY=$GEMINI_API_KEY
SERVICE_API_KEY=$SERVICE_API_KEY
HOST=127.0.0.1
PORT=8000
DEBUG=False
GEMINI_MODEL=gemini-2.5-flash
GEMINI_TEMPERATURE=0.1
GEMINI_MAX_TOKENS=8192
EOF
  chmod 600 "$APP_DIR/.env"
  echo "==> Wrote $APP_DIR/.env"
else
  echo "==> Reusing existing $APP_DIR/.env"
fi

# ---------- 3. Python env ----------
echo "==> Setting up Python venv..."
cd "$APP_DIR"
git pull --ff-only || true
python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt

# ---------- 4. systemd service (app on localhost:8000) ----------
echo "==> Installing systemd service..."
sudo tee /etc/systemd/system/$SERVICE.service >/dev/null <<EOF
[Unit]
Description=Sparks AI Brain (FastAPI)
After=network.target

[Service]
User=$RUN_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE"
sudo systemctl restart "$SERVICE"

# ---------- 5. nginx reverse proxy (IP:80 -> app:8000) ----------
echo "==> Configuring nginx..."
SERVER_NAME="${DOMAIN:-_}"
sudo tee /etc/nginx/sites-available/$SERVICE >/dev/null <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 180s;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/$SERVICE /etc/nginx/sites-enabled/$SERVICE
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

# ---------- 6. HTTPS via Let's Encrypt (only if DOMAIN is set) ----------
if [ -n "$DOMAIN" ]; then
  echo "==> Setting up HTTPS for $DOMAIN..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL" --redirect
  echo "==> HTTPS enabled (auto-renews via systemd timer)"
fi

# ---------- 7. Verify ----------
echo "==> Waiting for app to come up..."
sleep 3
if curl -sf http://127.0.0.1:8000/health >/dev/null; then
  PUBLIC_IP=$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 || curl -sf https://checkip.amazonaws.com || echo "<your-VM-IP>")
  echo ""
  echo "✅ Sparks AI Brain is LIVE"
  if [ -n "$DOMAIN" ]; then
    echo "   URL:    https://$DOMAIN"
    echo "   Health: https://$DOMAIN/health"
  else
    echo "   URL:    http://$PUBLIC_IP"
    echo "   Health: http://$PUBLIC_IP/health"
  fi
  echo ""
  echo "   Logs:    sudo journalctl -u $SERVICE -f"
  echo "   Restart: sudo systemctl restart $SERVICE"
  echo "   Update:  cd $APP_DIR && git pull && sudo systemctl restart $SERVICE"
else
  echo "❌ App failed health check. Logs:"
  sudo journalctl -u "$SERVICE" -n 40 --no-pager
  exit 1
fi
