# Build and Release Provider

## Manual Build (Any Version)

Trigger the build workflow with a specific version:

```bash
gh workflow run build.yml -f version="v0.1.1"
```

## Release Workflow (Auto on Release)

Creating a GitHub **Release** (e.g., `v0.1.1`) triggers `publish.yml`, which
builds, packages, and uploads the artifacts using the release tag for the
version. Pushing a tag alone does NOT trigger it — the tag must be attached to
a release:

```bash
gh release create v0.1.1 --generate-notes
# or create the release from the GitHub UI
```

`publish.yml` derives the artifact version from `github.event.release.tag_name`.

## Artifacts

After successful build, two artifacts are uploaded to the workflow run's
**Artifacts** tab (they are NOT GitHub Release assets; the same files are baked
into the new registry image by `build.sh`):

1. `terraform-provider-llm01_0.1.1_linux_amd64.zip` - The binary
2. `terraform-provider-llm01_0.1.1_linux_amd64_SHA256SUMS` - SHA256 checksum

## Version naming (unified)

The `v` prefix is only used in git tags and workflow inputs (e.g. `v0.1.1`).
Registry-facing file names strip it, while the binary **inside** the zip keeps
it (Terraform registry convention):

| Context | Example |
|---|---|
| Git tag / workflow input / artifact name | `v0.1.1` |
| zip / SHA256SUMS / `.sig` file names | `terraform-provider-llm01_0.1.1_linux_amd64.zip` |
| Binary inside the zip | `terraform-provider-llm01_v0.1.1` |

## Manual Build Command

```bash
cd templates/podman-template/providers/llm01_workspace_target
cargo build --release --bin terraform-provider-llm01
```

## Binary Distribution

The binary is published to private registry:
- Registry: `registry.l.arrieta.eu/infra/llm01`
- Package: `terraform-provider-llm01_0.1.1_linux_amd64`
- Version: `~> 0.1`

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
   new version's files + protocol JSON, builds and pushes a new registry image.
3. The workflow prints the new image digest; bump it in the k8s-casa
   deployment manifest and push — Flux GitOps deploys it.

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
**binary** GPG signature (`gpg --sign`, no `--armor`); ASCII-armored signatures
are rejected by the registry ("invalid data: tag byte does not have MSB set").
