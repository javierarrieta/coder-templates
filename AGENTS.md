# AGENTS.md — coder-templates

Single Coder template (`templates/podman-template`) + a Rust Terraform provider
companion (`.../providers/llm01_workspace_target`). All template logic lives in
`templates/podman-template/`; the provider implements the `llm01_workspace_target`
resource over the workspace-target helper API.

## Repo layout (only the things you'll touch)

```
coder-templates/
  templates/podman-template/
    main.tf                 # the template (agent, volumes, container, params)
    compatibility/main.tf   # standalone mTLS/registry compatibility test (run in a provisioner pod)
    scripts/truenas-iscsi-helper-client.sh  # mTLS lifecycle script (provision/attach/detach/destroy)
    providers/llm01_workspace_target/       # Rust Terraform provider
      Cargo.toml / Cargo.lock / src/{lib,main}.rs
    README.md               # canonical push + image-rebuild instructions (read this first)
  nixos-configurations/ (OUTSIDE this repo)  # pkgs/coder-workspace builds the workspace image
```

The workspace image itself is built from `~/code/nixos-configurations/pkgs/coder-workspace`
(`dockerTools.buildImage` in the nixos-configurations flake), not from this repo.
Changes to the image require editing the Nix flake and pushing a new image tag.

## Rebuild + push the workspace image (exact)

The image is built in the sibling repo **`nixos-configurations`**
(<https://github.com/javierarrieta/nixos-configurations>), checked out at
`~/code/nixos-configurations`. Edit only
`pkgs/coder-workspace/default.nix` in that repo (do NOT touch the `fish` package
override at the top, which bakes config into the fish package). Then, on a
machine able to build `x86_64-linux` (the previous image-build host):

```bash
# Build the image tarball (flake output attr: .#coder-workspace)
nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace
# Load + tag + push to the private registry
docker load -i result
docker tag coder-workspace:pinned registry.l.arrieta.eu/coder-workspace:<short-sha>
docker push registry.l.arrieta.eu/coder-workspace:<short-sha>
# (no docker daemon? fall back to podman load/push, or:)
# skopeo copy docker-archive:result docker://registry.l.arrieta.eu/coder-workspace:<short-sha>
```

`<short-sha>` = `git -C ~/code/nixos-configurations rev-parse --short HEAD`. Authenticate
to the registry with the dedicated push credential; do not record it anywhere.

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

After the image builds, set `workspace_image` to the new tag, push the template,
and **update** the workspace (see below).

## Push a template change (exact)

```bash
coder login <coder url>
coder templates push podman-template \
  --directory coder/templates/podman-template \
  --yes
```

**Pushing alone does NOT upgrade existing workspaces.** After changing the
template or the workspace image, you must also **update** the workspace to the
new template version (`coder update <workspace>` or the dashboard Update button)
and **restart** for the new image/cmd to take effect. A plain restart keeps the
old template/image.

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

After rebuilding the image, set `workspace_image` to the new `<short-sha>` tag,
push the template, and **update** the workspace. Verify on the Podman host:

```sh
podman inspect coder-<workspace> --format '{{json .Config.Image}}'
podman exec coder-<workspace> ls -l /lib64/ld-linux-x86-64.so.2 /lib64/libstdc++.so.6
```

## Template parameters / constraints

- `memory_gb` (2–8, mutable), `cpu_count` (2–24, mutable), `workspace_image` (mutable).
- `disk_gb` (10–200) is **immutable after workspace creation** (`mutable = false`).
- The container's only volume is `/home/coder` (iSCSI-backed via the `llm01`
  provider + helper). Data outside `/home/coder` is ephemeral to the pod.
- Auth/certs are mounted from Coder secrets: `/run/secrets/coder-podman-client`
  (mTLS), `/run/secrets/coder-registry-pull/{username,password}` (registry pull).
- The single-workspace lease + iSCSI target is acquired through the `llm01`
  private provider (`registry.l.arrieta.eu/infra/llm01`). Update the source
  address in `main.tf` to match your private registry.

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
  standalone check run from a provisioner pod (mTLS + registry pull + bind-volume
  + cgroup v2 limits + non-root uid 1000). On success it requires filling in
  `docs/superpowers/evidence/2026-08-08-coder-podman-compatibility.md` and
  committing it.

## Tooling

- `terraform` and the `coder` CLI are NOT in this repo's environment; install
  `coder` (to push) and Terraform locally if you need to run plans.
- `cargo` (1.92, Nix profile) builds the provider: `cargo build` in
  `templates/podman-template/providers/llm01_workspace_target/`.

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
