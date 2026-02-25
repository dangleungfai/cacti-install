# Cacti 一键部署 (Ubuntu 24.04+)

基于 [Cacti 官方文档 Installing-Under-Ubuntu-Debian](https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md) 的一键安装与升级脚本。

## 为何使用 PHP 8（官方文档是 PHP 7）

- 官方文档里的 `php7.0`、`php-mysql` 等是针对**旧版 Ubuntu/Debian**（自带 PHP 7 的版本）的。
- **Ubuntu 24.04 官方源里已没有 PHP 7**，只有 PHP 8.x（默认 8.3），因此本脚本在 24.04 上使用 PHP 8 是必然选择；Cacti 1.2.x 支持 PHP 8。
- 若访问 **https://IP/cacti/** 时浏览器里看到的是 **PHP 源码**而不是页面，原因是 **Apache 没有执行 PHP**（未正确启用 mod_php 或未对 `/cacti` 目录设置处理器），**与 PHP 7/8 无关**。脚本已通过 `SetHandler application/x-httpd-php` 和 `a2enmod php*` 修复。
- 如需与官方文档一致使用 **PHP 7.4**，请在 **Ubuntu 22.04** 上使用：`sudo USE_PHP7=1 ./install-cacti.sh`（会添加 ondrej/php PPA 并安装 php7.4）。

## 特性

- **HTTPS 默认**：HTTP 自动 301 跳转到 HTTPS，使用自签名证书（默认 8250 天约 22 年，接近常见 OpenSSL 自签名上限）
- **默认目录访问**：安装后访问 **https://服务器IP/cacti/**（不做根路径跳转）
- **交互式密码**：安装过程中提示输入 MySQL root 密码与 Cacti 数据库密码，不通过环境变量传密
- **系统要求**：面向 **Ubuntu 24.04 及以上**
- **最新版本**：默认安装 Cacti **最新稳定版**（1.2.x 分支）；可通过环境变量 `CACTI_BRANCH=develop` 安装开发版
- **Weathermap 插件**：脚本**自动安装** [Cacti Group 官方 Weathermap 插件](https://github.com/Cacti/plugin_weathermap)，安装后需在 Cacti 控制台 -> 插件管理 中启用
- **一键升级**：`upgrade-cacti.sh` 可升级到最新代码，**不丢数据**（备份数据库与 config，保留 rra/plugins）

## 要求

- **系统**：Ubuntu 24.04 或更高（脚本会检测并提示）
- **权限**：需 root（`sudo`）
- **网络**：可访问 GitHub 与 apt 源

## 快速安装

执行安装脚本前，请先更新软件源并安装 git：

```bash
apt update
apt install -y git
```

然后克隆仓库并运行安装脚本：

```bash
git clone https://github.com/dangleungfai/cacti-install.git
cd cacti-install
chmod +x install-cacti.sh
sudo ./install-cacti.sh
```

按提示输入（**直接回车即使用默认密码**）：

1. **MySQL/MariaDB root 密码**（回车 = 默认 `root`）
2. **Cacti 数据库用户 cactiuser 的密码**（回车 = 默认 `cactiuser`）

也可输入自定义密码（会要求再输入一次确认）。  
安装完成后在浏览器访问：**https://你的服务器IP/cacti/**（HTTP 会自动跳转到 HTTPS）。按向导完成初始化，默认登录 **admin / admin**，首次登录会强制改密。  
若已安装 Weathermap 插件，请在 **控制台 -> 插件管理** 中启用。

若打开页面报 **FATAL: Connection to Cacti database failed**，请在服务器上执行（PHP 版本按实际，一般为 8.3）：
```bash
sudo apt-get install -y php8.3-mysql && sudo systemctl restart apache2
```
然后再访问 https://IP/cacti/ 。

若 **Cacti 安装向导** 报错（PHP 模块、memory_limit、时区表、MySQL 配置），可在服务器上执行以下命令后刷新向导页面：
```bash
# PHP 扩展与 php.ini
sudo apt-get install -y php8.3-intl php8.3-xml php8.3-gd php8.3-gmp php8.3-mbstring php8.3-ldap php8.3-snmp
sudo sed -i 's/^;\?memory_limit\s*=.*/memory_limit = 400M/' /etc/php/8.3/apache2/php.ini
sudo sed -i 's/^;\?max_execution_time\s*=.*/max_execution_time = 60/' /etc/php/8.3/apache2/php.ini
# MySQL 时区表（将 root 密码换成你的）
mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql -u root -p mysql
# 或 MariaDB：mariadb-tzinfo-to-sql /usr/share/zoneinfo | mysql -u root -p mysql
sudo systemctl restart apache2
```

若向导提示 **PHP 模块 snmp（可选）未安装**，执行后刷新即可：
```bash
sudo apt-get install -y php8.3-snmp && sudo systemctl restart apache2
```

若向导提示 **RRDtool 二进制路径** 不正确（红叉），执行后刷新本页：
```bash
sudo apt-get install -y rrdtool
# 确认路径
which rrdtool   # 应输出 /usr/bin/rrdtool
```

## 可选环境变量（安装）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CACTI_BRANCH` | 1.2.x | Git 分支（1.2.x=稳定版，develop=开发版） |
| `USE_PHP7` | 未设置 | 设为 `1` 时在 Ubuntu 20.04/22.04 上使用 PHP 7.4（添加 ondrej/php PPA，与官方文档一致） |
| `INSTALL_WEATHERMAP` | 1 | 是否安装 Weathermap 插件（1=安装，0=不安装） |
| `WEATHERMAP_PLUGIN_BRANCH` | develop | Weathermap 插件分支 |
| `POLLER_METHOD` | cron | 轮询方式：`cron` 或 `systemd` |

安装脚本会交互询问数据库密码，一般无需传环境变量。若需非交互（不推荐），可自行修改脚本或配合 expect 使用。

## 一键升级（不丢数据）

在**已用本安装脚本部署**的机器上，升级到最新版本：

```bash
chmod +x upgrade-cacti.sh
sudo ./upgrade-cacti.sh
```

可选环境变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CACTI_PATH` | /var/www/html/cacti | Cacti 安装路径 |
| `CACTI_BRANCH` | develop | 要升级到的分支 |
| `BACKUP_DIR` | /var/backups/cacti | 备份目录 |

升级过程会：

1. 备份数据库（mysqldump）与 `include/config.php`
2. 可选备份 `rra`、`plugins` 到 tar
3. `git pull` 拉取最新代码
4. 恢复 `config.php`（避免被覆盖）
5. 执行 `cli/audit_database.php` 与 `cli/upgrade_database.php` 做数据库结构升级
6. 修正权限并重启 Apache / cactid

**注意**：升级脚本依赖当前安装目录为 Git 克隆（即由 `install-cacti.sh` 安装）。若为手动解压安装，需先改为 Git 仓库或手动替换代码后再运行升级脚本做备份与权限处理。

## 安装脚本做了什么

1. 安装 Apache、MariaDB、RRDtool、SNMP、PHP 8.x 及扩展（含 intl）、git、openssl
2. 启动 MariaDB；**填充 MySQL 时区表**（满足安装向导）
3. 从 GitHub 克隆 Cacti（默认 1.2.x 稳定版）到 `/var/www/html/cacti`
4. 创建数据库 `cacti`、用户 `cactiuser` 并授权（密码为你输入的）
5. 导入 `cacti.sql`；写入 **MariaDB 推荐配置** `/etc/mysql/mariadb.conf.d/99-cacti.cnf`（collation、innodb_buffer_pool 约 25% 内存、max_heap_table_size/tmp_table_size=64M、innodb_doublewrite=OFF）并重启 MariaDB
6. 生成 `include/config.php` 并写入数据库配置
7. 生成自签名 HTTPS 证书（`/etc/ssl/cacti/`，有效期 8250 天约 22 年）
8. 配置 Apache：默认站点 80 跳 443，443 使用 DocumentRoot `/var/www/html`，`/cacti` 别名指向 `/var/www/html/cacti`，即访问 **https://IP/cacti/**；设置 **php.ini**（memory_limit=400M、max_execution_time=60）
9. 设置目录属主为 `www-data`；**配置 snmpd**（127.0.0.1 可用 community `public` 供 Cacti 本机 SNMP 轮询）
10. 配置每 5 分钟轮询：`/etc/cron.d/cacti` 或 systemd `cactid`
11. **自动安装 Weathermap 插件**到 `plugins/weathermap`（Cacti Group 官方 fork），需在控制台启用

## 参考

- [Installing Cacti 1.x in Ubuntu/Debian (官方)](https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md)
- [Upgrading Cacti](https://docs.cacti.net/Upgrading-Cacti.md)
- [Cacti 官网](https://www.cacti.net/)
