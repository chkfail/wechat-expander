#!/bin/bash
# 安装 wechat-expander：创建镜像、写配置、装脚本、装 LaunchAgent。
# 不迁移数据 —— 装完再单独跑 ./wechat-migrate.sh。
#
# 用法：./install.sh /Volumes/你的SSD [镜像上限]
#   例：./install.sh /Volumes/MySSD 500g
set -euo pipefail

VOL="${1:-}"
SIZE="${2:-500g}"

if [ -z "$VOL" ]; then
  echo "用法: $0 /Volumes/你的SSD [镜像上限，默认 500g]"
  echo
  echo "当前已挂载的卷："
  ls -1 /Volumes
  exit 1
fi

[ -d "$VOL" ] || { echo "找不到卷：$VOL"; exit 1; }

FS="$(mount | sed -n "s|^.* on ${VOL} (\([^,)]*\).*|\1|p" | head -1)"
case "$FS" in
  apfs|hfs) ;;
  "") echo "警告：无法判断 $VOL 的文件系统类型，请自行确认是 APFS 或 HFS+。" ;;
  *)  echo "注意：$VOL 是 ${FS}。sparsebundle 内层是独立的 APFS 卷，所以 exFAT 外壳也能用，"
      echo "      但拔盘风险更高，务必遵守「拔盘前先退微信」。" ;;
esac

CONF="${WECHAT_EXPANDER_CONF:-$HOME/.config/wechat-expander.conf}"
IMG="$VOL/WeChatData.sparsebundle"
BIN="$HOME/bin"
LOG="${TMPDIR:-/tmp}/wechatmount.log"
PLIST="$HOME/Library/LaunchAgents/com.local.wechatmount.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "镜像:   $IMG"
echo "配置:   $CONF"
echo "脚本:   $BIN/"
echo "Agent:  $PLIST"
echo
read -r -p "继续？输入 yes: " ok
[ "$ok" = "yes" ] || { echo "已中止。"; exit 1; }

# 1. 镜像
if [ -d "$IMG" ]; then
  echo "镜像已存在，跳过创建。"
else
  echo "创建镜像（上限 ${SIZE}，稀疏按需增长，不会立刻占满）..."
  hdiutil create -size "$SIZE" -type SPARSEBUNDLE -fs APFS -volname WeChatData "$IMG"
fi

# 2. 配置
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# wechat-expander 配置
WECHAT_IMAGE="$IMG"
# WECHAT_MOUNT="\$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
# WECHAT_WAIT_SECONDS=180
EOF
echo "已写入 $CONF"

# 3. 脚本
mkdir -p "$BIN"
install -m 755 "$HERE/wechat-mount.sh" "$BIN/wechat-mount.sh"
install -m 755 "$HERE/wechat-compact.sh" "$BIN/wechat-compact.sh"
echo "已安装 $BIN/wechat-mount.sh 和 $BIN/wechat-compact.sh"

# 4. LaunchAgent
mkdir -p "$(dirname "$PLIST")"
sed -e "s|__SHELL__|/bin/bash|" \
    -e "s|__MOUNT_SCRIPT__|$BIN/wechat-mount.sh|" \
    -e "s|__LOG__|$LOG|" \
    "$HERE/com.local.wechatmount.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "已加载 LaunchAgent（日志 ${LOG}）"

cat <<EOF

────────────────────────────────────────────────────────────
装完了。还有两件事必须你手动做：

1. 给 /bin/bash 完全磁盘访问权限
   系统设置 → 隐私与安全性 → 完全磁盘访问权限 → +
   → 在文件选择器里按 Cmd+Shift+G，输入 /bin/bash → 添加并打开

   不做这步，开机自动挂载会报 Permission denied。原因见 README。

2. 迁移数据（在有完全磁盘访问权限的「终端」App 里，先 Cmd+Q 退微信）
   bash $HERE/wechat-migrate.sh
────────────────────────────────────────────────────────────
EOF
