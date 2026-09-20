#!/bin/bash
# 开机 / SSD 插入时把微信数据镜像挂回容器
IMG="/Volumes/WDSSD/WeChatData.sparsebundle"
MNT="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"

mount | grep -q " on ${MNT} " && exit 0

for _ in $(seq 1 180); do
  [ -d "$IMG" ] && break
  sleep 1
done
[ -d "$IMG" ] || { echo "$(date): SSD 未出现，放弃"; exit 1; }

hdiutil attach "$IMG" -mountpoint "$MNT" -nobrowse -owners on \
  && echo "$(date): 挂载成功" || echo "$(date): 挂载失败"
