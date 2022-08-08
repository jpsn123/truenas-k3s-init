#!/bin/bash
## scripts/deploy/values.sh — jutze-deploy values 渲染约定。
## deploy_render_values <file>...
##   渲染到各文件所在目录的 temp/ 子目录:<dirname>/temp/<basename>;
##   未定义占位符默认保留(--missing=keep);不向 stdout 输出内容。
## 注意:局部变量用 _deploy_values_ 前缀小写名——本函数位于 template_render
## 调用链上,大写局部名会在间接展开时遮蔽同名模板变量(如 ${FILE})。

if [[ -n "${_VALUES_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/paths.sh" || return 1
source "$DEPLOY_LIB_DIR/liblog.sh" || return 1
source "$DEPLOY_LIB_DIR/libtemplate.sh" || return 1

function deploy_render_values() {
    local _deploy_values_file=""
    local _deploy_values_dir=""
    local _deploy_values_out=""
    for _deploy_values_file in "$@"; do
        if [ -z "$_deploy_values_file" ]; then
            log_error "deploy_render_values: empty file name."
            return 1
        fi
        if [ ! -f "$_deploy_values_file" ] || [ ! -r "$_deploy_values_file" ]; then
            log_error "deploy_render_values: values file not readable: $_deploy_values_file"
            return 1
        fi
        _deploy_values_dir=$(dirname -- "$_deploy_values_file")/temp
        _deploy_values_out=$_deploy_values_dir/$(basename -- "$_deploy_values_file")
        mkdir -p "$_deploy_values_dir" || {
            log_error "deploy_render_values: cannot create directory: $_deploy_values_dir"
            return 1
        }
        template_render "$_deploy_values_file" "$_deploy_values_out" || return 1
        log_info "rendered values file: $_deploy_values_out"
    done
}

_VALUES_SOURCED=1
