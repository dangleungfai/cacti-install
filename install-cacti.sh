#!/bin/bash
#
# Cacti 一键部署脚本 (Ubuntu 24.04+)
# 参考: https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md
#
# 特性:
#   - HTTP 自动跳转 HTTPS，使用自签名证书（最长有效期）
#   - 访问地址为 https://服务器IP/（根路径，无 /cacti）
#   - 安装过程中交互输入数据库密码
#   - 默认安装 Cacti 最新稳定版 (1.2.x)，可选开发版 (CACTI_BRANCH=develop)
#   - 自动安装 Weathermap 插件 (Cacti Group 官方 fork)
#
# 用法: sudo ./install-cacti.sh
# 可选: sudo CACTI_BRANCH=develop ./install-cacti.sh   # 安装开发版
#

set -e

# ------------------------- 固定配置（站点根即 Cacti）-------------------------
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

# 检测 PHP 版本 (Ubuntu 24.04 为 8.3)
detect_php() {
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
echo "  访问地址: https://本机IP/（根路径，自动跳 HTTPS）"
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
PHP_VER=$(detect_php)
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
		git \
		openssl \
		>/dev/null 2>&1 || true
}

if ! install_php_pkgs; then
	apt-get install -y --no-install-recommends \
		apache2 rrdtool mariadb-server mariadb-client snmp snmpd \
		php php-mysql php-snmp php-xml php-mbstring php-json \
		php-gd php-gmp php-zip php-ldap php-curl \
		git openssl
fi

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
	local try_conn=("$MYSQL_CMD" -u root)
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
	run_mysql "$CACTI_DB_NAME" < "$CACTI_PATH/cacti.sql"
else
	echo "      未找到 cacti.sql，跳过。"
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

# ------------------------- 8. Apache：根路径即 Cacti + HTTP 跳 HTTPS -------------------------
echo "[8/11] 配置 Apache（站点根为 Cacti，HTTP 跳转 HTTPS）..."
a2enmod ssl rewrite 2>/dev/null || true

# 默认站点改为：80 跳 443，443 的 DocumentRoot 为 Cacti
CONF_D="/etc/apache2/sites-available"
CONF_AVAILABLE="$CONF_D/cacti-default.conf"
cat > "$CONF_AVAILABLE" <<'EOCONF'
# HTTP -> HTTPS
<VirtualHost *:80>
	ServerName _
	Redirect permanent / https://%{HTTP_HOST}/
</VirtualHost>

# HTTPS，站点根即 Cacti
<VirtualHost *:443>
	ServerName _
	DocumentRoot /var/www/html/cacti
	<Directory /var/www/html/cacti>
		Options FollowSymLinks
		AllowOverride All
		Require all granted
		DirectoryIndex index.php
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

# ------------------------- 9. 权限与重启 Apache -------------------------
echo "[9/11] 设置目录权限..."
chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH"
for d in log rra cache resource scripts; do
	[[ -d "$CACTI_PATH/$d" ]] && chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH/$d"
done
systemctl restart apache2 2>/dev/null || systemctl restart apache 2>/dev/null || true

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
echo "  访问地址: https://${IP:-localhost}/"
echo "  （HTTP 会自动跳转到 HTTPS）"
echo ""
echo "  首次访问按向导完成初始化；默认登录 admin / admin（会强制改密）"
echo ""
if [[ "$INSTALL_WEATHERMAP" == "1" ]]; then
	echo "  已安装 Weathermap 插件，请在 控制台 -> 插件管理 中启用后使用。"
	echo ""
fi
echo "=============================================="
