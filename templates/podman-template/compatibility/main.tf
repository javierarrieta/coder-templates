# Podman/Docker-provider compatibility gate for podman-template workspaces.
#
# Run from a Coder-like provisioner pod with the mTLS client bundle mounted at
# /run/secrets/coder-podman-client. The workspace image is pulled from public
# GHCR (no registry credentials needed). After a successful run, the evidence
# document docs/superpowers/evidence/2026-08-08-coder-podman-compatibility.md
# must be filled in and committed before any later task.

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
  }
}

variable "host" {
  description = "mTLS Podman Docker-compatible API endpoint"
  default     = "tcp://localhost:2376"
}

variable "cert_path" {
  description = "Directory containing ca.pem, cert.pem, and key.pem"
  default     = "/run/secrets/coder-podman-client"
}

variable "workspace_image" {
  description = "Workspace container image (registry/repo:tag)"
  type        = string
  default     = "ghcr.io/javierarrieta/coder-workspace:latest"
}

provider "docker" {
  host      = var.host
  cert_path = var.cert_path
}

# 1. mTLS podman API + public GHCR pull: connects to the remote API with the
#    mTLS bundle; the image itself needs no registry credentials.
resource "docker_image" "workspace" {
  name = var.workspace_image
}

# 2. Bind mount for the home directory: a direct bind mount of the iSCSI-backed
#    path (no named volume), the exact mechanism the podman-template template
#    uses. Named volumes are chowned by rootless Podman on first use, which
#    fails with EPERM on network-backed mounts; bind mounts are never chowned.
#    The bind source must already exist on the Podman host (like the iSCSI
#    mount the helper creates): `sudo mkdir -p /srv/coder/workspaces/coder-compat-gate`.

# 3. Container with memory/cpus cgroup v2 limits; run as non-root uid 1000
#    mapped via keep-id to the podman host user.
resource "docker_container" "workspace" {
  name  = "coder-compat-gate"
  image = docker_image.workspace.image_id

  memory = 4096
  cpus   = "4"

  mounts {
    target = "/home/coder"
    source = "/srv/coder/workspaces/coder-compat-gate"
    type   = "bind"
  }

  user        = "1000:1000"
  userns_mode = "keep-id"

  env = [
    "COMPAT_GATE=1",
  ]

  command = ["sh", "-c", "id; mount | grep ' /home/coder '; touch /home/coder/.compat-write-test && ls -la /home/coder; sleep 300"]
}

# 4. Restart/destroy cycle is exercised by `terraform apply`/`terraform
#    destroy`. Device isolation (no host devices/GPU) is verified by inspecting
#    `docker inspect` output on the host and is recorded in the evidence doc.
output "workspace_id" {
  value = docker_container.workspace.id
}
