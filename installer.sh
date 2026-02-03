#!/bin/bash

# ==========================================
# Pterodactyl Automated Installer (Final Version)
# ==========================================

# 1. Domain Input
echo "=========================================="
echo "   Pterodactyl Panel Installer Setup"
echo "=========================================="
echo ""
read -p "Enter your Panel Domain (e.g., panel.example.com): " DOMAIN

# Check if domain is empty
if [ -z "$DOMAIN" ]; then
    echo "❌ Error: Domain cannot be empty!"
    exit 1
fi

# Variables
EMAIL="admin@$DOMAIN"
DB_PASS="pass5695@#"
DB_USER="pterodactyl"
DB_NAME="panel"

echo ""
echo "------------------------------------------"
echo "Target Domain: $DOMAIN"
echo "Script will auto-select Option '2' for SSL"
echo "------------------------------------------"
echo "Starting Installation in 3 seconds..."
sleep 3

# 2. Add Repositories
echo "--- Adding Repositories ---"
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

# Add PHP Repository
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

# Add Redis Repository
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

# Update
apt update

# 3. Install Dependencies
echo "--- Installing Dependencies ---"
apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# 4. Install Composer
echo "--- Installing Composer ---"
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

# 5. Download Panel
echo "--- Downloading Pterodactyl Panel ---"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# 6. Database Setup
echo "--- Setting up Database ---"
sudo mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

# 7. Environment Configuration
echo "--- Configuring Environment ---"
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Automating "php artisan p:environment:setup" with extra Enter handling
echo "--- Running p:environment:setup ---"
# Using 'yes' to handle any "Are you sure?" prompts or missing enters
yes "" | php artisan p:environment:setup \
    --author="$EMAIL" \
    --url="https://$DOMAIN" \
    --timezone="Asia/Kolkata" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="127.0.0.1" \
    --redis-pass="" \
    --redis-port="6379"

# Automating "php artisan p:environment:database"
echo "--- Running p:environment:database ---"
php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASS"

# Migration and Seeding
echo "--- Migrating Database ---"
php artisan migrate --seed --force

# Set Permissions
chown -R www-data:www-data /var/www/pterodactyl/*

# 8. Crontab Setup
echo "--- Setting up Crontab ---"
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

# 9. Service Setup (Queue Worker)
echo "--- Creating Systemd Service ---"
cat <<EOF > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable Services
sudo systemctl enable --now redis-server
sudo systemctl enable --now pteroq.service

# 10. Nginx Configuration (Basic)
# Note: The external SSL script will likely modify or overwrite Nginx configs,
# but we set up the basic Pterodactyl config first as a base.
echo "--- Configuring Initial Nginx ---"
rm /etc/nginx/sites-enabled/default

cat <<EOF > /etc/nginx/sites-enabled/pterodactyl.conf
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 8443 ssl http2;
    server_name $DOMAIN;
    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    
    # Placeholders for SSL (External script will handle real certs)
    # Ensure these paths are valid or commented out if certs don't exist yet
    # We will let the external script handle the final SSL injection
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }
}
EOF

# 11. External SSL Script (Automated)
echo "--- Running External SSL Script ---"
# Passing Domain (Line 1) and '2' (Line 2) automatically
printf "$DOMAIN\n2\n" | bash <(curl -s https://raw.githubusercontent.com/NothingTheking/SSL/refs/heads/main/main.sh)

# 12. Final Restart
echo "--- Restarting Nginx ---"
systemctl restart nginx

echo "=========================================="
echo "✅ Installation Complete!"
echo "Pterodactyl is running at https://$DOMAIN:8443"
echo "=========================================="
