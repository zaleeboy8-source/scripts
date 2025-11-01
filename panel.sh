#!/bin/bash
# ==============================
# 🚀 Pterodactyl Panel Installer (Simple Version)
# Author: ZaleeHost
# OS: Debian 12 x64
# ==============================

EMAIL="zaleeboy8@gmail.com"
USERNAME="ZaleeHost"
PASSWORD="zalee1"
DB_NAME="panel"
DB_USER="paneluser"
DB_PASS="zalee123"
DOMAIN="panel.zaleehost.qzz.io"

echo "🔧 Updating system..."
apt update -y && apt upgrade -y

echo "⚙️ Installing dependencies..."
apt install -y curl software-properties-common ca-certificates apt-transport-https gnupg lsb-release unzip git redis-server nginx mariadb-server

echo "📦 Adding PHP 8.3 repo..."
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury.list
apt update -y

echo "🧩 Installing PHP 8.3 + extensions..."
apt install -y php8.3 php8.3-{cli,common,mysql,pgsql,sqlite3,redis,gd,mbstring,bcmath,curl,zip,xml,intl,fpm}

echo "🗄️ Setting up MariaDB..."
systemctl enable mariadb
systemctl start mariadb
mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE ${DB_NAME};
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "🪄 Installing Composer..."
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

echo "🧠 Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "📥 Installing Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz && rm panel.tar.gz
composer install --no-dev --optimize-autoloader
cp .env.example .env
php artisan key:generate --force
php artisan p:environment:setup -n --author="${EMAIL}" --url="https://${DOMAIN}" --timezone="Asia/Jakarta" --cache=redis --session=redis --queue=redis --redis-host=127.0.0.1
php artisan p:environment:database -n --host=127.0.0.1 --port=3306 --database=${DB_NAME} --username=${DB_USER} --password=${DB_PASS}
php artisan migrate --seed --force

echo "👑 Creating admin user..."
php artisan p:user:make --email=${EMAIL} --username=${USERNAME} --name-first=Zalee --name-last=Host --password=${PASSWORD} --admin=1

chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

echo "🌐 Configuring Nginx..."
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx

echo "🔐 Installing SSL..."
apt install -y certbot python3-certbot-nginx
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${EMAIL}

systemctl restart php8.3-fpm
systemctl restart nginx

echo "✅ Installation finished!"
echo "🌍 Visit: https://${DOMAIN}"
echo "👤 Email: ${EMAIL}"
echo "🔑 Password: ${PASSWORD}"
