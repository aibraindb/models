#!/usr/bin/env bash
set -euo pipefail

# Pulls branches from aibraindb/models and reassembles *.chunks into ./src/models/<branch>/

REPO_URL="https://github.com/aibraindb/models.git"
WORKDIR="aibraindb-models"
DEST_ROOT="$(pwd)/src/models"

if [ $# -lt 1 ]; then
  cat <<USAGE
Usage: $0 <branch-safe-name> [<branch-safe-name> ...]
  Examples:
    $0 distilbert-base-uncased
    $0 microsoft__layoutlmv3-base
    $0 distilbert-base-uncased microsoft__layoutlmv3-base
Notes:
  - Use the *branch-safe* name (slashes replaced by double-underscores).
  - Script reassembles ALL *.chunks in each branch.
USAGE
  exit 1
fi

# 0) Ensure tools present
need() { command -v "$1" >/dev/null || { echo "Missing $1"; exit 1; }; }
need git
need python3

# 1) TLS backend per OS (harmless if repeated)
UNAME="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME" in
  Darwin*)  git config --global http.sslBackend secure-transport ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT*) git config --global http.sslBackend schannel || true ;;
  *)        git config --global http.sslBackend openssl ;;
esac
git config --global http.version HTTP/1.1 || true

# 2) Clone or reuse models repo
if [ -d "$WORKDIR/.git" ]; then
  echo "[i] Reusing $WORKDIR"
  (cd "$WORKDIR" && git fetch --all --prune)
else
  echo "[i] Cloning $REPO_URL → $WORKDIR"
  git clone "$REPO_URL" "$WORKDIR"
fi

# 3) Get passphrase once
if [ -z "${PASSPHRASE:-}" ]; then
  echo -n "Enter passphrase to decrypt chunks: "
  read -rs PASSPHRASE
  echo
fi

mkdir -p "$DEST_ROOT"

assemble_branch () {
  local BRANCH="$1"

  # Prefer main branch; fallback to _upload if that’s the only one
  local HAVE_MAIN HAVE_UPLOAD
  HAVE_MAIN=$(git -C "$WORKDIR" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')
  HAVE_UPLOAD=$(git -C "$WORKDIR" ls-remote --heads origin "${BRANCH}_upload" | wc -l | tr -d ' ')
  local USE_BRANCH="$BRANCH"
  if [ "$HAVE_MAIN" -eq 0 ] && [ "$HAVE_UPLOAD" -gt 0 ]; then
    USE_BRANCH="${BRANCH}_upload"
  fi

  echo "[i] Checking out $USE_BRANCH"
  ( cd "$WORKDIR"
    if git show-ref --verify --quiet "refs/heads/$USE_BRANCH"; then
      git checkout "$USE_BRANCH"
      git pull --ff-only || true
    else
      git checkout -b "$USE_BRANCH" --track "origin/$USE_BRANCH"
    fi
  )

  # Ensure join tool exists
  if [ ! -f "$WORKDIR/tools/join_file.py" ]; then
    echo "❌ join_file.py not found in $WORKDIR/tools. Did the compose upload finish?"
    exit 1
  fi

  # Find all *.chunks under models/<branch> (any depth)
  local CHUNKS_BASE="$WORKDIR/models/$BRANCH"
  if [ "$USE_BRANCH" != "$BRANCH" ]; then
    # when using *_upload branch, files are still under models/<BRANCH> folder
    CHUNKS_BASE="$WORKDIR/models/$BRANCH"
  fi

  if [ ! -d "$CHUNKS_BASE" ]; then
    echo "❌ No directory: $CHUNKS_BASE (branch $USE_BRANCH)."
    exit 1
  fi

  echo "[i] Scanning for chunk folders under $CHUNKS_BASE"
  mapfile -t CHUNK_DIRS < <(find "$CHUNKS_BASE" -type d -name "*.chunks" | sort)

  if [ "${#CHUNK_DIRS[@]}" -eq 0 ]; then
    echo "⚠️  No *.chunks found under $CHUNKS_BASE — nothing to assemble."
    return
  fi

  local DEST_DIR="$DEST_ROOT/$BRANCH"
  mkdir -p "$DEST_DIR"

  for d in "${CHUNK_DIRS[@]}"; do
    # Read original filename from manifest.json
    if [ ! -f "$d/manifest.json" ]; then
      echo "⚠️  Skipping $d (no manifest.json)"
      continue
    fi
    local FILENAME
    FILENAME="$(python3 - <<'PY' "$d/manifest.json"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    man = json.load(f)
print(man.get("original_filename","restored.bin"))
PY
)"
    local OUT_PATH="$DEST_DIR/$FILENAME"
    echo "[→] Assembling: $(basename "$d")  →  $OUT_PATH"
    # Use --passphrase to avoid prompt (our joiner supports it)
    python3 "$WORKDIR/tools/join_file.py" "$d" --out "$OUT_PATH" --passphrase "$PASSPHRASE"
  done

  echo "[✓] Done assembling branch $USE_BRANCH → $DEST_DIR"
}

# 4) Assemble each requested branch
for BR in "$@"; do
  assemble_branch "$BR"
done

echo
echo "[🎉] All requested branches assembled into: $DEST_ROOT"
echo "     You can now point your code at src/models/<branch>/<filename>"
