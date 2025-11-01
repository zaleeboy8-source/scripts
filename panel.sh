#!/bin/bash
# === Pterodactyl Panel Installer (Debian 12 / Ubuntu 22.04) ===
# by ZaleeHost Setup Script

set -e

echo "🧩 Updating system..."
apt update -y && apt upgrade -y

echo "🌍 Setting timezone to Asia/Jakarta..."
timedatectl set-timezone Asia/Jakarta

echo "📦 Installing dependencies..."
apt install -y curl apt-transport-https ca-certificates gnupg lsb-release software-properties-common

echo "🌐 Adding PHP repository (Sury)..."
curl -sSL https://packages.sury.org/php/README.txt | bash -x || true
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-php.gpg

apt update -y

echo "🧠 Installing PHP 8.3 and modules..."
apt install -y \
    php8.3 php8.3-cli php8.3-common php8.3-mysql php8.3-pgsql php8.3-sqlite3 php8.3-redis \
    php8.3-gd php8.3-mbstring php8.3-bcmath php8.3-curl php8.3-zip php8.3-xml php8.3-intl php8.3-fpm \
    php8.3-imap php8.3-readline unzip git redis-server nginx mariadb-server composer

echo "📂 Setting up Pterodactyl directory..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

echo "📥 Downloading latest Pterodactyl Panel..."
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz && rm panel.tar.gz

echo "🔧 Setting permissions..."
chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

echo "🧱 Installing Composer dependencies..."
composer install --no-dev --optimize-autoloader

echo "🔑 Generating encryption key..."
cp .env.example .env
php artisan key:generate --force

echo "⚙️ Setting up environment..."
php artisan p:environment:setup \
    --author-email="admin@zaleehost.qzz.io" \
    --url="https://panel.zaleehost.qzz.io" \
    --timezone="Asia/Jakarta" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --force

echo "🗄️ Setting up database..."
php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="panel" \
    --username="ptero" \
    --password="password123" \
    --force

echo "📜 Running migrations..."
php artisan migrate --seed --force

echo "🌐 Configuring nginx..."
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOL
server {
    listen 80;
    server_name panel.zaleehost.qzz.io;
    root /var/www/pterodactyl/public;

    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "✅ Installation completed!"
echo "Visit your panel at: https://panel.zaleehost.qzz.io"
