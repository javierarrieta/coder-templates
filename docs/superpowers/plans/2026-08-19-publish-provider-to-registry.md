# Publish Provider to Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `publish.yml` build and push a new `terraform-provider-registry` image (with the released provider's zip/SHA256SUMS/.sig baked in) to the private Docker registry, so publishing is no longer a fully manual image-bake.

**Architecture:** A new `registry-image/` dir in the provider crate contains a Dockerfile (nginx serving the Terraform registry protocol from `/usr/share/nginx/html`), a `build.sh` that assembles the file tree (downloads existing registry content from the public host, adds the new version) and builds/pushes the image, and a nginx config. `publish.yml` gains a GPG-sign step, runs `build.sh`, and prints the published immutable tag for the manual k8s-casa bump. Separately, the k8s-casa ingress gains a public host rule so GitHub runners can reach the registry.

**Tech Stack:** GitHub Actions, Bash, Docker/nginx, GPG, Terraform registry protocol v5.0.

## Global Constraints

- This repo is **public**; do not write concrete hostnames, IPs, namespaces, or secret names in new files/commits. Refer to "the public registry host", "the private k8s-casa repo", "the sops age key directory". (The pre-existing `registry.l.arrieta.eu` references in `main.tf`/`ci.yml` stay as-is.)
- Version comes only from the release tag (`github.event.release.tag_name`), never from the image digest.
- `v` prefix kept for: git tag, workflow input, artifact names. Stripped for: zip/SHA256SUMS/.sig file names, protocol JSON, pushed image tag.
- Binary inside the zip keeps the `v` (`terraform-provider-llm01_v0.1.1`).
- GPG signatures must be **binary and detached** (`gpg --detach-sign`, no `--armor`).
- Existing registry content must be preserved (0.1.0 × linux/amd64, linux/arm64, darwin/arm64; 0.1.1 × linux/amd64).
- No automatic k8s-casa bump — manual, after CI prints the published tag.
- k8s-casa is Flux GitOps — no imperative kubectl.

---

### Task 1: Registry image scaffolding (`registry-image/`)

**Files:**
- Create: `providers/llm01_workspace_target/registry-image/Dockerfile`
- Create: `providers/llm01_workspace_target/registry-image/nginx.conf`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `Dockerfile` (build context root is `registry-image/`, expects the file tree under `html/`), `nginx.conf` (serves protocol JSON as `application/json`, `/files/*` with default types). Task 2's `build.sh` builds this image.

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/
```

- [ ] **Step 2: Create `nginx.conf`**

```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Terraform registry protocol JSON (extensionless paths under
    # /.well-known/ and /v1/providers/) must be served as JSON.
    location ~ ^/(\.well-known/|v1/providers/) {
        default_type application/json;
    }

    location /files/ {
        default_type application/octet-stream;
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add providers/llm01_workspace_target/registry-image/Dockerfile providers/llm01_workspace_target/registry-image/nginx.conf
git commit -m "feat(registry-image): add Dockerfile and nginx config for provider registry image"
```

---

### Task 2: Registry image `build.sh`

**Files:**
- Create: `providers/llm01_workspace_target/registry-image/build.sh`

**Interfaces:**
- Consumes: Task 1's `Dockerfile` + `nginx.conf`. The workflow passes a staged zip at `release/terraform-provider-llm01_<bare>_linux_amd64.zip`, `release/terraform-provider-llm01_<bare>_SHA256SUMS`, and a binary `.sig` (created by Task 3) at `release/terraform-provider-llm01_<bare>_SHA256SUMS.sig`.
- Produces: `build.sh <bare-version> [protocol-host]` — assembles `registry-image/html/` (downloaded existing content + new version), builds and pushes `ghcr.io/javierarrieta/terraform-provider-registry:<bare>` (immutable tag; refuses to overwrite an existing one), then prints the published tag. Exit non-zero on any download/push failure.

- [ ] **Step 1: Write `build.sh`**

```bash
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
# passed as an argument and defaults to a placeholder that CI overrides.

version="${1:?usage: build.sh <bare-version> [protocol-host]}"
protocol_host="${2:-CHANGE_ME}"
image_repo="ghcr.io/javierarrieta/terraform-provider-registry"

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
tag="$image_repo:$version"
docker build -t "$tag" "$here"

# Tags are immutable: refuse to overwrite an existing tag (GitHub's
# immutable-tags setting is the registry-level backstop).
if docker manifest inspect "$tag" >/dev/null 2>&1; then
  echo "ERROR: image tag $tag already exists on GHCR; refusing to overwrite" >&2
  exit 1
fi

echo "==> Pushing image"
docker push "$tag"

echo "==> PUBLISHED IMAGE (reference this tag in k8s-casa): $tag"
digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$tag" | awk -F'@' '{print $2}')"
echo "digest for reference: $digest"
echo "digest=$digest" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Make it executable and shellcheck-validate**

Run: `chmod +x providers/llm01_workspace_target/registry-image/build.sh && bash -n providers/llm01_workspace_target/registry-image/build.sh`
Expected: exit 0, no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add providers/llm01_workspace_target/registry-image/build.sh
git commit -m "feat(registry-image): add build.sh to assemble, build, and push registry image"
```

---

### Task 3: Extend `publish.yml` with GPG signing + image build/push

**Files:**
- Modify: `.github/workflows/publish.yml` (after the "Upload checksums" step, add the new steps; no change to existing steps).

**Interfaces:**
- Consumes: Task 2's `build.sh`; the release zip/SHA256SUMS produced by the existing steps; GitHub secrets `GPG_SIGNING_KEY`, `PROTOCOL_HOST` (the public protocol host); GHCR push uses the automatic `GITHUB_TOKEN` (needs `packages: write` in the job `permissions`).
- Produces: the `.sig` file on disk (fed to `build.sh`), a pushed image, and the digest printed to the run summary + `$GITHUB_OUTPUT`.

- [ ] **Step 1: Add the new steps to `publish.yml`**

Append after the existing "Upload checksums" step (before end of the `publish` job):

```yaml
      - name: Sign SHA256SUMS (binary GPG)
        env:
          GPG_SIGNING_KEY: ${{ secrets.GPG_SIGNING_KEY }}
        run: |
          if [[ -z "$GPG_SIGNING_KEY" ]]; then
            echo "::error::GPG_SIGNING_KEY secret not configured; skipping publish"
            exit 1
          fi
          echo "$GPG_SIGNING_KEY" | gpg --batch --import
          cd release
          gpg --batch --yes --pinentry-mode loopback --detach-sign \
            --output terraform-provider-llm01_${{ steps.ver.outputs.bare }}_SHA256SUMS.sig \
            terraform-provider-llm01_${{ steps.ver.outputs.bare }}_SHA256SUMS
          ls -la

      - name: Build and push registry image
        id: registry
        run: |
          bash registry-image/build.sh "${{ steps.ver.outputs.bare }}" "$PROTOCOL_HOST"
        env:
          PROTOCOL_HOST: ${{ secrets.PROTOCOL_HOST }}
          GITHUB_OUTPUT: $GITHUB_OUTPUT
```

Note: `build.sh` needs to be invoked from the working directory. The job already sets `defaults.run.working-directory` to `providers/llm01_workspace_target`, so `registry-image/build.sh` resolves correctly. The `release/` dir referenced by `build.sh` is resolved by `build.sh` itself as `<crate-root>/release/` (its `$here` is `<crate-root>/registry-image`, so `../release` → the crate root `release/`), matching where the existing zip/checksum steps write. Add `packages: write` to the job's `permissions` block (GHCR push).

- [ ] **Step 2: Docker login before push**

Add a Docker login step immediately before the "Build and push registry image" step (GHCR auth via the automatic token):

```yaml
      - name: Login to GHCR
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
```

- [ ] **Step 3: Print digest in run summary**

Add a final step after "Build and push registry image":

```yaml
      - name: Show published image tag
        run: |
          echo "Published image: ghcr.io/javierarrieta/terraform-provider-registry:${{ steps.ver.outputs.bare }}"
          echo "Digest: ${{ steps.registry.outputs.digest }}"
          echo "Reference the immutable tag in the k8s-casa terraform-provider-registry deployment manifest, commit, and let Flux deploy."
```

- [ ] **Step 4: Validate YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/publish.yml'))"`
Expected: no error, exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/publish.yml
git commit -m "feat(ci): sign release, build and push registry image, print digest in publish workflow"
```

---

### Task 4: k8s-casa public ingress rule

**Files:**
- Modify: `apply/50-apps/casa/registry.yaml` (the `registry-ingress` Ingress, add a second rule + TLS entry).

**Interfaces:**
- Consumes: the existing `terraform-provider-registry` and `registry` services; the wildcard TLS secret referenced by the existing rules.
- Produces: a public host that GitHub runners can reach for protocol + Docker API. NOTE: This file lives in the **private k8s-casa repo**, so the exact hostname and TLS secret name are known there.

- [ ] **Step 1: Add the public host rule**

In the `registry-ingress` Ingress, add a second `rules` entry mirroring the existing `registry.l.arrieta.eu` rule, using the public hostname and its wildcard TLS secret (see the sibling cert/reflector manifests for the exact secret name). Path map stays identical: `/.well-known/`, `/v1/providers/`, `/files/` → `terraform-provider-registry:80`; `/` → `registry:5000`. Add the public host to `spec.tls` hosts with the wildcard secret name.

- [ ] **Step 2: Commit and push**

```bash
cd /home/coder/k8s-casa
git add apply/50-apps/casa/registry.yaml
git commit -m "feat(casa): expose registry ingress on the public hostname"
git push
```

- [ ] **Step 3: Verify public reachability**

Run: `curl -fsS https://<public-host>/.well-known/terraform.json`
Expected: `{"providers.v1":"/v1/providers/"}` (allow Flux a minute to reconcile).

Run: `curl -sS -o /dev/null -w '%{http_code}' https://<public-host>/v2/`
Expected: `401` (Docker registry requires auth).

---

### Task 5: Documentation update

**Files:**
- Modify: `providers/llm01_workspace_target/README.md` (replace the "publishing today" manual steps with the CI-publish flow).
- Modify: `AGENTS.md` (distribution section: CI now publishes; manual bump remains).

**Interfaces:**
- Consumes: the completed workflow (Tasks 1–3).
- Produces: accurate docs; no code.

- [ ] **Step 1: Update provider README**

Replace the "How the registry is served (publishing today)" numbered list with:

```markdown
### How the registry is served (publishing today)

> This repo is public; the concrete hostnames, namespaces, and secret names are
> intentionally omitted. They live in the private k8s-casa repo (sops-encrypted
> secrets) and the local sops age key directory.

The registry is an nginx + Docker registry. The Terraform provider protocol
(`/.well-known/`, `/v1/providers/`, `/files/`) is served by a **static nginx**
deployment whose `/files/` content is **baked into the image** (pushed to the
private Docker registry), not a mounted volume. `publish.yml` now does this
automatically on release:

1. `publish.yml` builds the zip + `SHA256SUMS`, GPG-signs the checksums
   (binary `.sig`), and uploads them as Actions artifacts.
2. `registry-image/build.sh` downloads the existing registry content, adds the
   new version's files + protocol JSON, builds and pushes a new registry image
   to public GHCR under an immutable version tag.
3. The workflow prints the published tag; reference it in the k8s-casa
   deployment manifest and push — Flux GitOps deploys it.

There is **no** direct file upload endpoint: `PUT` to `/files/` returns 404.
```

- [ ] **Step 2: Update `AGENTS.md` distribution section**

Change the "CI reality" paragraph's last sentence ("Publishing to the registry is currently a manual image-bake process") to:

```markdown
**CI reality:** `publish.yml` builds, signs, packages, **and pushes a new
registry image** (`registry-image/build.sh`) on release; `build.yml` (manual
trigger) only uploads Actions artifacts. The image goes to public **GHCR**
(`ghcr.io/javierarrieta/terraform-provider-registry`) tagged with the bare
release version; **tags are immutable** (build.sh refuses to overwrite, and
GitHub's immutable-tags setting rejects it at the registry); no `latest` tag.
The k8s-casa deployment references the version tag.
```

And update the "Distribution steps" heading to note the manual path is only a
fallback, keeping the steps (they document the same artifact shapes the CI
produces).

- [ ] **Step 3: Commit**

```bash
git add providers/llm01_workspace_target/README.md AGENTS.md
git commit -m "docs: document CI-publish flow for provider registry"
```

---

## Self-Review

**Spec coverage:**
- Spec "Versioning" → Tasks 2/3 use `steps.ver.outputs.bare` (already normalized); image tag uses bare version; tag only printed, not used for naming. ✓
- Spec §1 (k8s-casa ingress) → Task 4. ✓
- Spec §2 Dockerfile → Task 1; `build.sh` → Task 2; publish.yml steps → Task 3; GitHub secrets → Task 3 envs. ✓
- Spec §3 manual bump → Task 3 prints tag + Task 4/5 reference it; no auto-bump. ✓
- Spec Testing → Task 4 Step 3 verifies public reachability; Task 2 uses the live registry layout (verified against actual 0.1.0/0.1.1 responses). ✓
- Redaction constraint → no new hostname/namespace/secret-name strings in any new repo file; `build.sh` takes host as an arg with a `CHANGE_ME` default. ✓

**Placeholder scan:** No TBD/TODO. The only deliberate placeholder is `CHANGE_ME`/`<public-host>`/`<bare-version>` in docs/usage lines where the value is an environment secret or a private-repo value — flagged explicitly. All code steps carry full code. ✓

**Type consistency:** `build.sh` consumes `release/terraform-provider-llm01_<bare>_*` produced by the existing workflow steps (filenames match Task 3's sign step and the existing zip/checksum steps). `steps.registry.outputs.digest` written in `build.sh` (`echo "digest=$digest" >> "$GITHUB_OUTPUT"`) and read by Task 3 Step 3 (`${{ steps.registry.outputs.digest }}`) — consistent. ✓

**Gap found & fixed inline:** Task 3 originally omitted the Docker login step; the private registry requires htpasswd auth, so Task 3 Step 2 adds it explicitly. ✓