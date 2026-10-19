#!/usr/bin/env bash
#
# Apply the patches under patches/ to the cloned upstream code.
# Idempotent: re-running skips patches that are already applied.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/patches"
ASPIRE="$REPO_ROOT/Submodule/ASPIRE"
CUROBO="$ASPIRE/aspire/sim/cap/third_party/curobo"

apply_patch() {
  local target_dir="$1" patch_file="$2" label="$3"
  local name; name="$(basename "$patch_file")"

  if [ ! -d "$target_dir" ]; then
    echo "[!] $label: target not found, run scripts/setup_third_party.sh first"
    return 1
  fi
  if [ ! -f "$patch_file" ]; then
    echo "[!] $label: patch missing: $patch_file"
    return 1
  fi

  # `git apply --reverse --check` succeeding means the patch is already in.
  if git -C "$target_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "[=] $label: already applied ($name)"
    return 0
  fi

  if ! git -C "$target_dir" apply --check "$patch_file" 2>/dev/null; then
    echo "[!] $label: cannot apply $name (context mismatch?)"
    echo "    inspect with: git -C $target_dir apply --check -v $patch_file"
    return 1
  fi

  git -C "$target_dir" apply "$patch_file"
  echo "[+] $label: applied $name"
}

# cuRobo v0.7.8 is a submodule, so it is its own git repo.
# The SAM3 loader patch lives in the ASPIRE checkout itself.
#
# Failures are collected rather than aborting, so one stale patch does not
# silently skip the rest. (With `set -e`, an early failure would exit here.)
FAILED=0
apply_patch "$CUROBO" "$PATCH_DIR/curobo-0.7.8-build-fixes.patch" "cuRobo v0.7.8" || FAILED=1
apply_patch "$ASPIRE" "$PATCH_DIR/aspire-sam3-local-checkpoint.patch" "ASPIRE (SAM3 checkpoint)" || FAILED=1

echo
if [ "$FAILED" -ne 0 ]; then
  echo "[done] patches applied, but some failed -- see above"
  exit 1
fi
echo "[done] patches applied"

