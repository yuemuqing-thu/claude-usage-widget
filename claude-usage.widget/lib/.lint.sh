#!/bin/sh
# 检查所有 shell 脚本里有没有「$VAR 紧跟全角字符」——
# 这种写法会把多字节吞进变量名，报 unbound variable。踩过两次了。
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
bad=0
for f in "$ROOT"/install.sh "$ROOT"/claude-usage.widget/lib/*.sh "$ROOT"/claude-usage.widget/bin/*.sh; do
  [ -f "$f" ] || continue
  hits=$(python3 -c "
import re,sys
s=open(sys.argv[1]).read()
for m in re.finditer(r'\\\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])', s):
    print('%d: \$%s' % (s[:m.start()].count(chr(10))+1, m.group(1)))
" "$f")
  if [ -n "$hits" ]; then
    echo "✗ $(basename "$f")"; printf '%s\n' "$hits" | sed 's/^/    /'; bad=1
  fi
done
[ "$bad" = 0 ] && echo "✓ 没有 \$VAR 紧跟全角字符的写法"
exit "$bad"
