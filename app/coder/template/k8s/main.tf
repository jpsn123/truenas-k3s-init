terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in for another cluster. For the default Coder install cluster, workspaces are always created in coder."
  default     = "coder"
}

variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use pasted kubeconfig for another Kubernetes cluster? (true/false)

  Set this to false for the default Coder install cluster. The default install
  only grants namespaced Roles in the coder namespace, so local workspaces are
  always created in coder.

  Set this to true for another Kubernetes cluster. Paste the base64-encoded
  kubeconfig in the kubeconfig variable, then set namespace to the target namespace.
  EOF
  default     = false
}

variable "kubeconfig" {
  type        = string
  description = "Base64-encoded kubeconfig used when use_kubeconfig is true. Supports certificate-authority-data with token or client certificate credentials."
  default     = ""
  sensitive   = true

  validation {
    condition     = var.kubeconfig == "" || can(yamldecode(base64decode(replace(replace(trimspace(var.kubeconfig), "\r", ""), "\n", ""))))
    error_message = "kubeconfig must be valid base64-encoded YAML text."
  }
}

variable "code_server_mirror_url" {
  type        = string
  description = "The mirror URL used to download code-server releases."
  default     = "__CODE_SERVER_MIRROR_URL__"
}

variable "storage_class_name" {
  type        = string
  description = "The Kubernetes StorageClass used for workspace home disks."
  default     = "__STORAGE_CLASS_NAME__"
}

variable "workspace_image_registry_repo" {
  type        = string
  description = "The Docker repository used to push generated workspace images. Example: registry.example.com/coder-workspace."
  default     = "__WORKSPACE_IMAGE_REGISTRY_REPO__"
}

variable "workspace_image_registry_secret_name" {
  type        = string
  description = "The Kubernetes docker config secret used by BuildKit to push generated workspace images and by workspace Pods to pull them."
  default     = "coder-workspace-image-registry"
}

variable "workspace_image_buildctl_image" {
  type        = string
  description = "The BuildKit image used as buildctl client for generated workspace images."
  default     = "moby/buildkit:rootless"
}

variable "workspace_image_buildkit_addr" {
  type        = string
  description = "The BuildKit daemon address used to build generated workspace images."
  default     = "tcp://buildkit.buildkit.svc.cluster.local:1234"
}

variable "workspace_image_registry_check_image" {
  type        = string
  description = "The image used to check whether generated workspace images already exist."
  default     = "quay.io/skopeo/stable:latest"
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU 核心数"
  order        = 1
  description  = "工作区容器可使用的最大 CPU 核心数。创建后仍可修改。"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 核"
    value = "2"
  }
  option {
    name  = "4 核"
    value = "4"
  }
  option {
    name  = "8 核"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "内存大小"
  order        = 2
  description  = "工作区容器可使用的最大内存，单位为 GB。创建后仍可修改。"
  default      = "4"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
  option {
    name  = "16 GB"
    value = "16"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home 磁盘大小"
  order        = 3
  description  = "工作区 /home/coder 持久化磁盘容量，单位为 GB。创建后不可修改，允许范围为 50 到 500。"
  default      = "100"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 50
    max = 500
  }
}

data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "工作区基础镜像"
  order        = 4
  description  = "选择工作区使用的基础镜像。下方填写的 apt 包和自定义 RUN 命令会基于这个镜像构建新的个人工作区镜像。"
  default      = "__WORKSPACE_IMAGE_BASIC__"
  icon         = "/icon/docker.svg"
  mutable      = true
  option {
    name  = "基础开发环境"
    value = "__WORKSPACE_IMAGE_BASIC__"
  }
  option {
    name  = "C++ 开发环境"
    value = "__WORKSPACE_IMAGE_CPP__"
  }
  option {
    name  = "Web 开发环境"
    value = "__WORKSPACE_IMAGE_WEB__"
  }
}

data "coder_parameter" "ai_connector_token" {
  name         = "ai_connector_token"
  display_name = "__AI_CONNECTOR_DISPLAY_NAME__"
  order        = 5
  description  = "可选。用于初始化 Claude Code 和 Codex 的访问令牌。"
  default      = ""
  icon         = "/emojis/1f511.png"
  mutable      = true
  validation {
    regex = "^$|^[A-Za-z0-9._~:/+=-]+$"
    error = "令牌可以为空；如果填写，只能包含字母、数字和 . _ ~ : / + = -。"
  }
}

data "coder_parameter" "workspace_packages" {
  name         = "workspace_packages"
  display_name = "额外 apt 包"
  order        = 6
  description  = "可选。工作区重启会重置除Home目录以外的数据，故apt包只能通过这里预装，多个包用空格分隔。如需更复杂系统环境配置，请使用下方‘自定义镜像RUN命令’。"
  default      = ""
  icon         = "/emojis/1f4e6.png"
  mutable      = true
  validation {
    regex = "^$|^[A-Za-z0-9.+:_-]+( [A-Za-z0-9.+:_-]+)*$"
    error = "请使用空格分隔 apt 包名；只允许字母、数字、.、+、:、_ 和 -。"
  }
}

data "coder_parameter" "workspace_custom_run_script" {
  name         = "workspace_custom_run_script"
  display_name = "自定义镜像RUN命令"
  order        = 7
  description  = <<-EOF
    可选。这个功能用于构建你自己的持久化工作区镜像，让你的所有配置不被重置。
    
    可以自由定制开发环境，例如安装系统包、下载工具、写入全局配置、准备语言运行时等。

    如果你不会写，可以让 AI 帮你生成命令。建议把这些前提告诉 AI：
    正在构建 Coder workspace 镜像；基础镜像是 Ubuntu 24.04 并已包含绝大部分通用工具；根据需求生成配置环境的 shell 命令；命令在 Dockerfile RUN 阶段以 root 执行；可以多行；非交互执行；不要解释文字；不要包含敏感信息。
  EOF
  default      = <<-EOF
    # 可选：在这里填写 shell 命令；留空或只保留注释表示不启用。
    # 示例：curl -fsSL https://example.com/install.sh | sh
  EOF
  icon         = "/emojis/1f6e0-fe0f.png"
  mutable      = true
  form_type    = "textarea"
}

provider "kubernetes" {
  # use_kubeconfig=false uses the in-cluster ServiceAccount from the default Coder install.
  # use_kubeconfig=true connects to another cluster from the base64-encoded kubeconfig.
  host                   = local.has_kubeconfig ? try(local.kubeconfig_cluster.cluster.server, null) : null
  cluster_ca_certificate = local.has_kubeconfig ? try(base64decode(local.kubeconfig_cluster.cluster["certificate-authority-data"]), null) : null
  insecure               = local.has_kubeconfig ? try(local.kubeconfig_cluster.cluster["insecure-skip-tls-verify"], null) : null
  token                  = local.has_kubeconfig ? try(local.kubeconfig_user.user.token, null) : null
  username               = local.has_kubeconfig ? try(local.kubeconfig_user.user.username, null) : null
  password               = local.has_kubeconfig ? try(local.kubeconfig_user.user.password, null) : null
  client_certificate     = local.has_kubeconfig ? try(base64decode(local.kubeconfig_user.user["client-certificate-data"]), null) : null
  client_key             = local.has_kubeconfig ? try(base64decode(local.kubeconfig_user.user["client-key-data"]), null) : null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  kubeconfig_base64         = replace(replace(trimspace(var.kubeconfig), "\r", ""), "\n", "")
  has_kubeconfig            = var.use_kubeconfig && local.kubeconfig_base64 != ""
  workspace_namespace       = var.use_kubeconfig ? var.namespace : "coder"
  kubeconfig_data           = local.has_kubeconfig ? yamldecode(base64decode(local.kubeconfig_base64)) : null
  kubeconfig_context_name   = local.has_kubeconfig ? lookup(local.kubeconfig_data, "current-context", "") : ""
  kubeconfig_context        = local.has_kubeconfig ? one([for context in try(local.kubeconfig_data.contexts, []) : context if context.name == local.kubeconfig_context_name]) : null
  kubeconfig_cluster_name   = local.has_kubeconfig ? local.kubeconfig_context.context.cluster : ""
  kubeconfig_user_name      = local.has_kubeconfig ? local.kubeconfig_context.context.user : ""
  kubeconfig_cluster        = local.has_kubeconfig ? one([for cluster in try(local.kubeconfig_data.clusters, []) : cluster if cluster.name == local.kubeconfig_cluster_name]) : null
  kubeconfig_user           = local.has_kubeconfig ? one([for user in try(local.kubeconfig_data.users, []) : user if user.name == local.kubeconfig_user_name]) : null
  workspace_name_raw = trim(
    replace(
      lower("${data.coder_workspace.me.name}"),
      "/[^a-z0-9-]/",
      "-"
    ),
    "-"
  )
  workspace_name     = trim(substr(local.workspace_name_raw, 0, 32), "-")
  workspace_hostname = local.workspace_name != "" ? local.workspace_name : "workspace"
  workspace_tag_name_raw = trim(
    substr(
      trim(
        replace(
          lower("${data.coder_workspace.me.name}"),
          "/[^a-z0-9.-]/",
          "-"
        ),
        "-."
      ),
      0,
      32
    ),
    "-."
  )
  workspace_tag_name  = local.workspace_tag_name_raw != "" ? local.workspace_tag_name_raw : "workspace"
  workspace_owner_raw = data.coder_workspace_owner.me.email != "" ? split("@", data.coder_workspace_owner.me.email)[0] : data.coder_workspace_owner.me.name
  workspace_owner_name = trim(
    substr(
      trim(
        replace(
          lower("${local.workspace_owner_raw}"),
          "/[^a-z0-9.-]/",
          "-"
        ),
        "-."
      ),
      0,
      32
    ),
    "-."
  )
  workspace_owner_tag       = local.workspace_owner_name != "" ? local.workspace_owner_name : "user"
  workspace_deployment_name = "coder-workspace-${local.workspace_owner_tag}-${local.workspace_hostname}"
  workspace_configmap_name  = "${local.workspace_deployment_name}-custom"
  base_workspace_image             = data.coder_parameter.workspace_image.value
  workspace_packages               = trimspace(data.coder_parameter.workspace_packages.value)
  workspace_custom_run_script      = data.coder_parameter.workspace_custom_run_script.value
  workspace_custom_run_commands    = trimspace(join("\n", [for line in split("\n", local.workspace_custom_run_script) : line if trimspace(line) != "" && !startswith(trimspace(line), "#")]))
  has_workspace_packages           = local.workspace_packages != ""
  has_workspace_custom_run_script  = local.workspace_custom_run_commands != ""
  has_workspace_image_customization = local.has_workspace_packages || local.has_workspace_custom_run_script
  workspace_custom_run_dockerfile = format("RUN %s", jsonencode(["/bin/sh", "-euxc", join("\n", compact([
    "if [ -n \"$APT_PACKAGES\" ]; then",
    "  apt-get update",
    "  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $APT_PACKAGES",
    "fi",
    local.workspace_custom_run_commands,
    "rm -rf /var/lib/apt/lists/*",
  ]))]))
  workspace_template_hash = filesha1("${path.module}/Dockerfile.custom")
  workspace_image_hash            = substr(sha1(jsonencode([data.coder_workspace.me.id, local.base_workspace_image, local.workspace_packages, local.workspace_custom_run_commands, local.workspace_template_hash])), 0, 8)
  workspace_image_tag             = "${local.workspace_owner_tag}-${local.workspace_tag_name}-${local.workspace_image_hash}"
  generated_workspace_image        = "${var.workspace_image_registry_repo}:${local.workspace_image_tag}"
  workspace_image                  = local.has_workspace_image_customization ? local.generated_workspace_image : local.base_workspace_image
  build_job_name                   = "coder-${substr(data.coder_workspace.me.id, 0, 24)}-image-${local.workspace_image_hash}"
}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<-EOT
    set -e

    cat > /tmp/workspace-init.sh <<'WORKSPACE_INIT_SH'
${file("${path.module}/workspace-init.sh")}
WORKSPACE_INIT_SH
    chmod +x /tmp/workspace-init.sh

    # Install code-server and initialize workspace defaults (code-server settings/extensions + AI tools).
    CODE_SERVER_MIRROR_URL="$${CODE_SERVER_MIRROR_URL:-${var.code_server_mirror_url}}" \
    AI_CONNECTOR_TOKEN="$${AI_CONNECTOR_TOKEN:-${data.coder_parameter.ai_connector_token.value}}" \
      /tmp/workspace-init.sh
    export PATH="$${HOME}/.local/bin:$${PATH}"

    # Start code-server in the background.
    code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "home-${local.workspace_owner_tag}-${local.workspace_tag_name}"
    namespace = local.workspace_namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      //Coder-specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace_owner.me.id
      "com.coder.user.username"  = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false

  lifecycle {
    precondition {
      condition     = var.use_kubeconfig || var.namespace == "coder"
      error_message = "namespace must be coder when use_kubeconfig is false because the default Coder install only has namespaced Roles in the coder namespace."
    }
    precondition {
      condition     = !var.use_kubeconfig || trimspace(var.kubeconfig) != ""
      error_message = "kubeconfig must be provided when use_kubeconfig is true."
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_config_map_v1" "workspace_image_build" {
  count = local.has_workspace_image_customization ? 1 : 0
  metadata {
    name      = local.workspace_configmap_name
    namespace = local.workspace_namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace-image-build"
      "app.kubernetes.io/instance" = local.build_job_name
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
  }
  data = {
    "Dockerfile" = replace(file("${path.module}/Dockerfile.custom"), "# __WORKSPACE_CUSTOM_RUN__", local.workspace_custom_run_dockerfile)
  }
}

resource "kubernetes_job_v1" "workspace_image_build" {
  count               = local.has_workspace_image_customization && data.coder_workspace.me.start_count > 0 ? 1 : 0
  wait_for_completion = true
  timeouts {
    create = "30m"
    update = "30m"
  }
  metadata {
    name      = local.build_job_name
    namespace = local.workspace_namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace-image-build"
      "app.kubernetes.io/instance" = local.build_job_name
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  spec {
    backoff_limit              = 1
    ttl_seconds_after_finished = 86400
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace-image-build"
          "app.kubernetes.io/instance" = local.build_job_name
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name
          "com.coder.user.id"          = data.coder_workspace_owner.me.id
          "com.coder.user.username"    = data.coder_workspace_owner.me.name
        }
      }
      spec {
        restart_policy                 = "Never"
        automount_service_account_token = false
        init_container {
          name    = "check-image"
          image   = var.workspace_image_registry_check_image
          command = ["sh", "-c"]
          args = [
            <<-EOT
              BASE_DIGEST=$(skopeo inspect --authfile /docker/config.json docker://${local.base_workspace_image} 2>/dev/null | sed -n 's/^.*"Digest": *"\([^"]*\)".*$/\1/p' | head -n 1)
              IMAGE_BASE_DIGEST=$(skopeo inspect --authfile /docker/config.json docker://${local.generated_workspace_image} 2>/dev/null | sed -n 's/^.*"org.opencontainers.image.base.digest": *"\([^"]*\)".*$/\1/p' | head -n 1)

              echo "$BASE_DIGEST" > /status/base-digest
              if [ -n "$BASE_DIGEST" ] && [ "$BASE_DIGEST" = "$IMAGE_BASE_DIGEST" ]; then
                echo current > /status/image
              else
                echo stale > /status/image
              fi
            EOT
          ]
          volume_mount {
            name       = "docker-config"
            mount_path = "/docker"
            read_only  = true
          }
          volume_mount {
            name       = "image-status"
            mount_path = "/status"
          }
        }
        container {
          name    = "buildctl"
          image   = var.workspace_image_buildctl_image
          command = ["sh", "-c"]
          args = [
            <<-EOT
              if [ "$(cat /status/image 2>/dev/null || true)" = "current" ]; then
                echo "Image ${local.generated_workspace_image} is current, skip build."
                exit 0
              fi

              BASE_DIGEST=$(cat /status/base-digest 2>/dev/null || true)
              BASE_IMAGE_REF="${local.base_workspace_image}"
              if [ -n "$BASE_DIGEST" ] && ! echo "$BASE_IMAGE_REF" | grep -q '@'; then
                BASE_IMAGE_REF="$BASE_IMAGE_REF@$BASE_DIGEST"
              fi

              set -- \
                --addr=${var.workspace_image_buildkit_addr} \
                build \
                --progress=plain \
                --frontend=dockerfile.v0 \
                --local=context=/workspace \
                --local=dockerfile=/workspace \
                --opt=build-arg:BASE_IMAGE_REF="$BASE_IMAGE_REF" \
                --opt=build-arg:BASE_IMAGE=${local.base_workspace_image} \
                --opt=build-arg:BASE_IMAGE_DIGEST="$BASE_DIGEST"

              if [ -n '${local.workspace_packages}' ]; then
                set -- "$@" --opt=build-arg:APT_PACKAGES='${local.workspace_packages}'
              fi

              exec buildctl "$@" \
                --output=type=image,name=${local.generated_workspace_image},push=true
            EOT
          ]
          volume_mount {
            name       = "docker-config"
            mount_path = "/home/user/.docker"
            read_only  = true
          }
          volume_mount {
            name       = "image-status"
            mount_path = "/status"
          }
          volume_mount {
            name       = "context"
            mount_path = "/workspace"
            read_only  = true
          }
        }
        volume {
          name = "docker-config"
          secret {
            secret_name = var.workspace_image_registry_secret_name
            items {
              key  = ".dockerconfigjson"
              path = "config.json"
            }
          }
        }
        volume {
          name = "context"
          config_map {
            name = kubernetes_config_map_v1.workspace_image_build[0].metadata.0.name
          }
        }
        volume {
          name = "image-status"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim_v1.home,
    kubernetes_job_v1.workspace_image_build
  ]
  wait_for_rollout = false
  metadata {
    name      = local.workspace_deployment_name
    namespace = local.workspace_namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
        "app.kubernetes.io/part-of"  = "coder"
        "com.coder.resource"         = "true"
        "com.coder.workspace.id"     = data.coder_workspace.me.id
        "com.coder.workspace.name"   = data.coder_workspace.me.name
        "com.coder.user.id"          = data.coder_workspace_owner.me.id
        "com.coder.user.username"    = data.coder_workspace_owner.me.name
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name
          "com.coder.user.id"          = data.coder_workspace_owner.me.id
          "com.coder.user.username"    = data.coder_workspace_owner.me.name
        }
      }
      spec {
        hostname                        = local.workspace_hostname
        automount_service_account_token = false

        image_pull_secrets {
          name = var.workspace_image_registry_secret_name
        }

        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }

        container {
          name              = "dev"
          image             = local.workspace_image
          image_pull_policy = "Always"
          command           = ["sh", "-c", coder_agent.main.init_script]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          resources {
            requests = {
              "cpu"    = "100m"
              "memory" = "512Mi"
            }
            limits = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata.0.name
            read_only  = false
          }
        }

        affinity {
          // This affinity attempts to spread out all workspace pods evenly across
          // nodes.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}