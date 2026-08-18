# Build and Release Provider

## Manual Build (Any Version)

Trigger the build workflow with a specific version:

```bash
gh workflow run build.yml -f version="v0.1.1"
```

## Release Workflow (Auto on Tag)

When a tag is pushed (e.g., `v0.1.1`):

```bash
git tag v0.1.1
git push origin v0.1.1
```

The `publish.yml` workflow will automatically build, package, and upload artifacts.

## Artifacts

After successful build, two artifacts are uploaded:

1. `terraform-provider-llm01_v0.1.1_linux_amd64.zip` - The binary
2. `terraform-provider-llm01_v0.1.1_linux_amd64_SHA256SUMS` - SHA256 checksum

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

## GPG Signing

The binary must be signed with GPG (fingerprint: `1667A87F5D80F5EB`) before uploading to registry.
