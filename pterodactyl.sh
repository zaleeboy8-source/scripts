#!/usr/bin/env bash
# pterodactyl.sh — Interactive installer (Panel, Wings, Theme, SSL)
# Target: Debian 12+ (Bookworm). Tested concepts: Nginx, PHP 8.3 (SURY), MariaDB, Redis, Certbot (snap)
# Author: ZaleeHost (prepared for zaleeboy)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
LOGFILE="/root/ptero_install.log"

# ---------- Colors ----------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; BLUE="\e[34m"; MAGENTA="\e[35m"
BOLD="\e[1m"; RESET="\e[0m"

info(){ echo -e "${BOLD}${BLUE}==>${RESET} $1"; }
ok(){ echo -e "${GREEN}✔ $1${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ $1${RESET}"; }
err(){ echo -e "${RED}✘ $1${RESET}"; exit 1; }

# ---------- Helpers ----------
spinner_start(){
  # start spinner for background PID: spinner_start <pid>
  pid="$1"
  (
    spin='/-\|'
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r [%c] " "${spin:i%4:1}"
      sleep 0.08
      ((i++))
    done
    printf "\r"
  ) &
  SPINNER_PID=$!
}
spinner_stop(){
  # stop spinner
  kill "$SPINNER_PID" 2>/dev/null || true
  wait "$SPINNER_PID" 2>/dev/null || true
  printf "\r"
}

check_root(){
  if [ "$EUID" -ne 0 ]; then
    err "Please run this script as root (sudo)."
  fi
}

confirm_prompt(){
  # confirm_prompt "Question" default_yes_flag
  local prompt="$1"; local default_yes="${2:-1}"
  local ans
  if [ "$default_yes" -eq 1 ]; then
    read -rp "$prompt [Y/n]: " ans
    ans=${ans:-Y}
  else
    read -rp "$prompt [y/N]: " ans
    ans=${ans:-N}
  fi
  case "${ans,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

read_input(){
  # read_input "prompt" "default"
  local prompt="$1"
  local default="${2:-}"
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " val
    val=${val:-$default}
  else
    read -rp "$prompt: " val
  fi
  echo "$val"
}

# ---------- Banner ----------
clear
cat <<'EOF'
██████╗ ███████╗████████╗ █████╗ ██████╗  ██████╗  ██████╗██╗  ██╗
██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝
██████╔╝█████╗     ██║   ███████║██████╔╝██║   ██║██║     █████╔╝ 
██╔═══╝ ██╔══╝     ██║   ██╔══██║██╔═══╝ ██║   ██║██║     ██╔═██╗ 
██║     ███████╗   ██║   ██║  ██║██║     ╚██████╔╝╚██████╗██║  ██╗
╚═╝     ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝      ╚═════╝  ╚═════╝╚═╝  ╚═╝
      ZaleeHost — Pterodactyl Interactive Installer
EOF
echo
echo "Log will be saved to: $LOGFILE"
echo

check_root

# ---------- Interactive choices ----------
echo "Choose what to install (you can run multiple times):"
echo "  1) Install Panel (frontend)"
echo "  2) Install Wings (node)"
echo "  3) Apply Theme (ZaleeDark)"
echo "  4) Full Install (Panel + Wings + Theme)"
echo "  0) Exit"
read -rp "Select option [1-4,0]: " CHOICE
CHOICE=${CHOICE:-4}

# Collect common info (allow manual edits)
DEFAULT_DOMAIN="panel.tesdomain2105.dpdns.org"
DOMAIN=$(read_input "Enter domain for panel (must point to this server)" "$DEFAULT_DOMAIN")
ADMIN_EMAIL=$(read_input "Enter admin email (for Let's Encrypt & admin user)" "zaleeboy8@gmail.com")
PANEL_DIR_DEFAULT="/var/www/pterodactyl"
PANEL_DIR=$(read_input "Panel directory" "$PANEL_DIR_DEFAULT")

# SSL choice
if confirm_prompt "Use Let's Encrypt (recommended) for SSL?" 1; then
  SSL_CHOICE="letsencrypt"
else
  SSL_CHOICE="manual"
fi

# MariaDB choice
if confirm_prompt "Install local MariaDB on this server?" 1; then
  DB_INSTALL="yes"
  # ask manual DB credentials or auto
  if confirm_prompt "Create DB user/password automatically?" 1; then
    DB_AUTOGEN=1
    DB_PASS="$(openssl rand -base64 16)"
  else
    DB_AUTOGEN=0
    DB_PASS=$(read_input "Enter desired DB password" "")
  fi
else
  DB_INSTALL="no"
  DB_AUTOGEN=0
  DB_PASS=""
fi

# Admin account options
if confirm_prompt "Create admin user automatically? (email & password will be shown in summary)" 1; then
  CREATE_ADMIN=1
  ADMIN_USER=$(read_input "Admin username" "ZaleeHost")
  ADMIN_PASS=$(read_input "Admin password" "zalee1")
else
  CREATE_ADMIN=0
  ADMIN_USER=""
  ADMIN_PASS=""
fi

# Theme repo (allow change)
THEME_REPO_DEFAULT="https://github.com/zaleeboy8-source/zaleedark-theme.git"
THEME_REPO=$(read_input "Theme repo URL (ZaleeDark default)" "$THEME_REPO_DEFAULT")

echo
echo "Summary of choices:"
echo "  Install option : $CHOICE"
echo "  Domain         : $DOMAIN"
echo "  Admin email    : $ADMIN_EMAIL"
echo "  SSL method     : $SSL_CHOICE"
echo "  MariaDB install: $DB_INSTALL"
[ "$DB_INSTALL" = "yes" ] && echo "  DB password    : ${DB_PASS:0:8}...(hidden)"
echo "  Panel dir      : $PANEL_DIR"
echo "  Theme repo     : $THEME_REPO"
echo
if ! confirm_prompt "Continue with these settings?" 1; then
  err "Aborting by user"
fi

# Start logging
exec > >(tee -a "$LOGFILE") 2>&1

# ---------- Functions for tasks ----------
install_basic_packages(){
  info "Updating system and installing basic packages..."
  apt update -y
  apt upgrade -y
  apt install -y nginx redis-server unzip git curl tar ufw ca-certificates lsb-release gnupg build-essential
  ok "Basic packages installed"
}

add_sury_php(){
  info "Adding SURY repo (PHP 8.3)..."
  apt install -y apt-transport-https lsb-release ca-certificates curl gnupg
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
  apt update -y
  ok "SURY repo ready"
  info "Installing PHP 8.3 and extensions..."
  apt install -y php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-mbstring php8.3-gd \
    php8.3-mysql php8.3-redis php8.3-xml php8.3-bcmath php8.3-curl php8.3-zip php8.3-intl composer
  systemctl enable --now php8.3-fpm
  ok "PHP 8.3 installed"
}

install_mariadb(){
  info "Installing MariaDB server..."
  apt install -y mariadb-server
  systemctl enable --now mariadb
  # create DB and user
  if [ -z "$DB_PASS" ]; then
    DB_PASS="$(openssl rand -base64 16)"
  fi
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`panel\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'ptero'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`panel\`.* TO 'ptero'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  echo "$DB_PASS" > /root/.ptero_db_pass
  chmod 600 /root/.ptero_db_pass
  ok "MariaDB installed and DB/user created (user: ptero)"
}

download_panel(){
  info "Downloading Pterodactyl Panel (latest release)..."
  rm -rf "$PANEL_DIR"
  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  ok "Panel files placed at $PANEL_DIR"
}

install_composer_deps(){
  info "Installing Composer dependencies (may take time)..."
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
  fi
  composer install --no-dev --optimize-autoloader --no-interaction --no-ansi
  ok "Composer packages installed"
}

prepare_env_and_migrate(){
  info "Preparing .env and Laravel key"
  cp .env.example .env
  php artisan key:generate --force
  # write DB + URL + Redis settings
  sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|" .env
  sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
  sed -i "s|DB_PORT=.*|DB_PORT=3306|" .env
  sed -i "s|DB_DATABASE=.*|DB_DATABASE=panel|" .env
  sed -i "s|DB_USERNAME=.*|DB_USERNAME=ptero|" .env
  DB_PASS_FILE="/root/.ptero_db_pass"
  if [ -f "$DB_PASS_FILE" ]; then
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$(cat $DB_PASS_FILE)|" .env
  else
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
  fi
  sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env || true
  sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env || true
  sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env || true
  sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env || true

  info "Running migrations & seeders (may take a few minutes)..."
  php artisan migrate --seed --force
  ok "Migrations & seeders completed"
}

set_permissions(){
  info "Setting permissions for panel files..."
  chown -R www-data:www-data "$PANEL_DIR"
  find "$PANEL_DIR" -type d -exec chmod 755 {} \;
  find "$PANEL_DIR" -type f -exec chmod 644 {} \;
  ok "Permissions set"
}

nginx_site_create(){
  info "Creating Nginx site for ${DOMAIN}..."
  cat > /etc/nginx/sites-available/pterodactyl.conf <<NG
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
  ok "Nginx site created and reloaded"
}

install_certbot_snap(){
  info "Installing snapd & certbot (snap)"
  apt install -y snapd
  snap install core || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
  ok "Certbot installed via snap"
}

request_letsencrypt(){
  info "Requesting certificate from Let's Encrypt (using certbot)"
  if certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive --redirect; then
    ok "Let's Encrypt certificate obtained & nginx configured!"
    return 0
  else
    warn "Certbot nginx plugin failed — trying webroot method"
    if certbot certonly --webroot -w "${PANEL_DIR}/public" -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive; then
      nginx -t && systemctl reload nginx
      ok "Certificate obtained via webroot and nginx reloaded"
      return 0
    else
      warn "Let's Encrypt failed (rate limit or other). Will fallback to self-signed certificate"
      return 1
    fi
  fi
}

install_self_signed(){
  info "Creating self-signed certificate (fallback)"
  mkdir -p /etc/ssl
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/panel.key -out /etc/ssl/panel.crt \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=ZaleeHost/OU=Hosting/CN=${DOMAIN}"
  sed -i "s|ssl_certificate .*|ssl_certificate /etc/ssl/panel.crt;|g" /etc/nginx/sites-available/pterodactyl.conf || true
  sed -i "s|ssl_certificate_key .*|ssl_certificate_key /etc/ssl/panel.key;|g" /etc/nginx/sites-available/pterodactyl.conf || true
  nginx -t && systemctl reload nginx
  warn "Self-signed certificate in use (browser will show a warning)"
}

create_queue_service(){
  info "Creating systemd unit for queue worker (pteroq.service)"
  cat > /etc/systemd/system/pteroq.service <<SVC
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
  ok "Queue worker service enabled"
}

install_wings(){
  info "Installing Docker & Wings (node)"
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
  ok "Wings installed and running (service: wings)"
}

apply_theme_zaleedark(){
  info "Applying ZaleeDark theme from: ${THEME_REPO}"
  mkdir -p "${PANEL_DIR}/public/themes"
  if git ls-remote "${THEME_REPO}" &>/dev/null; then
    rm -rf /tmp/zaleedark || true
    git clone --depth 1 "${THEME_REPO}" /tmp/zaleedark
    cp -r /tmp/zaleedark/* "${PANEL_DIR}/public/themes/" || true
    chown -R www-data:www-data "${PANEL_DIR}/public/themes"
    rm -rf /tmp/zaleedark
    ok "ZaleeDark theme applied to panel"
  else
    warn "Could not access theme repo; please check THEME_REPO URL"
  fi
}

# ---------- Execution sequences based on CHOICE ----------
# We will perform tasks step-by-step with checks
if [ "$CHOICE" = "0" ]; then
  echo "Exit selected. Bye."
  exit 0
fi

# always install basics first when doing panel/wings/full or theme apply needs files
if [[ "$CHOICE" =~ ^(1|3|4)$ ]]; then
  install_basic_packages
  add_sury_php
fi

# Install DB if requested and Panel related selected
if [[ "$CHOICE" =~ ^(1|4)$ ]] && [ "$DB_INSTALL" = "yes" ]; then
  install_mariadb
fi

# PANEL installation
if [[ "$CHOICE" =~ ^(1|4)$ ]]; then
  download_panel
  install_composer_deps
  prepare_env_and_migrate
  set_permissions
  nginx_site_create
  create_queue_service
  # SSL handling
  if [ "$SSL_CHOICE" = "letsencrypt" ]; then
    install_certbot_snap
    if ! request_letsencrypt; then
      install_self_signed
    fi
  else
    install_self_signed
  fi
  # apply theme if chosen in full/install flow or via option 3 later
  if [ "$CHOICE" = "4" ] || confirm_prompt "Apply ZaleeDark theme now?" 1; then
    apply_theme_zaleedark
  fi
  ok "Panel installation finished"
fi

# WINGS installation
if [[ "$CHOICE" =~ ^(2|4)$ ]]; then
  install_wings
fi

# If user selected only theme (3) and not panel, still attempt to fetch theme into panel dir
if [ "$CHOICE" = "3" ] && [ ! -d "$PANEL_DIR" ]; then
  warn "Panel directory $PANEL_DIR not present — theme will be downloaded but may not apply until panel is installed."
  mkdir -p "$PANEL_DIR/public/themes"
fi
if [ "$CHOICE" = "3" ]; then
  apply_theme_zaleedark
fi

# Final admin creation (if requested)
if [ "$CREATE_ADMIN" -eq 1 ] && [[ "$CHOICE" =~ ^(1|4)$ ]]; then
  info "Attempting to create admin user via artisan (best-effort)"
  if php "${PANEL_DIR}/artisan" p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --name-first="Zalee" --name-last="Host" --password="${ADMIN_PASS}" --admin=1 --no-interaction >/dev/null 2>&1; then
    ok "Admin created: ${ADMIN_EMAIL} / ${ADMIN_PASS}"
  else
    warn "Automatic admin creation not supported by this panel build — create manually with:"
    echo "php ${PANEL_DIR}/artisan p:user:make"
  fi
fi

# UFW
info "Applying UFW rules (22,80,443)"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true
ok "Firewall configured"

# Summary
echo
echo -e "${BOLD}${GREEN}========================================${RESET}"
echo -e "${BOLD}${GREEN}  Installation finished (check above for ✔ messages)${RESET}"
echo -e "  Panel URL  : https://${DOMAIN}"
if [ -f /root/.ptero_db_pass ]; then
  echo -e "  DB user    : ptero"
  echo -e "  DB pass    : $(cat /root/.ptero_db_pass)"
fi
if [ "$CREATE_ADMIN" -eq 1 ]; then
  echo -e "  Admin user : ${ADMIN_EMAIL} / ${ADMIN_PASS}"
else
  echo -e "  Admin user : please create manually: php ${PANEL_DIR}/artisan p:user:make"
fi
echo -e "  Panel dir  : ${PANEL_DIR}"
echo -e "  Logs       : $LOGFILE"
echo -e "${BOLD}${GREEN}========================================${RESET}"
