#!/bin/bash
set -euo pipefail
DEBIAN_FRONTEND=noninteractive
trap 'echo "安装失败：行 $LINENO" >&2' ERR

# 交互输入
read -p "MySQL 数据库名: " DB_NAME
read -p "MySQL 用户名: " DB_USER
read -s -p "MySQL 用户密码: " DB_PASSWORD; echo
read -p "MySQL root 密码: " MYSQL_ROOT_PASSWORD
read -p "域名(如 example.com): " DOMAIN
read -p "SSL 邮箱: " SSL_EMAIL
read -p "WP 管理员用户名: " ADMIN_USER
read -s -p "WP 管理员密码: " ADMIN_PASS; echo
read -p "(可选) XML 文件路径: " XML_FILE
read -p "(可选) 主题 ZIP URL: " THEME_ZIP_URL
read -p "(可选) 主题 ZIP 本地路径: " THEME_ZIP_PATH

WP_PATH="/var/www/wordpress"
PHP_VERSION="8.3"
SWAP_SIZE="2G"

# root 检查
if [ "$(id -u)" -ne 0 ]; then echo "请用 root 运行：sudo -E bash $0" >&2; exit 1; fi

# 更新与安装基础组件
apt update -y && apt upgrade -y
apt install -y nginx mysql-server curl wget unzip software-properties-common ufw
if ! apt-cache policy php${PHP_VERSION}-fpm | grep -q Candidate; then add-apt-repository -y ppa:ondrej/php; apt update -y; fi
apt install -y \
  php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
  php${PHP_VERSION}-mysql php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
  php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-soap \
  php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-xsl \
  php${PHP_VERSION}-opcache imagemagick certbot python3-certbot-nginx

# Imagick 扩展
apt install -y php-imagick || { apt install -y php-pear php${PHP_VERSION}-dev libmagickwand-dev || true; printf "\n" | pecl install imagick || true; echo "extension=imagick" > /etc/php/${PHP_VERSION}/mods-available/imagick.ini || true; phpenmod imagick || true; }
php -r 'echo "Imagick扩展:".(extension_loaded("imagick")?"已启用\n":"未启用\n");' || true

# WP-CLI
if ! command -v wp >/dev/null 2>&1; then curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp; fi
WP_CMD="wp"; [ "$(id -u)" -eq 0 ] && WP_CMD="$WP_CMD --allow-root"

# Swap
if ! swapon --show | grep -q '^'; then fallocate -l ${SWAP_SIZE} /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab; fi

# MySQL root 与库/用户
systemctl start mysql || true
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null || sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1 || { echo "MySQL root配置失败"; exit 1; }
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# WordPress 文件
mkdir -p ${WP_PATH}
if [ ! -f "${WP_PATH}/wp-settings.php" ]; then cd /tmp && wget -q https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz && cp -a wordpress/. ${WP_PATH}; fi
FPM_USER=$(awk -F'=| ' '/^user *=/{print $NF}' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf 2>/dev/null | tail -n1 || echo www-data)
FPM_GROUP=$(awk -F'=| ' '/^group *=/{print $NF}' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf 2>/dev/null | tail -n1 || echo www-data)
chown -R ${FPM_USER}:${FPM_GROUP} ${WP_PATH}
find ${WP_PATH} -type d -exec chmod 755 {} \;
find ${WP_PATH} -type f -exec chmod 644 {} \;
mkdir -p "${WP_PATH}/wp-content/uploads" "${WP_PATH}/wp-content/tmp" "${WP_PATH}/wp-content/uploads/astra-sites" "${WP_PATH}/wp-content/uploads/ai-builder"
chown -R ${FPM_USER}:${FPM_GROUP} "${WP_PATH}/wp-content/uploads" "${WP_PATH}/wp-content/tmp"
find "${WP_PATH}/wp-content/uploads" -type d -exec chmod 755 {} \;
find "${WP_PATH}/wp-content/uploads" -type f -exec chmod 644 {} \;
chmod 755 "${WP_PATH}/wp-content/tmp"

# Nginx 全局上传与超时 + 缓存开关
cat > /etc/nginx/conf.d/wordpress-global.conf <<'NG'
client_max_body_size 1024M;
fastcgi_read_timeout 1800; fastcgi_connect_timeout 1800; fastcgi_send_timeout 1800;
client_body_timeout 1800; send_timeout 1800;
server_tokens off; etag on;
fastcgi_cache_path /var/cache/nginx/wordpress levels=1:2 keys_zone=WORDPRESS:100m inactive=60m max_size=512m;
map $http_cookie $no_cache_cookie { default 0; ~wordpress_logged_in_ 1; ~woocommerce_cart_hash 1; }
map $request_uri $no_cache_uri { default 0; ~^/wp-admin/ 1; ~^/wp-login\.php 1; ~^/xmlrpc\.php 1; ~^/wp-json 1; }
map $request_method $no_cache_method { default 0; POST 1; }
map $query_string $no_cache_query { default 0; "" 0; ~.+ 1; }
map "$no_cache_cookie$no_cache_uri$no_cache_method$no_cache_query" $skip_cache { default 0; ~.*1.* 1; }
NG

# Nginx 站点配置(80)
cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
  listen 80; server_name ${DOMAIN} www.${DOMAIN};
  root ${WP_PATH}; index index.php index.html index.htm;
  location / { try_files \$uri \$uri/ /index.php?\$args; }
  location ~ \.php\$ {
    include snippets/fastcgi-php.conf; fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name; fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
    fastcgi_cache_key \$scheme\$request_method\$host\$request_uri; fastcgi_cache_bypass \$skip_cache; fastcgi_no_cache \$skip_cache;
    fastcgi_cache WORDPRESS; fastcgi_cache_valid 200 301 302 10m; fastcgi_cache_use_stale error timeout updating http_500 http_503;
    add_header X-Cache \$upstream_cache_status always; add_header Cache-Control "public, max-age=600" always;
  }
  location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ { expires max; add_header Cache-Control "public, max-age=86400" always; log_not_found off; }
}
EOF

[ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default || true
mkdir -p /var/cache/nginx/wordpress && chown -R ${FPM_USER}:${FPM_GROUP} /var/cache/nginx || true
nginx -t && systemctl reload nginx

# PHP 配置
for INI in /etc/php/${PHP_VERSION}/{fpm,cli}/php.ini; do [ -f "$INI" ] || continue;
  sed -i -E "s|^upload_max_filesize.*|upload_max_filesize = 1024M|" "$INI";
  sed -i -E "s|^post_max_size.*|post_max_size = 1024M|" "$INI";
  sed -i -E "s|^memory_limit.*|memory_limit = 512M|" "$INI";
  sed -i -E "s|^max_execution_time.*|max_execution_time = 1800|" "$INI";
  sed -i -E "s|^max_input_time.*|max_input_time = 1800|" "$INI";
  grep -q "^max_input_vars" "$INI" || echo "max_input_vars = 10000" >> "$INI";
  grep -q "^upload_tmp_dir" "$INI" && sed -i -E "s|^upload_tmp_dir.*|upload_tmp_dir = ${WP_PATH}/wp-content/tmp|" "$INI" || echo "upload_tmp_dir = ${WP_PATH}/wp-content/tmp" >> "$INI";
  grep -q "^cgi\.fix_pathinfo" "$INI" && sed -i -E "s|^cgi\.fix_pathinfo.*|cgi.fix_pathinfo=0|" "$INI" || echo "cgi.fix_pathinfo=0" >> "$INI";
done
sed -i -E "s|^;?request_terminate_timeout.*|request_terminate_timeout = 1800|" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf || true

# OPcache
for OPC in /etc/php/${PHP_VERSION}/fpm/conf.d/zz-opcache.ini /etc/php/${PHP_VERSION}/cli/conf.d/zz-opcache.ini; do cat > "$OPC" <<OPC
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

# WP-CLI 安装/配置
if [ ! -f "${WP_PATH}/wp-config.php" ]; then
${WP_CMD} --path="${WP_PATH}" config create --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASSWORD}" --dbhost=localhost --skip-check --force --extra-php <<'PHP'
define('FS_METHOD','direct');
define('WP_MEMORY_LIMIT','512M');
define('DISABLE_WP_CRON', true);
PHP
else
  ${WP_CMD} --path="${WP_PATH}" config set FS_METHOD direct --type=constant --raw --quiet || true
  ${WP_CMD} --path="${WP_PATH}" config set WP_MEMORY_LIMIT 512M --type=constant --raw --quiet || true
  ${WP_CMD} --path="${WP_PATH}" config set DISABLE_WP_CRON true --type=constant --raw --quiet || true
fi

if ! ${WP_CMD} --path="${WP_PATH}" core is-installed >/dev/null 2>&1; then
${WP_CMD} --path="${WP_PATH}" core install \
  --url="http://${DOMAIN}" --title="My Site" \
  --admin_user="${ADMIN_USER}" --admin_password="${ADMIN_PASS}" --admin_email="${SSL_EMAIL}"
fi
${WP_CMD} --path="${WP_PATH}" option update permalink_structure "/%postname%/" || true
${WP_CMD} --path="${WP_PATH}" rewrite flush --hard || true

# 主题安装（可选）
if [ -n "${THEME_ZIP_PATH}" ] && [ -f "${THEME_ZIP_PATH}" ]; then ${WP_CMD} --path="${WP_PATH}" theme install "${THEME_ZIP_PATH}" --activate || true; elif [ -n "${THEME_ZIP_URL}" ]; then ${WP_CMD} --path="${WP_PATH}" theme install "${THEME_ZIP_URL}" --activate || true; fi

# XML 导入（可选）
if [ -n "${XML_FILE}" ] && [ -f "${XML_FILE}" ]; then ${WP_CMD} --path="${WP_PATH}" plugin install wordpress-importer --activate || true; ${WP_CMD} --path="${WP_PATH}" import "${XML_FILE}" --authors=create --skip="media" || ${WP_CMD} --path="${WP_PATH}" import "${XML_FILE}" --authors=create || true; fi

# 系统 Cron（替代 DISABLE_WP_CRON=true）
echo "*/5 * * * * ${FPM_USER} /usr/bin/php -d register_argc_argv=On ${WP_PATH}/wp-cron.php >/dev/null 2>&1" > /etc/cron.d/wordpress
chmod 644 /etc/cron.d/wordpress
systemctl reload cron || systemctl restart cron || true

# 防火墙
ufw allow 'Nginx Full' || { ufw allow 80/tcp || true; ufw allow 443/tcp || true; }
ufw allow OpenSSH || ufw allow 22/tcp || true
ufw --force enable || true
ufw reload || true

# SSL 与 443 加固
certbot --nginx -d "${DOMAIN}" -m "${SSL_EMAIL}" --agree-tos --redirect -n || echo "SSL申请失败，稍后重试"
for SSL_CONF in "/etc/nginx/conf.d/${DOMAIN}.conf" "/etc/nginx/conf.d/${DOMAIN}-le-ssl.conf"; do
  if [ -f "$SSL_CONF" ] && grep -q "listen 443" "$SSL_CONF"; then
    grep -q "client_max_body_size" "$SSL_CONF" || sed -i '/listen 443/a \\    client_max_body_size 1024M;\\n    fastcgi_read_timeout 1800;\\n    fastcgi_connect_timeout 1800;\\n    fastcgi_send_timeout 1800;\\n    client_body_timeout 1800;\\n    send_timeout 1800;' "$SSL_CONF"
    grep -q "X-Cache-Enabled" "$SSL_CONF" || sed -i '/location ~ \\\.php\\\$ {/a \\        fastcgi_param HTTP_AUTHORIZATION \\$http_authorization;\\n        fastcgi_cache_key \\$scheme\\$request_method\\$host\\$request_uri;\\n        fastcgi_cache_bypass \\$skip_cache;\\n        fastcgi_no_cache \\$skip_cache;\\n        fastcgi_cache WORDPRESS;\\n        fastcgi_cache_valid 200 301 302 10m;\\n        fastcgi_cache_use_stale error timeout updating http_500 http_503;\\n        add_header X-Cache \\$upstream_cache_status always;\\n        add_header Cache-Control "public, max-age=600" always;' "$SSL_CONF"
  fi
done
nginx -t && systemctl reload nginx || true

# 切换站点到 https
${WP_CMD} --path="${WP_PATH}" option update home "https://${DOMAIN}" || true
${WP_CMD} --path="${WP_PATH}" option update siteurl "https://${DOMAIN}" || true
systemctl restart php${PHP_VERSION}-fpm || true

# 输出
echo "WordPress 安装完成"
echo "URL: https://${DOMAIN}"
echo "WP_PATH: ${WP_PATH}"
echo "DB: ${DB_NAME} 用户: ${DB_USER}"
echo "管理员: ${ADMIN_USER}"
