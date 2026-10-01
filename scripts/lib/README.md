# Bash 公共能力库

这些模块可整目录放入其他仓库或镜像，不依赖 Jutze 的 parameter.sh、命名规则或部署路径。只支持 Bash；Linux 系统操作依赖目标机器相应工具，不承诺 POSIX sh / macOS 兼容。

```bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/liblog.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/libjfrog.sh"
```

每个模块显式加载自己的直接依赖，重复 source 安全。需要使用某个模块的公开 API 时显式 source，不依赖偶然的间接导入。

## 契约

- 加载模块不联网、不安装工具、不创建目录、不改变 cwd、shell options、trap、umask。
- 日志写 stderr，结果写 stdout；调用者负责捕获结果和处理状态。
- 库函数使用 `return`，不退出宿主脚本。关键命令显式检查失败，不依赖调用者的 `set -e`。
- 外部命令仅在调用对应能力时需要。加载日志不要求 kubectl、Helm 或 BuildKit 已安装。
- 只有明确文档化的选项和加载标记是全局变量；内部变量局部化。`_` 前缀函数和模块内部变量不是公开 API。
- 文件与目录路径显式传入，不假定当前目录下有 temp。创建或更新系统资源需要由调用者提供权限。
- 临时文件在函数内清理，不占用调用者的 EXIT trap；入口负责自身跨步骤的工作目录。
- 不通过 eval 解析返回值、模板或凭据，不把凭据写入日志。含凭据的调用不要开启 shell xtrace。

## 模块与接口

下表列出公开调用形式；可选参数以方括号表示，详细返回码见函数注释。

### 日志、交互与密码

| 模块 | API |
|---|---|
| liblog.sh | `log_error/warn/info/trace/header/reminder TEXT` |
| libprompt.sh | `prompt_with_default REMINDER PROMPT [DEFAULT]`；`prompt_required REMINDER PROMPT [-s]`；`prompt_yes_no_with_default REMINDER PROMPT [DEFAULT]` |
| libpassword.sh | `password_derive_sha1 INPUT LENGTH`；`password_derive_sha256 INPUT LENGTH`；`password_derive_sha256_hex INPUT LENGTH`；`password_random LENGTH` |

日志使用 `LIBLOG_COLOR=auto|always|never`，默认 auto 仅在终端启用颜色。交互数据写 stdout；EOF 返回失败，不无限循环等待输入。密码模块依赖 sha1sum/sha256sum/base64；随机密码依赖 openssl。

确定性密码用于维持现有部署口令规则，**不是密码存储 KDF**。调用方必须自行拼好输入原文：

```bash
PASSWORD=$(password_derive_sha1 "$SEED@$NS@$SERVICE" 32)
```

sha1/sha256 的 base64 变体保持原有“十六进制摘要加换行 → base64 → 截取”顺序；hex 变体不经过 base64。不要为统一接口改变已部署密码的拼接规则。

### 模板

`template_render INPUT OUTPUT [--missing=keep|error]`

只替换 `${[A-Z_][A-Z0-9_]*}` 形式，从调用者 Bash 变量取值；定义为空与未定义不同。默认 keep 保留未定义的 token，error 模式报错；不执行表达式、命令替换或 eval。目标通过临时文件更新，失败不覆盖已有结果。不会替调用者做 YAML/JSON 转义。

### 远程与系统

| API | 说明 |
|---|---|
| `remote_run USER HOST COMMAND` | SSH 执行 Bash 命令；节点选择和本地执行属于项目层 |
| `remote_copy USER HOST SOURCE DEST` | 明确源、目标路径的 SCP |
| `os_load_kernel_modules CONF_PATH MODULE...` | 写 modules-load 配置并加载模块 |
| `os_apply_sysctl CONF_PATH KEY=VALUE...` | 幂等更新指定 sysctl 文件并应用 |

工具依赖：ssh/scp；系统模块使用 modprobe/sysctl。是否用 root、哪些节点包含本机不属于这些公共 API。

### Kubernetes

工具依赖：kubectl，读取使用 go-template。

```bash
kube_secret_get NS NAME KEY
kube_configmap_get NS NAME KEY
kube_secret_load NS NAME key=VARIABLE...
kube_configmap_load NS NAME key=VARIABLE...
kube_secret_apply_vars NS NAME key=VARIABLE...
kube_configmap_apply_vars NS NAME key=VARIABLE...
kube_apply_secret NS NAME [kubectl-create-secret-generic-args...]
kube_apply_configmap NS NAME [kubectl-create-configmap-args...]
kube_apply_registry_secret NS NAME SERVER USER PASSWORD
```

`key=VARIABLE` 的右侧是 Bash 变量名，不是 literal 值。模块内部保留的变量名前缀不可用作输出变量。读取 NotFound 或缺失 key 返回空值，权限、网络或其他 kubectl 错误返回非零。批量加载保留未匹配项已有值，不把空缺当成必须重设密码的信号。

写入采用 `kubectl create --dry-run=client` 生成权限受限的 manifest 后 apply，不先删除已有资源。默认使用 server-side apply/force-conflicts，维持本仓库资源管理方式；调用者应确认自己对这些字段的所有权。

### Helm、Registry、BuildKit

```bash
helm_chart_versions REPO URL CHART [APP_VERSION]
helm_ensure_chart REPO URL CHART CACHE_DIR [CHART_VERSION]
helm_chart_versions_local CHART_DIR

registry_host URL
registry_strip_host IMAGE
registry_latest_tag REPOSITORY [TAG_PATTERN] [USERNAME] [PASSWORD]
registry_write_auth CONFIG_DIR REGISTRY_HOST USERNAME PASSWORD

buildkit_ensure_client INSTALL_DIR [VERSION]
buildkit_build CONTEXT IMAGE BUILDKIT_ADDR DOCKER_CONFIG_DIR [BASE_IMAGE]
```

- Helm 模块依赖 helm、jq。版本函数返回 `chartVersion appVersion`；先捕获成功结果再 `read`。缓存位于 `CACHE_DIR/CHART`，不指定版本时可复用，指定版本时必须匹配。repo/OCI 获取分别调用 Helm 对应接口。
- Registry 标签查询依赖 curl/jq/sort，按版本顺序排序；没有默认 JFrog anonymous 账户，需要时由调用者显式提供。它不是覆盖所有 Registry OAuth 流程的 SDK。
- Docker 认证 JSON 安全编码并以受限权限写入，不递归删除整个 CONFIG_DIR；不使用该函数修改一份需要保留其他 registry 登录项的共享配置。
- `buildkit_ensure_client` 是显式的软件安装操作，需要安装目录权限；构建函数本身只调用 buildctl，不自行安装客户端。客户端安装使用 GitHub BuildKit release（Linux amd64/arm64）；可选 VERSION 只控制缺失时下载的版本，已有客户端直接复用。自定义 INSTALL_DIR 不在 PATH 时，调用者需自行加入 PATH 后再构建。镜像构建、推送是显式副作用。

### JFrog Artifactory

工具依赖：curl、jq、校验和与基础文件工具。

```bash
jfrog_stat ENDPOINT TOKEN PATH [TIMEOUT]
jfrog_list ENDPOINT TOKEN PATH [TIMEOUT]
jfrog_exists ENDPOINT TOKEN PATH [TIMEOUT]
jfrog_download ENDPOINT TOKEN PATH LOCAL_FILE [TIMEOUT]
jfrog_upload ENDPOINT TOKEN PATH LOCAL_FILE [TIMEOUT]
jfrog_download_dir ENDPOINT TOKEN REMOTE_DIR LOCAL_DIR [OPTIONS...]
jfrog_upload_dir ENDPOINT TOKEN REMOTE_DIR LOCAL_DIR [OPTIONS...]
jfrog_get_properties ENDPOINT TOKEN PATH [TIMEOUT]
jfrog_set_properties ENDPOINT TOKEN PATH TIMEOUT key=value...
jfrog_delete ENDPOINT TOKEN PATH [TIMEOUT]
jfrog_move ENDPOINT TOKEN SOURCE_PATH TARGET_PATH [TIMEOUT]
```

- ENDPOINT 包含 `/artifactory`，例如 `https://bin.example.com/artifactory`；PATH 是 `repository/subdirectory/file`，不是任意完整 URL。
- TOKEN 是调用者传入的 Bearer token，不从某个项目全局变量中读取。
- `jfrog_exists`：0 存在、1 仅表示 404、2 表示请求/权限/服务等错误。调用者必须区分不存在与故障。
- stat/list 返回经过校验的 JSON；不要用空格拆分文件名。
- `jfrog_get_properties` 输出属性对象，值为字符串数组（例如 `{"last_version":["1.2.3"]}`）。properties API 的 404 同时可能表示无属性或条目不存在，均输出 `{}`；需要区分时先用 `jfrog_exists` 确认存在。其他 HTTP、网络或元数据错误返回失败。
- 上传下载可根据已验证的 checksum 跳过重复传输；不能确认相同就不能误判已同步。下载成功前不覆盖旧文件。
- 普通 PUT 上传携带 `X-Checksum-Sha1` 和 `X-Checksum-Sha256`，由 Artifactory 校验上传内容；摘要计算失败或服务端拒绝上传时返回失败。调用者须保证源文件从摘要计算到传输结束保持不变。
- 内容相同仍跳过上传，因此不会自动补齐历史制品的上传者摘要。不会启用 `X-Checksum-Deploy` 或批量重传旧文件。
- 认证请求不跟随重定向，HTTP 3xx 不是成功；不会把失败或无效 JSON 当作空目录。
- 单文件上传、下载不隐含删除其他文件。目录传输也默认不删除；版本保留和远端垃圾回收仍属于调用者的业务策略。

#### 服务端移动

`jfrog_move` 调用 Move Item API，源和目标都是含仓库名、不带首尾 `/` 的完整条目路径；文件移动必须指定目标文件名。默认超时 120 秒，可通过末尾参数覆盖。源路径逐段编码，目标作为 `to` 查询参数整体编码一次，支持空格及 URL 特殊字符。

只移动指定条目，不下载/重新上传内容，也不预删已有目标、生成日期或清理历史；目标冲突遵循服务端规则，需要确定性覆盖时由调用方显式处理。移动需要服务端支持及相应读、部署和删除权限。

返回 0 成功、1 失败，无 stdout 数据。非 2xx（包括重定向）、网络错误、非法/多文档 JSON、空消息及任何非 INFO 消息均报错；日志不输出 token 或服务端响应正文。失败不自动回滚/重试，网络中断或目录部分移动时，调用者须检查实际远端状态。不提供并发写入保护。

#### 目录传输

两个目录接口的参数顺序相同：endpoint、token、远端目录、本地目录。目录 API 的超时使用 flag，而不是单文件 API 的末尾位置参数。额外依赖 `find` 和 Bash 4+；不需要 Python 或 GNU 专有的文件工具选项。

| 选项 | 行为 |
|---|---|
| `--recursive` | 遍历子目录并保留相对路径；默认只传输直接子文件，不扁平化 |
| `--pattern GLOB` | 按文件 basename 忽略大小写匹配，默认 `*`，包含隐藏文件；请引用通配符。目录不受过滤影响 |
| `--delete` | 扫描、校验及全部传输成功后，删除目标端在源端不存在的匹配普通文件；不删除目录或未匹配文件 |
| `--timeout SECONDS` | 每个 HTTP 请求的超时，默认 120 秒，不是整次目录任务的总时限 |

```bash
# 下载直接子文件，保留本地多余文件。
jfrog_download_dir "$ENDPOINT" "$TOKEN" generic-local/packages ./packages

# 递归下载，子目录中的同名文件各自保留；创建本地空子目录。
jfrog_download_dir "$ENDPOINT" "$TOKEN" generic-local/packages ./packages --recursive

# 递归上传匹配文件，不上传空目录；大小写不敏感，*.ISO 也匹配。
jfrog_upload_dir "$ENDPOINT" "$TOKEN" generic-local/images ./images --recursive --pattern '*.iso'

# 显式镜像匹配的文件：所有传输成功后才清理远端多余的 ISO 文件。
jfrog_upload_dir "$ENDPOINT" "$TOKEN" generic-local/images ./images \
    --recursive --pattern '*.iso' --delete --timeout 300
```

- 上传源必须存在；下载目标目录可自动创建。上传目标根明确返回 HTTP 404 时允许通过文件上传创建；下载源缺失、子目录扫描失败、权限或网络故障都返回失败，不视为空目录。
- 有效空源目录配合显式 `--delete` **会清理目标范围内全部匹配文件**。未开启递归时不处理子目录内文件；开启后清理同一目录树内的匹配文件，但保留空目录。
- 在传输前完整扫描双方目录并检查文件/目录类型冲突，遇到冲突报错，不通过删除目录解决。非法/重复远端 child 路径、控制字符、路径穿越均被拒绝。
- 本地扫描范围内的符号链接（含悬空链接）和特殊文件直接报错，即使不匹配 pattern；根路径及祖先也不能经过符号链接。根路径可为相对或绝对路径，但不得含 `..`，且不能是文件系统根目录 `/`。
- 返回 0 成功、1 失败，无 stdout 数据。失败保留已成功传输的文件；不提供整批事务回滚，清理阶段失败时先前已删除的文件也不会恢复。重试可利用现有 checksum 跳过能力。
- 调用者须保证操作期间源/目标目录稳定，避免并发增删、替换、类型变化；路径复查不是文件系统锁，无法抵御并发恶意修改。大小写折叠沿用 Bash 当前 locale，不改变调用者 shell 选项。

## 验证与分发

模块应能从任意 cwd 重复 source，且不改变 shell options、cwd、trap 或 umask。修改后至少运行 Bash 语法检查，并针对外部命令使用 mock 或人工审查验证失败传播。

跨仓库使用时固定版本引入 lib 目录。容器只需携带实际需要的模块及其依赖；不要复制函数实现，也不要在运行时 curl/source 最新版本。
