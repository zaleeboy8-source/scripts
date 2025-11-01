#!/bin/bash
# === Pterodactyl Panel Installer (Debian 12) ===
# by ZaleeHost Setup Script

set -e

echo "🔧 Updating system..."
apt update -y && apt upgrade -y

echo "⚙️ Installing dependencies..."
apt install -y curl wget zip unzip git nginx mariadb-server redis-server certbot python3-certbot-nginx

echo "🧩 Installing PHP 8.3..."
apt install -y ca-certificates apt-transport-https software-properties-common lsb-release
curl -sSL https://packages.sury.org/php/README.txt | bash -x || true
apt update -y
apt install -y php8.3 php8.3-cli php8.3-gd php8.3-mysql php8.3-pdo php8.3-mbstring php8.3-tokenizer php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-common php8.3-intl composer

echo "🗄️ Setting up MariaDB..."
systemctl enable mariadb --now
mysql -e "CREATE DATABASE panel;"
mysql -e "CREATE USER 'ptero'@'127.0.0.1' IDENTIFIED BY 'zalee1';"
mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'ptero'@'127.0.0.1' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

echo "📥 Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz && rm panel.tar.gz

echo "🔧 Installing Panel dependencies..."
composer install --no-dev --optimize-autoloader
cp .env.example .env

php artisan key:generate --force

echo "🧰 Configuring environment..."
php artisan p:environment:setup \
  --author-email="zaleeboy8@gmail.com" \
  --app-url="https://panel.zaleehost.qzz.io" \
  --timezone="Asia/Jakarta"

php artisan p:environment:database \
  --host="127.0.0.1" \
  --port="3306" \
  --database="panel" \
  --username="ptero" \
  --password="zalee1"

php artisan migrate --seed --force

echo "👤 Creating admin user..."
php artisan p:user:make \
  --email="zaleeboy8@gmail.com" \
  --username="ZaleeHost" \
  --name-first="Zalee" \
  --name-last="Host" \
  --password="zalee1" \
  --admin=1

chown -R www-data:www-data /var/www/pterodactyl/*

echo "🌐 Configuring Nginx..."
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name panel.zaleehost.qzz.io;
    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

echo "🔐 Installing SSL certificate..."
certbot --nginx -d panel.zaleehost.qzz.io --non-interactive --agree-tos -m zaleeboy8@gmail.com

echo "✅ Panel setup complete!"
echo "Login: https://panel.zaleehost.qzz.io"
echo "User: ZaleeHost | Pass: zalee1"
