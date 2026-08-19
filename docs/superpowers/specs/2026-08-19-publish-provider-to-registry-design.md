# Design: Publish provider to the registry from GitHub Actions

Date: 2026-08-19

## Goal

Make `publish.yml` actually publish the `llm01_workspace_target` provider to
the private registry instead of only uploading GitHub Actions artifacts. Today
publishing is a manual image-bake process; the release workflow stops at zip +
SHA256SUMS.

## Background / constraints

> **Redaction note:** this repo is public. Exact ingress hostnames, IPs, and
> secret/key locations are intentionally omitted; they live in the private
> k8s-casa repo (sops-encrypted secrets) and the local sops age key
> directory. Where a value is referenced below, see k8s-casa for the concrete
> names.

- The registry serves the Terraform provider protocol (`/.well-known/`,
  `/v1/providers/`, `/files/`) from a **static nginx** deployment whose files
  are **baked into the image** (pushed to the private Docker registry) — no
  mounted volume, no upload endpoint (`PUT /files/` returns 404).
- The image source (Dockerfile / nginx config) does not exist in any repo; the
  0.1.x images were built ad hoc by a previous agent.
- The registry protocol is the modern Terraform v5.0 protocol:
  - `/.well-known/terraform.json` → `{"providers.v1":"/v1/providers/"}`
  - `/v1/providers/infra/llm01/versions` → version list + platforms
  - `/v1/providers/infra/llm01/{version}/download/{os}/{arch}` → download JSON
    (download_url, shasums_url, shasums_signature_url, shasum, signing_keys)
  - `/files/terraform-provider-llm01_{version}_{os}_{arch}.zip`
  - `/files/terraform-provider-llm01_{version}_SHA256SUMS`
  - `/files/terraform-provider-llm01_{version}_SHA256SUMS.sig`
- The registry host is reachable only from the local network. A public
  hostname already resolves and is covered by the wildcard TLS certificate
  (auto-reflected to the relevant namespace), but has no ingress rule yet
  (404 today). Exposing it lets GitHub-hosted runners reach the registry. The
  public host is where CI downloads existing content and pushes the new image.
- The Docker registry deployment is htpasswd-protected with users for pull and
  push; credentials are in sops-encrypted secrets in k8s-casa.
- The GPG signing key is in a sops-encrypted K8s secret in k8s-casa. Its
  fingerprint is public (it is embedded in the registry's download JSON).
  Signatures must be **binary** GPG (no `--armor`).
- k8s-casa is Flux GitOps: manifests in `apply/`, no imperative kubectl.
- Existing registry content is publicly readable (0.1.0 × linux/amd64,
  linux/arm64, darwin/arm64; 0.1.1 × linux/amd64), so CI can download it to
  rebuild the image from scratch.

## Design

### Versioning (release tag is the source of truth)

- The version always comes from the release tag (`github.event.release.tag_name`,
  e.g. `v0.1.1`), never from the image digest or any other source.
- `v` prefix is kept for: git tag, workflow input, artifact names.
- `v` prefix is stripped for: zip/SHA256SUMS/.sig file names, registry protocol
  JSON (versions + download), the pushed image tag. So the image is pushed as
  `ghcr.io/javierarrieta/terraform-provider-registry:0.1.1` (bare).
- The binary inside the zip keeps the `v` (`terraform-provider-llm01_v0.1.1`).

### 1. k8s-casa: expose the registry publicly

Edit the registry ingress manifest: add a second rule for the **public**
hostname with the wildcard TLS secret (same secret name as the existing rules),
with the same path→service mapping as the existing rule:

- `/.well-known/` → `terraform-provider-registry:80`
- `/v1/providers/` → `terraform-provider-registry:80`
- `/files/` → `terraform-provider-registry:80`
- `/` → `registry:5000`

Commit and push; Flux reconciles. (Exact hostname/secret-name values: see
k8s-casa.)

### 2. coder-templates: canonical registry image + CI publish

#### New dir `templates/podman-template/providers/llm01_workspace_target/registry-image/`

- **`Dockerfile`** — `FROM nginx:alpine`; `COPY` the assembled file tree into
  `/usr/share/nginx/html`; nginx config sets `default_type application/json`
  so the extensionless protocol JSON files serve as JSON; standard mime types
  for `/files/*` (`.zip`, `SHA256SUMS`, `.sig`).
- **`build.sh`** — args: bare version (e.g. `0.1.1`), protocol host, image name.
  1. Download the existing registry content (current `versions` JSON, each
     version's `download/{os}/{arch}` JSON, every `/files/*` file) from the
     **public** protocol host into a staging tree (GitHub-hosted runners
     cannot reach the LAN-only host).
  2. Add the new version: `versions` JSON gains the new version entry; write
     the new `download/linux/amd64` JSON (reuse the GPG public key from an
     existing download JSON; `shasum` = sha256 of the new zip); copy the new
     zip, SHA256SUMS, `.sig` into `/files/`.
  3. `docker build -t ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>`
     (also tagged `latest`).
  4. `docker push`.

#### `publish.yml` additions (after the existing zip + SHA256SUMS steps)

1. **GPG sign**: import the signing key from `GPG_SIGNING_KEY` secret, create
   the **binary** `.sig` of SHA256SUMS.
2. **Build + push the registry image**: login to GHCR with `GITHUB_TOKEN`
   (`packages: write` permission), run `registry-image/build.sh <bare>
   <protocol-host>`.
3. **Print the new image digest** (`docker inspect --format '{{.RepoDigests}}'`
   or `docker images --digests`) in the run summary for the manual k8s-casa
   bump. Nothing else writes to k8s-casa.

#### GitHub secrets required

- `PROTOCOL_HOST` — the public registry protocol host (redacted from this repo;
  used by `build.sh` for downloads and absolute URLs).
- `GPG_SIGNING_KEY` — the private key (base64 or armored).
- GHCR push uses the automatic `GITHUB_TOKEN` — no additional registry secrets.

### 3. Manual step (unchanged process)

After a successful publish run, bump the image digest in the k8s-casa
`terraform-provider-registry` deployment manifest using the digest printed by
the workflow, commit, and let Flux deploy.

## Testing

- Locally: run `build.sh` against a staging tag (or the live registry) and
  verify the assembled tree matches the live registry layout by diffing JSON.
- After the k8s-casa ingress change: `curl https://<public-host>/.well-known/terraform.json`
  from this workspace (public path) returns `{"providers.v1":"/v1/providers/"}`,
  and `curl https://<public-host>/v2/` returns a 401 (Docker registry auth
  required).
- In CI: after a publish, verify `terraform init` on the template can resolve
  the provider from the registry (via the LAN host, or a temporary filesystem
  mirror pointing at the public host).

## Risks

- Exposing the registry publicly puts the Docker registry behind htpasswd on
  the public internet; provider protocol files are public (as they effectively
  are today on the LAN). Credentials must stay out of logs.
- The nginx config is new (replaces the ad-hoc image). The registry protocol
  layout is verified against the live registry, but a mismatch would only show
  up when the k8s-casa digest is bumped.
- The push-capable htpasswd user grants push access to the whole private
  registry (not just the provider-registry image); the GitHub secret must be
  treated as sensitive.

## Out of scope

- Automatic k8s-casa bump (stays manual per decision).
- Reverting to LAN-only (the existing host remains wired).
- Publishing from `build.yml` (manual trigger) — the image-bake logic lives in
  `build.sh`, so wiring `build.yml` later is trivial.