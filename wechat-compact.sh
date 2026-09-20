#!/bin/bash
# 回收微信镜像里已删除数据占用的空间。半年跑一次即可。
set -euo pipefail

M="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
IMG="/Volumes/WDSSD/WeChatData.sparsebundle"

pgrep -x WeChat >/dev/null && { echo "微信还在运行，请 Cmd+Q 完全退出后重试。"; exit 1; }
[ -d "$IMG" ] || { echo "找不到镜像：$IMG（SSD 没插？）"; exit 1; }

echo "压缩前: $(du -sh "$IMG" | cut -f1)"

if mount | grep -q " on ${M} "; then
  echo "卸载镜像..."
  hdiutil detach "$M" >/dev/null
fi

echo "压缩中，几分钟，中途别拔盘别 Ctrl-C..."
hdiutil compact "$IMG"

echo "压缩后: $(du -sh "$IMG" | cut -f1)"

echo "重新挂载..."
bash "$HOME/bin/wechat-mount.sh" >/dev/null 2>&1 || true
if mount | grep -q " on ${M} "; then
  echo "完成，微信可以打开了。"
else
  echo "警告：重新挂载失败，手动跑  bash ~/bin/wechat-mount.sh"
  exit 1
fi
