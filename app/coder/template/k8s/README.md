# Coder Kubernetes Workspace Template

该目录是 Coder 的 Kubernetes 工作区模板，用于在集群中为每个用户工作区创建一个独立的 Pod，并在 Pod 内启动 code-server。

## 文件说明

| 文件 | 说明 |
|---|---|
| `main.tf` | Coder 模板的 Terraform 配置，定义工作区参数、PVC、Deployment、Coder Agent 和 code-server 应用入口。 |
| `workspace-init.sh` | 工作区初始化脚本。模板启动时会把该脚本写入 Debian-like 工作区 Pod，从 JFrog mirror 下载安装 code-server standalone 包、初始化默认设置和扩展，并创建 `$HOME/.local/bin/claude` 启动器，在执行时动态定位 Claude Code 插件内置 CLI。 |
| `settings.json` | 新工作区首次初始化时写入 code-server `User/settings.json` 的默认用户设置；已存在的用户设置不会被覆盖。 |
| `Dockerfile` | 内置工作区镜像 Dockerfile：单一 Ubuntu 26.04 基础镜像，`INSTALL_CPP`、`INSTALL_WEB` 构建参数控制是否安装 C++ / Web 工具链。 |
| `workspace-image.version` | 内置工作区镜像版本号，初始 `1.0.0`；修改内置 Dockerfile 后必须递增。 |

## 主要能力

- 通过 Coder 参数选择 CPU、内存和 home 目录磁盘大小。
- 创建工作区时通过 CPP / WEB 复选框选择 C++ 和 Web 工具链，两个选择组合出 basic / cpp / web / all 四种共享镜像 variant。
- 可填写自定义 Dockerfile 指令；填写后会先在集群内构建个人镜像、推送到镜像仓库，再用该镜像启动工作区。
- GitLens 使用 mirror-jobs 同步的 `__BRAND_PREFIX_LOWER__.gitlens`；工作区每次启动检查 mirror 最新版本，版本不同或未安装时下载安装，并从市场更新检查中排除，其他扩展仍可正常自动更新。
- 为每个工作区创建独立 PVC，挂载到 `/home/coder`。
- 工作区启动时将 code-server 安装到持久化的 `/home/coder/.local`，并以 `--auth none --port 13337` 启动。
- 在 Coder 中通过子域名暴露 `code-server` 应用入口，默认打开 `/home/coder`；保留 `share = "owner"`，允许通过 Workspace Sharing 获得 `use/admin` 权限的用户访问，不向所有登录用户或匿名用户开放。
- 工作区 Pod 和自定义镜像构建 Job 默认禁用 ServiceAccount token 自动挂载。
- 使用 Pod anti-affinity 尽量将工作区 Pod 分散到不同节点。

## 前置条件

- Coder 已部署完成，并配置 `CODER_WILDCARD_ACCESS_URL`、通配符 Ingress 和 TLS。本仓库默认使用 `*.dev.${DOMAIN}`，需确保该通配符 DNS 解析到 Ingress 入口；证书自动签发不会创建应用访问所需的 DNS 记录。
- `namespace` 指定的 Kubernetes namespace 已提前创建。
- Coder 有权限在该 namespace 中创建 PVC、Deployment、Pod 等资源。
- 目标 namespace 中存在 `workspace_image_registry_secret_name` 指向的 `kubernetes.io/dockerconfigjson` 类型 Secret（本地默认集群即 `coder` namespace），可由 `result/k8s/helper.sh` 创建。
- 集群中存在管理员在 `storage_class_name` 模板变量中配置的 StorageClass。
- code-server 和 GitLens mirror 已可用，允许工作区匿名只读访问，并且各 mirror 目录上存在 `last_version` property。
- 首次启动某个新镜像 tag（版本号、variant 或自定义指令变化）前，集群内 BuildKit 服务已可用。

## 模板变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `use_kubeconfig` | `false` | 是否使用 base64 编码的 kubeconfig 连接其它 Kubernetes 集群。默认 `false` 使用 Coder 默认安装所在集群。 |
| `namespace` | `coder` | 工作区资源所在 namespace。默认安装所在本地集群只能使用 `coder`；选择其它集群时可自定义，且必须提前存在。 |
| `kubeconfig` | 空 | `use_kubeconfig=true` 时使用的 base64 编码 kubeconfig，支持 token 或 client certificate 凭据。 |
| `code_server_mirror_url` | `__CODE_SERVER_MIRROR_URL__` | 用于下载 code-server release 包的 mirror 地址。 |
| `gitlens_mirror_url` | `__GITLENS_MIRROR_URL__` | 用于检查版本和下载 `__BRAND_PREFIX_LOWER__.gitlens` VSIX 的 mirror 地址。 |
| `storage_class_name` | `__STORAGE_CLASS_NAME__` | 管理员为工作区 home PVC 指定的 Kubernetes StorageClass。 |
| `workspace_image_registry_repo` | `__WORKSPACE_IMAGE_REGISTRY_REPO__` | 工作区镜像构建后推送的 Docker repository。 |
| `workspace_image_registry_secret_name` | `coder-workspace-image-registry` | BuildKit 推送镜像和工作区 Pod 拉取镜像时使用的 docker registry Secret。 |
| `workspace_image_buildctl_image` | `moby/buildkit:rootless` | 用于执行 `buildctl` 客户端的 BuildKit 镜像。 |
| `workspace_image_buildkit_addr` | `tcp://buildkit.buildkit.svc.cluster.local:1234` | 集群内 BuildKit 服务地址。 |
| `workspace_image_registry_check_image` | `quay.io/skopeo/stable:latest` | 检查目标镜像 tag 是否已存在时使用的 skopeo 镜像。 |

## 工作区参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `cpu` | `2` | 工作区容器 CPU limit，可选 2 / 4 / 8 cores。 |
| `memory` | `4` | 工作区容器内存 limit，可选 4 / 8 / 16 GB。 |
| `home_disk_size` | `100` | `/home/coder` PVC 容量，范围 50-500 GB。该参数不可变。 |
| `workspace_enable_cpp` | `true` | 是否安装 C++ 开发工具（Clang、LLVM、Ninja、ccache 等）。bool 复选框，创建后仍可修改。 |
| `workspace_enable_web` | `true` | 是否安装 Web 开发工具（Node.js、npm、Go）。bool 复选框，创建后仍可修改。 |
| `workspace_custom_dockerfile` | 空 | 可选的自定义 Dockerfile 指令，原样追加到内置 Dockerfile 最后；留空或仅有注释时使用共享镜像。 |

## 使用方式

先运行上一级的 `render.sh` 填充默认配置：脚本只提示 mirror、StorageClass 和 workspace image registry repository，不再提示镜像 tag，并把 `Dockerfile` 和 `workspace-image.version` 随其余模板文件一起输出到 `result/k8s/`。

在 Coder 中创建或更新模板时，模板目录选择渲染后的结果：

```text
app/coder/template/result/k8s
```

已有工作区需更新到新模板版本并重新构建，使 `code-server` 的子域名路由生效；仅重启旧模板版本的工作区不会应用此修改。更新后，分别使用所有者和已获 `use/admin` 权限的共享用户验证 code-server 访问，并确认未获授权的用户不能访问。

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

再使用生成的 `result/k8s/helper.sh` 输出目标集群的 base64 kubeconfig，helper 同时会创建 docker registry Secret。helper 可单文件复制到目标集群管理机运行，仅需 Bash、kubectl 和基础系统工具，不依赖本仓库、`scripts/`、`lib/` 或 jq。运行前需配置可管理目标 namespace 和 RBAC 的 kubeconfig；stdout 只输出 base64 kubeconfig，日志写 stderr。

已有 kubeconfig 时，也可以手动编码：

```bash
base64 kubeconfig.yaml | tr -d '\r\n'
```

## code-server mirror

`main.tf` 会把 `workspace-init.sh` 和 `settings.json` 分别写入工作区 Pod 的 `/tmp`，然后在 Coder Agent 的启动脚本中执行：

```sh
CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL:-<code_server_mirror_url>}" \
  GITLENS_MIRROR_URL="${GITLENS_MIRROR_URL:-<gitlens_mirror_url>}" \
  CODE_SERVER_DEFAULT_SETTINGS_FILE=/tmp/code-server-default-settings.json \
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
| `GITLENS_MIRROR_URL` | `__GITLENS_MIRROR_URL__` | GitLens mirror 地址，渲染时默认为 `https://bin.${DOMAIN}/artifactory/general/mirrors/gitlens`。 |
| `CODE_SERVER_PREFIX_DIR` | `$HOME/.local` | code-server 安装目录。 |
| `CODE_SERVER_DEFAULT_SETTINGS_FILE` | 无 | 首次初始化时复制到 code-server `User/settings.json` 的默认设置文件，由 `main.tf` 提供。 |

脚本不会生成 Claude Code 或 Codex 的认证文件；`settings.json` 中包含的扩展设置会作为新工作区的默认用户设置。

## GitLens mirror

扩展 ID 的品牌前缀由 `render.sh` 将中央配置 `BRAND_PREFIX` 转为全小写后填充，与 mirror-jobs 的 GitLens publisher 保持一致。切换品牌后需重新渲染并更新 Coder 模板。

每次工作区启动时，脚本读取 GitLens mirror 目录的 `last_version` 属性，与扩展 CLI 返回的已安装 `__BRAND_PREFIX_LOWER__.gitlens` 版本比较。版本相同则跳过下载安装；不同（包括 mirror 版本回退）或尚未安装时，下载 `__BRAND_PREFIX_LOWER__.gitlens-<version>.vsix` 并强制安装，完整下载的 VSIX 会缓存复用。

确认 mirror 版本已安装后，通过扩展 CLI 卸载旧的官方 `eamodio.gitlens`，避免两个 GitLens 同时启用。GitLens 继续标记为 resource/pinned，不参与市场自动更新。版本查询、下载或安装失败时会告警，不主动删除现有扩展，也不阻止工作区启动，下次启动再次检查。

## 工作区镜像构建

内置镜像由本目录的 `Dockerfile` 定义：单一 Ubuntu 26.04 基础镜像，`INSTALL_CPP`、`INSTALL_WEB` 构建参数分别来自 `workspace_enable_cpp`、`workspace_enable_web` 参数。两个复选框组合出 variant 和共享镜像 tag：

| CPP | WEB | variant | 共享镜像 tag |
|---|---|---|---|
| 否 | 否 | `basic` | `<version>-basic` |
| 是 | 否 | `cpp` | `<version>-cpp` |
| 否 | 是 | `web` | `<version>-web` |
| 是 | 是 | `all` | `<version>-all` |

`<version>` 来自 `workspace-image.version`，初始为 `1.0.0`（例如 `1.0.0-all`）。修改内置 Dockerfile 后必须递增该版本号，否则同名 tag 已存在时会跳过构建，工作区继续使用旧镜像。

`workspace_custom_dockerfile` 的内容会原样追加到内置 Dockerfile 的最后，不做任何改写；只有存在非注释的非空行时才构建个人镜像，tag 为：

```text
<version>-<variant>-<owner>-<workspace>-<hash>
```

其中 `<hash>` 是由 workspace id、镜像版本、variant 和完整 Dockerfile 内容计算的 12 位 SHA1，任何内容变化都会得到新 tag。

内置镜像的默认构建用户是 `coder`，安装系统包时需要先切换到 root，完成后切回 coder：

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends htop && rm -rf /var/lib/apt/lists/*
USER coder
```

构建上下文只包含渲染后的 Dockerfile，不包含本地项目文件。`/home/coder` 会被工作区持久卷覆盖，系统级配置应写入 `/etc` 或 `/usr/local`；不要在指令中填写密码、token 等敏感信息。

### 构建流程

每次工作区启动时模板都会创建 BuildKit Job，检查并按需构建该工作区选用的镜像：

1. init 容器使用 `workspace_image_registry_check_image` 镜像执行 `skopeo inspect` 检查目标 tag 是否已存在。
2. tag 已存在时跳过构建；返回明确的 manifest unknown / name unknown 时执行构建；其它错误（认证、网络等）直接令 Job 失败，不会静默重建或复用不确定的状态。
3. 需要构建时，`buildctl` 容器连接 `workspace_image_buildkit_addr` 指向的集群内 BuildKit 服务，以 `linux/amd64` 平台（与 Coder Agent 的 amd64 架构一致）构建，并推送到 `workspace_image_registry_repo`。
4. workspace Deployment 依赖该 Job，等待构建完成后才启动工作区 Pod。

### 从旧参数迁移

旧的 `workspace_image`、`workspace_packages`、`workspace_custom_run_script` 参数不会自动迁移到新参数：

- 原来在 `workspace_packages` 里填 apt 包名列表，现在需要写成完整的 Dockerfile 指令，例如 `RUN apt-get update && apt-get install -y --no-install-recommends htop`。
- 原来的自定义 shell 命令同样必须包在 `RUN` 中，或改用 `ENV` 等 Dockerfile 指令表达。
- 原来按 Basic / C++ / Web 三选一的 `workspace_image` 参数，改为 `workspace_enable_cpp` / `workspace_enable_web` 两个复选框。

## 注意事项

- `home_disk_size` 会影响 PVC 大小，创建后不建议修改。
- 模板默认使用 `com-block-ssd` StorageClass，管理员可通过 `storage_class_name` 模板变量覆盖。
- 内置镜像是 Ubuntu（Debian-like）；自定义指令中不要更改基础发行版，否则 code-server 安装脚本会失败。
- 旧版 `build-workspace-image.sh` 创建的同名 opaque registry Secret 与 docker-registry 类型不兼容；如果目标 namespace 中还存在，先备份内容再通过 helper.sh 或手动方式重建。
- `workspace-init.sh` 当前只支持从包含 `/artifactory/` 的 mirror URL 读取版本信息。
