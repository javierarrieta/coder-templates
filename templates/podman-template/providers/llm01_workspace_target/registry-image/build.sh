#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh <bare-version> [protocol-host]
# Downloads the current registry content from the public protocol host, adds
# the new version's files/protocol JSON, builds and pushes the registry image
# to GHCR (ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>),
# and prints the pushed tag. Tags are immutable: the script refuses to
# overwrite an existing tag.
#
# Redaction note: the concrete protocol host is not committed here; it is
# passed as an argument and defaults to a placeholder that CI overrides. The
# image repository is public (GHCR), so it is safe to hardcode.

version="${1:?usage: build.sh <bare-version> [protocol-host]}"
protocol_host="${2:-CHANGE_ME}"
image_repo="ghcr.io/javierarrieta/terraform-provider-registry"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$here/html"
# Paths under v1/.../download/<os>/<arch> are FILES (the protocol JSON), not
# directories — so create only the <os> parents here; write_download() below
# writes <arch> as a file.
mkdir -p "$stage/.well-known" \
  "$stage/v1/providers/infra/llm01/0.1.0/download/linux" \
  "$stage/v1/providers/infra/llm01/0.1.0/download/darwin" \
  "$stage/v1/providers/infra/llm01/0.1.1/download/linux" \
  "$stage/files"

base="https://$protocol_host"

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
mkdir -p "$stage/v1/providers/infra/llm01/$version/download/linux"

# Reuse the existing version's signing key (same key signs every version).
# key_id and ascii_armor are read directly from an existing version's download
# JSON (below) rather than hardcoded, so a key rotation is picked up
# automatically.

python3 - "$version" "$zip_sha" "$stage" "$base" <<'PYEOF'
import json, sys

version, zip_sha, stage, base = sys.argv[1:5]

# Read the signing key (key_id + ascii_armor) from an existing download JSON.
signing_path = f"{stage}/v1/providers/infra/llm01/0.1.1/download/linux/amd64"
key = json.load(open(signing_path))["signing_keys"]["gpg_public_keys"][0]
gpg_key_id = key["key_id"]
gpg_armor = key["ascii_armor"]

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
                {"key_id": gpg_key_id,
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
tag="$image_repo:$version"
docker build -t "$tag" "$here"

# Tags are immutable: refuse to overwrite an existing tag. This is the
# pipeline-level guarantee; GitHub's immutable-tags package setting is the
# registry-level backstop (an overwrite push would be rejected there too).
if docker manifest inspect "$tag" >/dev/null 2>&1; then
  echo "ERROR: image tag $tag already exists on GHCR; tags are immutable, refusing to overwrite" >&2
  exit 1
fi

echo "==> Pushing image"
docker push "$tag"

echo "==> PUBLISHED IMAGE (reference this tag in k8s-casa): $tag"
digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$tag" | awk -F'@' '{print $2}')"
echo "digest for reference: $digest"
echo "digest=$digest" >> "${GITHUB_OUTPUT:-/dev/null}"
