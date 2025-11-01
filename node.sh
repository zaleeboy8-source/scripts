#!/bin/bash
# === Pterodactyl Wings Node Installer (Debian 12) ===
# by ZaleeHost Setup Script

set -e

echo "🔧 Updating system..."
apt update -y && apt upgrade -y

echo "⚙️ Installing dependencies..."
apt install -y curl wget unzip tar xz-utils docker.io docker-compose

echo "🐳 Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
cd /etc/pterodactyl
curl -Lo wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x wings
mv wings /usr/local/bin/wings

echo "🧩 Creating systemd service..."
cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
LimitNOFILE=4096
LimitNPROC=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker --now
systemctl enable wings

echo "🌐 Configuring Firewall..."
ufw allow 22/tcp
ufw allow 8080/tcp
ufw allow 2022/tcp
ufw --force enable

echo "✅ Node installation complete!"
echo "Next steps:"
echo "1. Login to your panel (https://panel.zaleehost.qzz.io)"
echo "2. Go to Admin → Nodes → Create Node"
echo "3. Use node address: https://node.zaleehost.qzz.io:8080"
echo "4. Copy configuration JSON to /etc/pterodactyl/config.yml"
echo "5. Run: systemctl start wings"
