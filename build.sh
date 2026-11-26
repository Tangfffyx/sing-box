#!/usr/bin/env bash
# ============================================================
# build.sh — 将 lib/*.sh 与 py/*.py 合并为单体 sb.sh 用于分发
# 用法: bash build.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
OUT="${SCRIPT_DIR}/sb.sh"

if [ ! -d "$LIB_DIR" ]; then
  echo "[ERR] 未找到 lib/ 目录: $LIB_DIR"
  exit 1
fi

emit_module_with_embeds() {
  local file="$1" line rel_path target
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^#\ __EMBED_PY__:(.+)$ ]]; then
      rel_path="${BASH_REMATCH[1]}"
      target="${SCRIPT_DIR}/${rel_path}"
      if [ ! -f "$target" ]; then
        echo "[ERR] 未找到待内嵌文件: $target" >&2
        return 1
      fi
      sed 's/\r$//' "$target"
    else
      printf '%s\n' "$line"
    fi
  done < <(tail -n +2 "$file")
}

{
  echo '#!/usr/bin/env bash'
  echo ''
  echo '# ============================================================'
  echo '# Sing-box Management System'
  echo '# 由 build.sh 自动合并生成，请勿直接编辑此文件'
  echo '# 源码位于 lib/ 与 py/ 目录'
  echo '# ============================================================'
  echo ''

  for f in "$LIB_DIR"/[0-9]*.sh; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    echo ""
    echo "# >>>>>>>>> BEGIN MODULE: $fname <<<<<<<<<<<"
    emit_module_with_embeds "$f"
    echo ""
    echo "# >>>>>>>>> END MODULE: $fname <<<<<<<<<<<"
  done
} > "$OUT"

chmod +x "$OUT"

# 提取版本号用于验证
version="$(grep -E '^SCRIPT_VERSION=' "$OUT" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
lines="$(wc -l < "$OUT")"

echo "[OK] 构建完成: $OUT"
echo "     版本: ${version:-未知}"
echo "     行数: $lines"
