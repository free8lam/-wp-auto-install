#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ============================================
# WordPress 一键终极安装脚本 v2.4
# ✅ 完美支持 Ubuntu 22.04 / 24.04
# ✅ 自动安装 WP-CLI 官方版本
# ✅ 自动创建 swap / 优化 PHP / SSL / XML 导入
# ============================================

# === 输入参数 ===
read -p "请输入 MySQL 数据库名: " DB_NAME
read -p "请输入 MySQL 用户名: " DB_USER
read -s -p "请输入 MySQL 用户密码: " DB_PASSWORD
echo
read -p "请输入 MySQL root 用户密码: " MYSQL_ROOT_PASSWORD
read -p "请输入网站绑定的域名: " DOMAIN
read -p "请输入申请 SSL 证书用的邮箱: " SSL_EMAIL
read -p "请输入 XML 文件路径（可选，留空跳过）： " XML_FILE

WP_PATH="/var/www/wordpress"
PHP_VERSION="8.3"
SWAP_SIZE="2G"

echo
echo "=============== 🚀 WordPress 自动部署 v2.4 ==============="

# ==============================
# 系统更新
# ==============================
echo "🔄 更新系统包..."
sudo apt update -y && sudo apt upgrade -y

# ==============================
# 安装基础依赖
# ==============================
echo "📦 安装 Nginx / MySQL / PHP ..."
sudo apt install -y nginx mysql-server \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php-mysql \
    php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-xsl \
    imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx

# ==============================
# WP-CLI 官方安装
# ==============================
echo "⚙️ 安装 WP-CLI 官方版本..."
if ! command -v wp >/dev/null 2>&1; then
    cd /tmp
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    sudo mv wp-cli.phar /usr/local/bin/wp
    echo "✅ WP-CLI 安装完成：$(wp --version)"
else
    echo "✅ WP-CLI 已存在：$(wp --version)"
fi

# ==============================
# 创建 Swap
# ==============================
if ! swapon --show | grep -q '^'; then
    echo "💾 创建 ${SWAP_SIZE} Swap..."
    sudo fallocate -l ${SWAP_SIZE} /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
    echo "💾 Swap 已存在，跳过"
fi

# ==============================
# 配置 MySQL
# ==============================
echo "🛠️ 配置 MySQL..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# ==============================
# 安装 WordPress
# ==============================
echo "⬇️ 下载并安装 WordPress..."
sudo mkdir -p "${WP_PATH}"
cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
sudo cp -a wordpress/. "${WP_PATH}"
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;

# ==============================
# 自动检测 PHP-FPM socket
# ==============================
echo "🔎 检测 PHP-FPM socket..."
PHP_SOCKET=""
for sock in /run/php/php${PHP_VERSION}-fpm.sock /var/run/php/php${PHP_VERSION}-fpm.sock; do
    [ -S "$sock" ] && PHP_SOCKET="$sock"
done
if [ -z "$PHP_SOCKET" ]; then
    echo "⚠️ 未找到 PHP-FPM socket，使用 127.0.0.1:9000"
    PHP_SOCKET="127.0.0.1:9000"
fi

# ==============================
# 生成 Nginx 配置
# ==============================
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
echo "🌐 生成 Nginx 配置..."
sudo tee "${NGINX_CONF}" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WP_PATH};
    index index.php index.html index.htm;

    client_max_body_size 1024M;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 1800;
    proxy_read_timeout 1800;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass ${PHP_SOCKET};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

sudo nginx -t && sudo systemctl reload nginx

# ==============================
# SSL 配置
# ==============================
echo "🔐 申请 SSL 证书..."
sudo certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email --redirect || true

# ==============================
# 优化 PHP 配置
# ==============================
PHP_INIS=(
    "/etc/php/${PHP_VERSION}/fpm/php.ini"
    "/etc/php/${PHP_VERSION}/cli/php.ini"
)
for INI in "${PHP_INIS[@]}"; do
    sudo sed -i -E "s/^upload_max_filesize.*/upload_max_filesize = 1024M/" "$INI"
    sudo sed -i -E "s/^post_max_size.*/post_max_size = 1024M/" "$INI"
    sudo sed -i -E "s/^memory_limit.*/memory_limit = 512M/" "$INI"
    sudo sed -i -E "s/^max_execution_time.*/max_execution_time = 1800/" "$INI"
    sudo sed -i -E "s/^max_input_time.*/max_input_time = 1800/" "$INI"
    if ! grep -q "^max_input_vars" "$INI"; then
        echo "max_input_vars = 10000" | sudo tee -a "$INI" >/dev/null
    fi
done

sudo systemctl restart php${PHP_VERSION}-fpm

# ==============================
# XML 导入（可选）
# ==============================
if [[ -n "$XML_FILE" && -f "$XML_FILE" ]]; then
    echo "📂 使用 WP-CLI 导入 XML 文件..."
    sudo -u www-data wp import "$XML_FILE" --authors=create --path="$WP_PATH" --allow-root || true
fi

# ==============================
# 权限修复
# ==============================
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;
[ -f "${WP_PATH}/wp-config.php" ] && sudo chmod 600 "${WP_PATH}/wp-config.php"

# ==============================
# 完成
# ==============================
echo
echo "✅ WordPress 部署完成！"
echo "🌍 访问网站：https://${DOMAIN}"
echo "=============== 完成 ==============="
