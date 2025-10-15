#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# WordPress 终极稳定版一键安装脚本 v2.3
# - 修复 Ubuntu 24.04 无法安装 wp-cli
# - 保留自动创建 swap、优化 PHP/Nginx、SSL、XML 导入等全部功能

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
echo "=============== 开始：WordPress 终极安装 v2.3 ==============="

# 系统更新
echo "🔄 更新系统包..."
sudo apt update -y && sudo apt upgrade -y

# 安装基础环境
echo "📦 安装 Nginx/MySQL/PHP 及依赖..."
sudo apt install -y nginx mysql-server \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php-mysql \
    php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-xsl \
    imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx

# === 修复 wp-cli 安装问题 ===
echo "⚙️ 安装 WP-CLI..."
if ! command -v wp >/dev/null 2>&1; then
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    sudo mv wp-cli.phar /usr/local/bin/wp
else
    echo "✅ WP-CLI 已安装"
fi

# 创建 swap
if ! swapon --show | grep -q '^'; then
    echo "💾 创建 Swap: ${SWAP_SIZE}"
    sudo fallocate -l ${SWAP_SIZE} /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
    echo "💾 Swap 已存在，跳过"
fi

# 配置 MySQL
echo "🛠️ 配置 MySQL..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# 下载 WordPress
echo "⬇️ 下载 WordPress..."
sudo mkdir -p "${WP_PATH}"
cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
sudo cp -a wordpress/. "${WP_PATH}"
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;

# 自动检测 PHP-FPM socket
PHP_SOCKET=""
for p in /run/php/php${PHP_VERSION}-fpm.sock /var/run/php/php${PHP_VERSION}-fpm.sock; do
    [ -S "$p" ] && PHP_SOCKET="$p"
done
[ -z "$PHP_SOCKET" ] && PHP_SOCKET="127.0.0.1:9000"
echo "🔎 PHP-FPM socket: ${PHP_SOCKET}"

# 检测 fastcgi snippet
FASTCGI_INCLUDE_LINE=""
if [ -f /etc/nginx/snippets/fastcgi-php.conf ]; then
    FASTCGI_INCLUDE_LINE="include /etc/nginx/snippets/fastcgi-php.conf;"
else
    FASTCGI_INCLUDE_LINE="include fastcgi_params;"
fi

# Nginx 配置
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
        ${FASTCGI_INCLUDE_LINE}
        fastcgi_pass ${PHP_SOCKET};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

# 检测 nginx 配置
sudo nginx -t && sudo systemctl reload nginx

# SSL
echo "🔐 申请 SSL..."
sudo certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email --redirect || true

# 优化 PHP 配置
PHP_FPM_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"
for INI in "${PHP_FPM_INI}" "${PHP_CLI_INI}"; do
    sudo sed -i -E "s/^(upload_max_filesize\s*=).*/\1 1024M/" "$INI"
    sudo sed -i -E "s/^(post_max_size\s*=).*/\1 1024M/" "$INI"
    sudo sed -i -E "s/^(memory_limit\s*=).*/\1 512M/" "$INI"
    sudo sed -i -E "s/^(max_execution_time\s*=).*/\1 1800/" "$INI"
    sudo sed -i -E "s/^(max_input_time\s*=).*/\1 1800/" "$INI"
    if ! grep -q '^max_input_vars' "$INI"; then
        echo "max_input_vars = 10000" | sudo tee -a "$INI" >/dev/null
    fi
done

sudo systemctl restart php${PHP_VERSION}-fpm

# XML 导入
if [ -n "${XML_FILE}" ] && [ -f "${XML_FILE}" ]; then
    echo "📂 使用 WP-CLI 导入 XML..."
    sudo -u www-data wp --path="${WP_PATH}" import "${XML_FILE}" --authors=create --allow-root || true
fi

# 权限优化
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;
[ -f "${WP_PATH}/wp-config.php" ] && sudo chmod 600 "${WP_PATH}/wp-config.php"

echo
echo "✅ WordPress 完整安装完成！"
echo "🌍 网站地址：https://${DOMAIN}"
echo "=============== 结束 ==============="
