#!/bin/bash
# Pterodactyl Panel Full Auto Installer (Debian 12, PHP 8.3)
# - Panel URL: https://panel.zaleehost.qzz.io
# - Admin: ZaleeHost / zaleeboy8@gmail.com / zalee1
# - DB user: ptero / zalee1
# Run as root on a fresh Debian 12 system

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PANEL_DOMAIN="panel.zaleehost.qzz.io"
ADMIN_EMAIL="zaleeboy8@gmail.com"
ADMIN_USER="ZaleeHost"
ADMIN_PASS="zalee1"
DB_NAME="panel"
DB_USER="ptero"
DB_PASS="zalee1"
TIMEZONE="Asia/Jakarta"

echo "=== Starting Pterodactyl Panel auto-install ==="

echo "1) Update system"
apt update -y
apt upgrade -y

echo "2) Install basic deps"
apt install -y curl wget ca-certificates apt-transport-https lsb-release gnupg2 software-properties-common unzip git

echo "3) Set timezone"
timedatectl set-timezone ${TIMEZONE} || true

echo "4) Add SURY PHP repo (for PHP 8.3)"
# ensure gnupg installed
apt install -y gnupg
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list

apt update -y

echo "5) Install PHP 8.3, extensions and services"
apt install -y php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-mbstring php8.3-gd php8.3-xml php8.3-curl php8.3-zip php8.3-bcmath php8.3-mysql php8.3-pgsql php8.3-intl php8.3-sqlite3 php8.3-readline php8.3-dev \
  nginx mariadb-server redis-server certbot python3-certbot-nginx composer

# Ensure services enabled
systemctl enable --now php8.3-fpm nginx redis-server mariadb

echo "6) Secure/prepare MariaDB: create database and user"
# If mysql root requires password, user will need to adjust; assume fresh install with unix_socket auth
mysql <<MYSQL_SCRIPT || { echo "MySQL command failed"; exit 1; }
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "7) Download Pterodactyl Panel"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
# Remove any previous files if exist
rm -rf /var/www/pterodactyl/*
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
rm -f panel.tar.gz

chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

echo "8) Composer install"
# ensure composer exists
if ! command -v composer >/dev/null 2>&1; then
  curl -sS https://getcomposer.org/installer | php
  mv composer.phar /usr/local/bin/composer
fi

cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction

echo "9) Prepare environment file and keys"
cp .env.example .env

# write .env values to avoid interactive p:environment:setup prompts
php artisan key:generate --force

# Update .env with required values (use 127.0.0.1 as DB host)
sed -i "s|APP_URL=.*|APP_URL=https://${PANEL_DOMAIN}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|DB_PORT=.*|DB_PORT=3306|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

# Use redis for cache/session/queue (common config for Pterodactyl)
# The exact keys may vary by version; set widely-used env vars
sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env || true
sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env || true
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env || true

# Set mail defaults to avoid interactive issues (user may change after)
sed -i "s|MAIL_MAILER=.*|MAIL_MAILER=smtp|" .env || true
sed -i "s|MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${ADMIN_EMAIL}|" .env || true
sed -i "s|MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"${ADMIN_USER}\"|" .env || true

echo "10) Run migrations & seed (this may take a while)"
php artisan migrate --seed --force

echo "11) Create admin user (non-interactive)"
# Some p:user:make implementations accept flags; try flags, fallback to interactive if fails
if php artisan p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --name-first="Zalee" --name-last="Host" --password="${ADMIN_PASS}" --admin=1 --no-interaction >/dev/null 2>&1; then
  echo "Admin user created via flags."
else
  # fallback: create via tinker script if flags unavailable
  php -r "
require '/var/www/pterodactyl/vendor/autoload.php';
\$app = require '/var/www/pterodactyl/bootstrap/app.php';
\$kernel = \$app->make(Illuminate\Contracts\Console\Kernel::class);
\$kernel->call('p:user:make', [
  '--email' => '${ADMIN_EMAIL}',
  '--username' => '${ADMIN_USER}',
  '--name-first' => 'Zalee',
  '--name-last' => 'Host',
  '--password' => '${ADMIN_PASS}',
  '--admin' => 1
]);
"
fi || true

echo "12) Permissions"
chown -R www-data:www-data /var/www/pterodactyl
find /var/www/pterodactyl -type f -exec chmod 644 {} \;
find /var/www/pterodactyl -type d -exec chmod 755 {} \;

echo "13) Configure Nginx site"
cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGINX_CONF'
server {
    listen 80;
    server_name PANEL_DOMAIN_PLACEHOLDER;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log /var/log/nginx/pterodactyl.error.log;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX_CONF

# replace placeholder with actual domain
sed -i "s|PANEL_DOMAIN_PLACEHOLDER|${PANEL_DOMAIN}|g" /etc/nginx/sites-available/pterodactyl.conf

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t
systemctl reload nginx

echo "14) Obtain SSL certificate (Let's Encrypt) - non-interactive"
# certbot will fail if DNS not pointing; ignore errors but attempt
certbot --nginx -d "${PANEL_DOMAIN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" || echo "Certbot failed (ensure DNS A record points to this server)."

echo "15) Finalize: queue worker and schedule (systemd recommended by Pterodactyl docs)"
# create systemd service for schedule/worker if needed - minimal instruction only
# Pterodactyl recommends running queue worker with supervisord or systemd; user can configure later.

echo "=== Installation finished ==="
echo "Visit: https://${PANEL_DOMAIN}"
echo "Login: ${ADMIN_EMAIL} / ${ADMIN_PASS}"
echo "If the panel login doesn't work immediately, check /var/www/pterodactyl/storage/logs/laravel-*.log and nginx logs."

exit 0
