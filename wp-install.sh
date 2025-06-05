#!/bin/bash

# ==============================
# WordPress 一键安装脚本（交互输入无示例版）
# 适用于 Ubuntu 20.04 / 22.04
# ==============================

# === 交互输入参数 ===
read -p "请输入 MySQL 数据库名: " DB_NAME
read -p "请输入 MySQL 用户名: " DB_USER
read -s -p "请输入 MySQL 用户密码: " DB_PASSWORD
echo
read -p "请输入 MySQL root 用户密码: " MYSQL_ROOT_PASSWORD
read -p "请输入网站绑定的域名: " DOMAIN
read -p "请输入申请 SSL 证书用的邮箱: " SSL_EMAIL

WP_PATH="/var/www/wordpress"
PHP_VERSION="8.3"
CERTBOT_RETRY=3

# === 开始安装 ===
echo "👉 当前域名: ${DOMAIN}"
echo "🔄 更新系统..."
sudo apt update && sudo apt upgrade -y

# 安装必要组件
echo "📦 安装 Nginx、MySQL、PHP..."
sudo apt install -y nginx mysql-server php${PHP_VERSION}-fpm php-mysql \
php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip \
imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx

# 配置 MySQL 数据库
echo "🛠️ 配置 MySQL..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# 安装 WordPress
echo "⬇️ 下载并安装 WordPress..."
sudo mkdir -p ${WP_PATH}
cd /tmp
wget https://wordpress.org/latest.tar.gz || { echo "❌ WordPress 下载失败！"; exit 1; }
tar -xzf latest.tar.gz
sudo cp -a wordpress/. ${WP_PATH}
sudo chown -R www-data:www-data ${WP_PATH}
sudo chmod -R 755 ${WP_PATH}
sudo mkdir -p ${WP_PATH}/wp-content/uploads
sudo chown -R www-data:www-data ${WP_PATH}/wp-content/uploads

# 配置 Nginx 虚拟主机
echo "🌐 配置 Nginx..."
sudo tee /etc/nginx/conf.d/${DOMAIN}.conf > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WP_PATH};
    index index.php index.html index.htm;

    client_max_body_size 1024M;

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

# 启用配置并检查语法
sudo nginx -t || { echo "❌ Nginx 配置有误！"; exit 1; }
sudo systemctl reload nginx

# 申请 SSL 证书（仅主域名）
echo "🔐 申请 SSL 证书..."
PUNYCODE_DOMAIN=$(echo ${DOMAIN} | idn)
for i in $(seq 1 ${CERTBOT_RETRY}); do
    sudo certbot --nginx -d "${PUNYCODE_DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email && break
    echo "⚠️ SSL 申请失败，尝试重新申请 (${i}/${CERTBOT_RETRY})..."
    sleep 3
done

# 优化 PHP 配置参数
echo "⚙️ 优化 PHP 参数..."
PHP_INI_PATH="/etc/php/${PHP_VERSION}/fpm/php.ini"
if [ -f "$PHP_INI_PATH" ]; then
    sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $PHP_INI_PATH
    sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" $PHP_INI_PATH
    sudo sed -i "s/max_execution_time = .*/max_execution_time = 900/" $PHP_INI_PATH
    sudo sed -i "s/max_input_time = .*/max_input_time = 900/" $PHP_INI_PATH
fi

# 设置权限
echo "🔐 设置 WordPress 权限..."
sudo chown -R www-data:www-data ${WP_PATH}
sudo find ${WP_PATH} -type d -exec chmod 755 {} \;
sudo find ${WP_PATH} -type f -exec chmod 644 {} \;

# 保护 wp-config.php（如果存在）
if [ -f "${WP_PATH}/wp-config.php" ]; then
    sudo chmod 600 ${WP_PATH}/wp-config.php
fi

# 重启服务
echo "🚀 重启服务..."
sudo systemctl restart php${PHP_VERSION}-fpm
sudo systemctl restart nginx

echo "🎉 WordPress 安装完成！请访问：https://${DOMAIN} 进行站点初始化配置 🚀"
