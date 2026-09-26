#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for file in build.sh sb.sh lib/*.sh tests/*.sh; do bash -n "$file"; done
bash tests/reliability.sh
check_tmp="$(mktemp -d)"
trap 'rm -rf "$check_tmp"' EXIT
cp -R lib build.sh "$check_tmp/"
bash "$check_tmp/build.sh"
cmp sb.sh "$check_tmp/sb.sh"
python3 - <<'PY'
import ast
from pathlib import Path
source = Path('lib/63_telegram_bot.sh').read_text()
embedded = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
ast.parse(embedded)
print('PASS embedded Telegram Python syntax')
PY
