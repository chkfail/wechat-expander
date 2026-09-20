# CLAUDE.md

方案背景、原理、对比和使用说明都在 [README.md](README.md)，先读那个。本文件只记录改这套脚本时需要知道的约定和坑。

## 代码约定

**配置统一从 `~/.config/wechat-expander.conf` 读，环境变量可覆盖。** 每个脚本顶部四行：

```bash
CONF="${WECHAT_EXPANDER_CONF:-$HOME/.config/wechat-expander.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?...}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"
```

别在脚本里写死卷名或 home 路径 —— 这是公开仓库，之前踩过这个坑。plist 同理，用 `.template` + `install.sh` 里的 `sed` 填充。

**`wechat-mount.sh` 必须保持幂等。** `StartOnMount` 会在任何文件系统挂载时触发，重复执行是常态。开头那句 `mount | grep -q " on ${MNT} "` 是必需的，不是优化。

**破坏性操作必须有 `yes` 确认。** `wechat-migrate.sh` 里那两道关卡不要合并或去掉 —— 第二道是在 `ditto` 完成、校验数字打印之后、`mv` 之前，这个顺序是关键。

## 改动时容易踩的坑

**TCC ≠ App Sandbox，两套独立机制。** `~/Library/Containers/*/Data` 的 `Operation not permitted` 是 TCC，关掉 seatbelt 沙盒毫无帮助，只能在系统设置里授权且需要重启进程生效。调试时别把两者混为一谈。

**免 root 是这个方案成立的前提。** `hdiutil attach -mountpoint <用户目录>` 不需要 root（已实测），所以能用 LaunchAgent。任何把它换成 `diskutil` 或别的挂载方式的改动，都必须先验证免 root 是否还成立 —— 否则整个架构要退化成 LaunchDaemon。

**`uchg` 不是装饰。** 挂载点空目录上的 immutable 标志是数据分叉保护，已在真实的挂载失败场景下验证生效（失败后目录仍为空、标志仍在、mtime 未变）。不要因为"看起来多余"而删掉。挂载到 immutable 目录是正常工作的，实测过。

**`find` 比对两边文件数时，目标会多出卷元数据条目**（`.fseventsd` 等），属正常。判断拷贝完整性以 `du` 大小为准，别把文件数写成硬性断言。

**`sudo` + 进程替换 `<(...)` 会报 `Bad file descriptor`。** 排查时用临时文件代替。本项目所有操作都不需要 sudo。

## 给 AI agent 的操作提示

- **Claude Code 自己的 shell（包括 `!` 命令模式）没有完全磁盘访问权限**，任何触碰 `~/Library/Containers/*/Data` 的命令在这里必然失败。这类命令要交给用户在「终端」App 里执行。
- 判断命令跑在哪：输出带 shell 提示符（`用户名@主机名 %`）的是用户自己的终端。
- 写 `~/bin`、`~/Library/LaunchAgents`、`.git/config` 可能被沙盒或权限策略拦截，必要时让用户自己执行。
- 想验证挂载逻辑，可以拿一个临时 sparsebundle 挂到 `$TMPDIR` 下的目录测，不要拿真实微信数据试。
