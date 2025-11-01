#!/usr/bin/env bash
# ============================================================
# pterodactyl.sh — ZaleeHost Interactive Pterodactyl Installer
# Supports: Debian 12 (Bookworm) and Ubuntu 22.04/24.04
# Features: Panel, Wings, Theme (ZaleeDark), Let's Encrypt SSL, Self-signed fallback
# Author: ZaleeHost (prepared for zaleeboy)
# Log: /root/ptero_install.log
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
LOGFILE="/root/ptero_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ----------------- Colors & helpers -----------------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BLUE="\e[34m"
BOLD="\e[1m"; RESET="\e[0m"

info(){ printf "${BOLD}${CYAN}==>${RESET} %s\n" "$1"; }
ok(){ printf "${GREEN}✔ %s${RESET}\n" "$1"; }
warn(){ printf "${YELLOW}⚠ %s${RESET}\n" "$1"; }
fail(){ printf "${RED}✘ %s${RESET}\n" "$1"; exit 1; }

require_root(){
  if [ "$EUID" -ne 0 ]; then
    fail "Please run this script with sudo or as root."
  fi
}

spinner() {
  # spinner <pid>
  local pid=$1; local delay=0.08; local spinstr='|/-\'
  while ps -p "$pid" >/dev/null 2>&1; do
    for i in 0 1 2 3; do
      printf "\r ${BLUE}[%c]${RESET}" "${spinstr:i:1}"
      sleep $delay
    done
  done
  printf "\r"
}

confirm(){
  # confirm "Question" default_yes(1/0)
  local prompt="$1"
  local default_yes="${2:-1}"
  local ans
  if [ "$default_yes" -eq 1 ]; then
    read -rp "$prompt [Y/n]: " ans; ans=${ans:-Y}
  else
    read -rp "$prompt [y/N]: " ans; ans=${ans:-N}
  fi
  case "${ans,,}" in
    y|yes) return 0;;
    *) return 1;;
  esac
}

read_input(){
  # read_input "Prompt" "default"
  local prompt="$1"; local def="${2:-}"
  if [ -n "$def" ]; then
    read -rp "$prompt [$def]: " val
    val=${val:-$def}
  else
    read -rp "$prompt: " val
  fi
  echo "$val"
}

detect_distro(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID,,}"
    DISTRO_NAME="${NAME}"
    DISTRO_VER="${VERSION_ID}"
  else
    fail "Unsupported OS — cannot detect distribution."
  fi
}

banner(){
cat <<'EOF'
██████╗ ███████╗████████╗ █████╗ ██████╗  ██████╗  ██████╗██╗  ██╗
██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝
██████╔╝█████╗     ██║   ███████║██████╔╝██║   ██║██║     █████╔╝ 
██╔═══╝ ██╔══╝     ██║   ██╔══██║██╔═══╝ ██║   ██║██║     ██╔═██╗ 
██║     ███████╗   ██║   ██║  ██║██║     ╚██████╔╝╚██████╗██║  ██╗
╚═╝     ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝      ╚═════╝  ╚═════╝╚═╝  ╚═╝
      ZaleeHost — Pterodactyl Interactive Installer (Fancy)
EOF
}

# ----------------- Defaults (can be overridden interactively) -----------------
THEME_REPO_DEFAULT="https://github.com/zaleeboy8-source/zaleedark-theme.git"
PANEL_DIR_DEFAULT="/var/www/pterodactyl"

# ----------------- Pre-checks -----------------
require_root
detect_distro
banner
printf "%s %s %s\n\n" "Detected OS:" "$DISTRO_NAME" "$DISTRO_VER"

# ----------------- Interactive menu -----------------
echo "Choose action (enter the number):"
echo "  1) Install Panel (frontend)"
echo "  2) Install Wings (node)"
echo "  3) Apply Theme (ZaleeDark)"
echo "  4) Full Install (Panel + Wings + Theme)"
echo "  0) Exit"
read -rp "Select [1-4,0]: " CHOICE
CHOICE=${CHOICE:-4}

# Collect manual inputs
DOMAIN=$(read_input "Enter panel domain (must point to this server)" "$PANEL_DIR_DEFAULT" | sed 's|/$||')
# The above line had bug earlier: ensure DOMAIN default corrected:
if [ "$DOMAIN" = "$PANEL_DIR_DEFAULT" ]; then
  DOMAIN=$(read_input "Enter panel domain (must point to this server)" "panel.tesdomain2105.dpdns.org")
fi

ADMIN_EMAIL=$(read_input "Enter admin email (used for Let's Encrypt & admin user)" "zaleeboy8@gmail.com")
PANEL_DIR=$(read_input "Panel directory" "$PANEL_DIR_DEFAULT")
THEME_REPO=$(read_input "Theme repository URL" "$THEME_REPO_DEFAULT")

if confirm "Install local MariaDB server and create database/user?" 1; then
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

if confirm "Create admin user automatically after install?" 1; then
  CREATE_ADMIN=1
  ADMIN_USER=$(read_input "Admin username" "ZaleeHost")
  ADMIN_PASS=$(read_input "Admin password" "zalee1")
else
  CREATE_ADMIN=0
  ADMIN_USER=""
  ADMIN_PASS=""
fi

if confirm "Use Let's Encrypt for SSL (recommended)? " 1; then
  SSL_METHOD="letsencrypt"
else
  SSL_METHOD="selfsigned"
fi

echo
info "Summary — please confirm:"
echo "  Action: $(case $CHOICE in 1) echo Panel ;; 2) echo Wings ;; 3) echo Theme ;; 4) echo Full ;; *) echo Exit ;; esac)"
echo "  Domain: $DOMAIN"
echo "  Admin: $ADMIN_EMAIL"
echo "  Panel dir: $PANEL_DIR"
echo "  Theme repo: $THEME_REPO"
echo "  MariaDB install: $DB_WANT"
echo "  SSL method: $SSL_METHOD"
if [ "$DB_WANT" = "yes" ]; then
  echo "  DB password: ${DB_PASS:0:8}...(hidden)"
fi
if ! confirm "Continue with these settings?" 1; then
  fail "Aborted by user."
fi

# ----------------- Core helper functions -----------------
apt_quiet_install(){
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "$@" >/dev/null 2>&1
}

add_sury_php_repo(){
  info "Adding Sury PHP repo for PHP 8.3 (if needed)..."
  apt_quiet_install apt-transport-https ca-certificates lsb-release gnupg curl
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
  apt update -y >/dev/null 2>&1
  ok "Sury repo added"
}

install_common_packages(){
  info "Updating system and installing common packages..."
  apt update -y
  apt upgrade -y
  apt_quiet_install nginx redis-server unzip git curl tar ufw ca-certificates lsb-release gnupg build-essential
  ok "Common packages installed"
  systemctl enable --now nginx redis-server || true
}

install_php(){
  info "Installing PHP 8.3 and extensions..."
  add_sury_php_repo
  apt_quiet_install php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-mbstring php8.3-gd \
    php8.3-mysql php8.3-redis php8.3-xml php8.3-bcmath php8.3-curl php8.3-zip php8.3-intl composer
  systemctl enable --now php8.3-fpm
  ok "PHP 8.3 installed"
}

install_mariadb(){
  info "Installing MariaDB..."
  apt_quiet_install mariadb-server
  systemctl enable --now mariadb
  ok "MariaDB installed"
  info "Creating panel database and user..."
  DB_PASS_LOCAL="${DB_PASS:-$(openssl rand -base64 16)}"
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`panel\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'ptero'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_LOCAL}';
GRANT ALL PRIVILEGES ON \`panel\`.* TO 'ptero'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  echo "$DB_PASS_LOCAL" > /root/.ptero_db_pass
  chmod 600 /root/.ptero_db_pass
  ok "Database 'panel' and user 'ptero' created (password saved to /root/.ptero_db_pass)"
}

download_panel(){
  info "Downloading Pterodactyl Panel (latest)..."
  rm -rf "${PANEL_DIR}"
  mkdir -p "${PANEL_DIR}"
  cd "${PANEL_DIR}"
  curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  ok "Panel downloaded to ${PANEL_DIR}"
}

composer_install(){
  info "Installing Composer dependencies (may take many minutes)..."
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
  fi
  composer install --no-dev --optimize-autoloader --no-interaction --no-ansi
  ok "Composer dependencies installed"
}

env_setup_and_migrate(){
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
  else
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
  fi
  sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env || true
  sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env || true
  sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env || true
  sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env || true

  php artisan migrate --seed --force
  ok "Migrations and seeders completed"
}

set_permissions(){
  info "Setting ownership & permissions"
  chown -R www-data:www-data "${PANEL_DIR}"
  find "${PANEL_DIR}" -type d -exec chmod 755 {} \;
  find "${PANEL_DIR}" -type f -exec chmod 644 {} \;
  ok "Permissions set"
}

nginx_config(){
  info "Creating nginx site for ${DOMAIN}"
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
  ok "Nginx site enabled"
}

install_snap_certbot(){
  info "Installing snapd and certbot (snap)"
  apt_quiet_install snapd
  snap install core || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
  ok "Certbot (snap) ready"
}

get_lets_encrypt(){
  info "Requesting Let's Encrypt certificate for ${DOMAIN} (non-interactive)"
  # try nginx plugin first (will edit nginx conf)
  if certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive --redirect; then
    ok "Let's Encrypt cert installed (nginx plugin)"
    return 0
  fi
  warn "Certbot nginx plugin failed; trying webroot method..."
  if certbot certonly --webroot -w "${PANEL_DIR}/public" -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive; then
    nginx -t && systemctl reload nginx
    ok "Let's Encrypt cert obtained via webroot"
    return 0
  fi
  warn "Let's Encrypt request failed (rate-limit or other)."
  return 1
}

self_signed_cert(){
  info "Creating self-signed cert as fallback (valid 1 year)"
  mkdir -p /etc/ssl
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/panel.key -out /etc/ssl/panel.crt \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=ZaleeHost/OU=Hosting/CN=${DOMAIN}"
  sed -i "s|ssl_certificate .*|ssl_certificate /etc/ssl/panel.crt;|g" /etc/nginx/sites-available/pterodactyl.conf || true
  sed -i "s|ssl_certificate_key .*|ssl_certificate_key /etc/ssl/panel.key;|g" /etc/nginx/sites-available/pterodactyl.conf || true
  nginx -t && systemctl reload nginx
  warn "Self-signed certificate created (browser will show warning)"
}

create_queue_worker(){
  info "Creating pteroq systemd service"
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
  info "Installing Docker and Wings (node)"
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
  ok "Wings installed and running"
}

apply_theme_zaleedark(){
  info "Applying ZaleeDark theme from ${THEME_REPO}"
  mkdir -p "${PANEL_DIR}/public/themes"
  if git ls-remote "${THEME_REPO}" &>/dev/null; then
    rm -rf /tmp/zaleedark || true
    git clone --depth 1 "${THEME_REPO}" /tmp/zaleedark
    cp -r /tmp/zaleedark/* "${PANEL_DIR}/public/themes/" || true
    chown -R www-data:www-data "${PANEL_DIR}/public/themes"
    rm -rf /tmp/zaleedark
    ok "ZaleeDark theme applied"
  else
    warn "Theme repo not accessible; skipping theme application"
  fi
}

# ----------------- Execution flows -----------------
# Panel
if [[ "$CHOICE" =~ ^(1|4)$ ]]; then
  install_common_packages
  install_php
  if [ "$DB_WANT" = "yes" ]; then
    install_mariadb
  fi
  download_panel
  composer_install
  env_setup_and_migrate
  set_permissions
  nginx_config
  create_queue_worker

  if [[ "${SSL_METHOD}" == "letsencrypt" ]]; then
    install_snap_certbot
    if ! get_lets_encrypt; then
      self_signed_cert
    fi
  else
    self_signed_cert
  fi

  if [ "$CHOICE" = "4" ] || confirm "Apply ZaleeDark theme now?" 1; then
    apply_theme_zaleedark
  fi

  if [ "$CREATE_ADMIN" -eq 1 ]; then
    info "Attempting to create admin user via artisan (best-effort)"
    if php "${PANEL_DIR}/artisan" p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --name-first="Zalee" --name-last="Host" --password="${ADMIN_PASS}" --admin=1 --no-interaction >/dev/null 2>&1; then
      ok "Admin created: ${ADMIN_EMAIL} / ${ADMIN_PASS}"
    else
      warn "Automatic admin creation not supported on this panel version — create manually:"
      echo "  php ${PANEL_DIR}/artisan p:user:make"
    fi
  fi
fi

# Wings
if [[ "$CHOICE" =~ ^(2|4)$ ]]; then
  install_common_packages
  install_wings
fi

# Theme only (and panel not installed)
if [[ "$CHOICE" = "3" ]] && [ ! -d "${PANEL_DIR}" ]; then
  warn "Panel directory ${PANEL_DIR} does not exist. Theme will be saved but may not apply until panel is installed."
  mkdir -p "${PANEL_DIR}/public/themes"
fi
if [[ "$CHOICE" = "3" ]]; then
  apply_theme_zaleedark
fi

# UFW
info "Applying firewall rules (22/80/443)"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true
ok "Firewall ready"

# Final Summary
echo
printf "${BOLD}${GREEN}========================================${RESET}\n"
printf "${BOLD}${GREEN}  Installation completed (check messages above)${RESET}\n"
printf "  Panel URL  : https://%s\n" "$DOMAIN"
if [ -f /root/.ptero_db_pass ]; then
  printf "  DB user    : ptero\n"
  printf "  DB pass    : %s\n" "$(cat /root/.ptero_db_pass)"
fi
if [ "$CREATE_ADMIN" -eq 1 ]; then
  printf "  Admin      : %s / %s\n" "$ADMIN_EMAIL" "$ADMIN_PASS"
else
  printf "  Admin      : run: php %s/artisan p:user:make\n" "$PANEL_DIR"
fi
printf "  Panel dir  : %s\n" "$PANEL_DIR"
printf "  Log file   : %s\n" "$LOGFILE"
printf "${BOLD}${GREEN}========================================${RESET}\n"

ok "If you want, push this file to GitHub as 'pterodactyl.sh' in your repo and run it on the VPS."

# End of script
