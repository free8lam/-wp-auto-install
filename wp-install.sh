#!/bin/bash
set -euo pipefail

# ==============================
# 🚀 WordPress 终极自动部署 v4.2（稳定加强版）
# PHP 8.3 + Nginx/SSL 优化 + WP-CLI 初始化 + 可选主题/内容导入
# 一键完成：系统依赖 → MySQL → WordPress → Nginx/SSL → PHP 优化 → WP 安装
# ==============================

DEBIAN_FRONTEND=noninteractive

# 必须以 root 运行
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 用户运行：sudo -E bash $0" >&2
  exit 1
fi

# 打印错误行号，便于定位
trap 'echo "❌ 安装失败（行 $LINENO）。请检查上方输出。" >&2' ERR

# === 用户输入 ===
read -p "请输入 MySQL 数据库名: " DB_NAME
read -p "请输入 MySQL 用户名: " DB_USER
read -s -p "请输入 MySQL 用户密码: " DB_PASSWORD; echo
read -p "请输入 MySQL root 用户密码（将重置/设置）: " MYSQL_ROOT_PASSWORD
read -p "请输入网站域名(如 example.com): " DOMAIN
read -p "请输入申请 SSL 证书邮箱: " SSL_EMAIL
read -p "请输入 WordPress 管理员用户名: " ADMIN_USER
read -s -p "请输入 WordPress 管理员密码: " ADMIN_PASS; echo
read -p "(可选) 请输入 XML 文件路径（留空跳过）: " XML_FILE
read -p "(可选) 请输入主题 ZIP 的 URL（留空跳过）: " THEME_ZIP_URL
read -p "(可选) 请输入服务器本地主题 ZIP 路径（留空跳过）: " THEME_ZIP_PATH

WP_PATH="/var/www/wordpress"
PHP_VERSION="8.3"
SWAP_SIZE="2G"

echo "=============== 🚀 开始安装 WordPress ==============="

# ---------------- 系统更新 ----------------
echo "🔄 更新系统..."
apt update -y && apt upgrade -y

# ---------------- 安装依赖 ----------------
echo "📦 安装 Nginx、MySQL、基础工具..."
apt install -y nginx mysql-server curl wget unzip software-properties-common || true

# 确保 PHP 8.3 软件源可用（若系统默认无 8.3，则添加 PPA）
if ! apt-cache search "php${PHP_VERSION}-fpm" | grep -q "php${PHP_VERSION}-fpm"; then
  echo "📦 添加 PHP PPA 仓库..."
  add-apt-repository -y ppa:ondrej/php
  apt update -y
fi

echo "📦 安装 PHP 8.3 及扩展..."
apt install -y \
  php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
  php${PHP_VERSION}-mysql php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
  php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-soap \
  php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-xsl \
  php${PHP_VERSION}-opcache \
  imagemagick
apt install -y certbot python3-certbot-nginx

# 尝试安装并启用 PHP Imagick 扩展（WordPress 站点健康推荐）
echo "🧩 安装并启用 PHP Imagick 扩展..."
if apt install -y php-imagick; then
  phpenmod imagick || true
else
  echo "⚠️ apt 未能安装 php-imagick，尝试通过 PECL 构建..."
  apt install -y php-pear php${PHP_VERSION}-dev libmagickwand-dev || true
  # 非交互安装 imagick 扩展
  printf "\n" | pecl install imagick || true
  echo "extension=imagick" > /etc/php/${PHP_VERSION}/mods-available/imagick.ini || true
  phpenmod imagick || true
fi
# 先测试 CLI 下是否已加载（FPM 稍后会统一重启）
php -r 'echo "Imagick 扩展: ".(extension_loaded("imagick")?"已加载\n":"未加载\n");' || true

# ---------------- 安装 WP-CLI ----------------
if ! command -v wp &> /dev/null; then
  echo "⚙️ 安装 WP-CLI..."
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/local/bin/wp
fi

WP_CMD="wp"
if [ "$(id -u)" -eq 0 ]; then
  WP_CMD="$WP_CMD --allow-root"
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

systemctl is-active --quiet mysql || {
  echo "🔄 MySQL 服务未运行，正在启动..."
  systemctl start mysql
  sleep 3
}

echo "🔑 设置/重置 MySQL root 密码..."
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null || true
if ! mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
  echo "⚠️ 尝试使用 sudo 提升权限设置 root 密码..."
  sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
fi

if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
  echo "✅ MySQL root 密码设置成功"
else
  echo "❌ 无法设置 MySQL root 密码，请手动配置后重试"; exit 1
fi

echo "🗄️ 创建数据库与用户..."
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# ---------------- 安装 WordPress ----------------
echo "⬇️ 下载并安装 WordPress..."
mkdir -p ${WP_PATH}
if [ ! -f "${WP_PATH}/wp-settings.php" ]; then
  cd /tmp && wget -q https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz
  cp -a wordpress/. ${WP_PATH}
else
  echo "ℹ️ 检测到 WordPress 文件已存在，跳过下载与复制。"
fi
chown -R www-data:www-data ${WP_PATH}
find ${WP_PATH} -type d -exec chmod 755 {} \;
find ${WP_PATH} -type f -exec chmod 644 {} \;

# ---------------- Nginx 全局上传/超时配置 ----------------
echo "🌐 写入 Nginx 全局上传与超时配置..."
cat > /etc/nginx/conf.d/_global_upload.conf <<'EOF'
client_max_body_size 1024M;
fastcgi_read_timeout 1800;
fastcgi_buffers 16 16k;
fastcgi_buffer_size 32k;
fastcgi_connect_timeout 1800;
fastcgi_send_timeout 1800;
client_body_timeout 1800;
send_timeout 1800;
server_tokens off;
etag on;

fastcgi_cache_path /var/cache/nginx/wordpress levels=1:2 keys_zone=WORDPRESS:100m inactive=60m max_size=500m;
map $http_cookie $no_cache_cookie {
    default 0;
    ~wordpress_logged_in_ 1;
    ~woocommerce_cart_hash 1;
    ~wp-postpass_ 1;
    ~comment_author_ 1;
}
map $request_uri $no_cache_uri {
    default 0;
    ~^/wp-admin/ 1;
    ~^/wp-login\.php 1;
    ~^/xmlrpc\.php 1;
    ~^/wp-json 1;
}
map $request_method $no_cache_method { default 0; POST 1; }
map $query_string $no_cache_query { default 0; "" 0; ~.+ 1; }
map "$no_cache_cookie$no_cache_uri$no_cache_method$no_cache_query" $skip_cache {
    default 0;
    ~.*1.* 1;
}
EOF

# ---------------- Nginx 站点配置(80) ----------------
echo "🌐 配置 Nginx 80 端口站点..."
cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${WP_PATH};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
        fastcgi_cache_key \$scheme\$request_method\$host\$request_uri;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 301 302 10m;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        add_header X-Cache \$upstream_cache_status always;
        add_header X-Cache-Enabled "true" always;
        add_header Cache-Control "public, max-age=600" always;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        add_header Cache-Control "public, max-age=86400" always;
        log_not_found off;
    }
}
EOF

# 移除默认站点以避免冲突
if [ -f /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default || true
fi
nginx -t && systemctl reload nginx
# 创建 Nginx 缓存目录
mkdir -p /var/cache/nginx/wordpress || true
chown -R www-data:www-data /var/cache/nginx || true

# ---------------- PHP 优化 ----------------
echo "⚙️ 优化 PHP 配置..."
for INI in /etc/php/${PHP_VERSION}/{fpm,cli}/php.ini; do
  if [ -f "$INI" ]; then
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 1024M/" "$INI"
    sed -i "s/^post_max_size.*/post_max_size = 1024M/" "$INI"
    sed -i "s/^memory_limit.*/memory_limit = 512M/" "$INI"
    sed -i "s/^max_execution_time.*/max_execution_time = 1800/" "$INI"
    sed -i "s/^max_input_time.*/max_input_time = 1800/" "$INI"
    grep -q "^max_input_vars" "$INI" || echo "max_input_vars = 10000" >> "$INI"
    grep -q "^upload_tmp_dir" "$INI" || echo "upload_tmp_dir = ${WP_PATH}/wp-content/tmp" >> "$INI"
    # 安全性：禁用不安全路径信息
    if grep -q "^cgi\.fix_pathinfo" "$INI"; then
      sed -i "s/^cgi\.fix_pathinfo.*/cgi.fix_pathinfo=0/" "$INI"
    else
      echo "cgi.fix_pathinfo=0" >> "$INI"
    fi
  else
    echo "⚠️ 配置文件不存在: $INI"
  fi
done

# 预创建上传临时目录，确保 FPM 重启前权限正确
mkdir -p "${WP_PATH}/wp-content/tmp" || true
chown -R www-data:www-data "${WP_PATH}/wp-content" || true
chmod -R 775 "${WP_PATH}/wp-content" || true

# OPcache 性能优化
for OPC in /etc/php/${PHP_VERSION}/fpm/conf.d/zz-opcache.ini /etc/php/${PHP_VERSION}/cli/conf.d/zz-opcache.ini; do
  cat > "$OPC" <<OPC
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
OPC
done
phpenmod opcache || true
systemctl restart php${PHP_VERSION}-fpm

# ---------------- WP-CLI 配置与安装 ----------------
echo "🧩 通过 WP-CLI 配置并安装 WordPress..."
if [ ! -f "${WP_PATH}/wp-config.php" ]; then
$WP_CMD --path="$WP_PATH" config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost=localhost --skip-check --force --extra-php <<'PHP'
define('FS_METHOD','direct');
define('WP_MEMORY_LIMIT','512M');
define('DISABLE_WP_CRON', true);
PHP
else
  $WP_CMD --path="$WP_PATH" config set FS_METHOD direct --type=constant --raw --quiet || true
  $WP_CMD --path="$WP_PATH" config set WP_MEMORY_LIMIT 512M --type=constant --raw --quiet || true
  $WP_CMD --path="$WP_PATH" config set DISABLE_WP_CRON true --type=constant --raw --quiet || true
fi

if ! $WP_CMD --path="$WP_PATH" core is-installed >/dev/null 2>&1; then
$WP_CMD --path="$WP_PATH" core install \
  --url="http://${DOMAIN}" \
  --title="My Site" \
  --admin_user="$ADMIN_USER" \
  --admin_password="$ADMIN_PASS" \
  --admin_email="$SSL_EMAIL"
else
  echo "ℹ️ 检测到 WordPress 已安装，跳过 core install。"
fi

# 固化固定链接结构
$WP_CMD --path="$WP_PATH" option update permalink_structure "/%postname%/"
$WP_CMD --path="$WP_PATH" rewrite flush --hard

# 上传目录权限（tmp 已预创建，此处补充 uploads）
mkdir -p "$WP_PATH/wp-content/uploads" || true

# ---------------- 可选：安装并激活主题 ----------------
if [ -n "${THEME_ZIP_PATH}" ] && [ -f "${THEME_ZIP_PATH}" ]; then
  echo "🎨 安装本地主题包: ${THEME_ZIP_PATH}"
  $WP_CMD --path="$WP_PATH" theme install "${THEME_ZIP_PATH}" --activate || true
elif [ -n "${THEME_ZIP_URL}" ]; then
  echo "🎨 安装远程主题包: ${THEME_ZIP_URL}"
  $WP_CMD --path="$WP_PATH" theme install "${THEME_ZIP_URL}" --activate || true
else
  echo "ℹ️ 未提供主题包，跳过主题安装。可稍后后台或 WP‑CLI 安装。"
fi

# ---------------- 可选：导入 XML 内容 ----------------
if [[ -n "${XML_FILE}" && -f "${XML_FILE}" ]]; then
  echo "📦 安装导入插件并导入 XML 内容..."
  $WP_CMD --path="$WP_PATH" plugin install wordpress-importer --activate || true
  # 优先跳过媒体以加速，如需媒体则移除 --skip="media"
  $WP_CMD --path="$WP_PATH" import "${XML_FILE}" --authors=create --skip="media" || $WP_CMD --path="$WP_PATH" import "${XML_FILE}" --authors=create || true
fi

# ---------------- 防火墙（开放 80/443） ----------------
echo "🔓 开放 80/443 端口（UFW）..."
if command -v ufw >/dev/null 2>&1; then
  # 优先使用 Nginx Full 应用档案（一次性开放 80/443）
  ufw allow 'Nginx Full' || { ufw allow 80/tcp || true; ufw allow 443/tcp || true; }
  # 确保 SSH 不被阻断
  ufw allow OpenSSH || ufw allow 22/tcp || true
  ufw --force enable || true
  ufw reload || true
else
  apt install -y ufw
  ufw allow 'Nginx Full' || { ufw allow 80/tcp || true; ufw allow 443/tcp || true; }
  ufw allow OpenSSH || ufw allow 22/tcp || true
  ufw --force enable || true
  ufw reload || true
fi

# ---------------- SSL（HTTPS） ----------------
echo "🔐 申请并启用 SSL (Let’s Encrypt)..."
certbot --nginx -d "${DOMAIN}" -m "${SSL_EMAIL}" --agree-tos --redirect -n || echo "⚠️ SSL 自动申请失败，请稍后重试"

# 同步 HTTPS 443 站点上传/超时限制（若 Certbot 新增了 443 server 块）
for SSL_CONF in "/etc/nginx/conf.d/${DOMAIN}.conf" "/etc/nginx/conf.d/${DOMAIN}-le-ssl.conf"; do
  if [ -f "$SSL_CONF" ] && grep -q "listen 443" "$SSL_CONF"; then
    if ! grep -q "client_max_body_size" "$SSL_CONF"; then
      sed -i '/listen 443/a \    client_max_body_size 1024M;\n    fastcgi_read_timeout 1800;\n    fastcgi_connect_timeout 1800;\n    fastcgi_send_timeout 1800;\n    fastcgi_buffers 16 16k;\n    fastcgi_buffer_size 32k;\n    client_body_timeout 1800;\n    send_timeout 1800;' "$SSL_CONF"
    fi
    # 在 443 配置的 PHP 位置中注入缓存与授权头传递
    if grep -q "location ~ \\\.php\\$" "$SSL_CONF"; then
      if ! grep -q "X-Cache-Enabled" "$SSL_CONF"; then
        sed -i '/location ~ \\\.php\\$ {/a \        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;\n        fastcgi_cache_key \$scheme\$request_method\$host\$request_uri;\n        fastcgi_cache_bypass \$skip_cache;\n        fastcgi_no_cache \$skip_cache;\n        fastcgi_cache WORDPRESS;\n        fastcgi_cache_valid 200 301 302 10m;\n        fastcgi_cache_use_stale error timeout updating http_500 http_503;\n        add_header X-Cache \$upstream_cache_status always;\n        add_header X-Cache-Enabled "true" always;\n        add_header Cache-Control "public, max-age=600" always;' "$SSL_CONF"
      fi
    fi
  fi
done
nginx -t && systemctl reload nginx || true

# 将站点地址切换为 https，避免后台操作混用 http 导致 nonce 问题
$WP_CMD --path="$WP_PATH" option update home "https://${DOMAIN}" || true
$WP_CMD --path="$WP_PATH" option update siteurl "https://${DOMAIN}" || true

# 再次重启 PHP-FPM，确保一切生效
systemctl restart php${PHP_VERSION}-fpm || true

# ---------------- 完成 ----------------
echo "🎉 WordPress 安装完成！"
echo "🌍 访问: https://${DOMAIN}"
echo "📁 路径: ${WP_PATH}"
echo "✅ 数据库: ${DB_NAME}"
echo "👤 数据库用户: ${DB_USER}"
echo "👑 管理员: ${ADMIN_USER}"
echo "==============================================="
