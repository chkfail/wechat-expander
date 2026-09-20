# wechat-expander

把 macOS 微信的聊天数据搬到外置 SSD，**不重签名、不装 kext、不降低系统安全策略**。

适合小容量内置盘 + 常年外接 SSD 的 Mac（尤其是 Mac mini / Studio 这类台式机）。

![platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![license](https://img.shields.io/badge/license-MIT-blue)

> **English summary** — WeChat for Mac keeps tens of gigabytes of chat history inside
> its App Sandbox container and, unlike the Windows client, offers no setting to move
> it. A symlink does not work: the sandbox resolves symlinks and checks the *real*
> path, which now lies outside the container. The popular workaround — stripping the
> code signature with `codesign --force --deep --sign -` — breaks on every WeChat
> update and disables entitlement-dependent features.
>
> This project instead **mounts an APFS sparsebundle stored on an external SSD
> directly at the container's data directory**. A mount does not change the path, only
> the filesystem behind it, so the sandbox rule still matches and the signature is
> untouched. No re-signing, no macFUSE/kext, no reduced startup security policy.
> Because `hdiutil attach -mountpoint` needs no root, a plain user LaunchAgent handles
> mounting at boot and on re-plug. An immutable (`chflags uchg`) mount point prevents
> WeChat from silently rebuilding a divergent data set when the SSD is absent.
>
> Docs below are in Chinese; the scripts print Chinese messages too.

## 问题

Mac 版微信的聊天数据放在沙盒容器里，几年下来轻松吃掉几十 GB：

```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files
```

而 **Mac 版微信没有「更改存储位置」这个设置**（Windows 版 4.0 有，Mac 版一直没有）。

## 为什么软链接不行

微信是沙盒应用：

```console
$ codesign -d --entitlements - /Applications/WeChat.app
    [Key] com.apple.security.app-sandbox
    [Key] com.apple.security.files.downloads.read-write
    [Key] com.apple.security.files.user-selected.read-write
```

App Sandbox 校验的是**路径解析之后的真实位置**。软链接会解析到 `/Volumes/...`，落在容器外面，直接被拒。

网上流传的教程靠 `codesign --force --deep --sign -` 砸掉签名来绕过，代价是：微信每次自动更新都要重签、依赖 entitlement 的功能（如截图）失效、TCC 授权重置。本项目不走这条路。

## 方案：挂载点

挂载**不改变路径**，只替换路径背后的文件系统。路径仍在容器前缀内，沙盒的 `subpath` 规则照常匹配，签名完全不动。

macOS 没有 Linux 的 `mount --bind`，不能把目录挂到目录上，所以需要先用磁盘映像造出一个真正的块设备。sparsebundle 在这里的作用**不是**跨平台兼容，纯粹是「变出一个可挂载的设备」—— 并且 `hdiutil attach -mountpoint` 挂到用户自己的目录**不需要 root**，这让开机自动挂载可以用普通 LaunchAgent 完成，不必上 LaunchDaemon。

```
微信（沙盒进程）
 │   只认这一个路径，写死在容器里
 ▼
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files   ← 挂载点
 │   底下是一个 chflags uchg 的空目录，挂载时被盖住
 ▼
/dev/diskNs1    内层 APFS 卷「WeChatData」
 ▼
/dev/diskN      虚拟磁盘设备（hdiutil 从 sparsebundle 拉起）
 ▼
/Volumes/你的SSD/WeChatData.sparsebundle
 ▼
            外置 SSD
```

### 对比其他方案

| 方案 | 结论 |
|---|---|
| 软链接 + 重签名 | ❌ 破坏沙盒签名，微信每次更新都要重签，截图等功能失效 |
| macFUSE + bindfs | ❌ 需加载第三方 kext；Apple Silicon 必须进恢复模式把启动安全策略降到「降低安全性」 |
| 在 SSD 的 APFS 容器里直接加第二个卷 | ⚠️ 存储上更干净（共享空间、无需 compact），但挂到自定义路径需要 root → 得用 LaunchDaemon。未验证 |
| **sparsebundle + 挂载点**（本项目） | ✅ 免 root、免 kext、不动签名 |

## 要求

- macOS，外接 SSD（APFS 或 HFS+ 最佳）
- 微信 3.x 或 4.x（迁移脚本会自动探测两种目录结构）
- **SSD 需要常年接着** —— 拔掉时微信将无法打开（数据不会丢，见下）

## 安装

```bash
git clone https://github.com/chkfail/wechat-expander.git
cd wechat-expander
./install.sh /Volumes/你的SSD
```

`install.sh` 会创建镜像、写配置到 `~/.config/wechat-expander.conf`、把脚本装到 `~/bin/`、生成并加载 LaunchAgent。**它不动你的数据。**

然后还有两步必须手动：

### 1. 给 `/bin/bash` 完全磁盘访问权限

系统设置 → 隐私与安全性 → 完全磁盘访问权限 → `+` → 文件选择器里按 **Cmd+Shift+G** 输入 `/bin/bash` → 添加并打开。

LaunchAgent 以 `/bin/bash` 的身份访问受 TCC 保护的容器目录，没有这个授权，开机挂载会报 `Permission denied`。

> 觉得给系统 bash 开全盘权限太宽，可以 `cp /bin/bash ~/bin/wcbash`，把 plist 里的 `/bin/bash` 改成副本路径，只给副本授权。

### 2. 迁移数据

**必须在「终端」App 里跑**（同样需要完全磁盘访问权限，加完记得 Cmd+Q 退出终端再重开才生效），并且**先 Cmd+Q 完全退出微信**：

```bash
./wechat-migrate.sh
```

脚本会自动探测数据目录、拷进镜像、打印两边大小和文件数让你核对。**破坏性操作前有两道 `yes` 确认**，任何一步不满意都能中止，原数据不动。原目录会先改名成 `.bak` 保留，等你打开微信验证无误后再自己删。

## 日常使用

装完之后基本不用管 —— 开机和插盘时 LaunchAgent 会自动挂载。

```bash
# 查看状态
mount | grep xwechat
cat "${TMPDIR:-/tmp}/wechatmount.log"

# 手动挂载（自动挂载失败时）
bash ~/bin/wechat-mount.sh

# 回收空间（先 Cmd+Q 退微信）
bash ~/bin/wechat-compact.sh
```

## 注意事项

**拔盘前必须 Cmd+Q 退出微信。** 这是本方案唯一的真实风险点 —— SQLite 写到一半断连接会损坏数据库。插回去会自动重挂，不用手动操作。

**挂载点上的 `uchg` 是数据分叉保护。** 挂载失败时，那个空目录是 immutable 的，微信写不进去、只会报错打不开。没有这层保护的话，微信会在内置盘重建一套空数据，你以为没事继续用，下次挂载成功时这套新数据被盖掉 —— 那才是真正会丢东西的场景。

**sparsebundle 只增不减。** 在微信里删聊天记录不会把空间还给 SSD，要跑 `wechat-compact.sh` 回收。

**手机端才是聊天记录的主备份。** Mac 端始终当缓存看待。另外记得把 sparsebundle 加进 Time Machine 排除列表（如果你用 TM 备份那块外置盘的话），否则每次备份都会传一堆 band 文件。

**`hdiutil` 在较新的 macOS 上已有废弃告警**，提示改用 `diskutil image attach --mountPoint`。告警无害。但注意 `hdiutil attach -mountpoint` **不需要 root**，而 `diskutil` 挂到自定义路径可能需要 —— 将来真被移除时，免 root 这个前提要重新验证。

## 回退

```bash
# 先 Cmd+Q 退微信
. ~/.config/wechat-expander.conf
MNT="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"

launchctl unload ~/Library/LaunchAgents/com.local.wechatmount.plist
rm ~/Library/LaunchAgents/com.local.wechatmount.plist

hdiutil attach "$WECHAT_IMAGE" -mountpoint /tmp/wcback -nobrowse -owners on
hdiutil detach "$MNT"
chflags nouchg "$MNT" && rmdir "$MNT"
ditto /tmp/wcback "$MNT"
hdiutil detach /tmp/wcback
```

内置盘需要有足够空间容纳全部数据。

## 文件

| 文件 | 作用 |
|---|---|
| `install.sh` | 创建镜像、写配置、装脚本和 LaunchAgent。不动数据 |
| `wechat-migrate.sh` | 一次性迁移。路径自动探测 + 两道确认 |
| `wechat-mount.sh` | 挂载。幂等，会等待 SSD 出现（默认最多 180 秒） |
| `wechat-compact.sh` | 回收 sparsebundle 空间 |
| `com.local.wechatmount.plist.template` | LaunchAgent 模板，`RunAtLoad` + `StartOnMount` |

配置从 `~/.config/wechat-expander.conf` 读取，也可用同名环境变量覆盖。

## License

MIT
