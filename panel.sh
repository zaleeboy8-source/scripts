#!/bin/bash
# ============================================
#  🌐 Pterodactyl Panel Auto Installer (Elegant Edition)
#  ⚡ Nginx + PHP8.1 + Redis + MariaDB + SSL (Self-Signed)
#  🧠 Author : ZaleeHost / zaleeboy8-source
# ============================================

set -e

# 🎨 Warna
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
BLUE="\e[94m"
RESET="\e[0m"
BOLD="\e[1m"

# 🕐 Fungsi Progress Step
step() {
  echo -e "\n${BOLD}${BLUE}==> $1...${RESET}"
  sleep 1
}

success() {
  echo -e "${GREEN}✔ $1${RESET}"
}

error() {
  echo -e "${RED}✘ $1${RESET}"
  exit 1
}

clear
echo -e "${BOLD}${GREEN}
===========================================
     🚀 ZALEEHOST PTERODACTYL INSTALLER
===========================================${RESET}"
sleep 1

# -----------------------------
# 1️⃣ Update System
# -----------------------------
step "Updating system packages"
apt update -y && apt upgrade -y
success "System updated"

# -----------------------------
# 2️⃣ Install Dependencies
# -----------------------------
step "Installing dependencies"
apt install -y curl unzip tar nginx redis-server mariadb-server \
php8.1 php8.1-cli php8.1-fpm php8.1-common php8.1-gd php8.1-mysql \
php8.1-mbstring php8.1-bcmath php8.1-xml php8.1-curl php8.1-zip \
php8.1-intl php8.1-readline php8.1-redis composer ufw
success "Dependencies installed"

# -----------------------------
# 3️⃣ Database Setup
# -----------------------------
step "Setting up MariaDB database"
DB_PASS=$(openssl rand -base64 16)
mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE panel;
CREATE USER 'ptero'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON panel.* TO 'ptero'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
success "Database created (user: ptero / pass: $DB_PASS)"

# -----------------------------
# 4️⃣ Install Pterodactyl Panel
# -----------------------------
step "Installing Pterodactyl Panel"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache

cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force

sed -i "s|APP_URL=.*|APP_URL=https://panel.zaleehost.qzz.io|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=panel|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=ptero|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env

php artisan migrate --seed --force
success "Pterodactyl Panel installed"

# -----------------------------
# 5️⃣ Configure Nginx
# -----------------------------
step "Configuring Nginx web server"
cat >/etc/nginx/sites-available/panel.conf <<EOF
server {
    listen 80;
    server_name panel.zaleehost.qzz.io;
    root /var/www/pterodactyl/public;

    index index.php;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name panel.zaleehost.qzz.io;
    root /var/www/pterodactyl/public;

    index index.php;
    charset utf-8;
    client_max_body_size 100M;

    ssl_certificate /etc/ssl/panel.crt;
    ssl_certificate_key /etc/ssl/panel.key;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/panel.conf /etc/nginx/sites-enabled/panel.conf
success "Nginx configured"

# -----------------------------
# 6️⃣ SSL Setup
# -----------------------------
step "Generating self-signed SSL certificate"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/panel.key \
  -out /etc/ssl/panel.crt \
  -subj "/C=ID/ST=Jakarta/L=Jakarta/O=ZaleeHost/OU=Hosting/CN=panel.zaleehost.qzz.io"
nginx -t && systemctl restart nginx
success "SSL configured"

# -----------------------------
# 7️⃣ Setup Queue Worker
# -----------------------------
step "Creating queue worker service"
cat >/etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now pteroq
systemctl restart php8.1-fpm
success "Queue worker active"

# -----------------------------
# 8️⃣ Firewall Setup
# -----------------------------
step "Configuring firewall"
ufw allow 80
ufw allow 443
ufw allow 22
success "Firewall rules applied"

# -----------------------------
# ✅ Done
# -----------------------------
echo -e "\n${BOLD}${GREEN}
===========================================
 🎉 INSTALLATION COMPLETED SUCCESSFULLY!
===========================================
📍 URL     : https://panel.zaleehost.qzz.io
👤 To create admin:
    php /var/www/pterodactyl/artisan p:user:make
🧩 Database:
    DB: panel
    User: ptero
    Pass: $DB_PASS
===========================================${RESET}"
