#!/bin/bash
set -e

# ==============================
# 🚀 WordPress 终极自动部署 v3.1（修复 simplexml）
# ==============================

read -p "请输入 MySQL 数据库名: " DB_NAME
read -p "请输入 MySQL 用户名: " DB_USER
read -s -p "请输入 MySQL 用户密码: " DB_PASSWORD
echo
read -p "请输入 MySQL root 用户密码（新密码）: " MYSQL_ROOT_PASSWORD
read -p "请输入网站域名: " DOMAIN
read -p "请输入申请 SSL 证书邮箱: " SSL_EMAIL
read -p "请输入 XML 文件路径（可留空跳过）: " XML_FILE

WP_PATH="/var/www/wordpress"
PHP_VERSION="8.3"
SWAP_SIZE="2G"

echo "=============== 🚀 开始安装 WordPress ==============="

# ---------------- 系统更新 ----------------
apt update -y && apt upgrade -y

# ---------------- 安装依赖 ----------------
apt install -y nginx mysql-server php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
php-mysql php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-xsl \
imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx

# ---------------- 修复 simplexml 缺失 ----------------
echo "🧩 检查并强制启用 simplexml..."
EXT_DIR=$(php -i | grep '^extension_dir' | awk '{print $3}')
if [ -f "${EXT_DIR}/simplexml.so" ]; then
    echo "extension=simplexml" > /etc/php/${PHP_VERSION}/mods-available/simplexml.ini
    phpenmod simplexml
else
    echo "⚠️ 未找到 simplexml.so，尝试重新安装 XML 模块..."
    apt install -y php${PHP_VERSION}-xml
    echo "extension=simplexml" > /etc/php/${PHP_VERSION}/mods-available/simplexml.ini
    phpenmod simplexml
fi
systemctl restart php${PHP_VERSION}-fpm

# 验证加载
if php -m | grep -q simplexml; then
    echo "✅ simplexml 已成功启用"
else
    echo "❌ simplexml 启用失败，请检查 PHP 模块目录: ${EXT_DIR}"
fi

# ---------------- 创建 Swap ----------------
if ! swapon --show | grep -q '^'; then
    fallocate -l ${SWAP_SIZE} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

# ---------------- MySQL 配置 ----------------
if mysql -u root -e "SELECT user, plugin FROM mysql.user WHERE user='root';" | grep -q "auth_socket"; then
    mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
fi

mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# ---------------- 安装 WordPress ----------------
mkdir -p ${WP_PATH}
cd /tmp && wget -q https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz
cp -a wordpress/. ${WP_PATH}
chown -R www-data:www-data ${WP_PATH}
find ${WP_PATH} -type d -exec chmod 755 {} \;
find ${WP_PATH} -type f -exec chmod 644 {} \;

# ---------------- Nginx 配置 ----------------
cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
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

nginx -t && systemctl reload nginx

# ---------------- SSL ----------------
certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email || echo "⚠️ SSL 自动申请失败，请稍后重试"

# ---------------- PHP 优化 ----------------
for INI in /etc/php/${PHP_VERSION}/{fpm,cli}/php.ini; do
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 1024M/" $INI
    sed -i "s/^post_max_size.*/post_max_size = 1024M/" $INI
    sed -i "s/^memory_limit.*/memory_limit = 512M/" $INI
    sed -i "s/^max_execution_time.*/max_execution_time = 1800/" $INI
    sed -i "s/^max_input_time.*/max_input_time = 1800/" $INI
    grep -q "^max_input_vars" $INI || echo "max_input_vars = 10000" >> $INI
done
systemctl restart php${PHP_VERSION}-fpm nginx

# ---------------- 检查扩展 ----------------
echo "🔍 检查 PHP 扩展..."
for EXT in simplexml dom xmlreader xmlwriter mbstring curl xsl; do
    php -m | grep -q "$EXT" && echo "✅ $EXT 已加载" || echo "❌ $EXT 缺失"
done

# ---------------- 可选导入 XML ----------------
if [[ -n "$XML_FILE" && -f "$XML_FILE" ]]; then
    echo "📦 导入 XML 内容..."
    sudo -u www-data wp import "$XML_FILE" --authors=create --path="${WP_PATH}" --allow-root
fi

echo "🎉 WordPress 已安装完成！"
echo "🌍 访问: https://${DOMAIN}"
echo "📁 路径: ${WP_PATH}"
echo "✅ 数据库: ${DB_NAME}"
