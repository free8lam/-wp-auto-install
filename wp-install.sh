#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# WordPress 终极稳定版一键安装脚本 v2.2
# - 适用于 Ubuntu 22.04 / 24.04 + PHP 8.3
# - 自动创建 swap、安装/检测扩展、优化 PHP/Nginx、SSL、WP-CLI 导入
# 注意：以 root 或具有 sudo 权限的用户运行

# === 交互输入 ===
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
SWAP_SIZE="2G"

echo
echo "=============== 开始：WordPress 终极安装 v2.2 ==============="
echo "域名: ${DOMAIN}"
echo "网站路径: ${WP_PATH}"
echo

# 更新系统
echo "🔄 更新系统包..."
sudo apt update && sudo apt upgrade -y

# 安装必要软件
echo "📦 安装 Nginx/MySQL/PHP 及常用扩展、WP-CLI..."
sudo apt install -y nginx mysql-server \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php-mysql \
    php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-xsl \
    imagemagick php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx wp-cli

# 创建 Swap（如果不存在）
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
swapon --show

# 配置 MySQL（简单）
echo "🛠️ 配置 MySQL..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# 安装 WordPress 文件
echo "⬇️ 下载并部署 WordPress..."
sudo mkdir -p "${WP_PATH}"
cd /tmp
wget -q https://wordpress.org/latest.tar.gz || { echo "❌ WordPress 下载失败"; exit 1; }
tar -xzf latest.tar.gz
sudo cp -a wordpress/. "${WP_PATH}"
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;
sudo mkdir -p "${WP_PATH}/wp-content/uploads"
sudo chown -R www-data:www-data "${WP_PATH}/wp-content/uploads"

# 自动检测 PHP-FPM socket 路径（优先 /run/php）
PHP_SOCKET=""
CANDIDATES=("/run/php/php${PHP_VERSION}-fpm.sock" "/var/run/php/php${PHP_VERSION}-fpm.sock" "/run/php/php-fpm.sock")
for p in "${CANDIDATES[@]}"; do
    if [ -S "${p}" ]; then
        PHP_SOCKET="${p}"
        break
    fi
done
# 如果没有找到 socket，检查是否 php-fpm 正在监听 TCP 9000
if [ -z "${PHP_SOCKET}" ]; then
    # 检查是否有进程监听 9000
    if ss -ltn | grep -q ':9000'; then
        PHP_SOCKET="127.0.0.1:9000"
    else
        # 最后一招：假设常用路径（/run/php/..）并继续，php-fpm 启动后脚本会检测
        PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    fi
fi
echo "🔎 PHP-FPM socket 将使用: ${PHP_SOCKET}"

# 检测 fastcgi snippet
FASTCGI_INCLUDE_LINE=""
if [ -f /etc/nginx/snippets/fastcgi-php.conf ]; then
    FASTCGI_INCLUDE_LINE="include /etc/nginx/snippets/fastcgi-php.conf;"
else
    FASTCGI_INCLUDE_LINE="include fastcgi_params;"
fi
echo "🔎 fastcgi include 将使用: ${FASTCGI_INCLUDE_LINE}"

# 生成 Nginx 配置（注意对 Nginx 变量 $uri/$args 替换转义）
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
echo "🌐 写入 Nginx 配置到 ${NGINX_CONF} ..."
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

# 测试 Nginx 配置
echo "🔧 测试 Nginx 配置..."
if ! sudo nginx -t; then
    echo "❌ Nginx 配置检测失败，显示最后 60 行 journal（php-fpm/nginx）供排查："
    sudo journalctl -u nginx -n 60 --no-pager || true
    sudo journalctl -u php${PHP_VERSION}-fpm -n 60 --no-pager || true
    exit 1
fi
sudo systemctl reload nginx

# 申请 SSL（certbot）
echo "🔐 申请 SSL..."
PUNYCODE_DOMAIN=$(echo "${DOMAIN}" | idn)
for i in $(seq 1 ${CERTBOT_RETRY}); do
    if sudo certbot --nginx -d "${PUNYCODE_DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email --redirect; then
        echo "✅ SSL 申请成功"
        break
    else
        echo "⚠️ certbot 申请失败，重试 (${i}/${CERTBOT_RETRY})..."
        sleep 3
    fi
done

# 优化 PHP-FPM 与 CLI 配置（统一）
PHP_FPM_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"

echo "⚙️ 优化 PHP 配置（FPM & CLI）..."
for INI in "${PHP_FPM_INI}" "${PHP_CLI_INI}"; do
    if [ -f "${INI}" ]; then
        sudo sed -i -E "s/^(upload_max_filesize\s*=\s*).*/\11024M/" "${INI}" || true
        sudo sed -i -E "s/^(post_max_size\s*=\s*).*/\11024M/" "${INI}" || true
        sudo sed -i -E "s/^(memory_limit\s*=\s*).*/\1512M/" "${INI}" || true
        sudo sed -i -E "s/^(max_execution_time\s*=\s*).*/\11800/" "${INI}" || true
        sudo sed -i -E "s/^(max_input_time\s*=\s*).*/\11800/" "${INI}" || true
        # 如果没有 max_input_vars，添加一行
        if ! grep -qE "^max_input_vars" "${INI}"; then
            echo "max_input_vars = 10000" | sudo tee -a "${INI}" >/dev/null
        else
            sudo sed -i -E "s/^(;?max_input_vars\s*=\s*).*/max_input_vars = 10000/" "${INI}" || true
        fi
    fi
done

# 确保 PHP 扩展存在（检查 CLI 和 FPM 两套）
echo "🔎 检查 PHP 关键扩展 (CLI 与 FPM)..."
REQUIRED_EXT=(simplexml dom xmlreader mbstring curl xsl)
MISSING=()
for EXT in "${REQUIRED_EXT[@]}"; do
    ok_cli=false
    ok_fpm=false
    if php -m 2>/dev/null | grep -q -E "^${EXT}\$"; then ok_cli=true; fi
    # 检查 php-fpm 模块（若 php-fpm<version> 可用）
    if command -v php-fpm${PHP_VERSION} >/dev/null 2>&1; then
        if php-fpm${PHP_VERSION} -m 2>/dev/null | grep -q -E "^${EXT}\$"; then ok_fpm=true; fi
    else
        # 尝试使用 php-fpm -m（若存在）
        if command -v php-fpm >/dev/null 2>&1; then
            if php-fpm -m 2>/dev/null | grep -q -E "^${EXT}\$"; then ok_fpm=true; fi
        fi
    fi

    if ! ${ok_cli} || ! ${ok_fpm}; then
        MISSING+=("${EXT}")
    fi

    printf " - %s: CLI=%s FPM=%s\n" "${EXT}" "${ok_cli}" "${ok_fpm}"
done

if [ ${#MISSING[@]} -ne 0 ]; then
    echo "⚠️ 注意：发现部分扩展在 CLI / FPM 中未同时加载： ${MISSING[*]}"
    echo "尝试安装/重装 php xml 包并重启 php-fpm..."
    sudo apt install --reinstall -y php${PHP_VERSION}-xml || true
    sudo systemctl restart php${PHP_VERSION}-fpm || true
    sleep 2
    # 再次检查
    for EXT in "${MISSING[@]}"; do
        if php -m 2>/dev/null | grep -q -E "^${EXT}\$"; then ok_cli=true; else ok_cli=false; fi
        if command -v php-fpm${PHP_VERSION} >/dev/null 2>&1; then
            if php-fpm${PHP_VERSION} -m 2>/dev/null | grep -q -E "^${EXT}\$"; then ok_fpm=true; else ok_fpm=false; fi
        fi
        printf " - %s after reinstall: CLI=%s FPM=%s\n" "${EXT}" "${ok_cli}" "${ok_fpm}"
    done
fi

# 重启服务以应用配置
echo "🔁 重启 PHP-FPM 与 Nginx..."
sudo systemctl restart php${PHP_VERSION}-fpm
sudo systemctl restart nginx

# 安装完成 / 可选 XML 导入（使用 WP-CLI，绕过 FPM 超时）
if [ -n "${XML_FILE}" ] && [ -f "${XML_FILE}" ]; then
    echo "📂 使用 WP-CLI 导入 XML（以 www-data 用户执行）..."
    sudo -u www-data wp --path="${WP_PATH}" import "${XML_FILE}" --authors=create --allow-root || {
        echo "❗ WP-CLI 导入失败，请查看 /var/log/syslog 与 wp-cli 输出"
    }
    echo "✅ XML 导入完成（若包含附件，会尝试下载）"
fi

# 最终权限与安全
echo "🔐 最终设置权限与 wp-config.php 保护..."
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;
if [ -f "${WP_PATH}/wp-config.php" ]; then
    sudo chmod 600 "${WP_PATH}/wp-config.php" || true
fi

echo
echo "🎉 安装完成！"
echo "访问站点: https://${DOMAIN}"
echo "若 Nginx 出现问题，请运行: sudo nginx -t && sudo journalctl -u nginx -n 80 --no-pager"
echo "若 PHP 扩展仍有缺失，请手动检查 apt 源或贴出 journal 日志给我，我来分析。"
echo "=============== 结束 ==============="
