#!/bin/bash
set -euo pipefail
DEBIAN_FRONTEND=noninteractive
trap 'echo "安装失败：行 $LINENO" >&2' ERR

# 交互输入（先占位，稍后根据检测补齐；支持环境变量预置）
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
DOMAIN="${DOMAIN:-}"
SSL_EMAIL="${SSL_EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
XML_FILE="${XML_FILE:-}"
THEME_ZIP_URL="${THEME_ZIP_URL:-}"
THEME_ZIP_PATH="${THEME_ZIP_PATH:-}"

WP_PATH="/var/www/wordpress"
PHP_VERSION="8.3"
SWAP_SIZE="2G"

# root 检查
if [ "$(id -u)" -ne 0 ]; then echo "请用 root 运行：sudo -E bash $0" >&2; exit 1; fi

# 更新与安装基础组件
apt update -y && apt upgrade -y
apt install -y nginx mysql-server curl wget unzip software-properties-common ufw
# 确保 PHP 版本可用（网络/DNS不通时跳过添加 PPA 并自动降级）
ensure_php_version() {
  local want="$PHP_VERSION"
  # 候选存在则直接使用
  if apt-cache policy "php${want}-fpm" | awk '/Candidate:/{print $2}' | grep -vq "(none)"; then
    return 0
  fi
  # 网络可用时尝试添加 PPA
  if getent hosts api.launchpad.net >/dev/null 2>&1 || getent hosts ppa.launchpad.net >/dev/null 2>&1; then
    add-apt-repository -y ppa:ondrej/php && apt update -y || echo "PPA 添加失败，继续尝试可用版本"
  else
    echo "DNS/网络不可用，跳过添加 PPA：ondrej/php"
  fi
  # 选择最高可用的 PHP 版本
  local avail
  avail="$(apt-cache search '^php[0-9.]+-fpm$' | sed -n 's/^php\([0-9]\+\.[0-9]\+\)-fpm.*/\1/p' | sort -Vr)"
  for v in $avail; do
    if apt-cache policy "php${v}-fpm" | awk '/Candidate:/{print $2}' | grep -vq "(none)"; then
      PHP_VERSION="$v"; export PHP_VERSION
      echo "使用可用的 PHP 版本: ${PHP_VERSION}"
      return 0
    fi
  done
  echo "未找到可用的 PHP-FPM 包，无法继续。" >&2
  exit 1
}
ensure_php_version
apt install -y \
  php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
  php${PHP_VERSION}-mysql php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
  php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-soap \
  php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-xsl \
  php${PHP_VERSION}-opcache imagemagick certbot python3-certbot-nginx

# Imagick 扩展（更稳健的安装与启用）
ensure_imagick_loaded() {
  local phpv="${PHP_VERSION}"
  local php_bin="$(command -v php${PHP_VERSION} || command -v php)"
  local phpize_bin="$(command -v phpize${PHP_VERSION} || command -v phpize || echo '')"
  local php_config_bin="$(command -v php-config${PHP_VERSION} || command -v php-config || echo '')"

  # 先尝试 apt 安装 imagick
  apt install -y php-imagick >/dev/null 2>&1 || true

  # 创建并启用 ini（分别针对 fpm 与 cli）
  local mods="/etc/php/${phpv}/mods-available/imagick.ini"
  [ -f "$mods" ] || echo "extension=imagick" > "$mods"
  phpenmod -v "${phpv}" -s fpm imagick || ln -sf "$mods" "/etc/php/${phpv}/fpm/conf.d/20-imagick.ini" || true
  phpenmod -v "${phpv}" -s cli imagick || ln -sf "$mods" "/etc/php/${phpv}/cli/conf.d/20-imagick.ini" || true
  systemctl restart "php${phpv}-fpm" || true

  # 若 CLI 仍未加载或 FPM 报错（ABI 不匹配），强制用目标版本工具链重新编译安装
  if ! $php_bin -r 'exit(extension_loaded("imagick")?0:1);'; then
    # 临时禁用以清除启动警告
    phpdismod -v "${phpv}" -s fpm imagick || true
    phpdismod -v "${phpv}" -s cli imagick || true

    apt install -y php-pear "php${PHP_VERSION}-dev" libmagickwand-dev || true
    if [ -x "$phpize_bin" ] && [ -x "$php_config_bin" ]; then
      local tmpdir
      tmpdir="$(mktemp -d)"
      (
        cd "$tmpdir" && pecl download imagick >/dev/null 2>&1 && \
        tar -xzf imagick-*.tgz && cd imagick-* && \
        "$phpize_bin" && ./configure --with-php-config="$php_config_bin" && \
        make -j"$(nproc 2>/dev/null || echo 2)" && make install
      ) || true
      rm -rf "$tmpdir"
    else
      # 无法定位版本专属 phpize/php-config，则回退普通 pecl（可能失败）
      yes '' | pecl install imagick || true
    fi

    # 重新启用 ini 并重启 FPM
    [ -f "$mods" ] || echo "extension=imagick" > "$mods"
    phpenmod -v "${phpv}" -s fpm imagick || ln -sf "$mods" "/etc/php/${phpv}/fpm/conf.d/20-imagick.ini" || true
    phpenmod -v "${phpv}" -s cli imagick || ln -sf "$mods" "/etc/php/${phpv}/cli/conf.d/20-imagick.ini" || true
    systemctl restart "php${phpv}-fpm" || {
      echo "PHP-FPM 重启失败（可能 imagick ABI 不匹配），回滚 imagick.ini 以恢复服务" >&2
      rm -f "/etc/php/${phpv}/fpm/conf.d/20-imagick.ini" "/etc/php/${phpv}/cli/conf.d/20-imagick.ini" || true
      systemctl restart "php${phpv}-fpm" || true
    }
  fi

  # 打印 CLI 状态
  $php_bin -r 'echo "CLI Imagick:".(extension_loaded("imagick")?"启用\n":"未启用\n");' || true
}
ensure_imagick_loaded
PHP_BIN_EARLY="$(command -v php${PHP_VERSION} || command -v php || true)"; [ -z "$PHP_BIN_EARLY" ] && PHP_BIN_EARLY="php"
"$PHP_BIN_EARLY" -r 'echo "Imagick扩展:".(extension_loaded("imagick")?"已启用\n":"未启用\n");' || true

# WP-CLI
if ! command -v wp >/dev/null 2>&1; then curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp; fi
WP_CMD="wp"; [ "$(id -u)" -eq 0 ] && WP_CMD="$WP_CMD --allow-root"
WP_CMD_SAFE="$WP_CMD --skip-plugins --skip-themes"
# 统一 WP-CLI PHP 版本并确保 mysqli 扩展可用
PHP_BIN="$(command -v php${PHP_VERSION} || true)"
if [ -z "$PHP_BIN" ]; then PHP_BIN="$(command -v php)"; fi
export WP_CLI_PHP="$PHP_BIN"
update-alternatives --set php "$PHP_BIN" >/dev/null 2>&1 || true
if ! "$PHP_BIN" -r 'exit(extension_loaded("mysqli")?0:1);'; then
  apt install -y "php${PHP_VERSION}-mysql" || true
  phpenmod mysqli || true
  phpenmod pdo_mysql || true
  phpenmod mysqlnd || true
  systemctl restart "php${PHP_VERSION}-fpm" || true
  if ! "$PHP_BIN" -r 'exit(extension_loaded("mysqli")?0:1);'; then
    echo "错误：CLI 环境缺少 mysqli 扩展，无法继续 WP 安装。" >&2
    "$PHP_BIN" -m || true
    exit 1
  fi
fi

# 安装检测与修复模式
REPAIR_MODE=0
get_cfg() { ${WP_CMD_SAFE} --path="${WP_PATH}" config get "$1" 2>/dev/null || true; }
is_installed=0
: # 跳过仅以文件存在判定安装状态，改用 WP-CLI 真实检测
if ${WP_CMD_SAFE} --path="${WP_PATH}" core is-installed >/dev/null 2>&1; then is_installed=1; fi
if [ "$is_installed" -eq 1 ]; then
  REPAIR_MODE=1
  echo "检测到已安装的 WordPress，进入修复模式"
  CFG_DB_NAME="$(get_cfg DB_NAME)"; [ -n "$CFG_DB_NAME" ] && DB_NAME="$CFG_DB_NAME"
  CFG_DB_USER="$(get_cfg DB_USER)"; [ -n "$CFG_DB_USER" ] && DB_USER="$CFG_DB_USER"
  CFG_DB_PASSWORD="$(get_cfg DB_PASSWORD)"; [ -n "$CFG_DB_PASSWORD" ] && DB_PASSWORD="$CFG_DB_PASSWORD"
  SITEURL="$(${WP_CMD_SAFE} --path="${WP_PATH}" option get siteurl 2>/dev/null || ${WP_CMD_SAFE} --path="${WP_PATH}" option get home 2>/dev/null || echo "")"
  if [ -z "${DOMAIN}" ] && [ -n "${SITEURL}" ]; then DOMAIN="$(echo "${SITEURL}" | awk -F[/:] '{print $4}')"; fi
else
  echo "未检测到现有安装，进行全新安装"
fi

# 根据检测结果补齐交互输入（仅对缺失项提示）
cfg_file() { local k="$1"; local f="${WP_PATH}/wp-config.php"; [ -f "$f" ] || return 0; sed -nE "s/.*define\(['\"]${k}['\"],\s*['\"]([^'\"]+)['\"]\).*/\1/p" "$f"; }
# 优先从 wp-config.php 填充数据库参数，避免已安装环境重复输入
[ -z "${DB_NAME}" ] && DB_NAME="$(cfg_file DB_NAME)"
[ -z "${DB_USER}" ] && DB_USER="$(cfg_file DB_USER)"
[ -z "${DB_PASSWORD}" ] && DB_PASSWORD="$(cfg_file DB_PASSWORD)"

if [ "$is_installed" -eq 0 ]; then
  # 全新安装：仅对缺失项进行提示
  [ -z "${DB_NAME}" ] && read -p "MySQL 数据库名: " DB_NAME
  [ -z "${DB_USER}" ] && read -p "MySQL 用户名: " DB_USER
  if [ -z "${DB_PASSWORD}" ]; then read -s -p "MySQL 用户密码: " DB_PASSWORD; echo; fi
  # root 密码可留空，仅用于某些环境的第三回退
  if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then read -p "MySQL root 密码(留空则跳过): " MYSQL_ROOT_PASSWORD; fi
  [ -z "${DOMAIN}" ] && read -p "域名(如 example.com): " DOMAIN
  [ -z "${SSL_EMAIL}" ] && read -p "SSL 邮箱: " SSL_EMAIL
  [ -z "${ADMIN_USER}" ] && read -p "WP 管理员用户名: " ADMIN_USER
  if [ -z "${ADMIN_PASS}" ]; then read -s -p "WP 管理员密码: " ADMIN_PASS; echo; fi
  # 可选项（仅全新安装时询问一次）
  [ -z "${XML_FILE}" ] && read -p "(可选) XML 文件路径: " XML_FILE
  [ -z "${THEME_ZIP_URL}" ] && read -p "(可选) 主题 ZIP URL: " THEME_ZIP_URL
  [ -z "${THEME_ZIP_PATH}" ] && read -p "(可选) 主题 ZIP 本地路径: " THEME_ZIP_PATH
else
  # 修复模式：不再询问已存在信息，仅在缺失且必要时处理域名
  [ -z "${DOMAIN}" ] && [ -n "${SITEURL}" ] && DOMAIN="$(echo "${SITEURL}" | awk -F[/:] '{print $4}')"
  # DOMAIN 缺失则跳过 SSL 与 URL 更新
fi

# Swap
if ! swapon --show | grep -q '^'; then fallocate -l ${SWAP_SIZE} /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab; fi

# MySQL 数据库与用户创建（不强制修改 root，多重登录回退）
systemctl start mysql || true
MYSQL_MAINT="/etc/mysql/debian.cnf"

mysql_try() {
  local sql="$1"
  # 1) 维护用户（debian-sys-maint）
  if [ -r "$MYSQL_MAINT" ]; then
    mysql --defaults-file="$MYSQL_MAINT" -e "$sql" && return 0
  fi
  # 2) 本机root（auth_socket/unix_socket）
  if command -v mysql >/dev/null 2>&1; then
    sudo mysql -e "$sql" && return 0
  fi
  # 3) root + 你输入的密码（若已设置）
  if [ -n "${MYSQL_ROOT_PASSWORD}" ]; then mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "$sql" && return 0; fi
  return 1
}

# 仅当数据库参数齐全时才创建/授权，修复模式下缺失则跳过
if [ -n "${DB_NAME}" ] && [ -n "${DB_USER}" ] && [ -n "${DB_PASSWORD}" ]; then
  if ! mysql_try "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"; then
    echo "无法创建数据库：请确认维护用户文件、sudo mysql或root密码有效。" >&2
    exit 1
  fi
  mysql_try "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';" || {
    mysql_try "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';" || { echo "无法创建/更新 MySQL 业务用户 '${DB_USER}'" >&2; exit 1; }
  }
  mysql_try "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" || { echo "授予权限失败" >&2; exit 1; }
else
  echo "跳过数据库创建：未检测到完整的 DB_NAME/DB_USER/DB_PASSWORD（修复模式无需）。"
fi

# 若 root 密码已知且可登录，则统一其认证插件为 mysql_native_password（仅在成功登录时执行）
if [ -n "${MYSQL_ROOT_PASSWORD}" ] && mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
fi

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
if [ -n "${DOMAIN}" ]; then
cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
  listen 80; server_name ${DOMAIN} www.${DOMAIN};
  if (\$host = "www.${DOMAIN}") { return 301 https://${DOMAIN}\$request_uri; }
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
fi

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
# 确保 FPM 请求超时配置存在
if ! grep -q "^request_terminate_timeout" "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"; then
  echo "request_terminate_timeout = 1800" >> "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
fi
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
define('FORCE_SSL_ADMIN', false);
PHP
else
  # 纠正 wp-config.php 中可能存在的未加引号常量（由旧脚本或错误参数产生）
  sed -i -E "s|define\(\s*'FS_METHOD'\s*,\s*direct\s*\)|define('FS_METHOD','direct')|g" "${WP_PATH}/wp-config.php" || true
  sed -i -E "s|define\(\s*'WP_MEMORY_LIMIT'\s*,\s*([0-9]+M)\s*\)|define('WP_MEMORY_LIMIT','\\1')|g" "${WP_PATH}/wp-config.php" || true
  # 正确写入：字符串不使用 --raw，布尔值才使用 --raw
  ${WP_CMD_SAFE} --path="${WP_PATH}" config set FS_METHOD direct --type=constant --quiet || true
${WP_CMD_SAFE} --path="${WP_PATH}" config set WP_MEMORY_LIMIT 512M --type=constant --quiet || true
${WP_CMD_SAFE} --path="${WP_PATH}" config set DISABLE_WP_CRON true --type=constant --raw --quiet || true
${WP_CMD_SAFE} --path="${WP_PATH}" config set FORCE_SSL_ADMIN false --type=constant --raw --quiet || true
fi

# 预检：确认 PHP 模块与数据库连接可用（避免安装阶段失败）
export DB_HOST="localhost"
export DB_NAME DB_USER DB_PASSWORD
if ! "$PHP_BIN" -r 'exit(extension_loaded("mysqli")?0:1);'; then
  echo "错误：CLI 缺少 mysqli 扩展" >&2
  "$PHP_BIN" -m | egrep -i 'mysql|mysqli|pdo_mysql' || true
  exit 1
fi
if [ -n "${DB_NAME}" ] && [ -n "${DB_USER}" ] && [ -n "${DB_PASSWORD}" ]; then
  "$PHP_BIN" -r '$h=getenv("DB_HOST")?:"localhost"; $u=getenv("DB_USER"); $p=getenv("DB_PASSWORD"); $d=getenv("DB_NAME"); $m=@new mysqli($h,$u,$p,$d); if($m->connect_errno){fwrite(STDERR,"DB连接失败:".$m->connect_error."\n"); exit(1);} echo "DB连接正常\n";'
else
  echo "跳过DB连接预检：缺少 DB_NAME/DB_USER/DB_PASSWORD（修复模式可跳过）"
fi

# 仅在未安装时才执行核心安装；修复模式绝不触发该步骤
if [ "$is_installed" -eq 0 ]; then
  if [ -z "${DOMAIN}" ] || [ -z "${ADMIN_USER}" ] || [ -z "${ADMIN_PASS}" ] || [ -z "${SSL_EMAIL}" ]; then
    echo "错误：缺少 DOMAIN/ADMIN_USER/ADMIN_PASS/SSL_EMAIL，无法执行全新安装。" >&2
    echo "请提供这些参数或通过交互输入补齐后重试。" >&2
    exit 1
  fi
  ${WP_CMD_SAFE} --path="${WP_PATH}" core install \
    --url="http://${DOMAIN}" --title="My Site" \
    --admin_user="${ADMIN_USER}" --admin_password="${ADMIN_PASS}" --admin_email="${SSL_EMAIL}" && {
      is_installed=1
      SITEURL="http://${DOMAIN}"
    }
fi
if [ "$is_installed" -eq 1 ]; then
  ${WP_CMD_SAFE} --path="${WP_PATH}" option update permalink_structure "/%postname%/" || true
  ${WP_CMD_SAFE} --path="${WP_PATH}" rewrite flush --hard || true
else
  echo "跳过固定链接与重写刷新：站点未安装" || true
fi

# 主题安装（可选，需站点已安装）
if [ "$is_installed" -eq 1 ]; then
  if [ -n "${THEME_ZIP_PATH}" ] && [ -f "${THEME_ZIP_PATH}" ]; then ${WP_CMD} --path="${WP_PATH}" theme install "${THEME_ZIP_PATH}" --activate || true; elif [ -n "${THEME_ZIP_URL}" ]; then ${WP_CMD} --path="${WP_PATH}" theme install "${THEME_ZIP_URL}" --activate || true; fi
fi

# XML 导入（可选，需站点已安装）
if [ "$is_installed" -eq 1 ] && [ -n "${XML_FILE}" ] && [ -f "${XML_FILE}" ]; then ${WP_CMD} --path="${WP_PATH}" plugin install wordpress-importer --activate || true; ${WP_CMD} --path="${WP_PATH}" import "${XML_FILE}" --authors=create --skip="media" || ${WP_CMD} --path="${WP_PATH}" import "${XML_FILE}" --authors=create || true; fi

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
if [ -n "${DOMAIN}" ]; then
WWW_AVAILABLE=0
if getent hosts "www.${DOMAIN}" >/dev/null 2>&1; then WWW_AVAILABLE=1; fi
if [ "$WWW_AVAILABLE" -eq 1 ]; then
  certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" -m "${SSL_EMAIL}" --agree-tos --redirect -n || \
  certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" --expand -n || echo "SSL申请失败，稍后重试"
else
  echo "跳过 www 别名：DNS 未解析 www.${DOMAIN}"
  certbot --nginx -d "${DOMAIN}" -m "${SSL_EMAIL}" --agree-tos --redirect -n || echo "SSL申请失败，稍后重试"
fi
for SSL_CONF in "/etc/nginx/conf.d/${DOMAIN}.conf" "/etc/nginx/conf.d/${DOMAIN}-le-ssl.conf"; do
  if [ -f "$SSL_CONF" ] && grep -q "listen 443" "$SSL_CONF"; then
    grep -q "client_max_body_size" "$SSL_CONF" || sed -i '/listen 443/a \\    client_max_body_size 1024M;\\n    fastcgi_read_timeout 1800;\\n    fastcgi_connect_timeout 1800;\\n    fastcgi_send_timeout 1800;\\n    client_body_timeout 1800;\\n    send_timeout 1800;' "$SSL_CONF"
    grep -q "X-Cache-Enabled" "$SSL_CONF" || sed -i '/location ~ \\\.php\\\$ {/a \\        fastcgi_param HTTP_AUTHORIZATION \\\$http_authorization;\\n        fastcgi_cache_key \\\$scheme\\$request_method\\$host\\$request_uri;\\n        fastcgi_cache_bypass \\\$skip_cache;\\n        fastcgi_no_cache \\\$skip_cache;\\n        fastcgi_cache WORDPRESS;\\n        fastcgi_cache_valid 200 301 302 10m;\\n        fastcgi_cache_use_stale error timeout updating http_500 http_503;\\n        add_header X-Cache \\\$upstream_cache_status always;\\n        add_header Cache-Control "public, max-age=600" always;' "$SSL_CONF"
    grep -q "if (\\$host = www.${DOMAIN})" "$SSL_CONF" || sed -i '/server_name/a \\    if (\\$host = www.${DOMAIN}) { return 301 https://${DOMAIN}\\$request_uri; }' "$SSL_CONF"
  fi
done
fi
nginx -t && systemctl reload nginx || true

# 切换站点到 https（需站点已安装且 DOMAIN 存在）
if [ "$is_installed" -eq 1 ] && [ -n "${DOMAIN}" ]; then
  # 依据 HTTPS 就绪状态切换站点URL与后台SSL
SSL_READY=0
ssl_code="$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/wp-json/" --connect-timeout 10 --max-time 15 || echo 000)"
if echo "$ssl_code" | egrep -q '^(2|3)[0-9]{2}$'; then SSL_READY=1; fi
if [ "$SSL_READY" -eq 1 ]; then
  ${WP_CMD_SAFE} --path="${WP_PATH}" option update home "https://${DOMAIN}" || true
  ${WP_CMD_SAFE} --path="${WP_PATH}" option update siteurl "https://${DOMAIN}" || true
  ${WP_CMD_SAFE} --path="${WP_PATH}" config set FORCE_SSL_ADMIN true --type=constant --raw --quiet || true
else
  ${WP_CMD_SAFE} --path="${WP_PATH}" option update home "http://${DOMAIN}" || true
  ${WP_CMD_SAFE} --path="${WP_PATH}" option update siteurl "http://${DOMAIN}" || true
  ${WP_CMD_SAFE} --path="${WP_PATH}" config set FORCE_SSL_ADMIN false --type=constant --raw --quiet || true
fi
fi
systemctl restart php${PHP_VERSION}-fpm || true

# Imagick 状态（站点内）
if [ "$is_installed" -eq 1 ]; then
  ${WP_CMD_SAFE} --path="${WP_PATH}" eval 'echo "WP Imagick:".(extension_loaded("imagick")?"启用":"未启用")."\n";'
fi

# REST API 自检（https）
if [ "$is_installed" -eq 1 ] && [ -n "${DOMAIN}" ]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/wp-json/" || echo 000)"
  echo "REST API: https://${DOMAIN}/wp-json/ -> HTTP ${code}"
fi

# 输出
  if [ "$is_installed" -eq 1 ]; then
  echo "WordPress 安装完成"
else
  echo "WordPress 未安装（仅完成修复/环境配置）"
fi
echo "URL: $(${WP_CMD_SAFE} --path=\"${WP_PATH}\" option get siteurl 2>/dev/null || ${WP_CMD_SAFE} --path=\"${WP_PATH}\" option get home 2>/dev/null || echo \"http://${DOMAIN}\")"
echo "WP_PATH: ${WP_PATH}"
echo "DB: ${DB_NAME} 用户: ${DB_USER}"
echo "管理员:${ADMIN_USER}"
