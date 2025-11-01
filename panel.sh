#!/usr/bin/env bash
# panel.sh — ZaleeHost Pterodactyl Installer (stable, Debian/Ubuntu)
# Features:
#  - OS detection (Debian/Ubuntu), mirror fallback
#  - Interactive: Panel / Wings / Theme / Full
#  - Manual domain/email/db input
#  - Auto-create DB user 'ptero' (or use manual credentials)
#  - Let's Encrypt via snap (fallback self-signed)
#  - Composer install, migrations, queue service
#  - Logging: /root/panel_install.log
# Usage:
#   wget -qO panel.sh https://raw.githubusercontent.com/zaleeboy8-source/scripts/main/panel.sh
#   chmod +x panel.sh
#   sudo bash panel.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
LOGFILE="/root/panel_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ---------- Colors ----------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BLUE="\e[34m"
BOLD="\e[1m"; RESET="\e[0m"
info(){ printf "${BOLD}${CYAN}==>${RESET} %s\n" "$1"; }
ok(){ printf "${GREEN}✔ %s${RESET}\n" "$1"; }
warn(){ printf "${YELLOW}⚠ %s${RESET}\n" "$1"; }
fail(){ printf "${RED}✘ %s${RESET}\n" "$1"; exit 1; }

# ---------- Helpers ----------
require_root(){ [ "$EUID" -eq 0 ] || fail "Run as root (sudo)."; }

confirm(){
  # confirm "Question" default_yes(1/0)
  local prompt="$1"; local default_yes="${2:-1}"; local ans
  if [ "$default_yes" -eq 1 ]; then
    read -rp "$prompt [Y/n]: " ans; ans=${ans:-Y}
  else
    read -rp "$prompt [y/N]: " ans; ans=${ans:-N}
  fi
  case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

read_input(){
  # read_input "Prompt" "default"
  local prompt="$1"; local def="${2:-}"; local val
  if [ -n "$def" ]; then
    read -rp "$prompt [$def]: " val
    val=${val:-$def}
  else
    read -rp "$prompt: " val
  fi
  echo "$val"
}

detect_os(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID,,}"
    DISTRO_VER="${VERSION_ID}"
    info "Detected OS: $NAME $VERSION_ID"
  else
    fail "Cannot detect OS. Supported: Debian/Ubuntu."
  fi
}

fix_mirrors(){
  # replace slower mirrors (digitalocean) with deb.debian.org or archive.ubuntu.com
  info "Ensuring fast apt mirrors (auto-fix if necessary)..."
  if grep -q "mirrors.digitalocean.com" /etc/apt/sources.list 2>/dev/null; then
    if [[ "$DISTRO_ID" == "debian" ]]; then
      sed -i 's|http://mirrors.digitalocean.com/debian|http://deb.debian.org/debian|g' /etc/apt/sources.list || true
    elif [[ "$DISTRO_ID" == "ubuntu" ]]; then
      sed -i 's|http://mirrors.digitalocean.com/ubuntu|http://archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list || true
    fi
    ok "Replaced DigitalOcean mirror entries."
  fi
  # enforce IPv4 for apt if IPv6 problems
  APT_OPTS="-o Acquire::ForceIPv4=true"
  info "Updating apt cache..."
  apt update $APT_OPTS || { warn "apt update failed; retrying without IPv4 forced..."; apt update || fail "apt update failed"; }
  ok "apt update completed"
}

apt_quiet_install(){
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "$@" >/dev/null 2>&1 || apt install -y "$@"
}

add_sury_repo(){
  info "Adding SURY PHP repository (for PHP 8.3)..."
  apt_quiet_install apt-transport-https ca-certificates lsb-release gnupg curl
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
  apt update $APT_OPTS
  ok "SURY repo added"
}

install_common(){
  info "Installing common packages: nginx, git, curl, redis, unzip, tar, ufw..."
  apt_quiet_install nginx git curl redis-server unzip tar ufw ca-certificates lsb-release gnupg build-essential
  systemctl enable --now nginx redis-server || true
  ok "Common packages installed & services started"
}

install_php(){
  info "Installing PHP 8.3 and extensions..."
  add_sury_repo
  apt_quiet_install php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-mbstring php8.3-gd \
    php8.3-mysql php8.3-redis php8.3-xml php8.3-bcmath php8.3-curl php8.3-zip php8.3-intl composer
  systemctl enable --now php8.3-fpm
  ok "PHP 8.3 ready"
}

install_mariadb_and_create(){
  info "Installing MariaDB server..."
  apt_quiet_install mariadb-server
  systemctl enable --now mariadb
  ok "MariaDB installed"
  # create DB & user
  local dbpass="${1:-}"
  if [ -z "$dbpass" ]; then dbpass=$(openssl rand -base64 16); fi
  info "Creating database 'panel' and user 'ptero' with generated password..."
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`panel\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'ptero'@'127.0.0.1' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`panel\`.* TO 'ptero'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  echo "$dbpass" > /root/.ptero_db_pass
  chmod 600 /root/.ptero_db_pass
  ok "Database and user created; password saved to /root/.ptero_db_pass"
}

download_panel(){
  local dest="${1:-/var/www/pterodactyl}"
  PANEL_DIR="$dest"
  info "Downloading Pterodactyl Panel to ${PANEL_DIR}..."
  rm -rf "${PANEL_DIR}"
  mkdir -p "${PANEL_DIR}"
  cd "${PANEL_DIR}"
  curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  ok "Panel downloaded"
}

install_composer_deps(){
  info "Installing Composer dependencies (may take several minutes)..."
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
  fi
  composer install --no-dev --optimize-autoloader --no-interaction --no-ansi
  ok "Composer dependencies installed"
}

env_and_migrate(){
  info "Preparing .env and running migrations..."
  cp .env.example .env
  php artisan key:generate --force
  sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|" .env
  sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
  sed -i "s|DB_PORT=.*|DB_PORT=3306|" .env
  sed -i "s|DB_DATABASE=.*|DB_DATABASE=panel|" .env
  sed -i "s|DB_USERNAME=.*|DB_USERNAME=ptero|" .env
  if [ -f /root/.ptero_db_pass ]; then
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$(cat /root/.ptero_db_pass)|" .env
  elif [ -n "${DB_PASS:-}" ]; then
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
  fi
  sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env || true
  sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env || true
  sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env || true
  sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env || true

  # test DB connection before running migrations
  info "Testing database connection..."
  DBPASS=$(grep '^DB_PASSWORD=' .env | cut -d'=' -f2-)
  if ! mysql -u ptero -p"${DBPASS}" -e "USE panel;" >/dev/null 2>&1; then
    warn "Unable to connect as ptero to DB — trying host=127.0.0.1 and ensuring grants..."
    # ensure privileges for ptero@127.0.0.1
    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`panel\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`panel\`.* TO 'ptero'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  fi

  php artisan migrate --seed --force
  ok "Migrations and seeders done"
}

set_permissions(){
  info "Setting file ownership & permissions..."
  chown -R www-data:www-data "${PANEL_DIR}"
  find "${PANEL_DIR}" -type d -exec chmod 755 {} \;
  find "${PANEL_DIR}" -type f -exec chmod 644 {} \;
  ok "Permissions applied"
}

create_nginx_conf(){
  info "Creating nginx configuration for ${DOMAIN}..."
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
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl reload nginx
  ok "nginx site created & reloaded"
}

install_snap_certbot(){
  info "Installing snapd & certbot (snap)..."
  apt_quiet_install snapd
  snap install core || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
  ok "certbot (snap) ready"
}

request_lets(){
  info "Requesting certificate from Let's Encrypt for ${DOMAIN}..."
  # try nginx plugin
  if certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive --redirect; then
    ok "Let's Encrypt certificate installed"
    return 0
  fi
  warn "nginx plugin failed; trying webroot..."
  if certbot certonly --webroot -w "${PANEL_DIR}/public" -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive; then
    nginx -t && systemctl reload nginx
    ok "Certificate via webroot obtained"
    return 0
  fi
  warn "Let's Encrypt failed (rate limits or other)."
  return 1
}

self_signed(){
  info "Creating self-signed certificate (fallback)..."
  mkdir -p /etc/ssl
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/panel.key -out /etc/ssl/panel.crt \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=ZaleeHost/OU=Hosting/CN=${DOMAIN}"
  sed -i "s|ssl_certificate .*|ssl_certificate /etc/ssl/panel.crt;|g" /etc/nginx/sites-available/pterodactyl.conf || true
  sed -i "s|ssl_certificate_key .*|ssl_certificate_key /etc/ssl/panel.key;|g" /etc/nginx/sites-available/pterodactyl.conf || true
  nginx -t && systemctl reload nginx
  warn "Self-signed cert installed (browser will warn)"
}

create_queue_service(){
  info "Creating systemd service: pteroq"
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
  ok "Queue worker enabled"
}

install_wings(){
  info "Installing Docker & Wings..."
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
  WINGS_BIN_URL=$(curl -s https://api.github.com/repos/pterodactyl/wings/releases/latest | grep "browser_download_url" | grep linux | head -n1 | cut -d '"' -f4)
  mkdir -p /usr/local/bin
  curl -sL -o /usr/local/bin/wings "${WINGS_BIN_URL}"
  chmod +x /usr/local/bin/wings
  mkdir -p /etc/wings /var/lib/wings
  cat >/etc/systemd/system/wings.service <<W
[Unit]
Description=Wings Daemon
After=network.target docker.service

[Service]
User=root
Group=root
Restart=always
ExecStart=/usr/local/bin/wings

[Install]
WantedBy=multi-user.target
W
  systemctl daemon-reload
  systemctl enable --now wings
  ok "Wings installed & started"
}

apply_theme(){
  local repo="${1:-}"
  if [ -z "$repo" ]; then
    repo="https://github.com/zaleeboy8-source/zaleedark-theme.git"
  fi
  info "Applying theme from: $repo"
  mkdir -p "${PANEL_DIR}/public/themes"
  if git ls-remote "$repo" &>/dev/null; then
    rm -rf /tmp/zaleedark || true
    git clone --depth 1 "$repo" /tmp/zaleedark
    cp -r /tmp/zaleedark/* "${PANEL_DIR}/public/themes/" || true
    chown -R www-data:www-data "${PANEL_DIR}/public/themes"
    rm -rf /tmp/zaleedark
    ok "Theme applied"
  else
    warn "Theme repo not accessible; skipped"
  fi
}

# ----------------- Interactive flow START -----------------
require_root
detect_os
fix_mirrors

# menu
echo
echo "Choose action:"
echo " 1) Install Panel"
echo " 2) Install Wings"
echo " 3) Apply Theme (ZaleeDark)"
echo " 4) Full Install (Panel + Wings + Theme)"
echo " 0) Exit"
read -rp "Select [0-4]: " CHOICE
CHOICE=${CHOICE:-4}

# collect inputs (manual)
DOMAIN=$(read_input "Domain for panel (must point to this server)" "panel.tesdomain2105.dpdns.org")
ADMIN_EMAIL=$(read_input "Admin email (for cert & admin user)" "zaleeboy8@gmail.com")
PANEL_DIR=$(read_input "Panel directory" "/var/www/pterodactyl")
THEME_REPO=$(read_input "Theme repo (ZaleeDark)" "https://github.com/zaleeboy8-source/zaleedark-theme.git")

# DB choices
if confirm "Install MariaDB locally and create DB user 'ptero'?" 1; then
  DB_WANT="yes"
  if confirm "Auto-generate DB password?" 1; then
    DB_PASS="$(openssl rand -base64 16)"
  else
    DB_PASS=$(read_input "Enter DB password" "")
  fi
else
  DB_WANT="no"
  DB_PASS=""
fi

# admin creation
if confirm "Create admin user automatically after install?" 1; then
  CREATE_ADMIN=1
  ADMIN_USER=$(read_input "Admin username" "ZaleeHost")
  ADMIN_PASS=$(read_input "Admin password" "zalee1")
else
  CREATE_ADMIN=0
  ADMIN_USER=""; ADMIN_PASS=""
fi

# ssl
if confirm "Use Let's Encrypt for SSL (recommended)?" 1; then
  SSL_METHOD="letsencrypt"
else
  SSL_METHOD="selfsigned"
fi

# summary and confirm
echo
info "Summary:"
echo " Action       : $(case $CHOICE in 1) echo Panel ;; 2) echo Wings ;; 3) echo Theme ;; 4) echo Full ;; *) echo Exit ;; esac)"
echo " Domain       : $DOMAIN"
echo " Admin Email  : $ADMIN_EMAIL"
echo " Panel Dir    : $PANEL_DIR"
echo " Theme Repo   : $THEME_REPO"
echo " Install DB   : $DB_WANT"
if [ "$DB_WANT" = "yes" ]; then
  echo " DB password  : ${DB_PASS:0:8}...(hidden)"
fi
echo " SSL Method   : $SSL_METHOD"
if ! confirm "Continue?" 1; then
  fail "Aborted by user."
fi

# Execution based on choice
if [[ "$CHOICE" =~ ^(1|4)$ ]]; then
  install_common
  install_php
  if [ "$DB_WANT" = "yes" ]; then
    install_mariadb_and_create "$DB_PASS"
  fi
  download_panel "$PANEL_DIR"
  cd "$PANEL_DIR"
  install_composer_deps
  env_and_migrate
  set_permissions
  create_nginx_conf
  create_queue_service

  if [ "$SSL_METHOD" = "letsencrypt" ]; then
    install_snap_certbot
    if ! request_lets; then
      self_signed
    fi
  else
    self_signed
  fi

  if confirm "Apply ZaleeDark theme now?" 1; then
    apply_theme "$THEME_REPO"
  fi
  ok "Panel installation finished"
fi

if [[ "$CHOICE" =~ ^(2|4)$ ]]; then
  install_common
  install_wings
fi

if [[ "$CHOICE" = "3" ]]; then
  if [ ! -d "$PANEL_DIR" ]; then
    warn "Panel directory $PANEL_DIR not found — theme files will be stored under it but may not apply."
    mkdir -p "$PANEL_DIR/public/themes"
  fi
  apply_theme "$THEME_REPO"
fi

# firewall
info "Configuring UFW (22,80,443)..."
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw --force enable || true
ok "Firewall rules set"

# final summary
echo
printf "${BOLD}${GREEN}========================================${RESET}\n"
printf "  Panel URL  : https://%s\n" "$DOMAIN"
if [ -f /root/.ptero_db_pass ]; then
  printf "  DB user    : ptero\n"
  printf "  DB pass    : %s\n" "$(cat /root/.ptero_db_pass)"
fi
if [ "$CREATE_ADMIN" -eq 1 ] && [[ "$CHOICE" =~ ^(1|4)$ ]]; then
  printf "  Admin      : %s / %s\n" "$ADMIN_USER" "$ADMIN_PASS"
else
  printf "  Admin      : run: php %s/artisan p:user:make\n" "$PANEL_DIR"
fi
printf "  Panel dir  : %s\n" "$PANEL_DIR"
printf "  Log file   : %s\n" "$LOGFILE"
printf "${BOLD}${GREEN}========================================${RESET}\n"

ok "Script finished. If nginx fails due to SSL path, check /etc/letsencrypt or run certbot manually."

# End
