#!/bin/bash
# ==========================================
# 🐉 ZaleeHost - Pterodactyl Panel Installer
# OS: Debian 12 + PHP 8.3
# Author: zaleeboy8@gmail.com
# ==========================================

set -e

echo "🔧 Updating system..."
apt update -y && apt upgrade -y

echo "⚙️ Installing dependencies..."
apt install -y curl wget git unzip tar zip redis-server mariadb-server apache2 \
    php8.3 php8.3-cli php8.3-common php8.3-mysql php8.3-pgsql php8.3-sqlite3 php8.3-redis \
    php8.3-gd php8.3-mbstring php8.3-bcmath php8.3-curl php8.3-zip php8.3-xml php8.3-intl php8.3-fpm composer

echo "🌍 Setting timezone to Asia/Jakarta..."
timedatectl set-timezone Asia/Jakarta

echo "📦 Downloading latest Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache
composer install --no-dev --optimize-autoloader

echo "⚙️ Creating environment file..."
cp .env.example .env

echo "🔑 Generating application key..."
php artisan key:generate --force || true

echo "🧩 Setting environment..."
php artisan p:environment:setup --url="https://panel.zaleehost.qzz.io" \
  --timezone="Asia/Jakarta" \
  --cache="redis" \
  --session="redis" \
  --queue="redis" \
  --settings-ui=false \
  --author="ZaleeHost" \
  --email="zaleeboy8@gmail.com" || true

echo "🗄️ Configuring database..."
php artisan p:environment:database \
  --host="127.0.0.1" \
  --port="3306" \
  --database="panel" \
  --username="ptero" \
  --password="zalee1"

echo "🧱 Migrating database..."
php artisan migrate --seed --force

echo "👑 Creating admin user..."
php artisan p:user:make \
  --email="zaleeboy8@gmail.com" \
  --username="ZaleeHost" \
  --name-first="Zalee" \
  --name-last="Host" \
  --password="zalee1" \
  --admin=1 || true

echo "🌐 Configuring Apache..."
cat > /etc/apache2/sites-available/pterodactyl.conf <<EOF
<VirtualHost *:80>
    ServerName panel.zaleehost.qzz.io
    DocumentRoot /var/www/pterodactyl/public
    <Directory /var/www/pterodactyl/public>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF

a2enmod rewrite
a2ensite pterodactyl.conf
a2dissite 000-default.conf
systemctl restart apache2

echo "✅ Installation complete!"
echo "Login now at: https://panel.zaleehost.qzz.io"
echo "Email: zaleeboy8@gmail.com"
echo "Password: zalee1"
