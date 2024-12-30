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
    for i in ${HOST_ARRAY[*]}
    do
        RES=`ip addr | grep $i 2>/dev/null`
        if [ -n "$RES" ]; then
            LOCAL_IP=$i
            break
        fi
    done
    for i in ${HOST_ARRAY[*]}
    do
        if [ "$i" == "$LOCAL_IP" ]; then
            if [ "$3" != false ]; then
                echo -e "\033[32m   running command \033[34m \" $2 \" \033[32m, at local...  \033[0m"
                echo "$2"|sh
                echo -e "\n"
            fi
        else
            echo -e "\033[32m   running command \033[34m \" $2 \" \033[32m, at remote node:\033[35m $i...  \033[0m"
            ssh root@$i "$2"
            echo -e "\n"
        fi
    done
}

## function remote_copy can copy file to every node corresponding path.
## $1: node list
## $2: the file
function remote_copy() {
    HOST_ARRAY=$1
    for i in ${HOST_ARRAY[*]}
    do
        RES=`ip addr | grep $i 2>/dev/null`
        if [ -n "$RES" ]; then
            LOCAL_IP=$i
            break
        fi
    done
    for i in ${HOST_ARRAY[*]}
    do
        if [ "$i" != "$LOCAL_IP" ]; then
            echo -e "\033[32m   copying file \033[34m $2 \033[32m to remote node:\033[35m $i...  \033[0m"
            scp "$2" "root@$i:$2"
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
    for ((i=0;i<$4;i++))
    do
        RES=`k3s kubectl -n $1 rollout status $2 $3 -w=false 2>/dev/null|grep -E 'successfully|complete' || true`
        if [ -n "$RES" ]; then
            echo -e "\033[34m   resource $3 is ready!  \033[0m"
            return 0
        fi
        echo -e "\033[33m   waiting $3 be ready...  \033[0m"
        sleep 5
    done
    echo -e "\033[31m   ERROR: resource $3 isn't ready!  \033[0m"
    return -1
}

## function k8s_job_wait.
## $1: k8s namespace
## $2: resource
## $3: duration count
function k8s_job_wait() {
    for ((i=0;i<$3;i++))
    do
        RES=`k3s kubectl -n $1 get jobs.batch $2 -o=jsonpath='{.status.succeeded}' 2>/dev/null || true`
        if [ "$RES" == '1'  ]; then
            echo -e "\033[34m   resource $2 is ready!  \033[0m"
            return 0
        fi
        echo -e "\033[33m   waiting $2 be ready...  \033[0m"
        sleep 5
    done
    echo -e "\033[31m   ERROR: resource $2 isn't ready!  \033[0m"
    return -1
}

## function app_is_exist.
## $1: namespace
## $2: application name.
function app_is_exist() {
    APPS=`helm list -n $1 -a | sed -n '2,$p' | awk '{print $1}'`
    for i in ${APPS[*]}
    do
        if [ "$i" == "$2" ]; then
            echo true
            return
        fi
    done
    echo false
}