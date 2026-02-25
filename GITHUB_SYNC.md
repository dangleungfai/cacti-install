# 同步到 GitHub

当前目录已是一个 Git 仓库，包含 `install-cacti.sh`、`upgrade-cacti.sh`、`README.md`。

## 方式一：推送到新仓库（仓库名即 cacti-install）

在 GitHub 上新建一个空仓库，例如：`https://github.com/你的用户名/cacti-install`

然后在本地执行（把 `你的用户名` 换成你的 GitHub 用户名）：

```bash
cd /Users/dean/Documents/cursor_projects/cacti-install
git remote add origin https://github.com/你的用户名/cacti-install.git
git branch -M main
git push -u origin main
```

若使用 SSH：

```bash
git remote add origin git@github.com:你的用户名/cacti-install.git
git push -u origin main
```

## 方式二：推送到已有仓库的 cacti-install 目录

若你的 GitHub 仓库已有其他文件，且希望把本目录内容放在该仓库的 `cacti-install/` 子目录下：

1. 克隆你的仓库到临时目录，进入仓库根目录
2. 把本目录的三个文件复制进去：
   - `cp /Users/dean/Documents/cursor_projects/cacti-install/{install-cacti.sh,upgrade-cacti.sh,README.md} cacti-install/`
3. 在仓库根目录执行：`git add cacti-install && git commit -m "Add cacti-install scripts" && git push`

或者在你的仓库里添加 submodule（高级用法）：

```bash
git submodule add https://github.com/你的用户名/cacti-install.git cacti-install
```

当前本地已完成一次提交，只需添加 `origin` 并执行 `git push` 即可同步到 GitHub。
