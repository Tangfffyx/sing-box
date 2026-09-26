#!/usr/bin/env bash
# ============================================================
# build.sh — 将 lib/*.sh 模块合并为单体 sb.sh 用于分发
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

{
  echo '#!/usr/bin/env bash'
  echo ''
  echo '# ============================================================'
  echo '# Sing-box Elite Management System'
  echo '# 由 build.sh 自动合并生成，请勿直接编辑此文件'
  echo '# 源码位于 lib/ 目录下的各模块文件'
  echo '# ============================================================'
  echo ''

  for f in "$LIB_DIR"/[0-9]*.sh; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    echo ""
    echo "# >>>>>>>>> BEGIN MODULE: $fname <<<<<<<<<<<"
    # 跳过 shebang 行，保留其余全部内容
    tail -n +2 "$f" | sed 's/\r$//'
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
