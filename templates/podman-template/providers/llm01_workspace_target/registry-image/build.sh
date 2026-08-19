#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh <bare-version> [registry-host]
# Downloads the current registry content from the public host, adds the new
# version's files/protocol JSON, builds and pushes the registry image, and
# prints the pushed image digest (for the manual k8s-casa bump).
#
# Redaction note: the concrete public registry host is not committed here; it
# is passed as an argument and defaults to a placeholder that CI overrides.

version="${1:?usage: build.sh <bare-version> [registry-host]}"
host="${2:-CHANGE_ME}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$here/html"
mkdir -p "$stage/.well-known" "$stage/v1/providers/infra/llm01/0.1.0/download/linux/amd64" "$stage/v1/providers/infra/llm01/0.1.0/download/linux/arm64" "$stage/v1/providers/infra/llm01/0.1.0/download/darwin/arm64" "$stage/v1/providers/infra/llm01/0.1.1/download/linux/amd64" "$stage/files"

base="https://$host"

echo "==> Downloading existing registry content from $base"
for p in \
  ".well-known/terraform.json" \
  "v1/providers/infra/llm01/versions" \
  "v1/providers/infra/llm01/0.1.0/download/linux/amd64" \
  "v1/providers/infra/llm01/0.1.0/download/linux/arm64" \
  "v1/providers/infra/llm01/0.1.0/download/darwin/arm64" \
  "v1/providers/infra/llm01/0.1.1/download/linux/amd64" \
  "files/terraform-provider-llm01_0.1.0_linux_amd64.zip" \
  "files/terraform-provider-llm01_0.1.0_linux_arm64.zip" \
  "files/terraform-provider-llm01_0.1.0_darwin_arm64.zip" \
  "files/terraform-provider-llm01_0.1.0_SHA256SUMS" \
  "files/terraform-provider-llm01_0.1.0_SHA256SUMS.sig" \
  "files/terraform-provider-llm01_0.1.1_linux_amd64.zip" \
  "files/terraform-provider-llm01_0.1.1_SHA256SUMS" \
  "files/terraform-provider-llm01_0.1.1_SHA256SUMS.sig" \
; do
  out="$stage/$p"
  mkdir -p "$(dirname "$out")"
  curl -fsS --retry 3 "$base/$p" -o "$out"
done

echo "==> Adding new version $version"
release="$here/../release"
zip_file="terraform-provider-llm01_${version}_linux_amd64.zip"
sums_file="terraform-provider-llm01_${version}_SHA256SUMS"
sig_file="terraform-provider-llm01_${version}_SHA256SUMS.sig"

for f in "$release/$zip_file" "$release/$sums_file" "$release/$sig_file"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

cp "$release/$zip_file" "$stage/files/$zip_file"
cp "$release/$sums_file" "$stage/files/$sums_file"
cp "$release/$sig_file" "$stage/files/$sig_file"

zip_sha="$(awk '{print $1}' "$release/$sums_file" | head -1)"
mkdir -p "$stage/v1/providers/infra/llm01/$version/download/linux/amd64"

# Reuse the existing version's signing key (same key signs every version).
gpg_armor="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["signing_keys"]["gpg_public_keys"][0]["ascii_armor"])
' "$stage/v1/providers/infra/llm01/0.1.1/download/linux/amd64")"

python3 - "$version" "$zip_file" "$zip_sha" "$gpg_armor" "$stage" "$base" <<'PYEOF'
import json, sys

version, zip_file, zip_sha, gpg_armor, stage, base = sys.argv[1:7]

def write_download(os_, arch):
    data = {
        "protocols": ["5.0"],
        "os": os_,
        "arch": arch,
        "filename": f"terraform-provider-llm01_{version}_{os_}_{arch}.zip",
        "download_url": f"{base}/files/terraform-provider-llm01_{version}_{os_}_{arch}.zip",
        "shasums_url": f"{base}/files/terraform-provider-llm01_{version}_SHA256SUMS",
        "shasums_signature_url": f"{base}/files/terraform-provider-llm01_{version}_SHA256SUMS.sig",
        "shasum": zip_sha,
        "signing_keys": {
            "gpg_public_keys": [
                {"key_id": "17DC83110709EC6A07A4C7D81667A87F5D80F5EB",
                 "ascii_armor": gpg_armor},
            ]
        },
    }
    path = f"{stage}/v1/providers/infra/llm01/{version}/download/{os_}/{arch}"
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

# linux/amd64 only — the current workflow builds a single platform.
write_download("linux", "amd64")

# Add the new version to the versions listing.
versions_path = f"{stage}/v1/providers/infra/llm01/versions"
with open(versions_path) as f:
    versions = json.load(f)
versions["versions"].append({
    "version": version,
    "protocols": ["5.0"],
    "platforms": [{"os": "linux", "arch": "amd64"}],
})
with open(versions_path, "w") as f:
    json.dump(versions, f, indent=2)
    f.write("\n")
PYEOF

echo "==> Building image"
tag="$host/infra/terraform-provider-registry:$version"
docker build -t "$tag" "$here"

echo "==> Pushing image"
docker push "$tag"

digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$tag" | awk -F'@' '{print $2}')"
echo "==> NEW IMAGE DIGEST (bump in k8s-casa): $digest"
echo "digest=$digest" >> "$GITHUB_OUTPUT"
