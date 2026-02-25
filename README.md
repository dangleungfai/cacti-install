# Cacti 安装指南 (Ubuntu 24.04+)

本文档介绍如何在 Ubuntu 24.04 及以上系统上安装与升级 Cacti，基于 [Cacti 官方文档 Installing on Ubuntu/Debian](https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md)。

## 系统要求

- **操作系统**：Ubuntu 24.04 LTS 或更高版本
- **权限**：需具备 root 或 sudo 权限
- **网络**：可访问软件源与 GitHub

## 安装

### 1. 准备环境

在运行安装脚本前，请先更新软件源并安装 git：

```bash
apt update
apt install -y git
```

### 2. 获取安装脚本并执行

```bash
git clone https://github.com/dangleungfai/cacti-install.git
cd cacti-install
chmod +x install-cacti.sh
sudo ./install-cacti.sh
```

按提示输入数据库密码（直接回车则使用默认值：root 用户 `root`，Cacti 用户 `cactiuser`）。

### 3. 完成安装

安装完成后，在浏览器中访问：

**https://你的服务器IP/cacti/**

（HTTP 将自动重定向至 HTTPS。）按安装向导完成初始化。默认管理员账号为 **admin / admin**，首次登录需修改密码。

若已安装 Weathermap 插件，请在 **控制台 → 插件管理** 中启用。

---

## 功能概览

- **HTTPS**：自动签发自签名证书，HTTP 请求重定向至 HTTPS
- **访问路径**：https://服务器IP/cacti/
- **版本**：默认安装 Cacti 1.2.x 稳定版；可选安装开发版
- **Weathermap**：可选自动安装官方 Weathermap 插件
- **升级**：提供一键升级脚本，升级前自动备份数据库与配置

---

## 可选参数（安装）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CACTI_BRANCH` | 1.2.x | Cacti 分支（1.2.x 稳定版，develop 开发版） |
| `USE_PHP7` | 未设置 | 设为 `1` 时在 Ubuntu 20.04/22.04 上使用 PHP 7.4 |
| `INSTALL_WEATHERMAP` | 1 | 是否安装 Weathermap 插件（1=是，0=否） |
| `WEATHERMAP_PLUGIN_BRANCH` | develop | Weathermap 插件分支 |
| `POLLER_METHOD` | cron | 轮询方式：cron 或 systemd |

---

## 升级

在通过本脚本安装的 Cacti 上，可使用升级脚本升级至最新稳定版（默认 1.2.x 分支）：

```bash
cd cacti-install
chmod +x upgrade-cacti.sh
sudo ./upgrade-cacti.sh
```

升级前将自动备份数据库与 `config.php`，并可选备份 rra、plugins 目录。升级完成后执行数据库结构更新并修正权限。

**可选环境变量**：`CACTI_PATH`（默认 `/var/www/html/cacti`）、`CACTI_BRANCH`（默认 `1.2.x`）、`BACKUP_DIR`（默认 `/var/backups/cacti`）。

**注意**：升级脚本要求 Cacti 目录为 Git 克隆所得。若为手动解压安装，请先转换为 Git 仓库或手动更新代码后再使用升级脚本进行备份与权限处理。

---

## 常见问题

- **无法连接 Cacti 数据库**（`FATAL: Connection to Cacti database failed`）  
  请在服务器上确认 MariaDB 已启动，然后执行：  
  `sudo apt-get install -y php8.3-mysql && sudo systemctl restart apache2`

- **安装向导提示必需 PHP 模块缺失**（如 gd、gmp、intl、ldap、mbstring、xml、snmp）  
  请在服务器上执行（按实际 PHP 版本调整 8.3）：  
  `sudo apt-get install -y php8.3-gd php8.3-gmp php8.3-intl php8.3-ldap php8.3-mbstring php8.3-xml php8.3-snmp && sudo systemctl restart apache2`

- **安装向导提示 MySQL 时区数据库未就绪**  
  请在服务器上执行（根据实际 root 密码输入）：  
  `mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p mysql`  
  或使用 MariaDB 工具：  
  `mariadb-tzinfo-to-sql /usr/share/zoneinfo | mysql -u root -p mysql`

- **安装向导提示 RRDtool 二进制路径无效**  
  请在服务器上执行：  
  `sudo apt-get install -y rrdtool`  
  然后用 `which rrdtool` 确认路径为 `/usr/bin/rrdtool`。

---

## 参考

- [Installing Cacti 1.x in Ubuntu/Debian](https://docs.cacti.net/Installing-Under-Ubuntu-Debian.md)
- [Upgrading Cacti](https://docs.cacti.net/Upgrading-Cacti.md)
- [Cacti 官网](https://www.cacti.net/)
