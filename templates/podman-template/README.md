# podman-template Coder Template

Workspaces run as rootless podman containers on the configured host with homes on iSCSI volumes.

## Push

```bash
coder login <coder url>
coder templates push podman-template \
  --directory templates/podman-template \
  --yes
```

The built-in Coder provisioner runs the template and reaches the Podman host through the configured mTLS API.

## Creating a workspace

1. Choose `memory_gb` (2-8), `cpu_count` (2-24), and `disk_gb` (10-200; immutable after creation).
2. The template acquires the single-workspace lease and requests iSCSI provisioning through the capability-authenticated workspace target helper.
3. The helper provisions/attaches the target, and the Docker provider starts the container with provider-supplied registry auth.
4. Stop/start preserves `/home/coder` (data on TrueNAS). Delete tears down the target + zvol.

## VS Code Remote-SSH on a NixOS workspace image

The workspace image runs NixOS (`ID=nixos`). VS Code Server ships an Alpine/musl
CLI for such hosts, and its pre-flight check fails to find a usable environment:
NixOS keeps libraries in `/nix/store`, so there is neither `libstdc++.so`/
`ldconfig` (GNU) nor `/lib/ld-musl-x86_64.so.1` (musl). The connection fails with
`The remote host does not meet the prerequisites for running VS Code Server`.

### Template workaround (already applied)

At container start the template detects NixOS and creates the documented bypass
file, then wires the Nix store glibc into the standard loader/lib paths so the
downloaded glibc server binary can actually exec:

```sh
if grep -q ID=nixos /etc/os-release 2>/dev/null; then
  touch /tmp/vscode-skip-server-requirements-check
  if [ ! -e /lib64/ld-linux-x86-64.so.2 ] && [ -d /nix/store ]; then
    mkdir -p /lib64 /lib /usr/lib64 /usr/lib
    GLIBC=$(ls -d /nix/store/*-glibc-*/lib 2>/dev/null | head -n1)
    if [ -n "$GLIBC" ]; then
      LOADER=$(ls "$GLIBC"/ld-linux-x86-64.so.2 "$GLIBC"/ld-2*.so* 2>/dev/null | head -n1)
      if [ -n "$LOADER" ]; then
        ln -sfn "$LOADER" /lib64/ld-linux-x86-64.so.2
        ln -sfn "$LOADER" /lib/ld-linux-x86-64.so.2
      fi
    fi
    : > /etc/ld.so.conf
    for d in /nix/store/*/lib*; do
      [ -d "$d" ] && echo "$d" >> /etc/ld.so.conf
    done
    LDCONFIG=$(ls /nix/store/*-glibc-*/bin/ldconfig 2>/dev/null | head -n1)
    if [ -n "$LDCONFIG" ]; then
      "$LDCONFIG" 2>/dev/null
    fi
    for d in /nix/store/*/lib*; do
      [ -d "$d" ] || continue
      for f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libgcc_s.so.1 libstdc++.so.6; do
        if [ -e "$d/$f" ]; then
          [ -e /lib64/"$f" ] || ln -sfn "$d/$f" /lib64/"$f"
          [ -e "/usr/lib/$f" ] || ln -sfn "$d/$f" "/usr/lib/$f"
        fi
      done
    done
  fi
fi
```

The bypass file makes VS Code Server skip the pre-requisite check ("Server
stability is not guaranteed" warning) and proceed with the install. The loader
symlink + `ld.so.conf`/`ldconfig` cache make nixpkgs glibc resolve every shared
library (`libc`, `libstdc++`, `libgcc_s`, ...) from the store. Both steps only
run for NixOS images (`ID=nixos`); glibc-based images run the normal check.

The shim runs as the container's configured user. If the image starts as a
non-root user, `mkdir /lib64` fails and the shim is a no-op — prefer images that
boot as root (or apply the durable image fix below).

### Chosen approach: durable image fix

Prefer the root-level wiring at build time (runs as root regardless of the
container's startup user, and persists across container restarts/recreates).
The current image (`coder-workspace`) boots as `coder` (uid 1000), so the
template shim above **does not run**. The image is built from
`pkgs/coder-workspace` (`dockerTools.buildImage` in the `nixos-configurations`
flake); its `runAsRoot` does the following so VS Code Server's glibc binaries
can exec and resolve libraries from the store:

```sh
# glibc loader + libs at FHS paths so unpatched binaries can run.
mkdir -p /lib /lib64 /usr/lib /usr/lib64 /usr/bin /sbin
ln -sfn ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
ln -sfn ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2
for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libnss_dns.so.2 libnss_files.so.2; do
  ln -sfn ${pkgs.glibc}/lib/$lib /lib64/$lib
  ln -sfn ${pkgs.glibc}/lib/$lib /usr/lib/$lib
  ln -sfn ${pkgs.glibc}/lib/$lib /usr/lib64/$lib
done
ln -sfn ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 /lib64/libstdc++.so.6
ln -sfn ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 /usr/lib/libstdc++.so.6
ln -sfn ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 /usr/lib64/libstdc++.so.6
ln -sfn ${pkgs.libgcc}/lib/libgcc_s.so.1 /lib64/libgcc_s.so.1
ln -sfn ${pkgs.libgcc}/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
ln -sfn ${pkgs.libgcc}/lib/libgcc_s.so.1 /usr/lib64/libgcc_s.so.1
ln -sfn ${pkgs.zlib}/lib/libz.so.1 /lib64/libz.so.1
ln -sfn ${pkgs.zlib}/lib/libz.so.1 /usr/lib/libz.so.1
# 'sh' shebang needs /usr/bin/env; VS Code CLI GNU prereq probes need ldd and
# /sbin/ldconfig.
ln -sfn ${pkgs.coreutils}/bin/env /usr/bin/env
ln -sfn ${pkgs.glibc.bin}/bin/ldconfig /sbin/ldconfig
ln -sfn ${pkgs.glibc.bin}/bin/ldd /usr/bin/ldd
# NixOS marker: VS Code Server's CLI checks /etc/NIXOS (not os-release) and
# then selects the default glibc server build.
touch /etc/NIXOS
```

In Nix `''...''` strings the loop variable must be escaped as `\$lib`.
`programs.nix-ld` on a NixOS *host* is no substitute: the current nix-ld uses a
musl loader + `NIX_LD` env vars, while VS Code binaries hardcode PT_INTERP
`/lib64/ld-linux-x86-64.so.2` and are invoked directly (no env), so they need
the real glibc loader symlinked at the standard paths.

**Do NOT add a musl loader at `/lib`** (`ld-musl-x86_64.so.1`). The CLI's
`check_musl_interpreter` probe treats its presence as "this is a musl host"
and downloads the **Alpine/musl server** (`server-linux-alpine`); that musl
`node` then fails to run against the glibc libraries wired above
(`Error relocating /usr/lib/libstdc++.so.6: ... symbol not found`). Without
it, `check_is_nixos` (`/etc/NIXOS`) + the GNU libstdc++/libc probes select the
default `server-linux-x64` build, which is exactly what runs on these glibc
libraries.

After the rebuild: push the image to the registry under a new pinned tag
(`git rev-parse --short HEAD`), set `workspace_image` to it, push the template
(`coder templates push`), and **update** the workspace (push alone does not
upgrade existing workspaces; a plain restart keeps the old image/command).
Verify on the Podman host before testing VS Code:

```sh
podman inspect coder-llm01-podman --format '{{json .Config.Image}}'
podman exec coder-llm01-podman sh -c 'ls -l /lib64/ld-linux-x86-64.so.2 && /lib64/ld-linux-x86-64.so.2 --version'
```

Once the image ships the fix, the template's runtime shim is redundant but
harmless. See `fix/vscode-tar-workspace-image` for the previous image fix that
added `tar`.

After re-pushing the template, the workspace must be **updated** to the new
template version (`coder update <workspace>` or the dashboard Update button);
pushing alone does not upgrade existing workspaces, and a plain restart keeps
the old template. Verify the container got the new command and the file on the
Podman host:

```sh
podman inspect coder-<workspace> --format '{{json .Config.Cmd}}'
podman exec coder-<workspace> ls -l /tmp/vscode-skip-server-requirements-check
podman exec coder-<workspace> ls -l /lib64/ld-linux-x86-64.so.2 /lib64/libstdc++.so.6
```

## Providers

- `coder/coder` and `kreuzwerker/docker` come from `registry.terraform.io`.
- `registry.l.arrieta.eu/infra/llm01` is the pinned helper-client provider published to the in-cluster registry; checksums are committed in `.terraform.lock.hcl`. Update the source address in `main.tf` to match your provider registry.
