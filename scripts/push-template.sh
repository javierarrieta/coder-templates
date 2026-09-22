#!/usr/bin/env bash
# Push the Coder template using ONLY git-tracked files.
#
# Why this exists: `coder templates push --directory <dir>` tars the ENTIRE
# directory and the server rejects archives over 1 MiB ("Archive too big. Must be
# <= 1048576 bytes"). This CLI (v2.35.1) honors neither .coderignore nor
# .gitignore when building that tar -- verified: providers/llm01_workspace_target/
# target/ is git-ignored via the root .gitignore yet was still uploaded, blowing
# the archive up to 334 MB (272 MB Rust target/ + 63 MB compatibility/.terraform).
#
# The template itself needs only main.tf (it has no file()/templatefile()
# references); the llm01 provider is fetched from the provider registry by
# `terraform init` in the provisioner, never shipped from here.
#
# Usage: scripts/push-template.sh [template-name]   (default: podman-template)
set -euo pipefail

TEMPLATE="${1:-podman-template}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_REL="templates/${TEMPLATE}"
SRC_DIR="$REPO_ROOT/$SRC_REL"

[[ -d "$SRC_DIR" ]] || { echo "no such template directory: $SRC_DIR" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/${TEMPLATE}-push.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Working-tree copies of tracked files (so uncommitted edits are included),
# plus any untracked-but-not-ignored files. Skips everything git considers
# ignorable, which is what keeps target/ and .terraform/ out.
cd "$REPO_ROOT"
mapfile -t FILES < <(git ls-files --cached --others --exclude-standard "$SRC_REL")
[[ ${#FILES[@]} -gt 0 ]] || { echo "no tracked files under $SRC_REL" >&2; exit 1; }

for f in "${FILES[@]}"; do
  rel="${f#$SRC_REL/}"
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp "$f" "$STAGE/$rel"
done

SIZE=$(du -sk "$STAGE" | cut -f1)
echo "staged ${#FILES[@]} file(s), ${SIZE} KiB -> $TEMPLATE"
if (( SIZE > 1024 )); then
  echo "still over the 1 MiB upload limit; inspect: $STAGE" >&2
  find "$STAGE" -type f -exec du -h {} + | sort -h | tail -20 >&2
  exit 1
fi

coder templates push "$TEMPLATE" --directory "$STAGE" --yes
