# wechat-expander

把 macOS 微信的聊天数据从内置盘迁到外置 SSD，用**挂载点**绕过 App Sandbox，不改签名、不装 kext、不降系统安全策略。

已于 2026-09-20 在本机部署并验证通过。内置盘可用空间 48Gi → 76Gi。

## 为什么是这个方案

- Mac 版微信**没有**「更改存储位置」设置（Windows 4.0 有，Mac 一直没有）。
- 微信是沙盒应用（`codesign -d --entitlements` 确认有 `com.apple.security.app-sandbox`，只有 `user-selected.read-write` 和 `downloads.read-write`，无任何指向外置卷的 temporary-exception）。
- **软链接必然失败**：沙盒校验的是路径解析之后的真实位置。软链接会解析到 `/Volumes/...`，落在容器外，直接被拒。
- **挂载点可以**：挂载不改变路径，只替换路径背后的文件系统。路径仍在容器前缀内，沙盒的 `subpath` 规则照常匹配。
- macOS 没有 Linux 的 `mount --bind`，不能把目录挂到目录上，所以需要先用磁盘映像造出一个真正的块设备。sparsebundle 在这里的作用**不是**跨平台兼容，纯粹是「变出一个可挂载的设备」。

### 已评估并否决的方案

| 方案 | 否决原因 |
|---|---|
| 软链接 + `codesign --force --deep --sign -` 重签名 | 砸掉沙盒签名；微信每次自动更新都要重签；截图等依赖 entitlement 的功能失效；TCC 授权重置 |
| macFUSE + bindfs | 需加载第三方 kext，Apple Silicon 必须进恢复模式把启动安全策略降到「降低安全性」 |
| 在 SSD 的 APFS 容器里直接加第二个卷 | 存储上更干净（共享空间、无需 compact），但挂到自定义路径大概率需要 root → 得用 LaunchDaemon。**未实测**。sparsebundle 的免 root 挂载已实测通过，为了 LaunchAgent 选了后者 |

## 架构

```
微信（沙盒进程）
 │   只认这一个路径，写死在容器里
 ▼
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files   ← 挂载点
 │   底下是一个 chflags uchg 的空目录，挂载时被盖住
 ▼
/dev/disk5s1    内层 APFS 卷「WeChatData」
 ▼
/dev/disk5      虚拟磁盘设备（hdiutil 从 sparsebundle 拉起）
 ▼
/Volumes/WDSSD/WeChatData.sparsebundle    上限 500G，实占约 29G
 ▼
/dev/disk7s1    外层 APFS 卷「WDSSD」（2TB APFS 容器 disk7，物理存储 disk6s1）
 ▼
            2TB 外置 SSD
```

两层嵌套 APFS。设备号每次挂载会变，别硬编码。

## 文件与部署位置

| 本仓库文件 | 部署到 | 作用 |
|---|---|---|
| `wechat-migrate.sh` | 一次性，不部署 | 迁移。自动探测 4.x (`xwechat_files`) / 3.x (`Application Support`) 路径，两道 `yes` 确认，拷完校验大小和文件数才做破坏性 `mv` |
| `wechat-mount.sh` | `~/bin/wechat-mount.sh` | 挂载。幂等（已挂载直接退出），最多轮询 180 秒等 SSD 出现 |
| `com.local.wechatmount.plist` | `~/Library/LaunchAgents/` | LaunchAgent。`RunAtLoad` + `StartOnMount`，日志 `/tmp/wechatmount.log` |
| `wechat-compact.sh` | `~/bin/wechat-compact.sh` | 回收 sparsebundle 中已删除数据占用的空间 |

`StartOnMount` 意味着任何新文件系统挂载时都会触发一次，所以拔插 SSD 能自动恢复。脚本幂等，重复触发无害。

## 关键约束（踩过的坑）

**`/bin/bash` 必须有完全磁盘访问权限。** LaunchAgent 以 `/bin/bash` 的身份访问受 TCC 保护的容器目录，没有 FDA 时 `hdiutil attach` 报 `Permission denied`。这是部署时唯一真正卡住的环节。更收敛的替代：`cp /bin/bash ~/bin/wcbash`，改 plist 指向副本，只给副本授权（当时为省事没做）。

**TCC ≠ seatbelt 沙盒。** 两套独立机制。关掉 seatbelt 对 `~/Library/Containers/*/Data` 的 `Operation not permitted` 毫无帮助 —— 那是 TCC，只能在系统设置里授权且需要重启进程生效。

**挂载点上的 `uchg` 是数据分叉保护。** 挂载失败时微信写不进去，只会报错打不开；没有这层保护，微信会在内置盘重建一套空数据，下次挂载成功时被盖掉 —— 那才是真正会丢数据的场景。2026-09-20 部署时因 FDA 缺失挂载失败了两次，事后验证挂载点目录 `total 0` + `uchg` 仍在 + mtime 未变，保护确实生效了。

**拔盘前必须 Cmd+Q 退微信。** SQLite 写到一半断连接会坏库。这是本方案唯一的真实风险点。

**sparsebundle 只增不减。** 在微信里删聊天记录不会把空间还给 SSD，要跑 `wechat-compact.sh`。

**`hdiutil` 在当前 macOS 已有废弃告警**，提示改用 `diskutil image attach --mountPoint`。告警无害，但注意：`hdiutil attach -mountpoint` **不需要 root**（已实测），而 `diskutil` 挂到自定义路径可能需要。将来真被移除时要重新验证免 root 这一点。

**`sudo` + 进程替换 `<(...)` 会报 `Bad file descriptor`。** 排查时用临时文件代替。本项目的操作都不需要 sudo。

**本机没有配置 Time Machine**（`tmutil destinationinfo` → No destinations）。外置卷默认已排除，所以无需额外排除 sparsebundle。同时意味着微信数据在 Mac 上没有备份 —— 手机端是唯一的另一份。

## 常用操作

全部在有 FDA 的 Terminal.app 里执行。

```bash
# 查看状态
mount | grep xwechat
cat /tmp/wechatmount.log
du -sh /Volumes/WDSSD/WeChatData.sparsebundle

# 手动挂载（自动挂载失败时）
bash ~/bin/wechat-mount.sh

# 回收空间（先 Cmd+Q 退微信）
bash ~/bin/wechat-compact.sh

# 强制重跑 LaunchAgent（先 detach，否则脚本因幂等直接跳过）
hdiutil detach ~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files
launchctl kickstart -k gui/$(id -u)/com.local.wechatmount
```

## 回退

```bash
# 1. Cmd+Q 退微信
M=~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files
# 2. 卸掉 LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.local.wechatmount.plist
rm ~/Library/LaunchAgents/com.local.wechatmount.plist
# 3. 把数据拷回内置盘
hdiutil attach /Volumes/WDSSD/WeChatData.sparsebundle -mountpoint /tmp/wcback -nobrowse -owners on
hdiutil detach "$M"
chflags nouchg "$M" && rmdir "$M"
ditto /tmp/wcback "$M"
hdiutil detach /tmp/wcback
```

内置盘需要有足够空间（约 29G）。

## 给后续 session 的提示

- Claude Code 自己的 shell（包括 `!` 命令模式）**永远没有 FDA**，任何触碰 `~/Library/Containers/*/Data` 的命令在这里必然失败。需要用户在 Terminal.app 里执行。
- 判断命令跑在哪：输出带 `andrie@Mac-mini %` 提示符的是 Terminal.app（有 FDA）。
- 写 `~/bin`、`~/Library/LaunchAgents` 可能被权限策略拦截，需要用户自己 `cp`。
