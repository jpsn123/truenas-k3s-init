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
    echo -e "\033[42;30m $1\n\033[0m"
}

function log_reminder() {
    echo -e "\033[35m $1\n\033[0m"
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
