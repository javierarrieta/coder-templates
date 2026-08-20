# AGENTS.md — coder-templates

Single Coder template (`templates/podman-template`) + a Rust Terraform provider
companion (`.../providers/llm01_workspace_target`). All template logic lives in
`templates/podman-template/`; the provider implements the `llm01_workspace_target`
resource over the workspace-target helper API.

## Repo layout (only the things you'll touch)

```
coder-templates/
  templates/podman-template/
    main.tf                 # the template (agent, home bind mount, container, params)
    compatibility/main.tf   # standalone mTLS-podman-API + image-pull compatibility test (run in a provisioner pod)
    scripts/truenas-iscsi-helper-client.sh  # mTLS lifecycle script (provision/attach/detach/destroy)
    providers/llm01_workspace_target/       # Rust Terraform provider
      Cargo.toml / Cargo.lock / src/{lib,main}.rs
    README.md               # canonical push + image-rebuild instructions (read this first)
  nixos-configurations/ (OUTSIDE this repo)  # pkgs/coder-workspace builds the workspace image;
                                             # .github/workflows/workspace-image.yml pushes it to GHCR;
                                             # IMAGE_TAGS.md records tags (update/rollback reference)
```

The workspace image itself is built from `~/code/nixos-configurations/pkgs/coder-workspace`
(`dockerTools.buildImage` in the nixos-configurations flake), not from this repo.
Changes to the image require editing the Nix flake and pushing a new image tag.

## Rebuild + push the workspace image (GitHub Actions + GHCR)

The image is built in the sibling repo **`nixos-configurations`**
(<https://github.com/javierarrieta/nixos-configurations>). A workflow at
`.github/workflows/workspace-image.yml` builds `.#coder-workspace` on an
`ubuntu-latest` runner (Nix via `nix-installer-action`) and pushes to the public
**GHCR** package `ghcr.io/javierarrieta/coder-workspace`. No llm01 build host,
no registry credentials (public pull), no macOS keychain involved.

Edit only `pkgs/coder-workspace/default.nix` in that repo (do NOT touch the
`fish` package override at the top, which bakes config into the fish package;
its `doCheck = false` keeps the test suite from running in CI). The workflow
runs on:

- push to `main` touching `pkgs/coder-workspace/**`, `flake.lock`, or the workflow
- manual dispatch: `gh workflow run workspace-image.yml`

### Tag strategy (updates + rollback)

Each CI build pushes two tags to GHCR:

- `YYYYMMDD-<short-sha>` — immutable, content-accurate (CI builds the exact
  commit). Date prefix shows recency; never overwritten, so rollback-safe.
- `latest` — mutable pointer to the newest build (convenience only).

`IMAGE_TAGS.md` in the nixos-configurations repo is auto-appended by the
workflow (`tag | date | commit | changes`) and is the update/rollback
reference: newest row = current, older rows are rollback targets. Pin
`workspace_image` in the template to an immutable tag, never `latest`.

### Who owns what (why two repos)

The image and the template are coupled only by a tag string — nothing is
pushed from one repo into the other:

- **nixos-configurations** owns the image *source* (the Nix flake) and the
  build+push pipeline. Its CI publishes to the GHCR **package**
  `ghcr.io/javierarrieta/coder-workspace` (owned by the GitHub user, not by a
  repo) and records tags in `IMAGE_TAGS.md`.
- **coder-templates** only references the image by tag
  (`workspace_image = "ghcr.io/javierarrieta/coder-workspace:<tag>"` in
  `main.tf`). The workflow never writes here.

The one manual hop: after CI publishes a new tag, pin it into `main.tf` and
push the template. CI does not touch coder-templates.

The image is `bash` login shell with an interactive-only fish handoff in
`runAsRoot`'s `/etc/bashrc` **and** `/etc/profile`:

```sh
# Hand off interactive TTY sessions to fish only. The guard
# [[ $- == *i* ]] && [[ -t 0 ]] is TRUE for interactive+TTY and FALSE for VS
# Code Remote-SSH's non-interactive piped-stdin bootstrap (which must stay bash).
# Do NOT use `[[ -o interactive ]]` — that option does not exist.
if [[ $- == *i* ]] && [[ -t 0 ]] && command -v fish >/dev/null 2>&1; then
  exec fish
fi
```

Verify the wiring before pushing the template:

```bash
# non-interactive piped shell stays bash (the VS Code Remote-SSH path)
docker run --rm --entrypoint sh coder-workspace:pinned \
  -c 'echo hi | bash -c "echo running:\$0; type -t command"'   # expect: running:bash
# interactive TTY execs fish
docker run --rm -it --entrypoint bash coder-workspace:pinned -c 'echo $0'        # expect: fish
```

After the workflow run, pin `workspace_image` in the template to the new
immutable tag from `IMAGE_TAGS.md`, push the template, and **update** the
workspace (see below).

## Push a template change (exact)

```bash
coder login <coder url>
coder templates push podman-template \
  --directory templates/podman-template \
  --yes
```

After changing the template or the workspace image, you must also **update** the
workspace to the new template version (`coder update <workspace>` or the dashboard
Update button) and **restart** for the new image/cmd to take effect. A plain
restart keeps the old template/image. Pushing the template alone does NOT upgrade
existing workspaces.

**Update pitfall:** If `coder update` reports "Workspace is up-to-date" but the
workspace is still running the old image, the workspace has a *stored* value for
the mutable `workspace_image` parameter that overrides the new template default.
(Forcing via `coder update --force` does NOT exist in Coder v2.35.1 — it errors
"unknown flag: --force".) Reset the stored parameter by passing it explicitly on
`restart`, which re-applies it:
```bash
coder restart <workspace> --parameter workspace_image=ghcr.io/javierarrieta/coder-workspace:<YYYYMMDD-short-sha>
```
Confirm with `yes` at the restart prompt. Verify the running container picked up
the new image after the restart (e.g. `coder ssh <workspace> 'command -v sops age'`).

## Workspace image (NixOS + VS Code Server) rules

Built in `~/code/nixos-configurations/pkgs/coder-workspace/default.nix` via
`pkgs.dockerTools.buildImage { name="coder-workspace"; tag="pinned"; ... }`. The
container runs as uid 1000 (`coder`), `Cmd = ["/bin/sh"]`, `SHELL=/bin/bash`,
`PATH` includes `~/.cargo/bin`, `~/.local/bin`, `~/.bun/bin`, and
`LD_LIBRARY_PATH=/lib64:/usr/lib64:/usr/lib`.

NixOS keeps libs in `/nix/store`, so VS Code Server's glibc binaries can't exec.
The image's `runAsRoot` wires the Nix glibc into standard FHS paths so the
default glibc `server-linux-x64` build runs:

- `/lib64/ld-linux-x86-64.so.2` → `${pkgs.glibc}/lib/ld-linux-x86-64.so.2`
- `libc.so.6`, `libm`, `libdl`, `libpthread`, `librt`, `libresolv`, `libnss_*` → `/lib64`, `/usr/lib`, `/usr/lib64`
- `libstdc++.so.6` → `${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6`
- `libgcc_s.so.1` → `${pkgs.libgcc}/lib/libgcc_s.so.1`
- `libz.so.1` → `${pkgs.zlib}/lib/libz.so.1`
- `/usr/bin/env`, `/sbin/ldconfig`, `/usr/bin/ldd`, and `touch /etc/NIXOS`.

**Do NOT add a musl loader at `/lib` (`ld-musl-x86_64.so.so.1`).** Doing so makes
VS Code's `check_musl_interpreter` probe download the Alpine/musl server build,
whose `node` then fails with `Error relocating ... libstdc++.so.6: symbol not
found` against the glibc libs wired above. With the `/etc/NIXOS` marker and the
GNU libstdc++/libc probes, the default `server-linux-x64` is selected — exactly
what runs on these glibc libraries.

`runAsRoot` also bakes the interactive→fish handoff into `/etc/bashrc` and
`/etc/profile` (guard: `[[ $- == *i* ]] && [[ -t 0 ]] && command -v fish >/dev/null 2>&1`;
`[[ -o interactive ]]` is wrong — `interactive` is not a valid option).

After rebuilding the image, pin `workspace_image` to the new immutable tag from
`IMAGE_TAGS.md`, push the template, and **update** the workspace. Verify on the
Podman host:

```sh
podman inspect coder-<workspace> --format '{{json .Config.Image}}'
podman exec coder-<workspace> ls -l /lib64/ld-linux-x86-64.so.2 /lib64/libstdc++.so.6
```

## Template parameters / constraints

- `memory_gb` (2–8, mutable), `cpu_count` (2–24, mutable), `workspace_image` (mutable).
- `disk_gb` (10–200) is **immutable after workspace creation** (`mutable = false`).
- The container's only mount is `/home/coder` (iSCSI-backed via the `llm01`
  provider + helper). Data outside `/home/coder` is ephemeral to the pod.
- `/home/coder` is a **direct bind mount** (`mounts { type = "bind" }`) of the
  helper's iSCSI target — not a named volume. Rootless Podman chowns named
  volumes to the container user on first use, which fails with
  `lchown <volume>/_data: operation not permitted` on network-backed mounts;
  bind mounts are never chowned.
- The container runs as uid 1000 with `userns_mode = "keep-id"`, mapping the
  container's `coder` (uid 1000) to the Podman host user (uid 1000) so the
  existing home data stays owned/writable by the workspace user. If a workspace's
  agent can't write `/home/coder`, the freshly-mounted iSCSI target is owned by
  root on the host — the helper must `chown` the attached mount to uid 1000.
- Auth/certs are mounted from Coder secrets: `/run/secrets/coder-podman-client`
  (mTLS). The image is pulled from public GHCR — no registry pull credentials
  needed (the `coder-registry-pull` secret is no longer referenced).
- The single-workspace lease + iSCSI target is acquired through the `llm01`
  provider (`registry.home.arrieta.eu/infra/llm01` — the host that serves the
  provider's download_url). The source address in `main.tf` must match this;
  a mismatch with the host recorded in the workspace state makes Terraform
  treat them as different providers and fails init.

## The Rust provider (`llm01_workspace_target`)

- Built with cargo; available on the Nix profile (`/Users/javier/.nix-profile/bin/cargo`).
- `[[bin]]` + `[lib]` share `src/`. `main.rs` just calls
  `tf_provider::serve("llm01", Llm01Provider::default())`.
- It's a thin HTTP client over the workspace-target helper API (Provision /
  Attach / Detach / Destroy), carrying the per-workspace capability in a private
  resource state. The companion bash client (`truenas-iscsi-helper-client.sh`)
  does the same lifecycle over mTLS and keeps the capability in a 0600 file under
  `$CODER_HELPER_STATE_DIR` (default `./.helper-state`), sent only in the
  `X-Coder-Capability` header and never logged.
- No Terraform/test harness is in this repo. `compatibility/main.tf` is a
  standalone check run from a provisioner pod (mTLS podman API + public image
  pull + bind-mount home + keep-id + cgroup v2 limits + non-root uid 1000). On
  success it
  requires filling in
  `docs/superpowers/evidence/2026-08-08-coder-podman-compatibility.md` and
  committing it.

## Tooling

- `terraform` and the `coder` CLI are NOT in this repo's environment; install
  `coder` (to push) and Terraform locally if you need to run plans.
- `cargo` (1.96 here; CI uses `dtolnay/rust-toolchain@stable`) builds the
  provider as a **static musl** binary: `cargo build --release
  --target x86_64-unknown-linux-musl` with `RUSTFLAGS="-C target-feature=+crt-static"`
  in `templates/podman-template/providers/llm01_workspace_target/`. CI's
  `Install protoc and musl` step pins `protoc 25.1` via `curl` and installs the
  small `musl-tools` package (with apt retries + `--no-install-recommends`) to
  avoid the `apt-get install protobuf-compiler` hang seen on the GitHub runners.

### terraform-provider-llm01 v0.1.3 binary distribution (see README.md for full docs)

The `llm01_workspace_target` Rust provider is built by CI as a **fully static
musl** binary (`cargo build --release --target x86_64-unknown-linux-musl` with
`RUSTFLAGS="-C target-feature=+crt-static"`, reqwest uses `rustls-tls` so no
openssl/libc dependency remains) and published to the provider registry served at
`registry.home.arrieta.eu/infra/llm01` as `terraform-provider-llm01_0.1.3_linux_amd64.zip`
with SHA256 checksum and a binary detached GPG signature. The static binary
runs in the glibc-less Coder provisioner; a plain `cargo build` (glibc dynamic)
fails there with `no such file or directory`.

**Version naming (unified):** the `v` prefix is only used in git tags and
workflow inputs (`v0.1.3`). Registry-facing file names strip it
(`terraform-provider-llm01_0.1.3_linux_amd64.zip`), but the binary **inside**
the zip keeps it (`terraform-provider-llm01_v0.1.3`) — the Terraform registry
convention. The CI workflows (`build.yml` manual, `publish.yml` release)
normalize the version by stripping the leading `v` for file names.

**CI reality:** `publish.yml` builds, signs, packages, **and pushes a new
registry image** (`registry-image/build.sh`) on release; `build.yml` (manual
trigger) only uploads Actions artifacts. The image goes to public **GHCR**
(`ghcr.io/javierarrieta/terraform-provider-registry`) tagged with the **bare
release version** (`:0.1.3`). **Tags are immutable** — `build.sh` refuses to
overwrite an existing tag (and GitHub's immutable-tags package setting rejects
it at the registry too); there is no `latest` tag. The k8s-casa
deployment references the version tag.

**How the registry is served:** the registry is an nginx serving the Terraform
provider protocol and static `/files/` content **baked into the image** (pushed to
public **GHCR** `ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>`)
— no mounted volume, no upload endpoint (`PUT /files/` returns 404). Publishing means:

1. Build the zip + SHA256SUMS + binary `.sig`.
2. Bake the protocol JSON + files into a new registry-image and push it to
   public **GHCR** (`ghcr.io/javierarrieta/terraform-provider-registry`).
3. Reference the new image by its immutable version tag in the **k8s-casa**
   deployment manifest (image → `ghcr.io/javierarrieta/terraform-provider-registry:<bare-version>`) and push — Flux GitOps deploys it. GHCR images are
   publicly pullable, so no k8s-casa pull-credential change is needed.
   k8s-casa/AGENTS.md forbids imperative kubectl changes. (Concrete
   hostnames/namespaces/secret names live in k8s-casa only.)

Registry protocol layout (modern protocol, v5.0):

- `/.well-known/terraform.json` → `{"providers.v1":"/v1/providers/"}`
- `/v1/providers/infra/llm01/versions`
- `/v1/providers/infra/llm01/{version}/download/{os}/{arch}`
- `/files/terraform-provider-llm01_{version}_{os}_{arch}.zip`
- `/files/terraform-provider-llm01_{version}_SHA256SUMS`
- `/files/terraform-provider-llm01_{version}_SHA256SUMS.sig`

**Distribution steps (manual fallback only):**

1. Build: `cargo build --release --target x86_64-unknown-linux-musl --bin terraform-provider-llm01`
   with `RUSTFLAGS="-C target-feature=+crt-static"` (fully static; runnable in the
   glibc-less provisioner). A plain `cargo build` produces a glibc binary that
   fails there with `no such file or directory`.
2. Create `terraform-provider-llm01_0.1.3_linux_amd64.zip` containing the binary
   (renamed `terraform-provider-llm01_v0.1.3`)
3. Create `terraform-provider-llm01_0.1.3_SHA256SUMS` with the SHA256 hash
4. Decrypt GPG signing key from the sops-encrypted K8s secret in k8s-casa (age
   key in the local sops age key directory)
5. Create **binary, detached** GPG signature (no `--armor` flag): `gpg --detach-sign`
6. Bake the protocol JSON + files into a new `terraform-provider-registry`
   image, push it to public GHCR under the bare version tag (immutable), and
   reference that tag in the k8s-casa manifest (Flux deploys)
7. Terraform fetches the provider from the registry host in `main.tf` with
   version `~> 0.1.3`
8. Verify: `gpg --verify terraform-provider-llm01_0.1.3_SHA256SUMS.sig terraform-provider-llm01_0.1.3_SHA256SUMS` (expect "Good signature")

**Critical:** Use binary GPG signature, not ASCII-armored. ASCII-armored signatures
are rejected as "invalid data: tag byte does not have MSB set". The Terraform
provider client expects binary signatures. The GPG key is stored in k8s-casa's
K8s secrets via `sops-encrypted`, not in this repo (fingerprint public in the
registry's download JSON).

## Remote VS Code debugging notes (llm01)

When investigating remote-VS-Code issues on a workspace, the extension host data
lives under `~/.vscode-server/` on the container:
- logs: `~/.vscode-server/data/logs/<session>/exthost1/vscode.git/Git.log`,
  `vscode.github/GitHub.log`, `remoteexthost.log`, `ptyhost.log`
- server ext install: `~/.vscode-server/cli/servers/Stable-*/server/extensions/{git,github,git-base}/dist/main.js` (minified)
- globalState (per-extension, shared across workspaces on the same host):
  `state.vscdb` for the extension id, e.g. `vscode.git`
- The current `Stable` hash is `1b6a188127eeaf9194f945eb6eb89a657e93c54c`.

## Git

This repo is a thin template package — there is only a `LICENSE` (Apache-2.0),
the template, and the provider. Don't expect build pipelines here; linting/type
checking happens in the host flake (`nixos-configurations`), not in CI in this
repo.
