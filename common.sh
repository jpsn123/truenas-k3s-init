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

## function copy_and_replace_default_values.
## $@: file name
function copy_and_replace_default_values() {
    [ -d temp ] || mkdir temp
    for file in "$@"; do
        TEMP_NAME=$(dirname "$file")/temp
        cp -f "$file" "$TEMP_NAME/$file"
        sed -i "s/example.com/${DOMAIN}/g" "$TEMP_NAME/$file"
        sed -i "s/sc-shared-example-cachefs/${DEFAULT_SHARED_CACHEFS_STORAGE_CLASS}/g" "$TEMP_NAME/$file"
        sed -i "s/sc-shared-example/${DEFAULT_SHARED_STORAGE_CLASS}/g" "$TEMP_NAME/$file"
        sed -i "s/sc-large-example/${DEFAULT_LARGE_STORAGE_CLASS}/g" "$TEMP_NAME/$file"
        sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" "$TEMP_NAME/$file"
        sed -i -e "s/^\(.*\)10.0.0.1/\1${INGRESS_IP}/g" "$TEMP_NAME/$file"
    done
}
