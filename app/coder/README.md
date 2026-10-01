# Coder

该目录用于部署 Coder 服务端及其配套资源，包括 PostgreSQL、Ingress TLS、OIDC 配置、code-server mirror 地址 Secret，以及 Kubernetes workspace template 的辅助文件。

## 文件说明

| 路径 | 说明 |
|---|---|
| `install.sh` | 部署 Coder 应用的入口脚本。 |
| `values-coder.yaml` | Coder Helm chart values，包含访问域名、OIDC、数据库连接等配置。 |
| `values-postgresql.yaml` | Bitnami PostgreSQL values。 |
| `values-tls.yaml` | `dev.${DOMAIN}` 和 `*.dev.${DOMAIN}` 的 cert-manager Certificate。 |
| `patch.py` / `public.key` | Coder 服务端运行时补丁文件，通过 ConfigMap 挂载到 Pod。 |
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
4. 创建或复用 code-server JFrog mirror 地址 Secret。
5. 按需创建 Terraform provider mirror ConfigMap。
6. 部署 PostgreSQL。
7. 创建 Coder 数据库连接 Secret。
8. 创建 TLS Certificate 并部署 Coder。

安装成功后访问：

```text
https://dev.${DOMAIN}
```

## Coder 服务端镜像和版本

Coder 服务端不再维护本地自定义镜像目录。`install.sh` 会从 `https://helm.coder.com/v2` 查询默认 chart version 和 appVersion，允许安装时确认或覆盖，并把最终版本写入 `coder-install-version` ConfigMap。`reinstall` 模式会复用该 ConfigMap 中保存的版本。

服务端镜像使用上游 `ghcr.io/coder/coder:v${CODER_APP_VERSION}`，无需提前手工构建。运行时定制通过 `patch.py` 和 `public.key` 生成 `coder-patch` ConfigMap 后挂载到 Pod。

## 工作区镜像

本仓库不再维护 `workspace-image/` 目录和 `build-workspace-image.sh` 构建脚本。工作区镜像统一由 `template/k8s/Dockerfile` 定义：单一 Ubuntu 26.04 基础镜像，通过 `INSTALL_CPP`、`INSTALL_WEB` 构建参数决定是否安装 C++（Clang、LLVM、Ninja、ccache 等）和 Web（Node.js、npm、Go）工具链。

镜像不需要提前手工构建。工作区启动时由模板在集群内通过 BuildKit 按需构建并推送到 `workspace_image_registry_repo`：

- 共享镜像 tag：`<version>-basic` / `<version>-cpp` / `<version>-web` / `<version>-all`，由 CPP / WEB 两个复选框组合出的 variant 决定。
- 填写了自定义 Dockerfile 指令的工作区会构建个人镜像，tag 为 `<version>-<variant>-<owner>-<workspace>-<hash>`。

镜像版本记录在 `template/k8s/workspace-image.version`（初始 `1.0.0`）。修改内置 Dockerfile 后必须递增该版本，否则已存在的同名 tag 会被跳过构建，工作区继续使用旧镜像。

参数定义、构建流程和迁移说明见 `app/coder/template/k8s/README.md`。

## Workspace registry Secret

Workspace image registry repository、Secret 名称、BuildKit 镜像、BuildKit 地址和镜像检查镜像都由 `template/k8s/main.tf` 中的模板变量提供默认值；需要调整时，在 Coder 模板变量中修改即可，`install.sh` 不提示输入这些值。

现在所有工作区镜像都存放在私有仓库，目标 namespace 中必须始终存在 `workspace_image_registry_secret_name` 指向的 `kubernetes.io/dockerconfigjson` 类型 Secret，供 BuildKit Job 推送镜像和 workspace Pod 拉取镜像。该 Secret 由 `template/render.sh` 生成的 `result/k8s/helper.sh` 创建；使用其它集群时按 helper 输出的 kubeconfig 配置模板，本地默认集群不需要 kubeconfig 输出，但同样要在 `coder` namespace 中创建该 Secret。

旧版 `build-workspace-image.sh` 会用 `registry-url` / `registry-username` / `registry-token` key 创建同名 opaque Secret，与 docker-registry 类型不兼容。如果目标 namespace 中还存在这种旧 Secret，先备份内容，再通过 helper.sh 或手动 `kubectl create secret docker-registry` 有意识地重建或迁移。

## code-server mirror

mirror 内容同步任务已迁至独立应用 `app/mirror-jobs/`，本目录不再部署同步 CronJob，也不再要求输入 JFrog token。此处仅维护 Secret `coder-code-server-jfrog` 的 `mirror-url` 字段：`values-coder.yaml` 通过 `TF_VAR_code_server_mirror_url` 注入 Coder，供 workspace template 下载 code-server。

从旧版本迁移时，按 `app/mirror-jobs/README.md` 的迁移说明先暂停并下线旧的 `code-server-jfrog-sync` CronJob；Secret `coder-code-server-jfrog` 保留，消费端不变。

## Terraform provider mirror

安装时可以选择是否启用 Terraform provider mirror。脚本会无条件创建 `coder-terraformrc` ConfigMap：启用时写入 network_mirror 配置，不启用时写入空文件（等价于 Terraform 默认行为），通过 `values-coder.yaml` 挂载到 Coder Pod 的 `/home/coder/.terraformrc`。

## Workspace template

Kubernetes workspace template 位于 `template/k8s/`。模板本身的变量、工作区参数和运行逻辑见：

```text
app/coder/template/k8s/README.md
```

## 注意事项

- 运行 `install.sh` 前必须先编辑根目录 `parameter.sh`。
- `values-*.yaml` 中的 `${VAR}` 会由 `scripts/deploy/values.sh` 的 `deploy_render_values` 渲染到 `temp/` 后再使用。
- `template/render.sh` 生成的 `result/k8s/helper.sh` 是独立工具，可单文件复制到目标集群管理机运行，不依赖本仓库或 `lib/`。
- `template/render.sh` 只提示 mirror、StorageClass 和 workspace image registry repository，不再提示镜像 tag；渲染时会把 `template/k8s/` 下所有文件（含 `Dockerfile` 和 `workspace-image.version`）输出到 `result/k8s/`。
- 如果更换 workspace 镜像 registry，修改 Coder 模板的 `workspace_image_registry_repo` 变量，并更新目标 namespace 的 docker registry Secret；如果使用渲染默认值，先更新 `coder-template-render-config` ConfigMap 中缓存的 repository 再运行 `template/render.sh`。`install.sh` 无需改动。
- `temp/` 是运行时目录，已被 git 忽略。
