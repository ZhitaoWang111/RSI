#!/usr/bin/env bash
#
# Rewrite the URL hosts recorded in Submodule/ASPIRE/aspire/sim/uv.lock so
# that uv pulls from a domestic mirror instead of PyPI.
#
# Why this works: mirror files are byte-identical to PyPI's (verified by
# sha256 for both a normal wheel and the torch cu126 wheel), so uv.lock's
# integrity hashes still validate after the host is swapped.
#
# Measured on an Alibaba Cloud DSW instance:
#   PyPI            804 MB torch wheel: ~23 min   (0.58 MB/s)
#   mirrors.aliyun  804 MB torch wheel: 42.7 s    (19.7 MB/s)
#
# Usage:
#   scripts/use_mirror.sh                        # default: mirrors.aliyun.com
#   scripts/use_mirror.sh tuna                   # pypi.tuna.tsinghua.edu.cn
#   scripts/use_mirror.sh restore                # restore uv.lock from backup
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/Submodule/ASPIRE/aspire/sim/uv.lock"
BACKUP="$LOCK.orig"

[ -f "$LOCK" ] || { echo "uv.lock not found: $LOCK"; echo "Run scripts/setup_third_party.sh first."; exit 1; }

TARGET="${1:-aliyun}"

if [ "$TARGET" = "restore" ]; then
  [ -f "$BACKUP" ] || { echo "No backup at $BACKUP"; exit 1; }
  cp "$BACKUP" "$LOCK"
  echo "[+] restored uv.lock from backup"
  exit 0
fi

case "$TARGET" in
  aliyun) PYPI_HOST="mirrors.aliyun.com/pypi";      TORCH_HOST="mirrors.aliyun.com/pytorch-wheels" ;;
  tuna)   PYPI_HOST="pypi.tuna.tsinghua.edu.cn";    TORCH_HOST="mirrors.tuna.tsinghua.edu.cn/pytorch-wheels" ;;
  *)      echo "Unknown mirror: $TARGET (use: aliyun | tuna | restore)"; exit 1 ;;
esac

# Back up once, from the pristine copy, so repeated runs stay idempotent.
if [ ! -f "$BACKUP" ]; then
  cp "$LOCK" "$BACKUP"
  echo "[+] backed up uv.lock -> $(basename "$BACKUP")"
fi

# Always start from the pristine copy so switching mirrors does not stack.
cp "$BACKUP" "$LOCK"

# Three host forms appear in uv.lock and all three must be rewritten:
#   1. wheel/sdist file URLs
#   2. the pytorch CUDA index file URLs
#   3. the registry declarations uv uses to resolve anything at build time
sed -i "s|https://files.pythonhosted.org/|https://$PYPI_HOST/|g"                      "$LOCK"
sed -i "s|https://download.pytorch.org/whl/|https://$TORCH_HOST/|g"                   "$LOCK"
sed -i "s|https://download-r2.pytorch.org/whl/|https://$TORCH_HOST/|g"                "$LOCK"
sed -i "s|https://pypi.org/simple|https://$PYPI_HOST/simple|g"                        "$LOCK"

echo "[+] rewrote uv.lock to use $TARGET"
grep -oE "https://[a-z0-9.-]+" "$LOCK" | sort | uniq -c | sort -rn

cat <<EOF

[!] One gap remains: build-time dependencies (e.g. egl-probe's cmake) are
    resolved live and do NOT come from uv.lock. Export the default index too:

      export UV_DEFAULT_INDEX=https://$PYPI_HOST/simple/
      export UV_INDEX_STRATEGY=unsafe-best-match

    scripts/setup_aspire_env.sh does this automatically.

    To undo: scripts/use_mirror.sh restore
EOF
