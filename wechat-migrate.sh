#!/bin/bash
# 一次性迁移：把微信数据拷进 SSD 上的 sparsebundle，再把原目录换成挂载点。
# 只需跑一次。之后由 LaunchAgent + wechat-mount.sh 负责每次开机挂载。
#
# 破坏性操作前有两道 yes 确认，任何一步不满意都可以中止，原数据不动。
set -euo pipefail

CONF="${WECHAT_EXPANDER_CONF:-$HOME/.config/wechat-expander.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?未配置镜像路径。请先跑 ./install.sh，或手动创建 $CONF}"
CONTAINER="${WECHAT_CONTAINER:-$HOME/Library/Containers/com.tencent.xinWeChat/Data}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wcstage.XXXXXX")"

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
      echo "→ 容器不存在。微信可能从未在这台机器上启动过。"
      ;;
  esac
  exit 1
fi

pgrep -x WeChat >/dev/null && { echo "微信还在运行，请 Cmd+Q 完全退出后重试。"; exit 1; }
[ -d "$IMG" ] || { echo "找不到镜像：${IMG}。先跑 ./install.sh 创建它。"; exit 1; }

# --- 1. 自动探测数据目录 -----------------------------------------------
CANDIDATES=(
  "$CONTAINER/Documents/xwechat_files"                              # 微信 4.x
  "$CONTAINER/Library/Application Support/com.tencent.xinWeChat"    # 微信 3.x
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
hdiutil attach "$IMG" -mountpoint "$STAGE" -nobrowse -owners on >/dev/null
trap 'hdiutil detach "$STAGE" >/dev/null 2>&1 || true' EXIT

echo "== 拷贝中（ditto，保留 ACL/xattr）=="
ditto "$SRC" "$STAGE"

echo "== 校验 =="
du -sh "$SRC" "$STAGE"
echo "源文件数:   $(find "$SRC" | wc -l | tr -d ' ')"
echo "目标文件数: $(find "$STAGE" -not -path "$STAGE/.fseventsd*" -not -path "$STAGE/.Spotlight-V100*" | wc -l | tr -d ' ')"
echo
echo "（目标多出几个卷元数据条目属正常，重点看两边 du 的大小是否一致）"
read -r -p "对得上吗？继续替换成挂载点请输入 yes: " ok
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
echo "现在打开微信，验证聊天记录 / 历史图片能否加载 / 文件能否打开 / 搜索。"
echo "确认无误后删除备份："
echo "  rm -rf \"$SRC.bak\""
