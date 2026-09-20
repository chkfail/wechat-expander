#!/bin/bash
set -euo pipefail

CONTAINER="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
IMG="/Volumes/WDSSD/WeChatData.sparsebundle"
STAGE="/tmp/wcstage"

# --- 0. 环境诊断 -------------------------------------------------------
if ! ls "$CONTAINER" >/dev/null 2>&1; then
  err="$(ls "$CONTAINER" 2>&1 || true)"
  echo "无法读取微信容器目录。系统返回："
  echo "    ${err}"
  echo
  case "$err" in
    *"Operation not permitted"*)
      echo "→ 这是 TCC 权限问题，不是路径问题。"
      echo "  当前 shell 的宿主进程是："
      echo "    $(ps -o comm= -p $PPID 2>/dev/null || echo '(无法获取)')"
      echo "  需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里"
      echo "  给这个进程授权，然后完全退出它再重开。"
      echo "  建议直接用系统自带的「终端」App 跑本脚本。"
      ;;
    *"No such file"*)
      echo "→ 容器不存在。这台机器上的微信可能从未启动过，或版本不同。"
      ;;
  esac
  exit 1
fi

pgrep -x WeChat >/dev/null && { echo "微信还在运行，请完全退出（Cmd+Q）后重试。"; exit 1; }
[ -d "$IMG" ] || { echo "找不到镜像：$IMG（SSD 没插？）"; exit 1; }

# --- 1. 自动探测数据目录 -----------------------------------------------
CANDIDATES=(
  "$CONTAINER/Documents/xwechat_files"
  "$CONTAINER/Library/Application Support/com.tencent.xinWeChat"
)
SRC=""
echo "== 候选路径 =="
for c in "${CANDIDATES[@]}"; do
  if [ -d "$c" ]; then
    printf '  [有] %s  (%s)\n' "$c" "$(du -sh "$c" 2>/dev/null | cut -f1)"
    [ -z "$SRC" ] && SRC="$c"
  else
    printf '  [无] %s\n' "$c"
  fi
done
[ -n "$SRC" ] || { echo "两个候选路径都不存在，请手动确认数据位置。"; exit 1; }
echo
echo "将迁移: $SRC"
read -r -p "确认这个目录吗？输入 yes 继续: " ok
[ "$ok" = "yes" ] || { echo "已中止，未做任何修改。"; exit 1; }

# --- 2. 拷入镜像 -------------------------------------------------------
mkdir -p "$STAGE"
hdiutil attach "$IMG" -mountpoint "$STAGE" -nobrowse -owners on >/dev/null
trap 'hdiutil detach "$STAGE" >/dev/null 2>&1 || true' EXIT

echo "== 拷贝中（ditto，保留 ACL/xattr）=="
ditto "$SRC" "$STAGE"

echo "== 校验 =="
du -sh "$SRC" "$STAGE"
echo "源文件数:   $(find "$SRC" | wc -l | tr -d ' ')"
echo "目标文件数: $(find "$STAGE" -not -path "$STAGE/.fseventsd*" -not -path "$STAGE/.Spotlight-V100*" | wc -l | tr -d ' ')"
echo
read -r -p "两组数字对得上吗？继续替换成挂载点请输入 yes: " ok
[ "$ok" = "yes" ] || { echo "已中止，原数据未动。镜像内已有副本，可重跑。"; exit 1; }

hdiutil detach "$STAGE" >/dev/null; trap - EXIT; rmdir "$STAGE" 2>/dev/null || true

# --- 3. 换成挂载点 -----------------------------------------------------
mv "$SRC" "$SRC.bak"
mkdir -p "$SRC"
chflags uchg "$SRC"        # 未挂载时阻止微信写入，避免数据分叉
hdiutil attach "$IMG" -mountpoint "$SRC" -nobrowse -owners on >/dev/null

echo
echo "完成。挂载状态："
mount | grep -F "$SRC" || echo "  (警告：没看到挂载记录)"
echo
echo "现在打开微信验证聊天记录 / 图片 / 文件。"
echo "确认无误后删除备份："
echo "  rm -rf \"$SRC.bak\""
