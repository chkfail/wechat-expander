#!/bin/bash
# 把微信数据镜像挂载到容器内的数据目录。
# 由 LaunchAgent 在开机和插盘时调用，也可手动执行。幂等。

CONF="${WECHAT_EXPANDER_CONF:-$HOME/.config/wechat-expander.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?未配置镜像路径。请创建 $CONF 并写入 WECHAT_IMAGE=/Volumes/你的盘名/WeChatData.sparsebundle}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"
WAIT="${WECHAT_WAIT_SECONDS:-180}"

mount | grep -q " on ${MNT} " && exit 0

for _ in $(seq 1 "$WAIT"); do
  [ -d "$IMG" ] && break
  sleep 1
done
[ -d "$IMG" ] || { echo "$(date): 等待 ${WAIT}s 后仍未找到镜像 ${IMG}，放弃"; exit 1; }

hdiutil attach "$IMG" -mountpoint "$MNT" -nobrowse -owners on \
  && echo "$(date): 挂载成功" || echo "$(date): 挂载失败"
