#!/bin/bash
set -e

cd "$(dirname "$0")"
source ../../common.sh
source ../../parameter.sh

NS=coder
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" postgresql coder

## initial
#####################################
log_header "initial"
kubectl create namespace "$NS" 2>/dev/null || true
# db_pw
load_secret_vars "$NS" "postgresql" password=DB_PW
if (install_mode_enabled "$INSTALL_MODE" postgresql || install_mode_enabled "$INSTALL_MODE" coder) && [ -z "$DB_PW" ]; then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
    DB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@db" 32)
fi
if install_mode_enabled "$INSTALL_MODE" coder; then
    # oidc config
    load_secret_vars "$NS" "coder-oidc" \
        client-id=OIDC_CLIENT_ID \
        client-secret=OIDC_CLIENT_SECRET \
        email-domain=OIDC_EMAIL_DOMAIN \
        sign-in-text=OIDC_SIGN_IN_TEXT \
        icon-url=OIDC_ICON_URL
    if [ -z "$OIDC_CLIENT_ID" ]; then
        OIDC_CLIENT_ID=$(prompt_required "please input coder oidc client id and client secret." "oidc client id" "")
    fi
    if [ -z "$OIDC_CLIENT_SECRET" ]; then
        OIDC_CLIENT_SECRET=$(prompt_required "" "oidc client secret" -s)
    fi
    if [ -z "$OIDC_EMAIL_DOMAIN" ]; then
        OIDC_EMAIL_DOMAIN=$(prompt_required "please input coder oidc config." "oidc email domain" "")
    fi
    if [ -z "$OIDC_SIGN_IN_TEXT" ]; then
        OIDC_SIGN_IN_TEXT=$(prompt_required "" "oidc sign in text" "")
    fi
    if [ -z "$OIDC_ICON_URL" ]; then
        OIDC_ICON_URL=$(prompt_required "" "oidc icon url" "")
    fi
    apply_secret_vars "$NS" "coder-oidc" \
        client-id=OIDC_CLIENT_ID \
        client-secret=OIDC_CLIENT_SECRET \
        email-domain=OIDC_EMAIL_DOMAIN \
        sign-in-text=OIDC_SIGN_IN_TEXT \
        icon-url=OIDC_ICON_URL
    # code-server jfrog mirror config
    load_secret_vars "$NS" "coder-code-server-jfrog" \
        mirror-url=CODE_SERVER_MIRROR_URL \
        token=JFROG_TOKEN
    if [ -z "$CODE_SERVER_MIRROR_URL" ]; then
        CODE_SERVER_MIRROR_URL=$(prompt_with_default "please input code-server jfrog mirror config." "jfrog mirror url including repository path" "https://bin.$DOMAIN/artifactory/general/mirrors/code-server")
    fi
    CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL%/}"
    if [ -z "$JFROG_TOKEN" ]; then
        JFROG_TOKEN=$(prompt_required "" "jfrog token for code-server mirror" -s)
    fi
    apply_secret_vars "$NS" "coder-code-server-jfrog" \
        mirror-url=CODE_SERVER_MIRROR_URL \
        token=JFROG_TOKEN
    # code-server jfrog sync job
    apply_configmap "$NS" "coder-code-server-jfrog-sync" --from-file=sync-code-server-to-jfrog.sh=code-server-jfrog-sync.sh
    render_values_file_to_temp values-sync-job.yaml
    kubectl apply -f temp/values-sync-job.yaml
    kubectl -n "$NS" create job --from=cronjob/code-server-jfrog-sync "code-server-jfrog-sync-$(date +%s)" 2>/dev/null || true
    # terraform provider mirror config
    TERRAFORM_RC_CONTENT=$(get_configmap_value "$NS" "coder-terraformrc" ".terraformrc")
    if [ -n "$TERRAFORM_RC_CONTENT" ]; then
        log_info "reuse existing terraform provider mirror config."
    else
        ENABLE_TERRAFORM_MIRROR=$(prompt_with_default "please select terraform provider mirror config." "enable terraform provider mirror? (y/n)" "n")
        TERRAFORM_RC=$(mktemp) || exit 1
        if [[ "$ENABLE_TERRAFORM_MIRROR" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            TERRAFORM_MIRROR_URL=$(prompt_with_default "" "terraform provider mirror url" "https://bin.$DOMAIN/artifactory/api/terraform/terraform/providers/")
            cat >"$TERRAFORM_RC" <<EOF
provider_installation {
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }

  network_mirror {
    url = "$TERRAFORM_MIRROR_URL"
  }
}
EOF
        else
            : >"$TERRAFORM_RC"
        fi
        apply_configmap "$NS" "coder-terraformrc" --from-file=.terraformrc="$TERRAFORM_RC" || { rm -f "$TERRAFORM_RC"; exit 1; }
        rm -f "$TERRAFORM_RC"
    fi
    # coder patch script
    apply_configmap "$NS" "coder-patch" --from-file=patch.py=patch.py --from-file=public.key=public.key
    if [ "$INSTALL_MODE" != "reinstall" ]; then
        read -r CODER_CHART_VERSION DEFAULT_CODER_APP_VERSION <<<"$(get_helm_chart_versions "coder-v2" "https://helm.coder.com/v2" "coder")"
        CODER_APP_VERSION=$(prompt_with_default "" "coder app version" "$DEFAULT_CODER_APP_VERSION")
        if [ "$CODER_APP_VERSION" != "$DEFAULT_CODER_APP_VERSION" ]; then
            read -r CODER_CHART_VERSION _ <<<"$(get_helm_chart_versions "coder-v2" "https://helm.coder.com/v2" "coder" "$CODER_APP_VERSION")"
        fi
    else
        ensure_helm_repo_chart "coder-v2" "https://helm.coder.com/v2" "coder"
        resolve_chart_app_version "coder" CODER_CHART_VERSION CODER_APP_VERSION
    fi
    CODER_IMAGE=ghcr.io/coder/coder:v"$CODER_APP_VERSION"
fi
render_values_file_to_temp values-*.yaml

## install postgresql
#####################################
if install_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "16.7.27"
    helm upgrade --install -n "$NS" postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set-string global.postgresql.auth.postgresPassword="$DB_PW" \
        --set-string global.postgresql.auth.password="$DB_PW" \
        --set-string auth.replicationPassword="$DB_PW"
fi

## create coder secret
#####################################
if install_mode_enabled "$INSTALL_MODE" coder; then
    log_header "create coder secret"
    PG_CONNECTION_URL="postgres://coder:$DB_PW@postgresql:5432/coder?sslmode=disable"
    apply_secret_vars "$NS" "coder-db-url" url=PG_CONNECTION_URL
fi

## install coder
#####################################
if install_mode_enabled "$INSTALL_MODE" coder; then
    log_header "install coder"
    kubectl apply -n "$NS" -f temp/values-tls.yaml
    ensure_helm_repo_chart "coder-v2" "https://helm.coder.com/v2" "coder" "$CODER_CHART_VERSION"
    helm upgrade --install -n "$NS" coder temp/coder --wait --timeout 600s -f temp/values-coder.yaml
fi

## done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://dev.$DOMAIN"
