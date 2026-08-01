#!/usr/bin/env bash
# =============================================================================
# 将 mattpocock/skills 更新到最新版（v1.2.0, 2ab9580），并同步 reasonix
# 实际读取的 ~/.agents/skills 副本（reasonix 将 ~/.agents/skills 作为 global
# skill root 直接扫描，实测 read_skill 来源为 /Users/sasa/.agents/skills/<skill>/SKILL.md；
# ~/.claude/skills 中的同名条目为指向它的符号链接，同步后自动生效）。
#
# 用法:
#   bash ~/Vibe_product_MVP/浏览器录屏插件/update-mattpocock-skills.sh
# 测试模式（不碰真实环境）:
#   REPO=/tmp/mattpocock-skills-latest DEST=/tmp/test-dest bash <脚本路径>
# =============================================================================
set -euo pipefail
shopt -s nullglob

REPO="${REPO:-$HOME/skills-repos/mattpocock-skills}"
DEST="${DEST:-$HOME/.agents/skills}"
EXPECTED_HEAD="2ab958093e83e0ec752e6c1c5932da465bf23e0c"

# 规范化路径（去尾斜杠），防止 "$HOME/"、"$REPO/" 等变体绕过下面的防护
REPO="${REPO%/}"
DEST="${DEST%/}"
[ -n "$REPO" ] || { echo "✗ REPO 为空（原值可能为 / 或空串），已中止" >&2; exit 1; }
[ -n "$DEST" ] || { echo "✗ DEST 为空，已中止" >&2; exit 1; }

# 安全防护：DEST 不得指向 $HOME 本身或 $REPO 内部（防 rsync --delete 误删大范围目录）
case "$DEST" in
  "$HOME"|"$REPO"|"$REPO"/*)
    echo "✗ 危险配置: DEST=$DEST 指向 HOME 或 REPO 内部，已中止（请检查 DEST 环境变量）" >&2
    exit 1
    ;;
esac

echo "==> 1/5 处理未跟踪的旧 marketplace.json（避免阻塞 git pull）"
if [ -f "$REPO/.claude-plugin/marketplace.json" ] && \
   ! git -C "$REPO" ls-files --error-unmatch .claude-plugin/marketplace.json >/dev/null 2>&1; then
  cp "$REPO/.claude-plugin/marketplace.json" "$REPO/.claude-plugin/marketplace.json.bak.$(date +%Y%m%d-%H%M%S)"
  rm "$REPO/.claude-plugin/marketplace.json"
  echo "    已备份并移除未跟踪的 marketplace.json（远程 1.2.0 已跟踪同名文件）"
else
  echo "    无需处理"
fi

echo "==> 2/5 git pull（--ff-only，禁用 hooks）"
git -C "$REPO" -c core.hooksPath=/dev/null pull --ff-only origin main

echo "==> 3/5 版本校验"
HEAD="$(git -C "$REPO" rev-parse HEAD)"
echo "    HEAD = $HEAD"
if [ "$HEAD" = "$EXPECTED_HEAD" ]; then
  echo "    ✓ 已是最新版 v1.2.0"
elif [ "${ALLOW_UNEXPECTED_HEAD:-0}" = "1" ]; then
  echo "    ⚠ HEAD 与预期不一致但 ALLOW_UNEXPECTED_HEAD=1，继续同步"
else
  echo "    ✗ HEAD($HEAD) 与预期($EXPECTED_HEAD) 不一致 —— 供应链校验失败，已中止" >&2
  echo "      若确知仓库已更新，可设置 ALLOW_UNEXPECTED_HEAD=1 后重试（自行承担风险）" >&2
  exit 1
fi

echo "==> 4/5 同步 skill 副本到 $DEST"
count=0
for d in "$REPO"/skills/engineering/*/ "$REPO"/skills/productivity/*/; do
  name="$(basename "$d")"
  # 防护：若目标已是符号链接，rsync --delete 会跟随链接误删其指向目录，必须跳过
  if [ -L "$DEST/$name" ]; then
    echo "    ✗ 跳过 $name：$DEST/$name 是符号链接（为避免 --delete 误删链接目标），请手动处理"
    continue
  fi
  mkdir -p "$DEST/$name"
  rsync -a --delete "$d" "$DEST/$name/"
  count=$((count+1))
done
echo "    已同步 $count 个 skill"
if [ "$count" -eq 0 ]; then
  echo "    ✗ 警告：未匹配到任何 skill 目录，请检查仓库结构与 REPO 路径"
fi

echo "==> 5/5 一致性校验"
mismatch=0
for d in "$REPO"/skills/engineering/*/ "$REPO"/skills/productivity/*/; do
  name="$(basename "$d")"
  [ -L "$DEST/$name" ] && continue
  if ! diff -rq "$d" "$DEST/$name/" >/dev/null 2>&1; then
    echo "    ✗ 不一致: $name"
    mismatch=1
  fi
done
if [ "$mismatch" -eq 0 ]; then
  echo "    ✓ 副本与仓库完全一致"
else
  echo "    ✗ 存在不一致的 skill 副本，已中止（exit 1）" >&2
  exit 1
fi

echo ""
echo "完成。reasonix 下次会话将读取最新版 skill（重启 reasonix 可立即刷新索引）。"
echo "说明: 上游仓库删除的 skill 不会自动清理 ~/.agents/skills 旧副本（--delete 仅作用于同名目录内部）。"
echo "可选清理: 若不需要旧备份，可删除 $REPO/.claude-plugin/marketplace.json.bak.*"
