#!/bin/bash
set -e

# ==============================
# 🚀 WordPress 终极自动部署 v4.1
# 支持 PHP 8.3 + 完整 XML 导入 + Swap + PHP/Nginx/SSL 优化
# ==============================

# === 用户输入 ===
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
echo "🔄 更新系统..."
apt update -y && apt upgrade -y

# ---------------- 安装依赖 ----------------
echo "📦 安装 Nginx、MySQL、PHP 及扩展..."
apt install -y nginx mysql-server php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
php-mysql php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-xsl \
imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx

# 确保安装 simplexml 相关包
echo "📦 确保安装 simplexml 相关包..."
apt install -y php${PHP_VERSION}-xml libxml2 libxml2-dev

# ---------------- 安装 WP-CLI ----------------
if ! command -v wp &> /dev/null; then
    echo "⚙️ 安装 WP-CLI..."
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

# ---------------- 创建 Swap ----------------
if ! swapon --show | grep -q '^'; then
    echo "💾 创建 Swap..."
    fallocate -l ${SWAP_SIZE} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
else
    echo "💾 Swap 已存在"
fi

# ---------------- MySQL 配置 ----------------
echo "🛠️ 配置 MySQL root 用户..."

# 检查 MySQL 服务状态
systemctl is-active --quiet mysql || {
    echo "🔄 MySQL 服务未运行，正在启动..."
    systemctl start mysql
    sleep 3
}

# 尝试不同方式重置 root 密码
echo "🔑 尝试设置 MySQL root 密码..."

# 方法1: 使用 mysqladmin (适用于初始无密码状态)
mysqladmin -u root password "${MYSQL_ROOT_PASSWORD}" 2>/dev/null || echo "尝试方法1失败，继续尝试..."

# 方法2: 使用 ALTER USER (适用于已有密码但需要更改)
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null || echo "尝试方法2失败，继续尝试..."

# 方法3: 使用 UPDATE mysql.user (适用于某些旧版本)
mysql -u root -e "UPDATE mysql.user SET authentication_string=PASSWORD('${MYSQL_ROOT_PASSWORD}') WHERE User='root'; FLUSH PRIVILEGES;" 2>/dev/null || echo "尝试方法3失败，继续尝试..."

# 方法4: 如果是 auth_socket 认证
if mysql -u root -e "SELECT user, plugin FROM mysql.user WHERE user='root';" 2>/dev/null | grep -q "auth_socket"; then
    echo "🔧 检测到 root 使用 auth_socket，切换为密码登录..."
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
fi

# 验证 root 密码是否设置成功
if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "✅ MySQL root 密码设置成功"
else
    echo "⚠️ MySQL root 密码设置可能失败，尝试使用 sudo 权限..."
    # 使用 sudo 尝试最后的方法
    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
    
    if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
        echo "✅ MySQL root 密码通过 sudo 设置成功"
    else
        echo "❌ 无法设置 MySQL root 密码，请手动配置后重新运行脚本"
        exit 1
    fi
fi

# 创建数据库和用户
echo "🗄️ 创建数据库和用户..."
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# ---------------- 安装 WordPress ----------------
echo "⬇️ 下载并安装 WordPress..."
mkdir -p ${WP_PATH}
cd /tmp && wget -q https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz
cp -a wordpress/. ${WP_PATH}
chown -R www-data:www-data ${WP_PATH}
find ${WP_PATH} -type d -exec chmod 755 {} \;
find ${WP_PATH} -type f -exec chmod 644 {} \;

# ---------------- Nginx 配置 ----------------
echo "🌐 配置 Nginx..."
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
        fastcgi_read_timeout 1800;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

nginx -t && systemctl reload nginx

# ---------------- SSL ----------------
echo "🔐 申请 SSL..."
certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email || echo "⚠️ SSL 自动申请失败，请稍后重试"

# ---------------- PHP 优化 ----------------
echo "⚙️ 优化 PHP 配置..."
for INI in /etc/php/${PHP_VERSION}/{fpm,cli}/php.ini; do
    if [ -f "$INI" ]; then
        sed -i "s/^upload_max_filesize.*/upload_max_filesize = 1024M/" $INI
        sed -i "s/^post_max_size.*/post_max_size = 1024M/" $INI
        sed -i "s/^memory_limit.*/memory_limit = 512M/" $INI
        sed -i "s/^max_execution_time.*/max_execution_time = 1800/" $INI
        sed -i "s/^max_input_time.*/max_input_time = 1800/" $INI
        grep -q "^max_input_vars" $INI || echo "max_input_vars = 10000" >> $INI
    else
        echo "⚠️ 配置文件不存在: $INI"
    fi
done

# ---------------- 强制启用 simplexml ----------------
echo "🔎 检查并强制启用 simplexml..."

# 确保 php-xml 包已安装
apt install -y php${PHP_VERSION}-xml

# 检查 simplexml 是否已加载
if php -m | grep -q "simplexml"; then
    echo "✅ simplexml 已加载"
else
    echo "⚠️ simplexml 未加载，尝试手动启用..."
    
    # 查找 simplexml.so 文件
    PHP_EXT_DIR=$(php -i | grep '^extension_dir' | awk '{print $3}')
    
    # 如果找不到 simplexml.so，尝试查找 xml.so
    if [ ! -f "${PHP_EXT_DIR}/simplexml.so" ]; then
        echo "⚠️ 未找到 simplexml.so，尝试查找 xml.so..."
        if [ -f "${PHP_EXT_DIR}/xml.so" ]; then
            echo "extension=xml.so" > /etc/php/${PHP_VERSION}/mods-available/xml.ini
            phpenmod xml
        fi
    else
        echo "extension=simplexml.so" > /etc/php/${PHP_VERSION}/mods-available/simplexml.ini
        phpenmod simplexml
    fi
    
    # 重启 PHP-FPM
    systemctl restart php${PHP_VERSION}-fpm
    
    # 再次检查
    if php -m | grep -q "simplexml"; then
        echo "✅ simplexml 已成功启用"
    else
        echo "⚠️ simplexml 仍未加载，尝试最后的方法..."
        # 尝试直接在 php.ini 中添加扩展
        echo "extension=simplexml.so" >> /etc/php/${PHP_VERSION}/fpm/php.ini
        echo "extension=simplexml.so" >> /etc/php/${PHP_VERSION}/cli/php.ini
        systemctl restart php${PHP_VERSION}-fpm
    fi
fi

# ---------------- 检查 PHP 扩展 ----------------
echo "🔍 检查 PHP 扩展..."
MISSING_EXTS=""
for EXT in simplexml dom xmlreader xmlwriter mbstring curl xsl; do
    if php -m | grep -q "$EXT"; then
        echo "✅ $EXT 已加载"
    else
        echo "❌ $EXT 缺失"
        MISSING_EXTS="$MISSING_EXTS $EXT"
    fi
done

# 如果有缺失的扩展，尝试安装
if [ ! -z "$MISSING_EXTS" ]; then
    echo "⚠️ 尝试安装缺失的扩展: $MISSING_EXTS"
    apt install -y php${PHP_VERSION}-xml php${PHP_VERSION}-mbstring php${PHP_VERSION}-curl php${PHP_VERSION}-xsl
    systemctl restart php${PHP_VERSION}-fpm
    
    # 再次检查
    echo "🔍 再次检查扩展..."
    for EXT in $MISSING_EXTS; do
        if php -m | grep -q "$EXT"; then
            echo "✅ $EXT 已成功安装"
        else
            echo "❌ $EXT 仍然缺失"
        fi
    done
fi

# ---------------- 可选导入 XML ----------------
if [[ -n "$XML_FILE" && -f "$XML_FILE" ]]; then
    echo "📦 导入 XML 内容..."
    # 确保 wp-cli 可用
    if command -v wp &> /dev/null; then
        sudo -u www-data wp import "$XML_FILE" --authors=create --path="${WP_PATH}" --allow-root || echo "⚠️ XML 导入失败，请手动检查"
    else
        echo "❌ wp-cli 不可用，无法导入 XML"
    fi
fi

# ---------------- 完成 ----------------
echo "🎉 WordPress 已安装完成！"
echo "🌍 访问: https://${DOMAIN}"
echo "📁 路径: ${WP_PATH}"
echo "✅ 数据库: ${DB_NAME}"
echo "👤 数据库用户: ${DB_USER}"

# 显示安装信息摘要
echo "
=============== 📝 安装信息摘要 ===============
🔐 MySQL Root 密码: ${MYSQL_ROOT_PASSWORD}
🔐 WordPress 数据库: ${DB_NAME}
🔐 WordPress 数据库用户: ${DB_USER}
🔐 WordPress 数据库密码: ${DB_PASSWORD}
🌐 网站域名: ${DOMAIN}
📁 WordPress 安装路径: ${WP_PATH}
===============================================

请妥善保存以上信息！
"
