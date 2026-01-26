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

## function k8s_wait.
## $1: k8s namespace
## $2: resource type
## $3: resource
## $4: duration count
function k8s_wait() {
    sleep 2
    for ((_common_index = 0; _common_index < $4; _common_index++)); do
        RES=$(kubectl -n $1 rollout status $2 $3 -w=false 2>/dev/null | grep -E 'successfully|complete' || true)
        if [ -n "$RES" ]; then
            log_info "   resource $3 is ready!"
            return 0
        fi
        log_warn "   waiting $3 be ready...  "
        sleep 5
    done
    log_error "   ERROR: resource $3 isn't ready!"
    return -1
}

## function k8s_job_wait.
## $1: k8s namespace
## $2: resource
## $3: duration count
function k8s_job_wait() {
    sleep 2
    for ((_common_index = 0; _common_index < $3; _common_index++)); do
        RES=$(kubectl -n $1 get jobs.batch $2 -o=jsonpath='{.status.succeeded}' 2>/dev/null || true)
        if [ "$RES" = '1' ]; then
            log_info "   resource $2 is ready!"
            return 0
        fi
        log_warn "   waiting $2 be ready...  "
        sleep 5
    done
    log_error "   ERROR: resource $2 isn't ready!"
    return -1
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
        # Only expand ${VAR} in environment variables
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
load_kernel_modules_with_conf() {
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
apply_sysctl_patch() {
    local sysctl_conf="/etc/sysctl.conf"
    local marker="## PATCH"
    local kv key tmp

    for kv in "$@"; do
        key="${kv%%=*}"
        [[ -n "$key" && "$kv" == *=* ]] || { echo "bad kv: $kv" >&2; return 1; }
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

    sysctl -p
}

## function wait_helmchart_ready.
## $1: namespace
## $2: chart name
## $3: timeout in seconds
wait_helmchart_ready() {
    local namespace=$1
    local chart_name=$2
    local timeout=$3
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        STATUS=$(kubectl -n "$namespace" get helmchart "$chart_name" -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || echo "False")
        if [ "$STATUS" == "True" ]; then
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