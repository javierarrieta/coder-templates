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
    # NOTE: Update the source address to match your private provider registry.
    llm01 = {
      source  = "registry.l.arrieta.eu/infra/llm01"
      version = "~> 0.1"
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

provider "coder" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

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

resource "docker_volume" "home" {
  count = data.coder_workspace.me.start_count
  name  = "coder-${data.coder_workspace.me.name}-home"

  driver = "local"
  driver_opts = {
    type   = "none"
    o      = "bind"
    device = "/srv/coder/workspaces/coder-${data.coder_workspace.me.name}"
  }
  depends_on = [llm01_workspace_target.workspace]
}

data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "Workspace image"
  description  = "Workspace container image (registry/repo:tag)"
  type         = "string"
  default      = "ghcr.io/javierarrieta/coder-workspace:latest"
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

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home[0].name
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  command = ["sh", "-c", coder_agent.main.init_script]
  depends_on = [llm01_workspace_target.workspace]
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id
  item {
    key   = "workspace"
    value = data.coder_workspace.me.name
  }
}
