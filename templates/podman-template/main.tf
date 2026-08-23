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

provider "docker" {
  host      = var.docker_host
  cert_path = "/run/secrets/coder-podman-client"
}

provider "llm01" {
  endpoint  = var.workspace_endpoint
  cert_path = "/run/secrets/coder-podman-client"
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
    if ! home-manager switch --flake github:javierarrieta/nixos-configurations#coder-workspace >> /home/coder/.hm-switch.log 2>&1; then echo "hm-switch failed $(date -u +%FT%TZ)" >> /home/coder/.hm-switch.log; fi
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

data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "Workspace image"
  description  = "Workspace container image (registry/repo:tag)"
  type         = "string"
  default      = "ghcr.io/javierarrieta/coder-workspaces-nix:0.0.7"
  mutable      = true
}

resource "docker_image" "workspace" {
  name = data.coder_parameter.workspace_image.value
}

resource "docker_container" "chown_home" {
  count = data.coder_workspace.me.start_count
  name  = "coder-${data.coder_workspace.me.name}-chown"
  image = docker_image.workspace.image_id

  mounts {
    target = "/home/coder"
    source = "/srv/coder/workspaces/coder-${data.coder_workspace.me.name}"
    type   = "bind"
  }

  command = ["sh", "-c", "chown -R 1000:1000 /home/coder"]
  # Podman removes --rm containers the instant they exit, so the provider's
  # follow-up inspect calls fail with "no such container ... found in
  # database". Keep the exited container instead; it is one-shot work and
  # Terraform still owns its lifecycle.
  rm          = false
  must_run    = false
  user        = "0:0"
  userns_mode = "keep-id:uid=1000,gid=1000"

  depends_on = [llm01_workspace_target.workspace]
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
    chown -R 1000:1000 /home/coder
    exec setpriv --reuid=1000 --regid=1000 --init-groups /tmp/agent-init.sh
  EOS
  ]
  depends_on = [
    llm01_workspace_target.workspace,
    docker_container.chown_home,
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