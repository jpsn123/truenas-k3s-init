# Mirror Jobs

将上游制品同步到 JFrog mirror 的通用定时任务集合，部署在独立的 `mirror-jobs` namespace。每个任务是一个自包含子目录，`install.sh` 遍历 `*/values-job.yaml` 自动发现并部署，新增任务不需要修改安装脚本。

## 目录结构

| 路径 | 说明 |
|---|---|
| `install.sh` | 通用安装入口：读取配置、复用或构建镜像、部署 CronJob 并触发初始运行。 |
| `mirror.sh` | 任务共享的业务策略：配置校验、发布属性布局、版本保留与清理编排；构建时随镜像分发。 |
| `<name>/values-job.yaml` | 该任务的 CronJob 清单及全部配置。 |
| `<name>/Dockerfile` | 任务镜像构建文件，基础镜像来自清单 annotation。 |
| `<name>/sync.sh` | 任务同步入口，随镜像发布；拥有自己的工作目录和 EXIT trap。 |
| `gitlens/gitlens-patch.py` | GitLens 补丁脚本，仅 gitlens 任务使用。 |

当前任务：`code-server`（CronJob `mirror-code-server`）、`gitlens`（CronJob `mirror-gitlens`）、`openclash`（CronJob `mirror-openclash`）和 `openclash-core`（CronJob `mirror-openclash-core`）。

## 运行时布局

镜像内所有脚本位于 `/opt/mirror/`，与安装脚本的构建上下文一致：

```text
/opt/mirror/
├── sync.sh            # 入口：source lib 与 mirror.sh，自建 WORK_DIR 和 trap
├── mirror.sh          # 业务策略（属性布局、版本保留）
├── gitlens-patch.py   # 仅 gitlens
└── lib/
    ├── liblog.sh      # 复制自仓库 scripts/lib/
    └── libjfrog.sh    # 复制自仓库 scripts/lib/
```

`sync.sh` 通过自身位置（`BASH_SOURCE`）source `lib/liblog.sh`、`lib/libjfrog.sh` 和 `mirror.sh`，不依赖仓库路径。JFrog 通用 API（`scripts/lib/libjfrog.sh`）只接收显式参数：endpoint（含 `/artifactory`）、token、仓库相对路径、操作参数和可选超时；`mirror.sh` 的策略函数同样逐参传入 endpoint/token/目录/超时，不存在共享的全局配置变量。

## 任务清单约定

`values-job.yaml` 就是该任务的完整 CronJob 清单，不引入额外配置文件。清单声明：

- 资源名（`mirror-<name>`）、`schedule`/`timeZone`、资源限制、运行超时、重试与历史保留、TTL；`concurrencyPolicy: Forbid`，非 root、只读根文件系统、禁用 ServiceAccount token。
- 镜像：`${JFROG_REGISTRY}/jutze/mirror-<name>:<tag>`，各任务独立维护 tag。
- annotation `mirror-jobs/base-image`（当前 `alpine:3.22`）：安装脚本读取后作为 `BASE_IMAGE` 构建参数传入 Dockerfile。
- 公共 Secret `mirror-jobs-jfrog` 通过 `envFrom` 注入公共环境变量；不创建或引用镜像拉取 Secret，节点需能通过已有 registry 配置或匿名方式拉取任务镜像。
- 清单中 `suspend: true` 表示任务保持暂停，安装脚本会跳过其初始运行。

安装脚本会校验清单契约：唯一 CronJob/主容器、annotation 与超时存在、无未替换占位符、镜像位于配置的 registry 下。

### 公共环境变量（Secret `mirror-jobs-jfrog`）

| 变量 | 说明 |
|---|---|
| `JFROG_URL` | JFrog 基础地址，如 `https://bin.${DOMAIN}`，输入时无需 `/artifactory` 后缀。 |
| `JFROG_ARTIFACTORY_URL` | 安装脚本由 `JFROG_URL` 自动追加 `/artifactory` 生成，供同步任务使用；兼容读取旧 Secret 中的地址。 |
| `JFROG_REGISTRY` | Docker registry 地址，镜像构建推送与拉取使用。 |
| `JFROG_USERNAME` / `JFROG_TOKEN` | 认证凭据，同一 token 同时用于镜像推送和制品上传。 |
| `BUILDKIT_ADDR` | BuildKit 服务地址，默认 `tcp://buildkit.${DOMAIN}:1234`。 |

### 任务环境变量

| 变量 | 说明 |
|---|---|
| `MIRROR_PATH` | JFrog 内相对 mirror 路径，默认 `general/mirrors/<任务名>`。 |
| `KEEP_VERSIONS` | 稳定版制品保留版本数，默认 3；openclash 对 ipk/apk 分别保留，openclash-core 不使用此配置。 |
| `REQUEST_TIMEOUT` | 单个请求超时秒数，默认 300。 |
| `UPSTREAM_URL` / `CODE_SERVER_OS` / `CODE_SERVER_ARCH` | 仅 code-server：上游 release 地址与目标 OS/架构。 |
| `RELEASE_API` / `PUBLISHER` / `MAX_DOWNLOAD` / `MAX_UNPACKED` | 仅 gitlens：上游发布 API、发布者 ID（默认 `jutze`）、下载与解包大小上限（字节，默认 200 MiB / 512 MiB）。 |
| `RELEASE_API` | openclash：GitHub 最新稳定版 API，默认 `https://api.github.com/repos/vernesong/OpenClash/releases/latest`。 |
| `UPSTREAM_URL` / `CORE_GROUP` | openclash-core：上游仓库，默认 `https://github.com/vernesong/OpenClash`；同步 `core` 分支下的分组，默认 `master`，可改为 `dev`。 |

## 同步行为

code-server、gitlens 和 openclash 使用稳定版制品编排：解析上游最新稳定版 → 检查 mirror 是否已有该文件（存在 / 明确 404 / 其他错误三态区分，其他错误直接失败）→ 缺失时下载或补丁并上传（远端 checksum 一致时跳过传输，元数据查询失败不写远端）→ 发布属性 → 确认远端列表包含当前文件后才清理旧版本。

### code-server

- 查询上游最新稳定版；mirror 已有同版本 tarball 时跳过下载，否则下载上传。
- 文件名保持 `code-server-<version>-<os>-<arch>.tar.gz`，目录属性 `last_version`/`last_checked_at` 与制品属性不变，现有 Coder workspace 消费端无需修改。
- 上传并写完属性后按 `KEEP_VERSIONS` 清理旧版本，只删除精确匹配的稳定版文件。

### gitlens

- 下载官方最新稳定版 VSIX，校验后仅调整 Commit Graph 的账号/欢迎入口，保留 Pro access 检查、原作者及许可证信息，输出 `<publisher>.gitlens-<version>.vsix`。
- 补丁后执行 Node 语法检查与 ZIP 回读校验；验证失败或上游结构变化时直接失败，不发布、不更新版本属性、不清理旧版本。
- 远端只保存补丁 VSIX；原版、报告与解包临时文件不上传。
- 工作区当前仍使用官方 GitLens（模板固定 18.3.0）；补丁 VSIX 位于 `general/mirrors/gitlens/`，供手动下载安装，模板未接入。

### openclash

- 每 3 天 03:31（按 `${TIMEZONE}`，cron `31 3 */3 * *`）查询 OpenClash 最新稳定版，同步原版 `luci-app-openclash_<version>_all.ipk` 和 `luci-app-openclash-<version>.apk` 到 `general/mirrors/openclash/`。这两个安装包不区分架构，ARM64 也使用通用包。
- 两种格式从同一 release 文档解析，已有文件跳过下载；两者均上传成功后发布属性并分别按 `KEEP_VERSIONS` 保留版本。

### openclash-core

- 每 3 天 03:43（按 `${TIMEZONE}`，cron `43 3 */3 * *`）同步 OpenClash `core` 分支，默认读取 `master` 分组；只同步 `meta/clash-linux-arm64.tar.gz`，不再同步 Smart 或其他架构。Meta 内核是 ipk/apk 通用的 `.tar.gz`，不按安装包格式区分。任务总超时 3600 秒，临时空间 1 GiB。
- 制品直接放在 `general/mirrors/openclash-core/clash-linux-arm64.tar.gz`，不带分组或 `meta/` 子目录。`CORE_GROUP=dev` 只切换上游来源，仍覆盖同一目标文件；已有分组目录、Smart 及其他历史文件不会删除。
- 每轮固定同一上游 commit，精确读取 Meta ARM64 包和 `core_version` 的文件列表，拒绝截断、缺失或异常条目。先下载很小的 `core_version` 并验证大小及 Git blob SHA-1，读取第一行的 Meta 实际版本；该文件不上传，空版本或非法格式直接失败。
- 确认目标包存在后，优先读取制品 `openclash_core_version`，缺失时回退到目录同步元数据 `last_version`。版本相同就跳过内核包下载和上传；版本不同、目标包不存在或没有版本记录时才下载校验并上传。属性查询的权限、网络或非法响应直接失败，不当作无版本记录。
- 制品额外记录 `openclash_core_blob_sha`（上游内核包 Git blob SHA-1）；已有记录但 SHA 变化时，即使版本相同也重新下载校验，覆盖同版本重打包及切换分组的情况。历史制品尚无 SHA 时信任已有版本记录，跳过下载并补齐 SHA。需要上传时仍由 `jfrog_upload` 按远端 checksum 跳过相同内容，不套用数字版本清理。
- 同步成功（包括跳过下载）后在压缩包上写 `openclash_core_version` / `openclash_core_checked_at`，在目标根目录写 `last_version` / `last_checked_at`；版本值是 Meta 实际版本（例如 `alpha-ge183c58`），不再使用上游 commit SHA。
- 上传与属性发布不是原子操作；上传失败不会继续发布属性，属性发布失败时可重跑恢复。

两个 OpenClash 任务的 `*/3` 按月内日期运行（每月 1、4、7…日），跨月间隔不保证严格 72 小时。

### 版本保留与属性契约

以下版本保留规则适用于 code-server、gitlens 和 openclash；内核任务行为见上节。

- 当前版本永不清理（含上游回退），另保留数字版本最高的 `KEEP_VERSIONS-1` 个匹配文件；其他平台、预发布或不匹配文件一律不动。
- 制品属性 `<prefix>_version`/`<prefix>_checked_at`（前缀 `code_server`/`gitlens`/`openclash`），目录属性 `last_version`/`last_checked_at`。
- 上传、属性发布全部成功且远端列表确认包含当前文件后才允许删除；任一步失败都不会进入清理。

## JFrog 前提

- token 同时用于镜像和制品：对 Docker 仓库可推送/拉取 `jutze/mirror-*`，对制品仓库（默认 `general`）有 read/deploy/delete/annotate 权限（清理旧版本需要 delete）。
- openclash-core 会覆盖同名内核，其目标路径还需允许 redeploy/overwrite，不能配置为禁止覆盖已有制品。
- 凭据只保存在 Secret 中，不写入 YAML、构建参数或日志。
- 现有 Coder workspace 匿名下载 mirror 制品，mirror 路径需保持匿名只读。

## 安装

先编辑仓库根目录 `parameter.sh`（域名、时区等）。安装主机需要 Bash、kubectl、jq、k3s 和 flock；集群与远程 BuildKit 服务、JFrog 的 Docker／通用制品仓库应已准备好，本脚本不创建这些服务或仓库。

```bash
bash app/mirror-jobs/install.sh            # 安装 / 更新
bash app/mirror-jobs/install.sh reinstall  # 同一流程，重新遍历执行
```

两种模式执行同一循环：

1. 读取 Secret `mirror-jobs-jfrog`；缺失时提示 Artifactory URL、Docker registry、用户名/token、BuildKit 地址并保存，后续运行复用。
2. 遍历 `*/values-job.yaml`，渲染并校验清单契约。
3. 先尝试拉取清单声明的镜像，已存在则跳过构建；拉取失败才用 BuildKit 构建推送。构建上下文包含任务目录内容和 `mirror.sh`、`lib/liblog.sh`、`lib/libjfrog.sh`（复制自 `scripts/lib/`），不含仓库其他文件、参数或认证文件。
4. 部署 CronJob：先暂停调度并等待已有 Job 结束，应用清单后触发一次初始 Job（`mirror-<name>-initial-*`）并等待完成，成功后恢复调度。
5. 初始 Job 失败时 CronJob 保持暂停状态，按提示查看日志，排查后重新执行 `install.sh`。

同一工作副本的安装使用 flock 防止并发；不要从不同机器或不同工作副本同时部署指向同一 mirror 路径的任务。

### 镜像 tag 规则

镜像 tag 声明在各任务清单中。修改 `sync.sh`、`Dockerfile`、补丁脚本、共享 `mirror.sh`、`scripts/lib/libjfrog.sh`/`liblog.sh` 或基础镜像后必须提升相关任务的 tag：安装脚本只在镜像拉取失败时才构建，同 tag 已存在不会重建。仅修改 schedule、环境变量、保留数量、publisher 等清单配置不需要重建镜像。

## 手动运行

`concurrencyPolicy: Forbid` 只约束 CronJob 控制器创建的 Job，不覆盖 `--from=cronjob` 手动创建的 Job。手动执行前先暂停调度并等待运行中的 Job 结束：

```bash
kubectl -n mirror-jobs patch cronjob mirror-code-server -p '{"spec":{"suspend":true}}'
kubectl -n mirror-jobs get jobs   # 确认无运行中的 Job
JOB="mirror-code-server-manual-$(date +%s)"
kubectl -n mirror-jobs create job --from=cronjob/mirror-code-server "$JOB"
kubectl -n mirror-jobs wait --for=condition=complete "job/$JOB" --timeout=1860s && \
  kubectl -n mirror-jobs patch cronjob mirror-code-server -p '{"spec":{"suspend":false}}'
kubectl -n mirror-jobs logs "job/$JOB"
```

## 从 app/coder 迁移

旧同步任务 `coder/code-server-jfrog-sync` 已并入本应用，按以下顺序切换：

1. 安装新应用前，暂停旧 CronJob 并等待运行中的旧 Job 结束：

   ```bash
   kubectl -n coder patch cronjob code-server-jfrog-sync -p '{"spec":{"suspend":true}}'
   kubectl -n coder get jobs   # 等待运行中的 Job 结束
   ```

2. 确认任务清单 `MIRROR_PATH` 与旧任务一致（默认 `general/mirrors/code-server`），执行 `bash app/mirror-jobs/install.sh` 并确认初始 Job 成功。
3. 验证成功后手动删除旧资源；Secret `coder-code-server-jfrog` 保留，Coder 消费端不变：

   ```bash
   kubectl -n coder delete cronjob code-server-jfrog-sync
   kubectl -n coder delete configmap coder-code-server-jfrog-sync
   ```

新安装脚本不自动操作旧资源，迁移由上述手动步骤完成。

## 新增任务

1. 新建 `app/mirror-jobs/<name>/`，放入 `Dockerfile`、`values-job.yaml`、`sync.sh`（及所需辅助脚本）。
2. 按上文约定编写清单：镜像、`mirror-jobs/base-image` annotation、公共 envFrom、任务环境变量。
3. `sync.sh` 位于镜像 `/opt/mirror/`，入口为 `bash /opt/mirror/sync.sh`。安装脚本构建时会把 `mirror.sh` 和 `lib/{liblog.sh,libjfrog.sh}`（复制自仓库 `scripts/lib/`）一并暂存进构建上下文，`sync.sh` 用 `BASH_SOURCE` 相对自身 source 它们；入口自己创建工作目录并设置清理 trap，JFrog 调用使用 `mirror.sh` 的策略函数或 `libjfrog.sh` 的显式参数 API。
4. 重新执行 `install.sh` 即可，无需修改安装脚本。

## 故障排查

- 初始 Job 失败：CronJob 保持 `suspend: true`，通过 `kubectl -n mirror-jobs describe job` 和对应 Job 的 `logs` 定位原因，修复后重跑 `install.sh`。
- 401/403 是认证或权限问题，404 才表示尚未上传；网络、认证和元数据错误不会被当作已同步，也不会触发清理。
- 清理只按精确文件名匹配当前 publisher 或 OS/arch 的稳定版文件，不会递归删除目录；当前 `last_version` 对应文件始终保留，其余名额保留数字版本最高的文件。
- 补丁逻辑更新不会覆盖已存在的同版本 VSIX；若需重新发布同版本，先暂停任务、备份旧文件，再由管理员删除对应 VSIX 后重新运行。

## 验证

修改脚本后运行 `bash -n`，检查渲染后的 CronJob YAML、镜像构建上下文和 JFrog 请求顺序。不要自动运行真实 Docker 构建、集群任务或制品删除。部署后还应确认 Job 成功、JFrog 文件及属性、重复执行无重复上传，以及版本清理符合配置。
