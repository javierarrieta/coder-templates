terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.17"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
    # NOTE: The provider source host must match the registry that the workspace
    # state was created under (the host in the registry's download_url).
    llm01 = {
      source = "registry.home.arrieta.eu/infra/llm01"
      # 0.1.1 ships a macOS Mach-O binary in the linux_amd64 zip
      # (exec format error on provisioner init). 0.1.2 is dynamically
      # linked glibc (no such file or directory in the glibc-less
      # provisioner). 0.1.3+ is the static musl build, so require >= 0.1.3.
      version = "~> 0.1.3"
    }
  }
}

variable "docker_host" {
  description = "Docker/Podman API endpoint (mTLS)"
  type        = string
  default     = "tcp://192.168.0.29:2376"
}

variable "workspace_endpoint" {
  description = "Workspace target helper API endpoint"
  type        = string
  default     = "https://192.168.0.29:2377"
}

provider "coder" {
}

data "coder_workspace" "me" {
}
data "coder_workspace_owner" "me" {
}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "Memory (GB)"
  description  = "Container memory limit in GB (2-8)"
  type         = "number"
  default      = 4
  validation {
    min = 2
    max = 8
  }
  mutable = true
}

data "coder_parameter" "cpu_count" {
  name         = "cpu_count"
  display_name = "CPU count"
  description  = "Container CPU limit (2-24)"
  type         = "number"
  default      = 8
  validation {
    min = 2
    max = 24
  }
  mutable = true
}

data "coder_parameter" "disk_gb" {
  name         = "disk_gb"
  display_name = "Disk size (GB)"
  description  = "Size of the workspace home volume on TrueNAS (10-200)"
  type         = "number"
  default      = 50
  validation {
    min = 10
    max = 200
  }
  mutable = false
}

# Nix build parallelism.
#
# Nix's default `cores = 0` means "use every core", and it resolves that via
# std::thread::hardware_concurrency() -> sched_getaffinity, which is NOT
# cgroup-aware. Verified in coder-workspaces-nix v0.0.10 (Nix 2.31.2): in a
# --cpus=2 container the affinity mask is still the full 32-core host mask
# (nproc reports 2, sched_getaffinity reports 0-31), so a single build forks
# -j32 compilers and pays ~32x the peak RSS against the workspace memory
# limit -- which is how the workspace cgroup gets OOM-killed. Cap it explicitly.
#
# NOTE: this bounds the BUILD phase only. Nix 2.31 has no `max-threads` setting
# (`nix config show` -> "unknown setting 'max-threads'"), so evaluation is not
# thread-tunable; eval peak RSS is the flake's live working set and only more
# memory_gb reduces that.
data "coder_parameter" "nix_build_cores" {
  name         = "nix_build_cores"
  display_name = "Nix build cores"
  description  = "NIX_BUILD_CORES per nix build job (-j). Caps concurrent compiler processes, and so peak build memory. Does NOT bound nix evaluation memory. Restart the workspace to apply."
  type         = "number"
  default      = 2
  validation {
    min = 1
    max = 8
  }
  mutable = true
}

provider "docker" {
  host      = var.docker_host
  cert_path = "/run/secrets/coder-podman-client"
}

provider "llm01" {
  endpoint  = var.workspace_endpoint
  cert_path = "/run/secrets/coder-podman-client"
}

# Remaining fixed Nix knobs. Build parallelism itself is a workspace parameter
# (data.coder_parameter.nix_build_cores) so it can be retuned per workspace.
locals {
  nix_max_jobs = 1

  # oom_score_adj for nix/home-manager. Higher = killed first.
  nix_oom_score = 1000
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  # Config-only home-manager: dotfiles from github main; software comes from
  # the image. Requires image >= 0.0.6 and the flake merged to main.
  # Store-dir writability for uid 1000 is granted by the container's root
  # boot (see docker_container.workspace); no sudo needed here.
  startup_script = <<-EOT
    #!/bin/bash
    set -uo pipefail
    # OOM shield for the boot-time home-manager eval/build: this process and
    # everything it forks become the kernel's preferred victim, so when the
    # workspace cgroup runs out of memory the nix work is reaped rather than
    # the coder agent (PID 1 -- if it dies the container dies and the workspace
    # drops). Raising our own score is unprivileged; lowering the agent's would
    # need CAP_SYS_RESOURCE in init_user_ns, which rootless Podman lacks.
    echo ${local.nix_oom_score} > /proc/self/oom_score_adj 2>/dev/null || true
    if ! home-manager switch -b pre-hm --flake github:javierarrieta/nixos-configurations#coder-workspace >> /home/coder/.hm-switch.log 2>&1; then echo "hm-switch failed $(date -u +%FT%TZ)" >> /home/coder/.hm-switch.log; fi
  EOT

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }
}

resource "llm01_workspace_target" "workspace" {
  workspace = data.coder_workspace.me.name
  size_gb   = data.coder_parameter.disk_gb.value
  active    = data.coder_workspace.me.start_count > 0
}

# Pinned to the tag the running workspace actually uses. The registry publishes
# both "v0.0.10" and "0.0.10" at the same digest
# (sha256:dc9ce820fe127c83b0622faea5a1873e73b8a23bca840055aea512742c62fa69),
# which is also what "latest" points at right now -- never default to "latest",
# it moves under you and breaks rollback.
data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "Workspace image"
  description  = "Workspace container image (registry/repo:tag)"
  type         = "string"
  default      = "ghcr.io/javierarrieta/coder-workspaces-nix:v0.0.10"
  mutable      = true
}

resource "docker_image" "workspace" {
  name = data.coder_parameter.workspace_image.value
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  name  = "coder-${data.coder_workspace.me.name}"
  image = docker_image.workspace.image_id

  memory = data.coder_parameter.memory_gb.value * 1024
  cpus   = tostring(data.coder_parameter.cpu_count.value)

  # Bind-mount the iSCSI-backed home directory directly instead of a named
  # volume. Rootless Podman chowns named volumes to the container user on first
  # use, which fails with EPERM on the iSCSI mount; bind mounts are never
  # chowned.
  #
  # keep-id maps the podman host user to the given container uid:gid. Plain
  # "keep-id" maps host user -> container uid == host uid (here 27003), which
  # does NOT match the process user (1000:1000); the process then falls into
  # the subuid range (host 101000) and cannot access home data owned by the
  # host user. "keep-id:uid=1000,gid=1000" forces host user -> container
  # uid 1000 so the workspace user and its /home/coder data share one owner.
  mounts {
    target = "/home/coder"
    source = "/srv/coder/workspaces/coder-${data.coder_workspace.me.name}"
    type   = "bind"
  }

  # Boots as root solely to grant the nix store dirs to uid 1000 (in-build
  # chown crashes the image builder VM; runtime chown is cheap). Then drops
  # privileges and hands over to the agent init script (written to a file
  # because an inline jsonencode'd script crashed container creation in the
  # live spike).
  user        = "0:0"
  userns_mode = "keep-id:uid=1000,gid=1000"

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz",
  ]

  command = ["sh", "-c", <<-EOS
    cat > /tmp/agent-init.sh <<'AGENTINIT'
    ${coder_agent.main.init_script}
    AGENTINIT
    chmod +x /tmp/agent-init.sh
    chown 1000:1000 /nix /nix/store || echo 'store setup failed'
    chmod u+rwx /nix/store || true
    mkdir -p /nix/var/nix
    chown -R 1000:1000 /nix/var /nix/var/nix
    # Top-level only: a recursive chown crawls the whole home volume over
    # iSCSI and blocks agent start for many minutes. Volume contents are
    # already uid 1000 from prior use; fix strays with a one-off if ever seen.
    chown 1000:1000 /home/coder

    # Cap Nix build parallelism (see data.coder_parameter.nix_build_cores). Written to the
    # system nix.conf rather than the NIX_CONFIG env var because home-manager
    # exports its own session NIX_CONFIG (experimental-features only), which
    # would otherwise shadow this. Guarded so repeated starts don't grow the
    # file.
    mkdir -p /etc/nix
    grep -q '^# coder-template nix limits' /etc/nix/nix.conf 2>/dev/null || printf '\n# coder-template nix limits\ncores = %s\nmax-jobs = %s\n' '${tostring(data.coder_parameter.nix_build_cores.value)}' '${tostring(local.nix_max_jobs)}' >> /etc/nix/nix.conf

    # Nix OOM shield. When the workspace memory cgroup is exhausted the kernel
    # picks a victim from inside it, and the coder agent is PID 1 of this
    # container: if it is chosen, the container dies and the workspace drops.
    # Put a shim in front of the real nix so every nix invocation -- boot-time
    # home-manager, an interactive terminal, or an in-workspace coding agent --
    # raises its own oom_score_adj before running. The shim is resolved at boot
    # from the real PATH so it never points at itself, and the prepend survives
    # to the agent and all PTYs (nothing in this image's /etc/profile,
    # /etc/bashrc or /etc/fish/config.fish rewrites PATH).
    REAL_NIX="$(command -v nix || true)"
    [ -n "$REAL_NIX" ] || REAL_NIX=/bin/nix
    mkdir -p /nix-oom-shield
    printf '#!/bin/sh\necho ${local.nix_oom_score} > /proc/self/oom_score_adj 2>/dev/null || true\nexec %s "$@"\n' "$REAL_NIX" > /nix-oom-shield/nix
    chmod 0755 /nix-oom-shield/nix
    export PATH="/nix-oom-shield:$PATH"

    exec setpriv --reuid=1000 --regid=1000 --init-groups /tmp/agent-init.sh
  EOS
  ]
  depends_on = [
    llm01_workspace_target.workspace,
  ]
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id
  item {
    key   = "workspace"
    value = data.coder_workspace.me.name
  }
}