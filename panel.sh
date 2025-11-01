#!/usr/bin/env bash
# ==============================================
# 🎨 ZALEEHOST — Pterodactyl Panel Installer (Full Fancy)
# Target: Debian 12 (Bookworm) — Nginx + PHP 8.3 + MariaDB + Redis + Let's Encrypt
# Domain: panel.tesdomain2105.dpdns.org
# Admin email: zaleeboy8@gmail.com
# ==============================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
DOMAIN="panel.tesdomain2105.dpdns.org"
ADMIN_EMAIL="zaleeboy8@gmail.com"
PANEL_DIR="/var/www/pterodactyl"
DB_NAME="panel"
DB_USER="ptero"
ADMIN_USER="ZaleeHost"
ADMIN_PASS="zalee1"

# Colors & style
GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; BLUE="\e[34m"; MAGENTA="\e[35m"
BOLD="\e[1m"; RESET="\e[0m"

banner(){
cat <<'EOF'
███████╗ █████╗ ██╗     ███████╗███████╗███████╗██╗  ██╗
██╔════╝██╔══██╗██║     ██╔════╝██╔════╝██╔════╝██║ ██╔╝
█████╗  ███████║██║     █████╗  ███████╗█████╗  █████╔╝ 
██╔══╝  ██╔══██║██║     ██╔══╝  ╚════██║██╔══╝  ██╔═██╗ 
██║     ██║  ██║███████╗███████╗███████║███████╗██║  ██╗
╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝
      ZaleeHost — Pterodactyl Auto Installer (Fancy)
EOF
}

spinner(){
  # spinner <pid>
  local pid="$1"
  local delay=0.08
  local spinstr='|/-\'
  while ps -p "$pid" > /dev/null 2>&1; do
    for i in $(seq 0 3); do
      printf "\r [%c] " "${spinstr:i:1}"
      sleep $delay
    done
  done
  printf "\r"
}

step(){
  echo -e "\n${BOLD}${BLUE}==> ${1}${RESET}"
}

ok(){ echo -e "${GREEN}✔ ${1}${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ ${1}${RESET}"; }
err(){ echo -e "${RED}✘ ${1}${RESET}"; exit 1; }

clear
banner
echo -e "${MAGENTA}${BOLD}\nStarting installation for ${DOMAIN}\n${RESET}"
sleep 1

# 1) Basic update
step "Updating system packages"
apt update -y && apt upgrade -y -y &>/dev/null &
spinner $!
ok "System updated"

# 2) Add SURY repo for PHP 8.3
step "Adding SURY (PHP 8.3) repository"
apt install -y ca-certificates apt-transport-https lsb-release gnupg curl &>/dev/null
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
apt update -y &>/dev/null
ok "SURY repo added"

# 3) Install core packages
step "Installing Nginx, MariaDB, Redis, PHP 8.3 and tools (this may take a while)"
apt install -y nginx mariadb-server redis-server unzip git curl tar \
 php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-mbstring php8.3-gd php8.3-mysql \
 php8.3-pgsql php8.3-sqlite3 php8.3-redis php8.3-bcmath php8.3-curl php8.3-zip php8.3-xml php8.3-intl \
 composer ufw &>/dev/null &
spinner $!
ok "Core packages installed"

# 4) Enable/start core services
step "Enabling and starting services (nginx, mariadb, redis, php-fpm)"
systemctl enable --now nginx mariadb redis-server php8.3-fpm
ok "Services running"

# 5) Secure MariaDB and create DB/user
step "Creating database and user (MariaDB)"
# If MariaDB root uses socket auth, this will work. If not, user may need to adjust.
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS:=}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
# If DB_USER creation failed because DB_PASS empty (shell var), generate secure now:
if [ -z "${DB_PASS:-}" ]; then
  DB_PASS="$(openssl rand -base64 16)"
  mysql -u root -e "ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}'; FLUSH PRIVILEGES;"
fi
ok "Database created: ${DB_NAME} (user: ${DB_USER})"

# 6) Prepare panel directory
step "Downloading Pterodactyl Panel to ${PANEL_DIR}"
rm -rf "${PANEL_DIR}" && mkdir -p "${PANEL_DIR}"
cd "${PANEL_DIR}"
curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
tar -xzf panel.tar.gz
rm -f panel.tar.gz
ok "Panel files extracted"

# 7) Composer install
step "Installing Composer dependencies (this can take a while)"
# ensure composer exists
if ! command -v composer >/dev/null 2>&1; then
  curl -sS https://getcomposer.org/installer | php
  mv composer.phar /usr/local/bin/composer
fi
composer install --no-dev --optimize-autoloader --no-interaction --no-ansi &
spinner $!
ok "Composer dependencies installed"

# 8) Environment & key
step "Preparing .env and generating app key"
cp .env.example .env
php artisan key:generate --force
ok ".env and APP_KEY ready"

# 9) Configure .env (DB, URL, Redis)
step "Writing configuration to .env"
sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|DB_PORT=.*|DB_PORT=3306|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env || true
sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env || true
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env || true
sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env || true
ok ".env configured"

# 10) Migrate & seed
step "Running migrations & seeders"
php artisan migrate --seed --force &
spinner $!
ok "Database migrations & seeds completed"

# 11) Permissions
step "Setting ownership & permissions"
chown -R www-data:www-data "${PANEL_DIR}"
find "${PANEL_DIR}" -type d -exec chmod 755 {} \;
find "${PANEL_DIR}" -type f -exec chmod 644 {} \;
ok "Permissions set"

# 12) Nginx site config
step "Creating Nginx site configuration"
cat >/etc/nginx/sites-available/pterodactyl.conf <<NG
server {
    listen 80;
    server_name ${DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ /\.ht {
        deny all;
    }

    # Redirect HTTP to HTTPS - will be active after cert obtained
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php;
    charset utf-8;
    client_max_body_size 100M;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NG

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
ok "Nginx config deployed"

# 13) Install snapd & Certbot (snap) -> reliable Certbot
step "Installing snapd & certbot (snap)"
apt install -y snapd &>/dev/null
snap install core &>/dev/null
snap refresh core &>/dev/null
snap install --classic certbot &>/dev/null
ln -sf /snap/bin/certbot /usr/bin/certbot
ok "Certbot (snap) installed"

# 14) Request Let's Encrypt certificate (non-interactive)
step "Requesting Let's Encrypt certificate for ${DOMAIN} (non-interactive)"
if certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive --redirect; then
  ok "Let's Encrypt certificate obtained & nginx configured for HTTPS"
else
  warn "Let's Encrypt request failed — attempting webroot method"
  if certbot certonly --webroot -w "${PANEL_DIR}/public" -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive; then
    ok "Certificate obtained via webroot; reloading nginx"
    nginx -t && systemctl reload nginx
  else
    warn "Let's Encrypt failed (rate-limit or other). Generating self-signed fallback certificate."
    mkdir -p /etc/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/ssl/panel.key -out /etc/ssl/panel.crt \
      -subj "/C=ID/ST=Jakarta/L=Jakarta/O=ZaleeHost/OU=Hosting/CN=${DOMAIN}"
    # Update nginx config to use self-signed files
    sed -i "s|ssl_certificate .*|ssl_certificate /etc/ssl/panel.crt;|g" /etc/nginx/sites-available/pterodactyl.conf
    sed -i "s|ssl_certificate_key .*|ssl_certificate_key /etc/ssl/panel.key;|g" /etc/nginx/sites-available/pterodactyl.conf
    nginx -t && systemctl reload nginx
    warn "Self-signed certificate installed as fallback (browser will show warning)"
  fi
fi

# 15) Systemd queue worker
step "Creating systemd unit for queue worker"
cat >/etc/systemd/system/pteroq.service <<SVC
[Unit]
Description=Pterodactyl Queue Worker
After=network.target redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now pteroq.service
ok "Queue worker active"

# 16) Firewall (UFW)
step "Configuring UFW (allow ports 22,80,443)"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true
ok "Firewall ready"

# 17) Try to create admin user non-interactively
step "Creating admin user (best-effort)"
if php artisan p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --name-first="Zalee" --name-last="Host" --password="${ADMIN_PASS}" --admin=1 --no-interaction >/dev/null 2>&1; then
  ok "Admin created: ${ADMIN_EMAIL} / ${ADMIN_PASS}"
else
  warn "Automatic admin creation not supported on this panel version — please run:"
  echo "  php ${PANEL_DIR}/artisan p:user:make"
fi

# Final summary
echo -e "\n${BOLD}${GREEN}========================================${RESET}"
echo -e "${BOLD}${GREEN}  Pterodactyl Panel installation completed${RESET}"
echo -e "  URL     : https://${DOMAIN}"
echo -e "  Admin   : ${ADMIN_EMAIL} / ${ADMIN_PASS}"
echo -e "  DB      : ${DB_NAME} | ${DB_USER} | ${DB_PASS}"
echo -e "  Panel   : ${PANEL_DIR}"
echo -e "  Logs    : /var/log/nginx/, /var/www/pterodactyl/storage/logs/"
echo -e "${BOLD}${GREEN}========================================${RESET}"
