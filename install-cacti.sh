#!/bin/bash
#
# Cacti 一键部署脚本 (Ubuntu 24.04+)
# 参考: https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md
#
# 特性:
#   - HTTP 自动跳转 HTTPS，使用自签名证书（最长有效期）
#   - 访问地址为 https://服务器IP/（根路径，无 /cacti）
#   - 安装过程中交互输入数据库密码
#   - 默认安装 Cacti 最新版本 (develop 分支)
#
# 用法: sudo ./install-cacti.sh
#

set -e

# ------------------------- 固定配置（站点根即 Cacti）-------------------------
CACTI_WEB_USER="www-data"
CACTI_PATH="/var/www/html/cacti"
CACTI_BRANCH="${CACTI_BRANCH:-develop}"
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
echo "需要输入以下密码（安装过程中请勿使用环境变量）："
echo ""

while true; do
	read -s -p "MySQL/MariaDB root 密码（未设置则直接回车）: " MYSQL_ROOT_PASSWORD
	echo ""
	if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
		echo "  将使用无密码的 root 登录（仅限本机 socket）。"
		break
	fi
	read -s -p "请再输入一次 root 密码: " MYSQL_ROOT_PASS2
	echo ""
	if [[ "$MYSQL_ROOT_PASSWORD" == "$MYSQL_ROOT_PASS2" ]]; then
		break
	fi
	echo "  两次输入不一致，请重试。"
done

while true; do
	read -s -p "Cacti 数据库用户 $CACTI_DB_USER 的密码: " CACTI_DB_PASS
	echo ""
	[[ -n "$CACTI_DB_PASS" ]] && break
	echo "  密码不能为空，请重试。"
done
read -s -p "请再输入一次 Cacti 数据库密码: " CACTI_DB_PASS2
echo ""
if [[ "$CACTI_DB_PASS" != "$CACTI_DB_PASS2" ]]; then
	echo "两次输入不一致，退出。"
	exit 1
fi

echo ""
echo "  安装路径: $CACTI_PATH"
echo "  访问地址: https://本机IP/（根路径，自动跳 HTTPS）"
echo "  Cacti 分支: $CACTI_BRANCH"
echo "=============================================="

# ------------------------- 执行 MySQL -------------------------
run_mysql() {
	if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
		mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$@"
	else
		mysql -u root "$@"
	fi
}

# ------------------------- 1. 安装 LAMP 与依赖 -------------------------
echo "[1/10] 更新软件源并安装依赖..."
apt-get update -qq
PHP_VER=$(detect_php)
echo "      使用 PHP 版本: $PHP_VER"

install_php_pkgs() {
	local pkg="php$PHP_VER"
	apt-get install -y --no-install-recommends \
		apache2 \
		rrdtool \
		mariadb-server \
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
		apache2 rrdtool mariadb-server snmp snmpd \
		php php-mysql php-snmp php-xml php-mbstring php-json \
		php-gd php-gmp php-zip php-ldap php-curl \
		git openssl
fi

# ------------------------- 2. 启动 MariaDB -------------------------
echo "[2/10] 启动 MariaDB..."
systemctl enable mariadb 2>/dev/null || systemctl enable mysql 2>/dev/null || true
systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true

# ------------------------- 3. 克隆 Cacti（最新版本）-------------------------
echo "[3/10] 下载 Cacti ($CACTI_BRANCH)..."
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
echo "[4/10] 配置数据库..."
run_mysql <<EOSQL
CREATE DATABASE IF NOT EXISTS \`$CACTI_DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$CACTI_DB_USER'@'localhost' IDENTIFIED BY '$CACTI_DB_PASS';
GRANT ALL PRIVILEGES ON \`$CACTI_DB_NAME\`.* TO '$CACTI_DB_USER'@'localhost';
GRANT SELECT ON mysql.time_zone_name TO '$CACTI_DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOSQL

# ------------------------- 5. 导入 cacti.sql -------------------------
echo "[5/10] 导入 Cacti 初始数据..."
if [[ -f "$CACTI_PATH/cacti.sql" ]]; then
	run_mysql "$CACTI_DB_NAME" < "$CACTI_PATH/cacti.sql"
else
	echo "      未找到 cacti.sql，跳过。"
fi

# ------------------------- 6. 配置文件 config.php -------------------------
echo "[6/10] 生成 config.php..."
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
echo "[7/10] 生成自签名 HTTPS 证书（有效期 ${SSL_DAYS} 天，约 22 年）..."
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
echo "[8/10] 配置 Apache（站点根为 Cacti，HTTP 跳转 HTTPS）..."
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
echo "[9/10] 设置目录权限..."
chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH"
for d in log rra cache resource scripts; do
	[[ -d "$CACTI_PATH/$d" ]] && chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH/$d"
done
systemctl restart apache2 2>/dev/null || systemctl restart apache 2>/dev/null || true

# ------------------------- 10. 轮询任务 -------------------------
echo "[10/10] 配置 Cacti 轮询..."
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
echo "=============================================="
