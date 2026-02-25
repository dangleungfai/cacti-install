#!/bin/bash
#
# Cacti 一键部署脚本 (Ubuntu 24.04+)
# 参考: https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md
#
# 特性:
#   - HTTP 自动跳转 HTTPS，使用自签名证书（最长有效期）
#   - 访问地址为 https://服务器IP/cacti/（默认安装目录，不做根路径跳转）
#   - 安装过程中交互输入数据库密码
#   - 默认安装 Cacti 最新稳定版 (1.2.x)，可选开发版 (CACTI_BRANCH=develop)
#   - 自动安装 Weathermap 插件 (Cacti Group 官方 fork)
#
# 用法: sudo ./install-cacti.sh
# 可选: sudo CACTI_BRANCH=develop ./install-cacti.sh   # 安装开发版
#

set -e

# ------------------------- 固定配置（默认 /cacti/ 目录）-------------------------
CACTI_WEB_USER="www-data"
CACTI_PATH="/var/www/html/cacti"
# 默认最新稳定版；可选 CACTI_BRANCH=develop 安装开发版
CACTI_BRANCH="${CACTI_BRANCH:-1.2.x}"
INSTALL_WEATHERMAP="${INSTALL_WEATHERMAP:-1}"
WEATHERMAP_PLUGIN_REPO="https://github.com/Cacti/plugin_weathermap.git"
WEATHERMAP_PLUGIN_BRANCH="${WEATHERMAP_PLUGIN_BRANCH:-develop}"
CACTI_DB_NAME="cacti"
CACTI_DB_USER="cactiuser"
SSL_DIR="/etc/ssl/cacti"
SSL_DAYS="8250"
POLLER_METHOD="${POLLER_METHOD:-cron}"

# 安装过程中由用户输入
MYSQL_ROOT_PASSWORD=""
CACTI_DB_PASS=""

# 检测 PHP 版本 (Ubuntu 24.04 仅提供 PHP 8；可选 USE_PHP7=1 在 22.04 下用 PHP 7.4)
detect_php() {
	if [[ -n "$USE_PHP7" ]] && [[ "$USE_PHP7" == "1" ]]; then
		for v in 7.4 7.3; do
			if command -v "php$v" &>/dev/null; then echo "$v"; return; fi
		done
	fi
	for v in 8.4 8.3 8.2 8.1; do
		if command -v "php$v" &>/dev/null; then echo "$v"; return; fi
	done
	local v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
	[[ -n "$v" ]] && echo "$v" || echo "8.3"
}

# ------------------------- 检查 root -------------------------
if [[ $EUID -ne 0 ]]; then
	echo "请使用 root 运行此脚本: sudo $0"
	exit 1
fi

# ------------------------- 检查系统 (Ubuntu 24.04+) -------------------------
if ! command -v apt-get &>/dev/null; then
	echo "此脚本仅支持 Debian/Ubuntu。"
	exit 1
fi
if [[ -f /etc/os-release ]]; then
	. /etc/os-release
	VER="${VERSION_ID:-0}"
	if [[ "$ID" == "ubuntu" ]]; then
		if (( ${VER%%.*} < 24 )); then
			echo "建议在 Ubuntu 24.04 及以上版本运行。当前: $PRETTY_NAME"
			read -p "是否继续? [y/N] " -n 1 -r; echo
			[[ ! $REPLY =~ ^[yY]$ ]] && exit 1
		fi
	fi
fi

# ------------------------- 交互输入数据库密码 -------------------------
echo "=============================================="
echo "  Cacti 一键安装 (Ubuntu 24.04+)"
echo "=============================================="
echo ""
echo "需要输入以下密码（直接回车则使用默认）："
echo "  默认 root 密码: root"
echo "  默认 cactiuser 密码: cactiuser"
echo ""

read -s -p "MySQL/MariaDB root 密码（回车=root）: " MYSQL_ROOT_PASSWORD
echo ""
if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
	MYSQL_ROOT_PASSWORD="root"
	echo "  使用默认 root 密码: root"
else
	read -s -p "请再输入一次 root 密码: " MYSQL_ROOT_PASS2
	echo ""
	if [[ "$MYSQL_ROOT_PASSWORD" != "$MYSQL_ROOT_PASS2" ]]; then
		echo "  两次输入不一致，退出。"
		exit 1
	fi
fi

read -s -p "Cacti 数据库用户 $CACTI_DB_USER 的密码（回车=cactiuser）: " CACTI_DB_PASS
echo ""
if [[ -z "$CACTI_DB_PASS" ]]; then
	CACTI_DB_PASS="cactiuser"
	echo "  使用默认 cactiuser 密码: cactiuser"
else
	read -s -p "请再输入一次 Cacti 数据库密码: " CACTI_DB_PASS2
	echo ""
	if [[ "$CACTI_DB_PASS" != "$CACTI_DB_PASS2" ]]; then
		echo "  两次输入不一致，退出。"
		exit 1
	fi
fi

echo ""
echo "  安装路径: $CACTI_PATH"
echo "  访问地址: https://本机IP/cacti/（自动跳 HTTPS）"
echo "  Cacti 分支: $CACTI_BRANCH"
echo "=============================================="

# ------------------------- 执行 MySQL/MariaDB 客户端 -------------------------
set_mysql_cmd() {
	apt-get install -y mariadb-client &>/dev/null || true
	hash -r 2>/dev/null || true
	if command -v mysql &>/dev/null; then
		MYSQL_CMD="mysql"
	elif command -v mariadb &>/dev/null; then
		MYSQL_CMD="mariadb"
	elif [[ -x /usr/bin/mysql ]]; then
		MYSQL_CMD="/usr/bin/mysql"
	elif [[ -x /usr/bin/mariadb ]]; then
		MYSQL_CMD="/usr/bin/mariadb"
	else
		echo "错误: 无法找到 MySQL/MariaDB 客户端。请手动执行: apt-get update && apt-get install -y mariadb-client"
		exit 1
	fi
	# 优先使用 socket（若存在），否则用 TCP
	MYSQL_SOCKET=""
	[[ -S /run/mysqld/mysqld.sock ]] && MYSQL_SOCKET="/run/mysqld/mysqld.sock"
	[[ -z "$MYSQL_SOCKET" ]] && [[ -S /var/run/mysqld/mysqld.sock ]] && MYSQL_SOCKET="/var/run/mysqld/mysqld.sock"
	[[ -z "$MYSQL_SOCKET" ]] && [[ -S /tmp/mysql.sock ]] && MYSQL_SOCKET="/tmp/mysql.sock"
}
run_mysql() {
	set_mysql_cmd
	local conn_args=(-u root)
	[[ -n "$MYSQL_ROOT_PASSWORD" ]] && conn_args+=(-p"$MYSQL_ROOT_PASSWORD")
	local use_devnull=""
	[[ "$1" == "-e" ]] && use_devnull="yes"
	if [[ -n "$MYSQL_SOCKET" ]]; then
		if [[ -n "$use_devnull" ]]; then
			"$MYSQL_CMD" --socket="$MYSQL_SOCKET" "${conn_args[@]}" "$@" < /dev/null
		else
			"$MYSQL_CMD" --socket="$MYSQL_SOCKET" "${conn_args[@]}" "$@"
		fi
	else
		if [[ -n "$use_devnull" ]]; then
			"$MYSQL_CMD" -h 127.0.0.1 "${conn_args[@]}" "$@" < /dev/null
		else
			"$MYSQL_CMD" -h 127.0.0.1 "${conn_args[@]}" "$@"
		fi
	fi
}

# ------------------------- 1. 安装 LAMP 与依赖 -------------------------
echo "[1/11] 更新软件源并安装依赖..."
apt-get update -qq
# 可选：与官方文档一致使用 PHP 7（仅 Ubuntu 20.04/22.04，需 PPA）
if [[ -n "$USE_PHP7" ]] && [[ "$USE_PHP7" == "1" ]]; then
	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		if [[ "$ID" == "ubuntu" ]]; then
			case "${VERSION_ID:-0}" in
				20.04|22.04) ;;
				*) echo "      警告: USE_PHP7=1 建议在 Ubuntu 20.04/22.04 使用，当前 $PRETTY_NAME 将尝试 PPA 安装 PHP 7.4";;
			esac
		fi
	fi
	echo "      添加 ondrej/php PPA 以安装 PHP 7.4..."
	apt-get install -y software-properties-common
	add-apt-repository -y ppa:ondrej/php
	apt-get update -qq
	PHP_VER="7.4"
else
	PHP_VER=$(detect_php)
fi
[[ -z "$PHP_VER" ]] && PHP_VER=$(detect_php)
echo "      使用 PHP 版本: $PHP_VER"

install_php_pkgs() {
	local pkg="php$PHP_VER"
	apt-get install -y --no-install-recommends \
		apache2 \
		rrdtool \
		mariadb-server \
		mariadb-client \
		snmp \
		snmpd \
		"$pkg" \
		"$pkg"-mysql \
		"$pkg"-snmp \
		"$pkg"-xml \
		"$pkg"-mbstring \
		"$pkg"-json \
		"$pkg"-gd \
		"$pkg"-gmp \
		"$pkg"-zip \
		"$pkg"-ldap \
		"$pkg"-curl \
		"$pkg"-intl \
		libapache2-mod-"$pkg" \
		git \
		openssl \
		>/dev/null 2>&1 || true
}

if ! install_php_pkgs; then
	apt-get install -y --no-install-recommends \
		apache2 rrdtool mariadb-server mariadb-client snmp snmpd \
		php php-mysql php-snmp php-xml php-mbstring php-json \
		php-gd php-gmp php-zip php-ldap php-curl php-intl \
		git openssl
fi
# 必须确保 PHP 有 MySQL 扩展，否则 Cacti 会报 "Connection to Cacti database failed"
if ! php -m 2>/dev/null | grep -qE 'mysqli|pdo_mysql'; then
	echo "      安装 PHP MySQL 扩展 (php$PHP_VER-mysql)..."
	apt-get install -y "php$PHP_VER-mysql" 2>/dev/null || apt-get install -y php-mysql
fi
# 安装向导可选模块：PHP SNMP 扩展（用于 SNMP 轮询）
if ! php -m 2>/dev/null | grep -q '^snmp$'; then
	echo "      安装 PHP SNMP 扩展 (php$PHP_VER-snmp)..."
	apt-get install -y "php$PHP_VER-snmp" 2>/dev/null || apt-get install -y php-snmp
fi
# 安装向导必须模块：gd/gmp/intl/ldap/mbstring/xml(simplexml)，缺一不可
for mod in gd gmp intl ldap mbstring xml; do
	if ! php -m 2>/dev/null | grep -q "^${mod}$"; then
		echo "      安装 PHP 扩展 (php$PHP_VER-${mod})..."
		apt-get install -y "php$PHP_VER-${mod}" 2>/dev/null || apt-get install -y "php-${mod}"
	fi
done
# 确保 RRDtool 已安装且可执行（安装向导「关键可执行程序」步骤要求）
if [[ ! -x /usr/bin/rrdtool ]]; then
	echo "      安装 RRDtool..."
	apt-get install -y rrdtool
fi
# Cacti 安装向导要求：PHP memory_limit>=400M、max_execution_time>=60（Apache 与 CLI 均设置）
for ini_sapi in apache2 cli; do
	PHP_INI="/etc/php/${PHP_VER}/${ini_sapi}/php.ini"
	if [[ -f "$PHP_INI" ]]; then
		sed -i 's/^;\?memory_limit\s*=.*/memory_limit = 400M/' "$PHP_INI"
		sed -i 's/^;\?max_execution_time\s*=.*/max_execution_time = 60/' "$PHP_INI"
	fi
done
echo "      已设置 php.ini (apache2+cli): memory_limit=400M, max_execution_time=60"

# ------------------------- 2. 启动 MariaDB 并等待就绪 -------------------------
echo "[2/11] 启动 MariaDB..."
# 确保已安装服务端（步骤 1 若仅部分成功可能只装了 client）
if ! dpkg -s mariadb-server &>/dev/null; then
	echo "      安装 mariadb-server..."
	apt-get install -y mariadb-server
fi
mkdir -p /run/mysqld /var/run/mysqld 2>/dev/null || true
MYSQL_OWNER="mysql"
id mysql &>/dev/null || MYSQL_OWNER="mariadb"
chown -R "$MYSQL_OWNER:$MYSQL_OWNER" /run/mysqld /var/run/mysqld 2>/dev/null || true
if [[ ! -d /var/lib/mysql/mysql ]]; then
	mariadb-install-db --user="$MYSQL_OWNER" 2>/dev/null || mysql_install_db --user="$MYSQL_OWNER" 2>/dev/null || true
fi
systemctl enable mariadb 2>/dev/null || systemctl enable mysql 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
	sleep 2
	[[ -S /run/mysqld/mysqld.sock ]] && break
	[[ -S /var/run/mysqld/mysqld.sock ]] && break
	[[ -S /tmp/mysql.sock ]] && break
	systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
done
# 若仍无 socket，多等几秒（首次启动可能较慢）
if [[ ! -S /run/mysqld/mysqld.sock ]] && [[ ! -S /var/run/mysqld/mysqld.sock ]] && [[ ! -S /tmp/mysql.sock ]]; then
	echo "      等待 MariaDB 首次启动..."
	sleep 10
	systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
	sleep 5
fi

# ------------------------- 3. 克隆 Cacti（最新版本）-------------------------
echo "[3/11] 下载 Cacti ($CACTI_BRANCH)..."
PARENT_DIR="$(dirname "$CACTI_PATH")"
mkdir -p "$PARENT_DIR"
if [[ -d "$CACTI_PATH/.git" ]]; then
	cd "$CACTI_PATH"
	git fetch origin "$CACTI_BRANCH" 2>/dev/null || true
	git checkout "$CACTI_BRANCH" 2>/dev/null || git checkout -b "$CACTI_BRANCH" "origin/$CACTI_BRANCH" 2>/dev/null || true
	git pull --ff-only origin "$CACTI_BRANCH" 2>/dev/null || true
	cd - >/dev/null
else
	rm -rf "$CACTI_PATH"
	git clone -b "$CACTI_BRANCH" --depth 1 https://github.com/Cacti/cacti.git "$CACTI_PATH"
fi

# ------------------------- 4. 创建数据库与用户 -------------------------
echo "[4/11] 配置数据库..."
# 使用默认 root 密码时，若本机 MariaDB 尚未设置密码，先设为 root（失败不退出，可能已有密码）
if [[ "$MYSQL_ROOT_PASSWORD" == "root" ]]; then
	set +e
	set_mysql_cmd
	try_conn=("$MYSQL_CMD" -u root)
	[[ -n "$MYSQL_SOCKET" ]] && try_conn+=(--socket="$MYSQL_SOCKET") || try_conn+=(-h 127.0.0.1)
	if "${try_conn[@]}" -e "SELECT 1" < /dev/null &>/dev/null; then
		"${try_conn[@]}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'root'; FLUSH PRIVILEGES;" < /dev/null 2>/dev/null || true
	fi
	set -e
fi
# 先测试连接，失败时错误直接输出到终端并退出
set +e
run_mysql -e "SELECT 1"
_ret=$?
set -e
if [[ $_ret -ne 0 ]]; then
	echo ""
	echo "错误: 无法连接 MariaDB/MySQL，安装中断。请检查上方报错。"
	echo "建议: 1) systemctl status mariadb  确认服务已启动"
	echo "      2) root 密码是否正确（当前使用: $MYSQL_ROOT_PASSWORD）"
	echo "      3) 手动测试: mysql -u root -p -e \"SELECT 1\""
	exit 1
fi
# 创建数据库与用户，失败时保留报错并退出
set +e
run_mysql <<EOSQL
CREATE DATABASE IF NOT EXISTS \`$CACTI_DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$CACTI_DB_USER'@'localhost' IDENTIFIED BY '$CACTI_DB_PASS';
GRANT ALL PRIVILEGES ON \`$CACTI_DB_NAME\`.* TO '$CACTI_DB_USER'@'localhost';
GRANT SELECT ON mysql.time_zone_name TO '$CACTI_DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOSQL
_ret=$?
set -e
if [[ $_ret -ne 0 ]]; then
	echo ""
	echo "错误: 创建数据库/用户失败，请根据上方报错排查后重试。"
	exit 1
fi

# ------------------------- 5. 导入 cacti.sql -------------------------
echo "[5/11] 导入 Cacti 初始数据..."
if [[ -f "$CACTI_PATH/cacti.sql" ]]; then
	set +e
	run_mysql "$CACTI_DB_NAME" < "$CACTI_PATH/cacti.sql"
	_ret=$?
	set -e
	if [[ $_ret -ne 0 ]]; then
		echo "      警告: 导入 cacti.sql 返回错误码 $_ret，请检查上方报错。尝试继续..."
	fi
else
	echo "      未找到 cacti.sql，跳过。"
fi

# 填充 MySQL 时区表（Cacti 安装向导要求；失败不中断安装）
echo "      填充 MySQL 时区表..."
( set +e
  set_mysql_cmd
  if command -v mariadb-tzinfo-to-sql &>/dev/null; then
    mariadb-tzinfo-to-sql /usr/share/zoneinfo 2>/dev/null | run_mysql mysql 2>/dev/null && echo "      时区表已填充" || echo "      时区表填充跳过或失败，可安装后手动执行: mariadb-tzinfo-to-sql /usr/share/zoneinfo | mysql -u root -p mysql"
  elif command -v mysql_tzinfo_to_sql &>/dev/null; then
    mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | run_mysql mysql 2>/dev/null && echo "      时区表已填充" || echo "      时区表填充跳过或失败，可安装后手动执行"
  fi
)
true

# MariaDB 推荐配置（满足 Cacti 安装向导：collation、innodb、heap/tmp 表）
MARIADB_CONF_D="/etc/mysql/mariadb.conf.d"
if [[ -d "$MARIADB_CONF_D" ]]; then
	set +e
	# innodb_buffer_pool_size：建议 25% 系统内存，至少 256M
	MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
	if [[ "$MEM_KB" -gt 0 ]]; then
		MEM_M=$((MEM_KB / 1024))
		POOL_M=$((MEM_M * 25 / 100))
		[[ $POOL_M -lt 256 ]] && POOL_M=256
		[[ $POOL_M -gt 2048 ]] && POOL_M=2048
	else
		POOL_M=512
	fi
	cat > "$MARIADB_CONF_D/99-cacti.cnf" <<EOMYSQL
# Cacti 安装向导推荐
[mysqld]
character_set_server = utf8mb4
collation_server = utf8mb4_unicode_ci
innodb_doublewrite = OFF
innodb_buffer_pool_size = ${POOL_M}M
max_heap_table_size = 64M
tmp_table_size = 64M
EOMYSQL
	systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
	echo "      已写入 MariaDB 推荐配置（innodb_buffer_pool=${POOL_M}M, heap/tmp=64M）并重启"
	set -e
fi

# ------------------------- 6. 配置文件 config.php -------------------------
echo "[6/11] 生成 config.php..."
CONFIG_DIR="$CACTI_PATH/include"
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_DIR/config.php.dist" ]]; then
	cp -a "$CONFIG_DIR/config.php.dist" "$CONFIG_DIR/config.php"
	sed -i "s/^\$database_default\s*=.*/\$database_default  = '$CACTI_DB_NAME';/" "$CONFIG_DIR/config.php"
	sed -i "s/^\$database_hostname\s*=.*/\$database_hostname = 'localhost';/" "$CONFIG_DIR/config.php"
	sed -i "s/^\$database_username\s*=.*/\$database_username = '$CACTI_DB_USER';/" "$CONFIG_DIR/config.php"
	sed -i "s/^\$database_password\s*=.*/\$database_password = '$CACTI_DB_PASS';/" "$CONFIG_DIR/config.php"
else
	echo "      未找到 config.php.dist，请手动创建 config.php。"
fi

# ------------------------- 7. 自签名证书（最长有效期）-------------------------
echo "[7/11] 生成自签名 HTTPS 证书（有效期 ${SSL_DAYS} 天，约 22 年）..."
mkdir -p "$SSL_DIR"
openssl req -x509 -nodes -days "$SSL_DAYS" -newkey rsa:2048 \
	-keyout "$SSL_DIR/cacti.key" \
	-out "$SSL_DIR/cacti.crt" \
	-subj "/O=Cacti/CN=localhost" \
	-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
chmod 640 "$SSL_DIR/cacti.key"
chmod 644 "$SSL_DIR/cacti.crt"
chown root:root "$SSL_DIR/cacti.key" "$SSL_DIR/cacti.crt"

# ------------------------- 8. Apache：/cacti 目录 + HTTP 跳 HTTPS -------------------------
echo "[8/11] 配置 Apache（默认 /cacti/ 目录，HTTP 跳转 HTTPS）..."
if ! dpkg -s apache2 &>/dev/null; then
	echo "      安装 apache2..."
	apt-get install -y apache2
fi
a2enmod ssl rewrite 2>/dev/null || true
CONF_D="/etc/apache2/sites-available"
mkdir -p "$CONF_D"
# 80 跳 443；443 使用默认 DocumentRoot，/cacti 指向 Cacti 目录
CONF_AVAILABLE="$CONF_D/cacti-default.conf"
cat > "$CONF_AVAILABLE" <<'EOCONF'
# HTTP -> HTTPS
<VirtualHost *:80>
	ServerName _
	Redirect permanent / https://%{HTTP_HOST}/
</VirtualHost>

# HTTPS，默认目录访问 https://IP/cacti/
<VirtualHost *:443>
	ServerName _
	DocumentRoot /var/www/html
	Alias /cacti /var/www/html/cacti
	<Directory /var/www/html/cacti>
		Options FollowSymLinks
		AllowOverride All
		Require all granted
		DirectoryIndex index.php
		<FilesMatch \.php$>
			SetHandler application/x-httpd-php
		</FilesMatch>
	</Directory>
	SSLEngine on
	SSLCertificateFile /etc/ssl/cacti/cacti.crt
	SSLCertificateKeyFile /etc/ssl/cacti/cacti.key
	ErrorLog ${APACHE_LOG_DIR}/cacti_ssl_error.log
	CustomLog ${APACHE_LOG_DIR}/cacti_ssl_access.log combined
</VirtualHost>
EOCONF

# 禁用默认站点并启用本配置
a2dissite 000-default.conf 2>/dev/null || true
a2ensite cacti-default.conf 2>/dev/null || true
# 确保 Apache 能执行 PHP（/cacti 下 .php 必须被解释，否则浏览器会看到源码）
a2enmod "php$PHP_VER" 2>/dev/null || true
if [[ ! -L /etc/apache2/mods-enabled/php${PHP_VER}.load ]]; then
	echo "      启用 Apache PHP 模块 php$PHP_VER..."
	apt-get install -y "libapache2-mod-php$PHP_VER" 2>/dev/null || true
	a2enmod "php$PHP_VER" 2>/dev/null || true
fi

# ------------------------- 9. 权限与重启 Apache -------------------------
echo "[9/11] 设置目录权限..."
chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH"
for d in log rra cache resource scripts; do
	[[ -d "$CACTI_PATH/$d" ]] && chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH/$d"
done
systemctl restart apache2 2>/dev/null || systemctl restart apache 2>/dev/null || true

# 配置 snmpd 供 Cacti 本机 SNMP 轮询（安装向导可选模块提示）
if command -v snmpd &>/dev/null; then
	SNMPD_CONF_D="/etc/snmp/snmpd.conf.d"
	if [[ -d "$SNMPD_CONF_D" ]]; then
		cat > "$SNMPD_CONF_D/cacti.conf" <<'EOSNMP'
# Cacti 本机 SNMP 轮询：允许 127.0.0.1 使用 community public 只读（可改为自定义 community）
rocommunity public 127.0.0.1
EOSNMP
	else
		grep -q 'rocommunity public 127.0.0.1' /etc/snmp/snmpd.conf 2>/dev/null || \
			echo -e "\n# Cacti 本机 SNMP\nrocommunity public 127.0.0.1" >> /etc/snmp/snmpd.conf
	fi
	systemctl enable snmpd 2>/dev/null || true
	systemctl restart snmpd 2>/dev/null || true
	echo "      已配置 snmpd（127.0.0.1 可用 community public 轮询）"
fi

# ------------------------- 10. 轮询任务 -------------------------
echo "[10/11] 配置 Cacti 轮询..."
if [[ "$POLLER_METHOD" == "systemd" ]]; then
	SVC_FILE="$CACTI_PATH/service/cactid.service"
	if [[ -f "$SVC_FILE" ]]; then
		sed -i "s|/var/www/html/cacti|$CACTI_PATH|g" "$SVC_FILE"
		touch /etc/sysconfig/cactid 2>/dev/null || true
		cp -p "$SVC_FILE" /etc/systemd/system/
		systemctl daemon-reload
		systemctl enable cactid
		systemctl start cactid
		echo "      已启用 systemd: cactid"
	else
		POLLER_METHOD=cron
	fi
fi
if [[ "$POLLER_METHOD" == "cron" ]]; then
	cat > /etc/cron.d/cacti <<EOCRON
*/5 * * * * $CACTI_WEB_USER php $CACTI_PATH/poller.php >/dev/null 2>&1
EOCRON
	chmod 644 /etc/cron.d/cacti
	echo "      已创建 /etc/cron.d/cacti"
fi

# ------------------------- 11. 自动安装 Weathermap 插件 -------------------------
if [[ "$INSTALL_WEATHERMAP" == "1" ]]; then
	echo "[11/11] 安装 Weathermap 插件..."
	PLUGINS_DIR="$CACTI_PATH/plugins"
	mkdir -p "$PLUGINS_DIR"
	if [[ -d "$PLUGINS_DIR/weathermap/.git" ]]; then
		cd "$PLUGINS_DIR/weathermap"
		git fetch origin "$WEATHERMAP_PLUGIN_BRANCH" 2>/dev/null || true
		git checkout "$WEATHERMAP_PLUGIN_BRANCH" 2>/dev/null || git checkout -b "$WEATHERMAP_PLUGIN_BRANCH" "origin/$WEATHERMAP_PLUGIN_BRANCH" 2>/dev/null || true
		git pull --ff-only origin "$WEATHERMAP_PLUGIN_BRANCH" 2>/dev/null || true
		cd - >/dev/null
	else
		rm -rf "$PLUGINS_DIR/weathermap"
		git clone -b "$WEATHERMAP_PLUGIN_BRANCH" --depth 1 "$WEATHERMAP_PLUGIN_REPO" "$PLUGINS_DIR/weathermap"
	fi
	chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$PLUGINS_DIR/weathermap"
	echo "      已安装至 $PLUGINS_DIR/weathermap（请在 Cacti 控制台 -> 插件管理 中启用）"
else
	echo "[11/11] 跳过 Weathermap 插件（INSTALL_WEATHERMAP=0）"
fi

# ------------------------- 完成 -------------------------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo "=============================================="
echo "  Cacti 安装完成"
echo "=============================================="
echo "  访问地址: https://${IP:-localhost}/cacti/"
echo "  （HTTP 会自动跳转到 HTTPS）"
echo ""
echo "  首次访问按向导完成初始化；默认登录 admin / admin（会强制改密）"
echo ""
echo "  若页面报 Connection to Cacti database failed，请在服务器执行："
echo "    sudo apt-get install -y php${PHP_VER}-mysql && sudo systemctl restart apache2"
echo ""
if [[ "$INSTALL_WEATHERMAP" == "1" ]]; then
	echo "  已安装 Weathermap 插件，请在 控制台 -> 插件管理 中启用后使用。"
	echo ""
fi
echo "=============================================="
