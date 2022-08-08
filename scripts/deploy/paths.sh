#!/bin/bash
## scripts/deploy/paths.sh — jutze-deploy 仓库路径只读常量。
## DEPLOY_ROOT: 仓库根目录;DEPLOY_LIB_DIR: <root>/scripts/lib。
## 只做定位,不加载模块、不 source parameter.sh、不改变 cwd。source 无副作用。

if [[ -n "${_PATHS_SOURCED:-}" ]]; then
    return 0
fi

DEPLOY_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P) || return 1
readonly DEPLOY_ROOT

DEPLOY_LIB_DIR=$DEPLOY_ROOT/scripts/lib
readonly DEPLOY_LIB_DIR

_PATHS_SOURCED=1
