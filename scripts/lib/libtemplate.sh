#!/bin/bash
## libtemplate.sh — shell 变量模板渲染库,可独立分发。
## template_render <input> <output> [--missing=keep|error]
##   仅替换 ${[A-Z_][A-Z0-9_]*},调用方 shell 变量为输入来源;已定义空值替换为空,
##   未定义 keep 保留 / error 失败。值按字面量处理(无 eval、不二次展开);
##   行内 $lower、$VAR 等非占位 $ 不阻断后续扫描。输出经同目录临时文件原子 mv,
##   保留 mktemp 的 0600 权限(渲染结果可能含密钥);无换行的末行也会被处理。
## 注意:局部变量一律用 _libtemplate_ 前缀小写名,避免间接展开 ${!name} 被
## 调用方同名大写变量(INPUT/OUTPUT/FILE 等)冲突遮蔽。source 无副作用。

if [[ -n "${_LIB_TEMPLATE_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/liblog.sh" || return 1

function template_render() {
    local _libtemplate_input="${1:-}"
    local _libtemplate_output="${2:-}"
    local _libtemplate_option="${3:-}"
    local _libtemplate_missing="keep"
    local _libtemplate_dir=""
    local _libtemplate_tmp=""
    local _libtemplate_line=""
    local _libtemplate_out=""
    local _libtemplate_rest=""
    local _libtemplate_prefix=""
    local _libtemplate_token=""
    local _libtemplate_name=""
    local _libtemplate_dollar='$'

    case "$_libtemplate_option" in
    "" | --missing=keep)
        _libtemplate_missing="keep"
        ;;
    --missing=error)
        _libtemplate_missing="error"
        ;;
    *)
        log_error "template_render: unknown option: $_libtemplate_option"
        return 1
        ;;
    esac
    if [ -z "$_libtemplate_input" ] || [ -z "$_libtemplate_output" ]; then
        log_error "template_render: input and output are required."
        return 1
    fi
    if [ ! -f "$_libtemplate_input" ] || [ ! -r "$_libtemplate_input" ]; then
        log_error "template_render: input file not readable: $_libtemplate_input"
        return 1
    fi

    _libtemplate_dir=$(dirname -- "$_libtemplate_output")
    _libtemplate_tmp=$(mktemp "$_libtemplate_dir/.template_render.XXXXXX") || {
        log_error "template_render: cannot create temp file in $_libtemplate_dir"
        return 1
    }

    # 逐行扫描:优先尝试在第一个 '$' 处匹配占位符;匹配失败则跳过该 '$'
    # 继续向后扫描,因此非占位的 $lower/$VAR 不会阻断后续 ${UPPER}。
    while IFS= read -r _libtemplate_line || [ -n "$_libtemplate_line" ]; do
        _libtemplate_out=""
        _libtemplate_rest="$_libtemplate_line"
        while [ -n "$_libtemplate_rest" ]; do
            if [[ $_libtemplate_rest =~ ^([^$]*)(\$\{[A-Z_][A-Z0-9_]*\})(.*)$ ]]; then
                _libtemplate_out+="${BASH_REMATCH[1]}"
                _libtemplate_token="${BASH_REMATCH[2]}"
                _libtemplate_name="${_libtemplate_token:2:${#_libtemplate_token}-3}"
                if [[ -v "$_libtemplate_name" ]]; then
                    _libtemplate_out+="${!_libtemplate_name}"
                else
                    if [ "$_libtemplate_missing" == "error" ]; then
                        log_error "template_render: undefined variable $_libtemplate_token in $_libtemplate_input"
                        rm -f "$_libtemplate_tmp"
                        return 1
                    fi
                    _libtemplate_out+="$_libtemplate_token"
                fi
                _libtemplate_rest="${BASH_REMATCH[3]}"
            elif [[ $_libtemplate_rest == *"$_libtemplate_dollar"* ]]; then
                _libtemplate_prefix="${_libtemplate_rest%%"$_libtemplate_dollar"*}"
                _libtemplate_out+="$_libtemplate_prefix$_libtemplate_dollar"
                _libtemplate_rest="${_libtemplate_rest#*"$_libtemplate_dollar"}"
            else
                _libtemplate_out+="$_libtemplate_rest"
                _libtemplate_rest=""
            fi
        done
        printf '%s\n' "$_libtemplate_out"
    done <"$_libtemplate_input" >"$_libtemplate_tmp" || {
        rm -f "$_libtemplate_tmp"
        log_error "template_render: failed to render $_libtemplate_input"
        return 1
    }

    if ! mv -f "$_libtemplate_tmp" "$_libtemplate_output"; then
        log_error "template_render: failed to write output: $_libtemplate_output"
        rm -f "$_libtemplate_tmp"
        return 1
    fi
}

_LIB_TEMPLATE_SOURCED=1
