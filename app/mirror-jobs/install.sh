#!/bin/bash
set -e
set -o pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libregistry.sh"
source "$DEPLOY_ROOT/scripts/deploy/images.sh"
source "$DEPLOY_LIB_DIR/libbuildkit.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"
NS=mirror-jobs

INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE"
SHARED_SECRET=mirror-jobs-jfrog
APP_DIR="$PWD"
mkdir -p temp
# Serialize local installs; CronJob suspension only guards against scheduled runs.
exec 9>temp/install.lock
flock -n 9 || { log_error "another mirror-jobs installer is running from this checkout."; exit 1; }
WORK_DIR=$(mktemp -d "$APP_DIR/temp/install.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

function wait_job() {
    local NAME="$1"
    local DEADLINE="$2"
    local STATUS=""
    while [ "$SECONDS" -lt "$DEADLINE" ]; do
        STATUS=$(kubectl -n "$NS" get job "$NAME" -o json) || return 1
        if jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' <<<"$STATUS" >/dev/null; then
            return 0
        fi
        if jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' <<<"$STATUS" >/dev/null; then
            log_error "job failed: $NAME"
            return 1
        fi
        sleep 5
    done
    log_error "timed out waiting for job: $NAME"
    return 1
}

log_header "JFrog config"
kubectl create namespace "$NS" 2>/dev/null || true
kube_secret_load "$NS" "$SHARED_SECRET" \
    JFROG_URL=JFROG_URL \
    JFROG_ARTIFACTORY_URL=JFROG_ARTIFACTORY_URL \
    JFROG_REGISTRY=JFROG_REGISTRY \
    JFROG_USERNAME=JFROG_USERNAME \
    JFROG_TOKEN=JFROG_TOKEN \
    BUILDKIT_ADDR=BUILDKIT_ADDR
JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
JFROG_URL="${JFROG_URL:-${JFROG_ARTIFACTORY_URL%/artifactory}}"
[ -n "$JFROG_URL" ] || JFROG_URL=$(prompt_with_default "please input shared JFrog config." "JFrog URL" "https://bin.$DOMAIN")
[ -n "$JFROG_REGISTRY" ] || JFROG_REGISTRY=$(prompt_with_default "" "Docker registry" "hub.bin.$DOMAIN")
[ -n "$JFROG_USERNAME" ] || JFROG_USERNAME=$(prompt_required "" "JFrog username" "")
[ -n "$JFROG_TOKEN" ] || JFROG_TOKEN=$(prompt_required "token needs image push/pull and artifact read/deploy/delete/annotate permissions." "JFrog token" -s)
[ -n "$BUILDKIT_ADDR" ] || BUILDKIT_ADDR=$(prompt_with_default "" "BuildKit address" "tcp://buildkit.$DOMAIN:1234")
JFROG_URL="${JFROG_URL%/}"
JFROG_REGISTRY=$(registry_host "$JFROG_REGISTRY")
if [[ ! "$JFROG_URL" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] ||
    [[ ! "$JFROG_REGISTRY" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
    log_error "use an HTTPS JFrog URL and a registry host, both without a path."
    exit 1
fi
JFROG_ARTIFACTORY_URL="$JFROG_URL/artifactory"
kube_secret_apply_vars "$NS" "$SHARED_SECRET" \
    JFROG_URL=JFROG_URL \
    JFROG_ARTIFACTORY_URL=JFROG_ARTIFACTORY_URL \
    JFROG_REGISTRY=JFROG_REGISTRY \
    JFROG_USERNAME=JFROG_USERNAME \
    JFROG_TOKEN=JFROG_TOKEN \
    BUILDKIT_ADDR=BUILDKIT_ADDR
registry_write_auth "$WORK_DIR/docker-config" "$JFROG_REGISTRY" "$JFROG_USERNAME" "$JFROG_TOKEN"

for JOB_CONFIG in */values-job.yaml; do
    [ -f "$JOB_CONFIG" ] || continue
    (
        cd "$(dirname "$JOB_CONFIG")"
        deploy_render_values values-job.yaml
        if grep -Eq '\$\{[A-Z_][A-Z0-9_]*\}' temp/values-job.yaml; then
            log_error "unresolved variables in $JOB_CONFIG"
            exit 1
        fi
        JOB_JSON=$(kubectl create --dry-run=client --validate=false -f temp/values-job.yaml -o json)
        jq -e --arg ns "$NS" '
            .apiVersion == "batch/v1" and .kind == "CronJob" and .metadata.namespace == $ns
            and (.metadata.name | test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))
            and (.metadata.name | length <= 40)
            and (.spec.jobTemplate.spec.template.spec.containers | length == 1)
            and (.spec.jobTemplate.spec.template.spec.containers[0].image | type == "string")
            and (.metadata.annotations["mirror-jobs/base-image"] | type == "string")
            and (.spec.jobTemplate.spec.activeDeadlineSeconds | type == "number" and . > 0)
            and .spec.concurrencyPolicy == "Forbid"
        ' <<<"$JOB_JSON" >/dev/null || { log_error "invalid job contract: $JOB_CONFIG"; exit 1; }
        NAME=$(jq -r '.metadata.name' <<<"$JOB_JSON")
        IMAGE=$(jq -r '.spec.jobTemplate.spec.template.spec.containers[0].image' <<<"$JOB_JSON")
        BASE_IMAGE=$(jq -r '.metadata.annotations["mirror-jobs/base-image"]' <<<"$JOB_JSON")
        TIMEOUT=$(jq -r '.spec.jobTemplate.spec.activeDeadlineSeconds + 60' <<<"$JOB_JSON")
        if [[ "$IMAGE" != "$JFROG_REGISTRY/"* ]] || [[ "${IMAGE##*/}" != *:* ]] || [ -z "$BASE_IMAGE" ] || [ ! -f Dockerfile ]; then
            log_error "$NAME requires a Dockerfile, a base image and a tagged image under $JFROG_REGISTRY."
            exit 1
        fi
        log_header "install $NAME"
        if deploy_image_pull "$IMAGE" "$JFROG_USERNAME" "$JFROG_TOKEN"; then
            log_info "image is pullable: $IMAGE"
        else
            mkdir -p "$WORK_DIR/context/$NAME"
            tar --exclude='./temp' --exclude='./.git' --exclude='./__pycache__' -cf - . |
                tar -xf - -C "$WORK_DIR/context/$NAME"
            cp "$APP_DIR/mirror.sh" "$WORK_DIR/context/$NAME/mirror.sh"
            mkdir -p "$WORK_DIR/context/$NAME/lib"
            cp "$DEPLOY_LIB_DIR/liblog.sh" "$DEPLOY_LIB_DIR/libjfrog.sh" "$WORK_DIR/context/$NAME/lib/"
            buildkit_ensure_client /usr/local/bin
            buildkit_build "$WORK_DIR/context/$NAME" "$IMAGE" "$BUILDKIT_ADDR" "$WORK_DIR/docker-config" "$BASE_IMAGE"
        fi

        # Manual Jobs are not covered by concurrencyPolicy: Forbid. Drain before starting one.
        jq --arg name "$NAME" '
            .spec.suspend = true |
            .spec.jobTemplate.metadata.labels["mirror-jobs/name"] = $name
        ' <<<"$JOB_JSON" >temp/job-suspended.json
        kubectl apply -f temp/job-suspended.json
        ACTIVE_JOBS=$(kubectl -n "$NS" get jobs -o json | jq -r --arg name "$NAME" '
            .items[] | select(.metadata.labels["mirror-jobs/name"] == $name
                or any(.metadata.ownerReferences[]?; .kind == "CronJob" and .name == $name)) |
            select(any(.status.conditions[]?; (.type == "Complete" or .type == "Failed") and .status == "True") | not) |
            .metadata.name
        ')
        DEADLINE=$((SECONDS + TIMEOUT))
        while IFS= read -r ACTIVE_JOB; do
            [ -n "$ACTIVE_JOB" ] || continue
            # A failed previous run is terminal; allow the new run to retry it.
            if ! wait_job "$ACTIVE_JOB" "$DEADLINE"; then
                STATUS=$(kubectl -n "$NS" get job "$ACTIVE_JOB" -o json)
                jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' <<<"$STATUS" >/dev/null || exit 1
            fi
        done <<<"$ACTIVE_JOBS"
        if jq -e '.spec.suspend == true' <<<"$JOB_JSON" >/dev/null; then
            log_warn "$NAME is suspended by configuration; skip initial run."
            exit 0
        fi
        kubectl -n "$NS" create job --from="cronjob/$NAME" "$NAME-initial" --dry-run=client -o json |
            jq --arg name "$NAME" 'del(.metadata.name, .metadata.ownerReferences) |
                .metadata.generateName = ($name + "-initial-") |
                .metadata.labels["mirror-jobs/name"] = $name' >temp/job-initial.json
        INITIAL_JOB=$(kubectl -n "$NS" create -f temp/job-initial.json -o jsonpath='{.metadata.name}')
        if ! wait_job "$INITIAL_JOB" "$((SECONDS + TIMEOUT))"; then
            log_reminder "CronJob $NAME remains suspended. Check: kubectl -n $NS logs job/$INITIAL_JOB --all-containers=true"
            exit 1
        fi
        kubectl -n "$NS" patch cronjob "$NAME" --type=merge -p '{"spec":{"suspend":false}}'
        log_trace "$NAME initial sync succeeded; schedule enabled."
    )
done
log_trace "install mirror jobs success!!!"
