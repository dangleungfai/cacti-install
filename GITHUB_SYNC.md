# 使用 SSH 同步到 GitHub

当前目录已是一个 Git 仓库，包含 `install-cacti.sh`、`upgrade-cacti.sh`、`README.md` 等文件。

## 1. 准备 GitHub 仓库

1. 在 GitHub 上新建一个空仓库，例如：`https://github.com/你的用户名/cacti-install`
2. 确保本机已配置 SSH 公钥，并在 GitHub 账号中添加该公钥

## 2. 配置 SSH 远程并推送

在本机执行（将 `你的用户名` 替换为你的 GitHub 用户名）：

```bash
cd /Users/dean/Documents/cursor_projects/cacti-install
git remote add origin git@github.com:你的用户名/cacti-install.git
git branch -M main
git push -u origin main
```

首次推送成功后，后续只需：

```bash
git push
```

即可通过 SSH 将本地变更同步到 GitHub。
