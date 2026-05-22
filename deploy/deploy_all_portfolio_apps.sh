#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_HOST="${PUBLIC_HOST:-39.96.11.186}"
ROOT="/opt/portfolio-suite"
STATIC_ROOT="/var/www/portfolio-suite"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo -i"
  exit 1
fi

echo "==> Installing packages"
apt update
apt install -y git curl nginx python3 python3-venv python3-pip nodejs npm

mkdir -p "$ROOT" "$STATIC_ROOT"

clone_or_update() {
  local repo_url="$1"
  local dir="$2"
  if [ ! -d "$dir/.git" ]; then
    git clone "$repo_url" "$dir"
  fi
  git -C "$dir" fetch origin main
  git -C "$dir" reset --hard origin/main
}

echo "==> Updating repositories"
clone_or_update "https://github.com/dileonardoliebel813-jpg/ai-portfolio.git" "$ROOT/ai-portfolio"
clone_or_update "https://github.com/dileonardoliebel813-jpg/camp-rank.git" "$ROOT/camp-rank"
clone_or_update "https://github.com/dileonardoliebel813-jpg/github-trending.git" "$ROOT/github-trending"
clone_or_update "https://github.com/dileonardoliebel813-jpg/gomoku-game.git" "$ROOT/gomoku-game"

echo "==> Publishing static sites"
rm -rf "$STATIC_ROOT/portfolio" "$STATIC_ROOT/github-trending" "$STATIC_ROOT/gomoku-game" "$STATIC_ROOT/camp-rank"
mkdir -p "$STATIC_ROOT/portfolio" "$STATIC_ROOT/github-trending" "$STATIC_ROOT/gomoku-game" "$STATIC_ROOT/camp-rank"
cp -a "$ROOT/ai-portfolio"/. "$STATIC_ROOT/portfolio"/
rm -rf "$STATIC_ROOT/portfolio/.git" "$STATIC_ROOT/portfolio/offline" "$STATIC_ROOT/portfolio/ai-portfolio-offline.zip"
cp -a "$ROOT/github-trending"/. "$STATIC_ROOT/github-trending"/
rm -rf "$STATIC_ROOT/github-trending/.git" "$STATIC_ROOT/github-trending/.github" "$STATIC_ROOT/github-trending/.claude"
cp -a "$ROOT/gomoku-game"/. "$STATIC_ROOT/gomoku-game"/
rm -rf "$STATIC_ROOT/gomoku-game/.git"

echo "==> Building CampRank frontend"
cd "$ROOT/camp-rank/frontend"
npm ci
npm run build
cp -a dist/. "$STATIC_ROOT/camp-rank"/

echo "==> Installing CampRank backend"
cd "$ROOT/camp-rank/backend"
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
python -m pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple

cat >/etc/systemd/system/camp-rank.service <<EOF
[Unit]
Description=CampRank API
After=network.target

[Service]
WorkingDirectory=$ROOT/camp-rank/backend
ExecStart=$ROOT/camp-rank/backend/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8002
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Re-pointing existing JobFit service to local port 8001 if present"
if [ -f /etc/systemd/system/jobfit.service ]; then
  sed -i 's/--host 0.0.0.0 --port 80/--host 127.0.0.1 --port 8001/g' /etc/systemd/system/jobfit.service
fi

echo "==> Installing Nginx multi-app gateway"
cat >/etc/nginx/sites-available/portfolio-suite <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 20m;

    location /portfolio/ {
        alias $STATIC_ROOT/portfolio/;
        index index.html;
        try_files \$uri \$uri/ /portfolio/index.html;
    }

    location /camp-rank/ {
        alias $STATIC_ROOT/camp-rank/;
        index index.html;
        try_files \$uri \$uri/ /camp-rank/index.html;
    }

    location /github-trending/ {
        alias $STATIC_ROOT/github-trending/;
        index index.html;
        try_files \$uri \$uri/ /github-trending/index.html;
    }

    location /gomoku-game/ {
        alias $STATIC_ROOT/gomoku-game/;
        index index.html;
        try_files \$uri \$uri/ /gomoku-game/index.html;
    }

    location /api/v1/ {
        proxy_pass http://127.0.0.1:8001/api/v1/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 240s;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8002/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }

    location /health {
        proxy_pass http://127.0.0.1:8001/health;
    }

    location / {
        proxy_pass http://127.0.0.1:8001/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 240s;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/portfolio-suite /etc/nginx/sites-enabled/portfolio-suite
nginx -t

echo "==> Starting services"
systemctl daemon-reload
systemctl enable camp-rank
systemctl restart camp-rank
if [ -f /etc/systemd/system/jobfit.service ]; then
  systemctl restart jobfit
fi
systemctl restart nginx

echo "==> Checks"
curl -fsS "http://127.0.0.1/portfolio/" >/dev/null
curl -fsS "http://127.0.0.1/github-trending/" >/dev/null
curl -fsS "http://127.0.0.1/gomoku-game/" >/dev/null
curl -fsS "http://127.0.0.1/camp-rank/" >/dev/null
curl -fsS "http://127.0.0.1/health" >/dev/null

echo "==> Done"
echo "Portfolio:        http://$PUBLIC_HOST/portfolio/?v=deploy"
echo "JobFit:           http://$PUBLIC_HOST/"
echo "CampRank:         http://$PUBLIC_HOST/camp-rank/"
echo "GitHub Trending:  http://$PUBLIC_HOST/github-trending/"
echo "Gomoku Game:      http://$PUBLIC_HOST/gomoku-game/"
