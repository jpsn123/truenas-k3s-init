# Coder Kubernetes Workspace Template

该目录是 Coder 的 Kubernetes 工作区模板，用于在集群中为每个用户工作区创建一个独立的 Pod，并在 Pod 内启动 code-server。

## 文件说明

| 文件 | 说明 |
|---|---|
| `main.tf` | Coder 模板的 Terraform 配置，定义工作区参数、PVC、Deployment、Coder Agent 和 code-server 应用入口。 |
| `workspace-init.sh` | 工作区初始化脚本。模板启动时会把该脚本写入 Debian-like 工作区 Pod，从 JFrog mirror 下载安装 code-server standalone 包，并初始化 code-server 默认配置（设置、扩展）和 Claude Code 配置（`~/.claude/settings.json`）。 |
| `Dockerfile.custom` | 当用户填写额外 apt 包时，BuildKit 使用该 Dockerfile 基于所选工作区镜像构建新镜像并推送到 JFrog Docker 仓库。 |

## 主要能力

- 通过 Coder 参数选择 CPU、内存和 home 目录磁盘大小。
- 创建工作区时可选择 Basic Ubuntu、C++ 开发环境或 Web 开发环境。
- 可填写额外 apt 包；填写后会先在集群内构建新镜像、推送到镜像仓库，再用该镜像启动工作区。
- 为每个工作区创建独立 PVC，挂载到 `/home/coder`。
- 工作区启动时将 code-server 安装到持久化的 `/home/coder/.local`，并以 `--auth none --port 13337` 启动。
- 在 Coder 中暴露 `code-server` 应用入口，默认打开 `/home/coder`。
- 工作区 Pod 和自定义镜像构建 Job 默认禁用 ServiceAccount token 自动挂载。
- 使用 Pod anti-affinity 尽量将工作区 Pod 分散到不同节点。

## 前置条件

- Coder 已部署完成。
- `namespace` 指定的 Kubernetes namespace 已提前创建。
- Coder 有权限在该 namespace 中创建 PVC、Deployment、Pod 等资源。
- 目标 namespace 中存在 `workspace_image_registry_secret_name` 指向的 docker registry Secret。
- 集群中存在管理员在 `storage_class_name` 模板变量中配置的 StorageClass。
- code-server mirror 已可用，并且 mirror 目录上存在 `last_version` property。
- 使用自定义 apt 包构建工作区镜像前，集群内 BuildKit 服务已可用。

## 模板变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `use_kubeconfig` | `false` | 是否使用 base64 编码的 kubeconfig 连接其它 Kubernetes 集群。默认 `false` 使用 Coder 默认安装所在集群。 |
| `namespace` | `coder` | 工作区资源所在 namespace。默认安装所在本地集群只能使用 `coder`；选择其它集群时可自定义，且必须提前存在。 |
| `kubeconfig` | 空 | `use_kubeconfig=true` 时使用的 base64 编码 kubeconfig，支持 token 或 client certificate 凭据。 |
| `code_server_mirror_url` | `__CODE_SERVER_MIRROR_URL__` | 用于下载 code-server release 包的 mirror 地址。 |
| `storage_class_name` | `__STORAGE_CLASS_NAME__` | 管理员为工作区 home PVC 指定的 Kubernetes StorageClass。 |
| `workspace_image_registry_repo` | `__WORKSPACE_IMAGE_REGISTRY_REPO__` | 用户填写额外 apt 包时，生成镜像推送到的 Docker repository。 |
| `workspace_image_registry_secret_name` | `coder-workspace-image-registry` | BuildKit 推送镜像和工作区 Pod 拉取镜像时使用的 docker registry Secret。 |
| `workspace_image_buildctl_image` | `moby/buildkit:rootless` | 用于执行 `buildctl` 客户端的 BuildKit 镜像。 |
| `workspace_image_buildkit_addr` | `tcp://buildkit.buildkit.svc.cluster.local:1234` | 集群内 BuildKit 服务地址。 |

## 工作区参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `cpu` | `2` | 工作区容器 CPU limit，可选 2 / 4 / 8 cores。 |
| `memory` | `4` | 工作区容器内存 limit，可选 4 / 8 / 16 GB。 |
| `home_disk_size` | `100` | `/home/coder` PVC 容量，范围 50-200 GB。该参数不可变。 |
| `workspace_image` | `__WORKSPACE_IMAGE_BASIC__` | 工作区基础镜像，可选 Basic Ubuntu、C++ 开发环境或 Web 开发环境。 |
| `workspace_packages` | 空 | 可选的额外 apt 包，使用空格分隔；不为空时会触发 BuildKit 构建并自动使用生成镜像启动工作区。 |

## 使用方式

在 Coder 中创建或更新模板时，模板目录选择本目录：

```text
app/coder/template/k8s
```

导入模板后，默认使用 Coder 默认安装所在的本地 Kubernetes 集群，工作区 namespace 固定为 `coder`：

```hcl
use_kubeconfig = false
namespace      = "coder"
```

如果要把工作区创建到其它 Kubernetes 集群，则将 `use_kubeconfig` 设置为 `true`，在 `kubeconfig` 中粘贴目标集群 kubeconfig 的 base64 编码，并按需自定义 `namespace`：

```hcl
use_kubeconfig = true
namespace      = "workspace"
kubeconfig     = "<base64-kubeconfig>"
```

可以使用 helper 脚本输出目标集群的 base64 kubeconfig，也可以手动执行：

```bash
base64 kubeconfig.yaml | tr -d '\r\n'
```

## code-server mirror

`main.tf` 会在 Coder Agent 的启动脚本中执行：

```sh
CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL:-<code_server_mirror_url>}" \
AI_CONNECTOR_TOKEN="${AI_CONNECTOR_TOKEN:-<ai_connector_token>}" \
  /tmp/workspace-init.sh
```

`workspace-init.sh` 仅支持 Debian-like Linux，并只安装 mirror 中的 standalone 包。脚本会从 mirror 读取 `last_version` property，如果相同版本已经安装则跳过下载和解压，只补齐软链；否则下载对应的：

```text
code-server-<version>-linux-amd64.tar.gz
```

脚本通过环境变量配置，默认值如下：

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `CODE_SERVER_MIRROR_URL` | `__CODE_SERVER_MIRROR_URL__` | code-server 下载 mirror 地址。 |
| `CODE_SERVER_PREFIX_DIR` | `$HOME/.local` | code-server 安装目录。 |
| `AI_CONNECTOR_TOKEN` | 空 | 非空时在首次启动写入 AI 工具配置；为空则跳过初始化。 |

## 自定义 apt 包镜像构建

用户在创建 workspace 时如果填写 `workspace_packages`，模板会：

1. 使用 `Dockerfile.custom` 和所选工作区镜像生成构建上下文 ConfigMap。
2. 创建 BuildKit `buildctl` Job，连接 `workspace_image_buildkit_addr` 指向的集群内 BuildKit 服务，安装用户填写的 apt 包。
3. 将镜像推送到 `workspace_image_registry_repo`，tag 由 workspace id、所选镜像和包列表计算得到。
4. workspace Deployment 等待构建完成后自动使用生成镜像启动。

## 注意事项

- `home_disk_size` 会影响 PVC 大小，创建后不建议修改。
- 模板默认使用 `com-block-ssd` StorageClass，管理员可通过 `storage_class_name` 模板变量覆盖。
- 工作区镜像必须是 Debian-like 镜像，否则 code-server 安装脚本和 apt 包构建流程会失败。
- `workspace-init.sh` 当前只支持从包含 `/artifactory/` 的 mirror URL 读取版本信息。
