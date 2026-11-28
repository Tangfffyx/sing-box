#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for file in build.sh sb.sh lib/*.sh tests/*.sh; do bash -n "$file"; done
bash tests/reliability.sh
bash tests/migration.sh
bash tests/export.sh
bash tests/telegram-tasks.sh
bash tests/stage-a.sh
bash tests/stage-b.sh
bash tests/stage-c.sh
bash tests/stage-d.sh
bash tests/stage-e.sh
bash tests/stage-f.sh
bash tests/stage-g.sh
bash tests/stage-h.sh
bash tests/stage-i-uninstall.sh
if [ -f tests/tg-center-unit.py ]; then
  python3 tests/tg-center-unit.py
fi
check_tmp="$(mktemp -d)"
trap 'rm -rf "$check_tmp"' EXIT
cp -R lib py build.sh "$check_tmp/"
bash "$check_tmp/build.sh"
cmp sb.sh "$check_tmp/sb.sh"
python3 - <<'PY'
import ast
from pathlib import Path
src = Path('py/tg_center_bot.py').read_text(encoding='utf-8')
ast.parse(src)
built = Path('sb.sh').read_text(encoding='utf-8')
assert '# __EMBED_PY__:' not in built, 'Unresolved embed placeholder in sb.sh'
marker = 'cat > "$TG_CENTER_APP" <<\'PY\'\n'
embedded = built.split(marker, 1)[1].split('\nPY\n', 1)[0]
ast.parse(embedded)
print('PASS standalone & embedded Telegram Python syntax')
PY
