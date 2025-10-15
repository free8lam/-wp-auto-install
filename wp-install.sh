#!/bin/bash

# ==============================
# WordPress 终极一键安装脚本
# 支持大 XML 导入 + 自动 Swap + PHP-FPM 扩展完整
# 自动优化 PHP/Nginx/SSL/文件权限
# 适用于 Ubuntu 22.04 / 24.04 + PHP 8.3
# ==============================

# === 交互输入参数 ===
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
CERTBOT_RETRY=3
SWAP_SIZE=2G

# ==============================
# 更新系统
# ==============================
echo "🔄 更新系统..."
sudo apt update && sudo apt upgrade -y

# ==============================
# 安装必要软件
# ==============================
echo "📦 安装 Nginx、MySQL、PHP 及扩展..."
sudo apt install -y nginx mysql-server php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php-mysql \
php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-xsl \
imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx wp-cli

# ==============================
# 创建 Swap（如果不存在）
# ==============================
if ! swapon --show | grep -q '^'; then
    echo "💾 创建 ${SWAP_SIZE} Swap..."
    sudo fallocate -l ${SWAP_SIZE} /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
    echo "💾 Swap 已存在，跳过创建"
fi
swapon --show

# ==============================
# 配置 MySQL
# ==============================
echo "🛠️ 配置 MySQL..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# ==============================
# 安装 WordPress
# ==============================
echo "⬇️ 下载并安装 WordPress..."
sudo mkdir -p ${WP_PATH}
cd /tmp
wget https://wordpress.org/latest.tar.gz || { echo "❌ WordPress 下载失败！"; exit 1; }
tar -xzf latest.tar.gz
sudo cp -a wordpress/. ${WP_PATH}
sudo chown -R www-data:www-data ${WP_PATH}
sudo find ${WP_PATH} -type d -exec chmod 755 {} \;
sudo find ${WP_PATH} -type f -exec chmod 644 {} \;
sudo mkdir -p ${WP_PATH}/wp-content/uploads
sudo chown -R www-data:www-data ${WP_PATH}/wp-content/uploads

# ==============================
# 配置 Nginx
# ==============================
echo "🌐 配置 Nginx..."
sudo tee /etc/nginx/conf.d/${DOMAIN}.conf > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WP_PATH};
    index index.php index.html index.htm;

    client_max_body_size 1024M;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

sudo nginx -t || { echo "❌ Nginx 配置有误！"; exit 1; }
sudo systemctl reload nginx

# ==============================
# 申请 SSL
# ==============================
echo "🔐 申请 SSL 证书..."
PUNYCODE_DOMAIN=$(echo ${DOMAIN} | idn)
for i in $(seq 1 ${CERTBOT_RETRY}); do
    sudo certbot --nginx -d "${PUNYCODE_DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email && break
    echo "⚠️ SSL 申请失败，尝试重新申请 (${i}/${CERTBOT_RETRY})..."
    sleep 3
done

# ==============================
# 优化 PHP-FPM + CLI 配置
# ==============================
PHP_FPM_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"

echo "⚙️ 优化 PHP 参数..."
for INI in "$PHP_FPM_INI" "$PHP_CLI_INI"; do
    sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $INI
    sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" $INI
    sudo sed -i "s/memory_limit = .*/memory_limit = 512M/" $INI
    sudo sed -i "s/max_execution_time = .*/max_execution_time = 1800/" $INI
    sudo sed -i "s/max_input_time = .*/max_input_time = 1800/" $INI
    sudo sed -i "s/;*max_input_vars = .*/max_input_vars = 10000/" $INI
done

# ==============================
# 确保 PHP 扩展加载
# ==============================
echo "🔎 检查 PHP-FPM 扩展..."
REQUIRED_EXT=(simplexml dom xmlreader mbstring curl xsl)
for EXT in "${REQUIRED_EXT[@]}"; do
    if ! php -m | grep -q "^${EXT}$"; then
        echo "❌ PHP 扩展 ${EXT} 未安装或未加载，请检查！"
    else
        echo "✅ PHP 扩展 ${EXT} 已加载"
    fi
done

# ==============================
# 重启服务
# ==============================
echo "🚀 重启服务..."
sudo systemctl restart php${PHP_VERSION}-fpm
sudo systemctl restart nginx

# ==============================
# WordPress XML 导入（可选）
# ==============================
if [[ -n "$XML_FILE" && -f "$XML_FILE" ]]; then
    echo "📂 使用 WP-CLI 导入 XML 文件..."
    sudo -u www-data wp import "$XML_FILE" --authors=create --path="$WP_PATH" --allow-root
    echo "✅ XML 导入完成（附件会自动下载）"
fi

# ==============================
# 完成提示
# ==============================
echo "🎉 WordPress 安装完成！"
echo "🔗 访问站点：https://${DOMAIN}"
echo "💡 建议大型 XML 文件使用 WP-CLI 导入以避免超时"
