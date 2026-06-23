## functions for log
## $1: text
function log_error() {
    echo -e "\033[31m$1\033[0m"
}

function log_warn() {
    echo -e "\033[33m$1\033[0m"
}

function log_info() {
    echo -e "\033[32m$1\033[0m"
}

function log_trace() {
    echo -e "\033[34m$1\033[0m"
}

function log_header() {
    echo -e "\033[42;30m$1\n\033[0m"
}

function log_reminder() {
    echo -e "\033[35m$1\n\033[0m"
}

## function prompt_with_default.
## $1: reminder text
## $2: prompt text
## $3: default value
function prompt_with_default() {
    local REMINDER_TEXT="$1"
    local PROMPT_TEXT="$2"
    local DEFAULT_VALUE="$3"
    local INPUT_VALUE=""
    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT" >&2
    fi
    if [ -n "$DEFAULT_VALUE" ]; then
        read -p "$PROMPT_TEXT [$DEFAULT_VALUE]: " INPUT_VALUE
        if [ -z "$INPUT_VALUE" ]; then
            INPUT_VALUE="$DEFAULT_VALUE"
        fi
    else
        read -p "$PROMPT_TEXT: " INPUT_VALUE
    fi
    printf '%s' "$INPUT_VALUE"
}

## function prompt_required.
## $1: reminder text
## $2: prompt text
## $3: read option, use -s for secret input
function prompt_required() {
    local REMINDER_TEXT="$1"
    local PROMPT_TEXT="$2"
    local READ_OPT="$3"
    local INPUT_VALUE=""
    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT" >&2
    fi
    while [ -z "$INPUT_VALUE" ]; do
        if [ "$READ_OPT" == "-s" ]; then
            read -s -p "$PROMPT_TEXT: " INPUT_VALUE
            printf '\n' >&2
        else
            read -p "$PROMPT_TEXT: " INPUT_VALUE
        fi
    done
    printf '%s' "$INPUT_VALUE"
}

## function apply_secret_generic. create or update secret safely without deleting first.
## $1: namespace
## $2: secret name
## $@: kubectl create secret generic arguments
function apply_secret_generic() {
    local NS="$1"
    local NAME="$2"
    local TEMP_FILE=""
    local RESULT=0
    shift 2

    TEMP_FILE=$(mktemp) || return 1
    kubectl -n "$NS" create secret generic "$NAME" "$@" --dry-run=client -o yaml >"$TEMP_FILE" || { rm -f "$TEMP_FILE"; return 1; }
    kubectl apply --server-side --force-conflicts -f "$TEMP_FILE" || RESULT=$?
    rm -f "$TEMP_FILE"
    return $RESULT
}

## function apply_configmap. create or update configmap safely without deleting first.
## $1: namespace
## $2: configmap name
## $@: kubectl create configmap arguments
function apply_configmap() {
    local NS="$1"
    local NAME="$2"
    local TEMP_FILE=""
    local RESULT=0
    shift 2

    TEMP_FILE=$(mktemp) || return 1
    kubectl -n "$NS" create configmap "$NAME" "$@" --dry-run=client -o yaml >"$TEMP_FILE" || { rm -f "$TEMP_FILE"; return 1; }
    kubectl apply --server-side --force-conflicts -f "$TEMP_FILE" || RESULT=$?
    rm -f "$TEMP_FILE"
    return $RESULT
}

## function apply_docker_registry_secret. create or update docker registry secret safely without deleting first.
## $1: namespace
## $2: secret name
## $3: docker registry server
## $4: docker registry username
## $5: docker registry password or token
function apply_docker_registry_secret() {
    local NS="$1"
    local NAME="$2"
    local SERVER="$3"
    local USERNAME="$4"
    local PASSWORD="$5"
    local TEMP_FILE=""
    local RESULT=0

    TEMP_FILE=$(mktemp) || return 1
    kubectl -n "$NS" create secret docker-registry "$NAME" \
        --docker-server="$SERVER" \
        --docker-username="$USERNAME" \
        --docker-password="$PASSWORD" \
        --dry-run=client -o yaml >"$TEMP_FILE" || { rm -f "$TEMP_FILE"; return 1; }
    kubectl apply --server-side --force-conflicts -f "$TEMP_FILE" || RESULT=$?
    rm -f "$TEMP_FILE"
    return $RESULT
}

## function get_secret_value. get and decode a key from secret, return empty if not exists.
## $1: namespace
## $2: secret name
## $3: key
function get_secret_value() {
    local NS="$1"
    local NAME="$2"
    local KEY="$3"
    kubectl -n "$NS" get secret "$NAME" -o go-template="{{ with index .data \"$KEY\" }}{{ . | base64decode }}{{ end }}" 2>/dev/null || true
}

## function get_configmap_value. get a key from configmap, return empty if not exists.
## $1: namespace
## $2: configmap name
## $3: key
function get_configmap_value() {
    local NS="$1"
    local NAME="$2"
    local KEY="$3"
    kubectl -n "$NS" get configmap "$NAME" -o go-template="{{ with index .data \"$KEY\" }}{{ . }}{{ end }}" 2>/dev/null || true
}

## function load_secret_vars. load secret keys into variables.
## $1: namespace
## $2: secret name
## $@: key=VARIABLE_NAME pairs
function load_secret_vars() {
    local NS="$1"
    local NAME="$2"
    local ITEM=""
    local KEY=""
    local VAR=""
    local VALUE=""
    local LOADED=false
    shift 2

    for ITEM in "$@"; do
        KEY="${ITEM%%=*}"
        VAR="${ITEM#*=}"
        VALUE=$(get_secret_value "$NS" "$NAME" "$KEY")
        if [ -n "$VALUE" ]; then
            printf -v "$VAR" '%s' "$VALUE"
            LOADED=true
        fi
    done
    if [ "$LOADED" == true ]; then
        log_info "reuse existing secret $NAME."
    fi
}

## function load_configmap_vars. load configmap keys into variables.
## $1: namespace
## $2: configmap name
## $@: key=VARIABLE_NAME pairs
function load_configmap_vars() {
    local NS="$1"
    local NAME="$2"
    local ITEM=""
    local KEY=""
    local VAR=""
    local VALUE=""
    local LOADED=false
    shift 2

    for ITEM in "$@"; do
        KEY="${ITEM%%=*}"
        VAR="${ITEM#*=}"
        VALUE=$(get_configmap_value "$NS" "$NAME" "$KEY")
        if [ -n "$VALUE" ]; then
            printf -v "$VAR" '%s' "$VALUE"
            LOADED=true
        fi
    done
    if [ "$LOADED" == true ]; then
        log_info "reuse existing configmap $NAME."
    fi
}

## function apply_secret_vars. apply literal variables as a generic secret.
## $1: namespace
## $2: secret name
## $@: key=VARIABLE_NAME pairs
function apply_secret_vars() {
    local NS="$1"
    local NAME="$2"
    local ITEM=""
    local KEY=""
    local VAR=""
    local VALUE=""
    local ARGS=()
    shift 2

    for ITEM in "$@"; do
        KEY="${ITEM%%=*}"
        VAR="${ITEM#*=}"
        VALUE="${!VAR}"
        ARGS+=(--from-literal="$KEY=$VALUE")
    done
    apply_secret_generic "$NS" "$NAME" "${ARGS[@]}"
}

## function apply_configmap_vars. apply literal variables as a configmap.
## $1: namespace
## $2: configmap name
## $@: key=VARIABLE_NAME pairs
function apply_configmap_vars() {
    local NS="$1"
    local NAME="$2"
    local ITEM=""
    local KEY=""
    local VAR=""
    local VALUE=""
    local ARGS=()
    shift 2

    for ITEM in "$@"; do
        KEY="${ITEM%%=*}"
        VAR="${ITEM#*=}"
        VALUE="${!VAR}"
        ARGS+=(--from-literal="$KEY=$VALUE")
    done
    apply_configmap "$NS" "$NAME" "${ARGS[@]}"
}

## function derive_password_sha1. keep the same sha1sum + base64 password rule.
## $1: seed
## $2: purpose
## $3: length
function derive_password_sha1() {
    local SEED="$1"
    local PURPOSE="$2"
    local LENGTH="$3"
    echo -n "$SEED@$PURPOSE" | sha1sum | awk '{print $1}' | base64 | head -c "$LENGTH"
}

## function derive_password_sha256. keep the same sha256sum + base64 password rule.
## $1: seed
## $2: purpose
## $3: length
function derive_password_sha256() {
    local SEED="$1"
    local PURPOSE="$2"
    local LENGTH="$3"
    echo -n "$SEED@$PURPOSE" | sha256sum | awk '{print $1}' | base64 | head -c "$LENGTH"
}

## function derive_password_sha256_hex. sha256sum hex (without base64) password rule.
## 用于需要纯 hex 格式密钥的场景
## 与 derive_password_sha256 的区别是不经过 base64，直接取 sha256 的十六进制摘要。
## $1: seed
## $2: purpose
## $3: length
function derive_password_sha256_hex() {
    local SEED="$1"
    local PURPOSE="$2"
    local LENGTH="$3"
    echo -n "$SEED@$PURPOSE" | sha256sum | awk '{print $1}' | head -c "$LENGTH"
}

## function run_command can execute command on every node.
## $1: node list
## $2: the command
## $3: execute command on main master? default is true.
function run_command() {
    HOST_ARRAY=$1
    for _common_index in ${HOST_ARRAY[*]}; do
        RES=$(ip addr | grep $_common_index 2>/dev/null || true)
        if [ -n "$RES" ]; then
            LOCAL_IP=$_common_index
            break
        fi
    done
    for _common_index in ${HOST_ARRAY[*]}; do
        if [ "$_common_index" == "$LOCAL_IP" ]; then
            if [ "$3" != false ]; then
                log_info "   running command \"$2\" at local...  "
                echo "$2" | sh
                echo -e "\n"
            fi
        else
            log_info "   running command \" $2 \" at remote node: $_common_index...  "
            ssh root@$_common_index "$2"
            echo -e "\n"
        fi
    done
}

## function remote_copy can copy file to every node corresponding path.
## $1: node list
## $2: the file
function remote_copy() {
    HOST_ARRAY=$1
    for _common_index in ${HOST_ARRAY[*]}; do
        RES=$(ip addr | grep $_common_index 2>/dev/null || true)
        if [ -n "$RES" ]; then
            LOCAL_IP=$_common_index
            break
        fi
    done
    for _common_index in ${HOST_ARRAY[*]}; do
        if [ "$_common_index" != "$LOCAL_IP" ]; then
            log_info "   copying file $2 remote node: $_common_index...  "
            scp "$2" "root@$_common_index:$2"
            echo -e "\n"
        fi
    done
}

## function to create pool with param.
## $1: pool name
## $2: pg num
## $3: pgp num
## $4: redundancy type
## $5: crush rule
## $6: application label
## $7: min_pg
## $8: replicated size or ec_overwrites
## $9: ec_profile
function create_pool_helper() {
    if [[ $4 == replicated ]]; then
        ceph osd pool create $1 $2 $3 $4 $5
        ceph osd pool set $1 size $8
    else
        ceph osd pool create $1 $2 $3 $4 $9 $5
        ceph osd pool set $1 allow_ec_overwrites $8
    fi
    ceph osd pool application enable $1 $6
    ceph osd pool set $1 pg_num_min $7
}

## function to reset pool pg num.
## $1: pool name
## $2: pg num
function reset_pool_pg() {
    ceph osd pool set $1 pg_num $2
    ceph osd pool set $1 pgp_num $2
}

## function app_is_exist.
## $1: namespace
## $2: application name.
function app_is_exist() {
    APPS=$(helm list -n $1 -a | sed -n '2,$p' | awk '{print $1}')
    for _common_index in ${APPS[*]}; do
        if [ "$_common_index" == "$2" ]; then
            echo true
            return
        fi
    done
    echo false
}

## function render_values_file_to_temp. autofill parameter.sh value to values.yaml file.
## $@: file name
function render_values_file_to_temp() {
    [ -d temp ] || mkdir temp
    for file in "$@"; do
        TEMP_NAME=$(dirname "$file")/temp
        while IFS= read -r line; do
            out=""
            while [[ $line =~ ^([^$]*)(\$\{[A-Z_][A-Z0-9_]*\})(.*)$ ]]; do
                out+="${BASH_REMATCH[1]}"
                token="${BASH_REMATCH[2]}"
                var="${token:2:-1}"
                val="${!var}"
                if [[ -n "$val" ]]; then
                    out+="$val"
                else
                    out+="$token"
                fi
                line="${BASH_REMATCH[3]}"
            done
            printf '%s\n' "$out$line"
        done <"$file" >"$TEMP_NAME/$file"
    done
}

## function load_kernel_modules_with_conf.
## $1: conf file name
## $@: module names
function load_kernel_modules_with_conf() {
    local conf_name="$1"; shift
    local modules=("$@")

    if [[ -z "$conf_name" ]]; then
        log_error "conf path is empty"
        return 1
    fi
    if [[ "$conf_name" == */* ]]; then
        log_error "conf name must be a file name, not a path: $conf_name"
        return 1
    fi
    conf_path="/etc/modules-load.d/$conf_name"

    install -d /etc/modules-load.d || return 1
    {
        for m in "${modules[@]}"; do
            echo "$m"
        done
    } | tee "$conf_path" >/dev/null || return 1

    for m in "${modules[@]}"; do
        if modprobe "$m"; then
            log_info "modprobe ok: $m"
        else
            log_error "modprobe failed: $m"
        fi
    done
}

## function apply_sysctl_patch.
## $@: sysctl key-value pairs (e.g. net.ipv4.ip_forward=1)
function apply_sysctl_patch() {
    local sysctl_conf="/etc/sysctl.d/69-k3s.conf"
    local marker="## PATCH"
    local kv key tmp

    mkdir -p "$(dirname "$sysctl_conf")"
    touch "$sysctl_conf" || { log_error "Failed to create sysctl config file: $sysctl_conf"; return 1; }
    for kv in "$@"; do
        key="${kv%%=*}"
        [[ -n "$key" && "$kv" == *=* ]] || { log_error "bad kv: $kv"; return 1; }
        tmp="$(mktemp)" || return 1
        awk -v marker="$marker" -v key="$key" -v kv="$kv" '
            BEGIN { inpatch=0; seen_marker=0 }
            {
                if ($0 == marker) { inpatch=1; seen_marker=1; print; next }
                if (inpatch && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") next
                print
            }
            END {
                if (!seen_marker) { print ""; print marker }
                print kv
            }
        ' "$sysctl_conf" >"$tmp" && cat "$tmp" >"$sysctl_conf" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
    done

    sysctl -p "$sysctl_conf"
}

## function wait_helmchart_ready.
## $1: namespace
## $2: chart name
## $3: timeout in seconds
function wait_helmchart_ready() {
    local namespace=$1
    local chart_name=$2
    local timeout=$3
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        STATUS=$(kubectl -n "$namespace" get helmchart "$chart_name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "True")
        if [ "$STATUS" == "False" ]; then
            log_info "HelmChart $chart_name in namespace $namespace is deployed successfully."
            return 0
        fi
        log_warn "Waiting for HelmChart $chart_name in namespace $namespace to be deployed..."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "Timeout waiting for HelmChart $chart_name in namespace $namespace to be deployed."
    return 1
}

## function get_helm_chart_versions. get chart version and appVersion from a helm repo.
## 用于一次性获取 chart version 和 appVersion，避免多次更新/搜索 Helm repo。
## 如果传入 appVersion，则返回该 appVersion 对应的第一条 chart version；否则返回最新 chart 的 chart version 和 appVersion。
## $1: helm repo name, e.g. kasten
## $2: helm repo url, e.g. https://charts.kasten.io/
## $3: chart name in this repo, e.g. k10
## $4: appVersion to match, optional
## stdout: "<chartVersion> <appVersion>"
function get_helm_chart_versions() {
    local REPO_NAME="$1"
    local REPO_URL="$2"
    local CHART_NAME="$3"
    local APP_VERSION="$4"
    local VERSION_PAIR=""

    helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || true
    helm repo update "$REPO_NAME" >/dev/null
    if [ -z "$APP_VERSION" ]; then
        VERSION_PAIR=$(helm search repo "$REPO_NAME/$CHART_NAME" --versions | sed -n '2p' | awk '{print $2, $3}')
    else
        VERSION_PAIR=$(helm search repo "$REPO_NAME/$CHART_NAME" --versions | awk -v app_version="$APP_VERSION" 'NR > 1 && $3 == app_version { print $2, $3; exit }')
    fi
    if [ -z "$VERSION_PAIR" ]; then
        log_error "failed to get helm chart versions: $REPO_NAME/$CHART_NAME ${APP_VERSION:+app version $APP_VERSION}"
        return 1
    fi
    printf '%s' "$VERSION_PAIR"
}

## function validate_install_mode. validate app install mode.
## $1: install mode
## $@: supported component modes
function validate_install_mode() {
    local INSTALL_MODE="$1"
    local COMPONENT=""
    shift

    if [ "$INSTALL_MODE" == "full" ] || [ "$INSTALL_MODE" == "reinstall" ]; then
        return
    fi
    for COMPONENT in "$@"; do
        if [ "$INSTALL_MODE" == "$COMPONENT" ]; then
            return
        fi
    done
    log_error "unknown install mode: $INSTALL_MODE"
    log_reminder "supported install modes: full reinstall $*"
    exit 1
}

## function install_mode_enabled. check whether a component should run in current mode.
## $1: install mode
## $2: component mode
function install_mode_enabled() {
    local INSTALL_MODE="$1"
    local COMPONENT="$2"

    [ "$INSTALL_MODE" == "full" ] || [ "$INSTALL_MODE" == "reinstall" ] || [ "$INSTALL_MODE" == "$COMPONENT" ]
}

## function ensure_helm_repo_chart. pull helm chart to temp, reusing local cache when possible.
## chart version ($4) is optional:
##   - 未指定版本时，优先复用 temp/$CHART_NAME 本地缓存；缓存不存在才拉取最新版本。
##   - 指定版本时，若缓存缺失或版本不一致，才按指定版本拉取。
## reinstall 等无需固定版本的场景可不传 $4，直接走本地缓存或最新版本。
## $1: helm repo name, ignored for OCI charts
## $2: helm repo url or OCI registry url
## $3: chart name
## $4: chart version, optional
function ensure_helm_repo_chart() {
    local REPO_NAME="$1"
    local REPO_URL="$2"
    local CHART_NAME="$3"
    local CHART_VERSION="$4"
    local VERSION_FLAG=()

    if [ -z "$CHART_VERSION" ]; then
        if [ -f "temp/$CHART_NAME/Chart.yaml" ]; then
            log_info "reuse cached chart $CHART_NAME."
            return
        fi
    else
        if [ -f "temp/$CHART_NAME/Chart.yaml" ] && grep -Eq "version:[[:space:]]*$CHART_VERSION" "temp/$CHART_NAME/Chart.yaml"; then
            log_info "reuse cached chart $CHART_NAME $CHART_VERSION."
            return
        fi
        rm -rf "temp/$CHART_NAME"
        VERSION_FLAG=(--version="$CHART_VERSION")
    fi
    if [[ "$REPO_URL" == oci://* ]]; then
        helm pull "$REPO_URL/$CHART_NAME" --untar --untardir temp "${VERSION_FLAG[@]}"
    else
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || true
        helm repo update "$REPO_NAME"
        helm pull "$REPO_NAME/$CHART_NAME" --untar --untardir temp "${VERSION_FLAG[@]}"
    fi
}

## function resolve_chart_app_version. read chart version and appVersion from cached temp chart.
## 用于 reinstall 等不再持久化版本的场景：从本地缓存的 Chart.yaml 反推 chart version 与 appVersion，
## 避免重新查询 Helm repo 或依赖 ConfigMap。缓存不存在时返回失败。
## $1: chart name in temp/
## $2: variable name to receive chart version
## $3: variable name to receive app version
## return: 0 成功，1 缓存缺失
function resolve_chart_app_version() {
    local CHART_NAME="$1"
    local CHART_VERSION_VAR="$2"
    local APP_VERSION_VAR="$3"
    local CHART_VERSION=""
    local APP_VERSION=""

    if [ ! -f "temp/$CHART_NAME/Chart.yaml" ]; then
        log_error "cached chart $CHART_NAME not found, please run full mode first."
        return 1
    fi
    CHART_VERSION=$(awk '/^version:/{print $2}' "temp/$CHART_NAME/Chart.yaml")
    APP_VERSION=$(awk '/^appVersion:/{print $2}' "temp/$CHART_NAME/Chart.yaml")
    printf -v "$CHART_VERSION_VAR" '%s' "$CHART_VERSION"
    printf -v "$APP_VERSION_VAR" '%s' "$APP_VERSION"
}

## function normalize_registry_host. normalize registry url to image registry host.
## 用于用户输入 registry url 后，提取可拼接到镜像名前面的域名部分。
## 支持输入带 scheme 或 path 的地址，例如：
##   https://harbor.example.com/project -> harbor.example.com
##   http://registry.example.com:5000 -> registry.example.com:5000
##   registry.example.com/library -> registry.example.com
## 注意：本函数只做字符串规范化，不验证 registry 是否可访问。
## $1: registry url or host
## stdout: registry host without scheme and path
function normalize_registry_host() {
    local REGISTRY_URL="$1"
    local REGISTRY_HOST=""

    REGISTRY_HOST="${REGISTRY_URL#http://}"
    REGISTRY_HOST="${REGISTRY_HOST#https://}"
    REGISTRY_HOST="${REGISTRY_HOST%%/*}"
    printf '%s' "$REGISTRY_HOST"
}

## function strip_image_registry. strip registry host from an image repository.
## 用于重新拼接镜像名前缀：保留 namespace/repository，去掉已有 registry host。
## 仅当第一个路径段看起来像 registry host 时才会移除：包含 .、包含 :、或等于 localhost。
## 示例：
##   harbor.example.com/library/curl -> library/curl
##   localhost:5000/library/curl -> library/curl
##   library/curl -> library/curl
## $1: image repository, without tag is recommended
## stdout: image repository without registry host
function strip_image_registry() {
    local IMAGE="$1"
    local FIRST_PART="${IMAGE%%/*}"

    if [[ "$IMAGE" == */* && ( "$FIRST_PART" == *.* || "$FIRST_PART" == *:* || "$FIRST_PART" == "localhost" ) ]]; then
        printf '%s' "${IMAGE#*/}"
    else
        printf '%s' "$IMAGE"
    fi
}

## function write_docker_registry_auth_config. write Docker CLI compatible registry auth config.
## 用于 buildctl / docker / crane 等客户端通过 DOCKER_CONFIG 读取 registry 凭据。
## 会先删除并重建 $1 目录，然后写入 $1/config.json。
## 注意：$2 应使用 registry host，不要带 http://、https:// 或 path；可先用 normalize_registry_host 处理。
## $1: docker config dir
## $2: registry host
## $3: registry username
## $4: registry password or token
function write_docker_registry_auth_config() {
    local CONFIG_DIR="$1"
    local REGISTRY_HOST="$2"
    local USERNAME="$3"
    local PASSWORD="$4"
    local AUTH=""

    rm -rf "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    AUTH=$(printf '%s:%s' "$USERNAME" "$PASSWORD" | base64 | tr -d '\n')
    cat >"$CONFIG_DIR/config.json" <<EOF
{
  "auths": {
    "$REGISTRY_HOST": {
      "username": "$USERNAME",
      "password": "$PASSWORD",
      "auth": "$AUTH"
    }
  }
}
EOF
}

## function k3s_crictl_pull_image. check whether an image can be pulled by the local k3s runtime.
## 用于安装前确认集群节点运行时能拉取镜像，比本机 docker/crane 更贴近实际运行环境。
## 如果传入用户名，则使用 `k3s crictl pull --creds username:password`。
## stdout: none
## return: 0 if image can be pulled, non-zero otherwise
## $1: full image name, including tag if needed
## $2: registry username, optional
## $3: registry password or token, optional
function k3s_crictl_pull_image() {
    local IMAGE="$1"
    local USERNAME="$2"
    local PASSWORD="$3"

    if ! command -v k3s >/dev/null 2>&1; then
        log_error "k3s is required to check image pullability: $IMAGE"
        return 1
    fi

    if [ -n "$USERNAME" ]; then
        k3s crictl pull --creds "$USERNAME:$PASSWORD" "$IMAGE" >/dev/null 2>&1
    else
        k3s crictl pull "$IMAGE" >/dev/null 2>&1
    fi
}

## function ensure_buildctl_installed. install buildctl client if it is missing.
## 用于需要调用远端/集群内 BuildKit 的脚本，自动补齐本机 buildctl 客户端。
## 当前支持 linux amd64 和 arm64，从 moby/buildkit GitHub latest release 下载。
## 安装目标路径为 /usr/local/bin/buildctl，执行脚本的用户需要有写入权限。
## stdout: none
## return: 0 if buildctl exists or install succeeds, non-zero otherwise
function ensure_buildctl_installed() {
    local ARCH=""
    local DOWNLOAD_URL=""
    local TEMP_DIR=""

    if command -v buildctl >/dev/null 2>&1; then
        return
    fi

    case "$(uname -m)" in
    x86_64)
        ARCH=amd64
        ;;
    aarch64 | arm64)
        ARCH=arm64
        ;;
    *)
        log_error "unsupported buildctl architecture: $(uname -m)"
        return 1
        ;;
    esac

    log_info "buildctl does not exist, install buildctl."
    DOWNLOAD_URL=$(curl -fsSL https://api.github.com/repos/moby/buildkit/releases/latest | grep "browser_download_url.*linux-$ARCH.tar.gz" | head -n 1 | cut -d '"' -f 4)
    if [ -z "$DOWNLOAD_URL" ]; then
        log_error "failed to get buildctl download url."
        return 1
    fi

    TEMP_DIR=$(mktemp -d) || return 1
    curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_DIR/buildkit.tar.gz" || { rm -rf "$TEMP_DIR"; return 1; }
    tar -xzf "$TEMP_DIR/buildkit.tar.gz" -C "$TEMP_DIR" bin/buildctl || { rm -rf "$TEMP_DIR"; return 1; }
    install -m 0755 "$TEMP_DIR/bin/buildctl" /usr/local/bin/buildctl || { rm -rf "$TEMP_DIR"; return 1; }
    rm -rf "$TEMP_DIR"
}

## function build_image_with_buildkit. build and push an image through buildctl.
## 用于 Dockerfile context 已在本地、BuildKit daemon 在集群内或远端的场景。
## 会先调用 ensure_buildctl_installed，确保本机存在 buildctl 客户端。
## $4 会作为 DOCKER_CONFIG 传给 buildctl，用于向目标 registry 推送镜像；可由 write_docker_registry_auth_config 生成。
## 如果 $5 非空，会传入 Dockerfile build arg：BASE_IMAGE=$5。
## $1: build context dir, also used as dockerfile dir
## $2: full image name to push, including tag
## $3: buildkit address, e.g. tcp://buildkit.buildkit.svc.cluster.local:1234
## $4: docker config dir
## $5: BASE_IMAGE build arg, optional
function build_image_with_buildkit() {
    local CONTEXT="$1"
    local IMAGE="$2"
    local BUILDKIT_ADDR="$3"
    local DOCKER_CONFIG_DIR="$4"
    local BASE_IMAGE="$5"
    local BUILD_ARGS=()

    ensure_buildctl_installed || return 1
    if [ -n "$BASE_IMAGE" ]; then
        BUILD_ARGS+=(--opt=build-arg:BASE_IMAGE="$BASE_IMAGE")
    fi

    log_info "build image with buildkit: $IMAGE"
    DOCKER_CONFIG="$DOCKER_CONFIG_DIR" buildctl --addr="$BUILDKIT_ADDR" build \
        --progress=plain \
        --frontend=dockerfile.v0 \
        --local=context="$CONTEXT" \
        --local=dockerfile="$CONTEXT" \
        "${BUILD_ARGS[@]}" \
        --output=type=image,name="$IMAGE",push=true
}
