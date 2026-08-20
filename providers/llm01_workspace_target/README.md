# Build and Release Provider

## Manual Build (Any Version)

Trigger the build workflow with a specific version:

```bash
gh workflow run build.yml -f version="v0.1.3"
```

## Release Workflow (Auto on Release)

Creating a GitHub **Release** (e.g., `v0.1.3`) triggers `publish.yml`, which
builds, packages, and uploads the artifacts using the release tag for the
version. Pushing a tag alone does NOT trigger it — the tag must be attached to
a release:

```bash
gh release create v0.1.3 --generate-notes
# or create the release from the GitHub UI
```

`publish.yml` derives the artifact version from `github.event.release.tag_name`.

## Artifacts

After successful build, the artifacts are uploaded to the workflow run's
**Artifacts** tab (they are NOT GitHub Release assets; the same files are then
baked into the new registry image by `build.sh` in step 2 below):

1. `terraform-provider-llm01_0.1.3_linux_amd64.zip` — the provider binary
2. `terraform-provider-llm01_0.1.3_SHA256SUMS` — SHA256 checksum
3. `terraform-provider-llm01_0.1.3_SHA256SUMS.sig` — detached GPG signature over the checksums

## Version naming (unified)

The `v` prefix is only used in git tags and workflow inputs (e.g. `v0.1.3`).
Registry-facing file names strip it, while the binary **inside** the zip keeps
it (Terraform registry convention):

| Context | Example |
|---|---|
| Git tag / workflow input / artifact name | `v0.1.3` |
| zip / `SHA256SUMS` / `.sig` file names | `terraform-provider-llm01_0.1.3_linux_amd64.zip` |
| Binary inside the zip | `terraform-provider-llm01_v0.1.3` |

## Manual Build Command

This convenience command builds for the host toolchain. For release artifacts
you should use the `build.yml` / `publish.yml` workflows instead, because those
cross-compile a **fully static musl** binary (`x86_64-unknown-linux-musl`,
`RUSTFLAGS="-C target-feature=+crt-static"`). The static build runs anywhere,
including the glibc-less Coder provisioner — a plain `cargo build` here produces
a dynamically-linked glibc binary that fails with `no such file or directory`
in the provisioner.

```bash
cd providers/llm01_workspace_target
cargo build --release --bin terraform-provider-llm01
```

## Binary Distribution

The binary is published to the provider registry served at
`registry.home.arrieta.eu/infra/llm01` (an nginx fronting the GHCR-hosted
registry image):
- Package: `terraform-provider-llm01`
- Version: `0.1.4` (the template requires `~> 0.1.3`; 0.1.1 ships a macOS
  Mach-O binary in the `linux_amd64` zip, 0.1.2 is dynamic glibc — both
  fail in the provisioner, so 0.1.3+ is the static musl minimum. 0.1.4 fixes
  workspace deletion of a stopped workspace by re-acquiring the lease before
  destroying the iSCSI target).

### How the registry is served (publishing today)

> This repo is public; the concrete hostnames, namespaces, and secret names are
> intentionally omitted. They live in the private k8s-casa repo (sops-encrypted
> secrets) and the local sops age key directory.

The registry is an nginx serving the Terraform provider protocol and static
`/files/` content that is **baked into the image** (pushed to **public GHCR**:
`ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>`), not a
mounted volume. `publish.yml` does this automatically on release:

1. `publish.yml` builds the zip + `SHA256SUMS`, creates a **binary detached**
   GPG signature (`gpg --detach-sign`), and uploads them as Actions artifacts.
2. `registry-image/build.sh` downloads the existing registry content, adds the
   new version's files + protocol JSON, builds and pushes a new registry image
   to public GHCR (`ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>`).
   Tags are immutable — the script refuses to overwrite an existing tag and
   there is no `latest`.
3. The workflow prints the published tag; reference it in the k8s-casa
   deployment manifest (image → `ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>`) and push — Flux GitOps deploys it. GHCR images are
   publicly pullable, so no k8s-casa pull-credential change is needed.

There is **no** direct file upload endpoint: `PUT` to `/files/` returns 404.

### Registry protocol layout

The registry implements the modern Terraform registry protocol (v5.0):

- `/.well-known/terraform.json` → `{"providers.v1":"/v1/providers/"}`
- `/v1/providers/infra/llm01/versions` → version list + platforms
- `/v1/providers/infra/llm01/{version}/download/{os}/{arch}` → download JSON
  (download_url, shasums_url, shasums_signature_url, shasum, signing_keys)
- `/files/terraform-provider-llm01_{version}_{os}_{arch}.zip`
- `/files/terraform-provider-llm01_{version}_SHA256SUMS`
- `/files/terraform-provider-llm01_{version}_SHA256SUMS.sig`

## GPG Signing

The binary must be signed with GPG before uploading to registry. Fingerprint:
`17DC83110709EC6A07A4C7D81667A87F5D80F5EB` (short: `1667A87F5D80F5EB`).

The signing key lives in a sops-encrypted K8s secret in the private k8s-casa
repo (decryptable with the local sops age key). The signature must be a
**binary, detached** GPG signature (`gpg --detach-sign`, no `--armor`); ASCII-armored signatures
are rejected by the registry ("invalid data: tag byte does not have MSB set").
