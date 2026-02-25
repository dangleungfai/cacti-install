#!/bin/bash
#
# Cacti 一键升级脚本（不丢数据）
# 用于在现有安装上升级到最新版本，保留数据库、RRD、配置与插件等。
#
# 用法: sudo ./upgrade-cacti.sh
#
# 可选环境变量:
#   CACTI_PATH    Cacti 安装路径 (默认: /var/www/html/cacti)
#   CACTI_BRANCH  要升级到的分支 (默认: 1.2.x 稳定版)
#   BACKUP_DIR    备份目录 (默认: /var/backups/cacti)
#

set -e

CACTI_PATH="${CACTI_PATH:-/var/www/html/cacti}"
CACTI_BRANCH="${CACTI_BRANCH:-1.2.x}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cacti}"
CACTI_WEB_USER="www-data"

if [[ $EUID -ne 0 ]]; then
	echo "请使用 root 运行: sudo $0"
	exit 1
fi

if [[ ! -d "$CACTI_PATH" ]]; then
	echo "错误: 未找到 Cacti 目录: $CACTI_PATH"
	exit 1
fi

CONFIG_FILE="$CACTI_PATH/include/config.php"
if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "错误: 未找到 config.php，请确认 $CACTI_PATH 为有效 Cacti 安装。"
	exit 1
fi

echo "=============================================="
echo "  Cacti 一键升级（保留数据）"
echo "=============================================="
echo "  路径:   $CACTI_PATH"
echo "  分支:   $CACTI_BRANCH"
echo "  备份到: $BACKUP_DIR"
echo "=============================================="

# 从 config.php 读取数据库信息（兼容常见写法）
get_db_config() {
	local key="$1"
	grep -E "^\s*\\\$$key\s*=" "$CONFIG_FILE" 2>/dev/null | sed -E "s/.*=\s*['\"]?([^;'\"]+)['\"]?;.*/\\1/" | head -1 | tr -d " \t'\""
}
DB_NAME=$(get_db_config "database_default")
DB_USER=$(get_db_config "database_username")
DB_PASS=$(get_db_config "database_password")
DB_HOST=$(get_db_config "database_hostname")
[[ -z "$DB_NAME" ]] && DB_NAME="cacti"
[[ -z "$DB_USER" ]] && DB_USER="cactiuser"
[[ -z "$DB_HOST" ]] && DB_HOST="localhost"

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PREFIX="$BACKUP_DIR/cacti_$TIMESTAMP"

# ------------------------- 1. 备份数据库 -------------------------
echo "[1/6] 备份数据库..."
if command -v mysqldump &>/dev/null; then
	BACKUP_SQL="${BACKUP_PREFIX}.sql"
	export MYSQL_PWD="$DB_PASS"
	mysqldump -u "$DB_USER" -h "$DB_HOST" --single-transaction "$DB_NAME" > "$BACKUP_SQL" 2>/dev/null || \
		mysqldump -u "$DB_USER" -h "$DB_HOST" "$DB_NAME" > "$BACKUP_SQL"
	unset MYSQL_PWD
	echo "      已保存: $BACKUP_SQL"
else
	echo "      未找到 mysqldump，跳过数据库备份（不推荐）。"
fi

# ------------------------- 2. 备份 config.php 及关键目录 -------------------------
echo "[2/6] 备份 config.php 与 rra..."
cp -a "$CONFIG_FILE" "${BACKUP_PREFIX}_config.php"
[[ -d "$CACTI_PATH/rra" ]] && tar -cf "${BACKUP_PREFIX}_rra.tar" -C "$CACTI_PATH" rra 2>/dev/null || true
[[ -d "$CACTI_PATH/plugins" ]] && tar -cf "${BACKUP_PREFIX}_plugins.tar" -C "$CACTI_PATH" plugins 2>/dev/null || true
echo "      已保存: ${BACKUP_PREFIX}_config.php"

# ------------------------- 3. 拉取最新代码 -------------------------
echo "[3/6] 拉取 Cacti 最新代码 ($CACTI_BRANCH)..."
cd "$CACTI_PATH"
if [[ -d .git ]]; then
	git fetch origin "$CACTI_BRANCH" 2>/dev/null || git fetch origin
	git stash push -m "cacti-upgrade-$TIMESTAMP" -- include/config.php 2>/dev/null || true
	git checkout "$CACTI_BRANCH" 2>/dev/null || git checkout -b "$CACTI_BRANCH" "origin/$CACTI_BRANCH"
	git pull --ff-only origin "$CACTI_BRANCH" 2>/dev/null || git pull --ff-only origin
else
	echo "      当前目录不是 Git 仓库，无法自动升级。请手动替换代码后重新运行本脚本做备份与权限设置。"
	cd - >/dev/null
	exit 1
fi
cd - >/dev/null

# ------------------------- 4. 恢复 config.php -------------------------
echo "[4/6] 恢复 config.php..."
cp -a "${BACKUP_PREFIX}_config.php" "$CONFIG_FILE"
chown "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CONFIG_FILE"

# ------------------------- 5. 数据库结构升级 -------------------------
echo "[5/6] 执行数据库升级..."
if [[ -f "$CACTI_PATH/cli/audit_database.php" ]]; then
	su -s /bin/bash -c "cd $CACTI_PATH && php cli/audit_database.php" "$CACTI_WEB_USER" 2>/dev/null || \
		(cd "$CACTI_PATH" && php cli/audit_database.php) && echo "      audit_database 完成"
fi
if [[ -f "$CACTI_PATH/cli/upgrade_database.php" ]]; then
	su -s /bin/bash -c "cd $CACTI_PATH && php cli/upgrade_database.php" "$CACTI_WEB_USER" 2>/dev/null || \
		(cd "$CACTI_PATH" && php cli/upgrade_database.php) && echo "      upgrade_database 完成"
fi

# ------------------------- 6. 权限与服务 -------------------------
echo "[6/6] 设置权限并重启服务..."
chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH"
for d in log rra cache resource scripts plugins; do
	[[ -d "$CACTI_PATH/$d" ]] && chown -R "$CACTI_WEB_USER:$CACTI_WEB_USER" "$CACTI_PATH/$d"
done
systemctl restart apache2 2>/dev/null || systemctl restart apache 2>/dev/null || true
systemctl restart cactid 2>/dev/null || true

echo ""
echo "=============================================="
echo "  升级完成"
echo "=============================================="
echo "  备份位置: $BACKUP_DIR"
echo "  请使用浏览器访问 https://本机IP/cacti/ 确认界面与数据正常。"
echo "  若出现升级向导，按页面提示完成即可。"
echo "=============================================="
