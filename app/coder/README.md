# Coder

该目录用于部署 Coder 服务端及其配套资源，包括 PostgreSQL、Ingress TLS、OIDC 配置、code-server mirror 同步任务，以及 Kubernetes workspace template 的辅助文件。

## 文件说明

| 路径 | 说明 |
|---|---|
| `install.sh` | 部署 Coder 应用的入口脚本。 |
| `values-coder.yaml` | Coder Helm chart values，包含访问域名、OIDC、数据库连接等配置。 |
| `values-postgresql.yaml` | Bitnami PostgreSQL values。 |
| `values-tls.yaml` | `dev.${DOMAIN}` 和 `*.dev.${DOMAIN}` 的 cert-manager Certificate。 |
| `values-sync-job.yaml` | 定时同步 code-server release 到 JFrog mirror 的 CronJob。 |
| `code-server-jfrog-sync.sh` | CronJob 使用的 code-server release 同步脚本。 |
| `patch.py` / `public.key` | Coder 服务端运行时补丁文件，通过 ConfigMap 挂载到 Pod。 |
| `workspace-image/` | Basic / C++ / Web 工作区基础镜像构建文件。 |
| `template/k8s/` | Coder Kubernetes workspace template。 |

## 安装

安装前先按仓库约定编辑根目录 `parameter.sh`。

```bash
bash app/coder/install.sh
```

安装脚本会：

1. 创建 `coder` namespace。
2. 创建或复用 PostgreSQL 密码 Secret。
3. 创建或复用 Coder OIDC Secret / ConfigMap。
4. 创建或复用 code-server JFrog mirror 配置。
5. 部署 code-server mirror 同步 CronJob，并触发一次临时 Job。
6. 按需创建 Terraform provider mirror ConfigMap。
7. 部署 PostgreSQL。
8. 创建 Coder 数据库连接 Secret。
9. 创建 TLS Certificate 并部署 Coder。

安装成功后访问：

```text
https://dev.${DOMAIN}
```

## Coder 服务端镜像和版本

Coder 服务端不再维护本地自定义镜像目录。`install.sh` 会从 `https://helm.coder.com/v2` 查询默认 chart version 和 appVersion，允许安装时确认或覆盖，并把最终版本写入 `coder-install-version` ConfigMap。`reinstall` 模式会复用该 ConfigMap 中保存的版本。

服务端镜像使用上游 `ghcr.io/coder/coder:v${CODER_APP_VERSION}`，无需提前手工构建。运行时定制通过 `patch.py` 和 `public.key` 生成 `coder-patch` ConfigMap 后挂载到 Pod。

## 工作区基础镜像

基础工作区镜像位于 `workspace-image/`：

| 文件 | 说明 |
|---|---|
| `Dockerfile.basic` | 基础 Ubuntu 工作区镜像。 |
| `Dockerfile.cpp` | C++ 开发环境镜像。 |
| `Dockerfile.web` | Web 开发环境镜像。 |
| `build.sh` | 按 basic、cpp、web 顺序构建并推送镜像。 |

构建示例：

```bash
cd app/coder/workspace-image
bash build.sh
```

## Workspace registry Secret

Workspace image registry repository、Secret 名称、BuildKit 镜像和 BuildKit 地址都由 `template/k8s/main.tf` 中的模板变量提供默认值；需要调整时，在 Coder 模板变量中修改即可，`install.sh` 不再提示输入这些值。

如果使用 `workspace_packages` 构建自定义工作区镜像，目标 namespace 中仍需要存在 `workspace_image_registry_secret_name` 指向的 docker registry Secret，供 BuildKit Job 推送镜像和 workspace Pod 拉取镜像。

## code-server mirror

`code-server-jfrog-sync.sh` 会：

1. 查询 GitHub 上最新 code-server release。
2. 检查 JFrog mirror 中是否已有对应 tarball。
3. 不存在时下载并上传到 JFrog。
4. 写入 `last_version` 和检查时间属性。
5. 只保留最近 `CODE_SERVER_KEEP_VERSIONS` 个版本，默认 6 个。

CronJob 配置在 `values-sync-job.yaml`，默认每天 03:00 执行一次。镜像使用自带 `curl` 和 `jq` 的 `badouralix/curl-jq:alpine`。

## Terraform provider mirror

安装时可以选择是否启用 Terraform provider mirror。脚本会无条件创建 `coder-terraformrc` ConfigMap：启用时写入 network_mirror 配置，不启用时写入空文件（等价于 Terraform 默认行为），通过 `values-coder.yaml` 挂载到 Coder Pod 的 `/home/coder/.terraformrc`。

## Workspace template

Kubernetes workspace template 位于 `template/k8s/`。模板本身的变量、工作区参数和运行逻辑见：

```text
app/coder/template/k8s/README.md
```

## 注意事项

- 运行 `install.sh` 前必须先编辑根目录 `parameter.sh`。
- `values-*.yaml` 中的 `${VAR}` 会由 `render_values_file_to_temp` 渲染到 `temp/` 后再使用。
- 如果更换 workspace 镜像 registry，需要同步更新 `workspace-image/build.sh` 和 `template/k8s/main.tf` 中的默认镜像地址或模板变量。
- `temp/` 是运行时目录，已被 git 忽略。
