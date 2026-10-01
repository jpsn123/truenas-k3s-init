# 部署脚本与公共库

此目录分成两个独立层次，不提供全量加载入口：

- [lib/](lib/README.md)：可跨项目分发的 Bash 能力模块，不依赖 parameter.sh、仓库路径或固定缓存目录。
- [deploy/](deploy/)：Jutze 部署项目的路径、安装模式、values 输出、镜像检查与节点操作规则。

应用特有策略仍放在应用目录，例如 mirror-jobs 的版本保留与发布属性属于 [mirror.sh](../app/mirror-jobs/mirror.sh)，不属于 JFrog 通用 API。

Ceph pool 管理属于本仓库的 Ceph 部署逻辑，放在 [ceph/pool.sh](../ceph/pool.sh)，供主/备集群脚本显式加载，不作为公共库分发。其接口为 `ceph_ensure_pool NAME PG PGP TYPE CRUSH APPLICATION MIN_PG SIZE_OR_OVERWRITES [EC_PROFILE]`，依赖 ceph 和 jq；创建或配置 pool 时校验已有资源，不删除重建不兼容资源。

## 入口模式

```bash
#!/bin/bash
set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"
```

按入口层级调整 paths.sh 路径，只加载实际调用的模块。Ceph 入口加载 ceph/parameter.sh；库不替调用者选择参数文件。入口可以改变自己的 cwd、设置 `set -e` 和清理 trap，库不得接管这些行为。

## 项目模块

| 模块 | API / 约定 |
|---|---|
| paths.sh | 只读 `DEPLOY_ROOT`、`DEPLOY_LIB_DIR`；不创建目录或自动初始化环境 |
| install-mode.sh | `deploy_validate_mode MODE [COMPONENT...]`；`deploy_mode_enabled MODE COMPONENT` |
| values.sh | `deploy_render_values FILE...`，输出到各文件旁的 `temp/<basename>`；不输出结果到 stdout |
| images.sh | `deploy_image_pull IMAGE [USERNAME] [PASSWORD]`；通过本机 `k3s crictl pull` 检查镜像可拉取性，返回拉取结果 |
| nodes.sh | `deploy_nodes_local_ip NODE_LIST`；`deploy_nodes_run NODE_LIST COMMAND [INCLUDE_LOCAL]`；`deploy_nodes_copy NODE_LIST SOURCE [DEST]` |

节点列表是空白分隔的 IP 字符串，可用 `"${NODE_IP_LIST[*]}"` 传入。本项目以 root SSH 到节点，公共 remote 模块的用户、主机、路径则都是显式参数。节点操作日志不包含完整命令，以免其中的 token 或密码泄漏。

values 渲染只替换 `${UPPER_CASE}` 形式，已定义空值替换为空，未定义变量保留。模板可能包含容器启动时才能解析的变量，因此“是否允许未解析占位符”由业务入口决定。模板替换是文本操作，不自动对 YAML 标量做转义；值包含 YAML 特殊字符时，模板必须选用合适的标量样式。

## Helm 与构建流程

```bash
if [ "$INSTALL_MODE" != reinstall ]; then
    VERSION_PAIR=$(helm_chart_versions repo https://charts.example.com app "${APP_VERSION:-}")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
fi
helm_ensure_chart repo https://charts.example.com app temp "${CHART_VERSION:-}"
deploy_render_values values-app.yaml
helm upgrade --install -n "$NS" app temp/app -f temp/values-app.yaml --wait --timeout 600s
```

命令替换先赋值再 `read`，避免 `read <<<"$(failed_command)"` 掩盖版本查询失败。不指定 chart 版本时复用缓存，缺失再拉最新；指定时校验缓存版本。缓存是调用者的路径，不在库中固定。

显式加载 `scripts/deploy/images.sh` 后，使用 `deploy_image_pull` 通过本机 K3s 运行时实际拉取镜像；传入用户名时使用提供的凭据。镜像可拉取时跳过构建；确实要构建时显式调用 `buildkit_ensure_client /usr/local/bin`，再调用 `buildkit_build`。公共构建函数不自行安装系统工具。

## 分发到其他项目或运行环境

- 其他仓库可固定版本引入整个 lib 目录，只 source 所需模块；无需 deploy 目录。
- 容器、ConfigMap、生成的模板必须携带直接与传递依赖，保持模块相对位置。
- mirror-jobs 镜像携带日志/JFrog 库和 mirror 业务模块；不携带项目参数或 Docker 认证目录。
- Fortigate ConfigMap 同时携带同步脚本与日志库。
- Coder 的生成版 helper.sh 是单文件分发的例外：只内置自身需要的辅助函数，不依赖本仓库模块。
- 不运行时下载执行库，不依赖开发机上的绝对仓库路径，不手工复制函数形成第二套实现。

## 验证

修改后对维护的 Bash 文件运行 `bash -n`，并检查渲染后的 YAML 与未解析占位符。不得为验证自动运行真实镜像构建推送、安装或集群任务。
