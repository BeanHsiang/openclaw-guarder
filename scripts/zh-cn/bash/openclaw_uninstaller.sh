#!/usr/bin/env bash
# =============================================================================
# OpenClaw Uninstaller — Windows/Linux 完整卸载与残留清理脚本（Bash）
# =============================================================================
# 依据官方文档：https://docs.openclaw.ai/install/uninstall
#
# 目标：
#   1. 优先调用官方卸载命令（若 openclaw CLI 仍可用）
#   2. 手动停止并卸载 Gateway 服务（launchd）
#   3. 删除状态目录、profile 目录、自定义配置文件
#   4. 删除 CLI 全局安装（npm / pnpm / bun）
#   5. 删除 Windows/Linux App 与遗留目录：Application Support、Caches、Logs、Preferences 等
#
# 用法：
#   ./openclaw_uninstaller.sh                 # 仅扫描当前系统中的 OpenClaw 痕迹
#   ./openclaw_uninstaller.sh --dry-run       # 预览完整卸载动作，不实际删除
#   ./openclaw_uninstaller.sh --apply --yes   # 执行完整卸载（推荐自动化方式）
# =============================================================================

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  printf '\033[0;31m[ERROR]\033[0m 请使用 bash 运行本脚本：\n'
  printf '        bash %s\n' "$0"
  exit 1
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
log_ok()      { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
log_warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
log_error()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*"; }
log_section() { printf '\n%b\n' "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
                printf '%b\n' "${BOLD}  $*${RESET}"; \
                printf '%b\n' "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

DRY_RUN=false
APPLY=false
ASSUME_YES=false
REMOVE_CLI=true
REMOVE_APP=true
OPENCLAW_INSTALLED=false
OPENCLAW_VERSION=""
CURRENT_OS="$(uname -s)"

ACTION_DESCS=()
ACTION_CMDS=()
REGISTERED_PATHS=()

shell_quote() {
  printf '%q' "$1"
}

path_is_registered() {
  local target="$1"
  local existing
  for existing in "${REGISTERED_PATHS[@]}"; do
    [[ "$existing" == "$target" ]] && return 0
  done
  return 1
}

path_is_nested_in_registered_dir() {
  local target="$1"
  local existing
  for existing in "${REGISTERED_PATHS[@]}"; do
    case "$target" in
      "$existing"|"$existing"/*) return 0 ;;
    esac
  done
  return 1
}

queue_eval_action() {
  local description="$1"
  local command_str="$2"
  ACTION_DESCS+=("$description")
  ACTION_CMDS+=("$command_str")
}

register_removal_target() {
  local target="$1"
  local description="$2"

  [[ -n "$target" ]] || return 0
  [[ -e "$target" || -L "$target" ]] || return 0

  if path_is_registered "$target"; then
    return 0
  fi

  REGISTERED_PATHS+=("$target")
  queue_eval_action "$description" "rm -rf -- $(shell_quote "$target")"
}

register_systemd_unit_cleanup() {
  local unit_file="$1"
  local unit_name

  [[ -e "$unit_file" ]] || return 0
  unit_name="$(basename "$unit_file")"

  queue_eval_action \
    "卸载 systemd 用户服务：${unit_name}" \
    "systemctl --user disable --now $(shell_quote "$unit_name") >/dev/null 2>&1 || true"
  register_removal_target "$unit_file" "删除 systemd 用户单元文件：${unit_name}"
}

detect_openclaw_cli() {
  if command -v openclaw >/dev/null 2>&1; then
    OPENCLAW_VERSION="$(openclaw --version 2>&1 | head -1)"
    OPENCLAW_INSTALLED=true
    log_ok "检测到 openclaw CLI  →  ${OPENCLAW_VERSION}"
  else
    log_warn "未检测到 openclaw CLI，后续将使用手动清理方式"
  fi
}

collect_plugin_cleanup() {
  log_section "阶段 1 — 已安装插件卸载"

  if ! $OPENCLAW_INSTALLED; then
    log_info '未检测到 openclaw CLI，跳过插件卸载'
    return
  fi

  local installs_dump plugin_id
  installs_dump="$(openclaw config get plugins.installs 2>/dev/null || true)"

  if [[ -z "$installs_dump" ]]; then
    log_info '未检测到 plugins.installs 配置，跳过插件卸载'
    return
  fi

  local plugin_ids=()
  while IFS= read -r plugin_id; do
    [[ -n "$plugin_id" ]] || continue
    plugin_ids+=("$plugin_id")
  done < <(
    printf '%s\n' "$installs_dump" | awk '
      BEGIN { depth = 0 }
      {
        line = $0
        trimmed = line
        sub(/^[[:space:]]+/, "", trimmed)

        if (depth == 1 && trimmed ~ /^"?[A-Za-z0-9_@.\/:-]+"?[[:space:]]*:/) {
          key = trimmed
          sub(/[[:space:]]*:.*$/, "", key)
          gsub(/"/, "", key)
          print key
        }

        n = length(line)
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if (c == "{") depth++
          else if (c == "}") depth--
        }
      }
    ' | awk '!seen[$0]++'
  )

  if (( ${#plugin_ids[@]} == 0 )); then
    log_info '未解析到已安装插件 ID，跳过插件卸载'
    return
  fi

  for plugin_id in "${plugin_ids[@]}"; do
    queue_eval_action \
      "使用 OpenClaw CLI 卸载插件：${plugin_id}" \
      "openclaw plugins uninstall $(shell_quote "$plugin_id") >/dev/null 2>&1 || true"
  done
}

collect_gateway_cleanup() {
  log_section "阶段 2 — Gateway 服务与官方卸载流程"

  if $OPENCLAW_INSTALLED; then
    queue_eval_action \
      '停止 Gateway 服务（openclaw gateway stop）' \
      'openclaw gateway stop >/dev/null 2>&1 || true'
    queue_eval_action \
      '卸载 Gateway 服务（openclaw gateway uninstall）' \
      'openclaw gateway uninstall >/dev/null 2>&1 || true'
    queue_eval_action \
      '执行官方完整卸载（openclaw uninstall --all --yes --non-interactive）' \
      'openclaw uninstall --all --yes --non-interactive >/dev/null 2>&1 || true'
  fi

  if [[ "$CURRENT_OS" == 'Linux' ]]; then
    local unit_file
    local daemon_reload_needed=false
    shopt -s nullglob
    for unit_file in "$HOME/.config/systemd/user"/openclaw-gateway*.service; do
      register_systemd_unit_cleanup "$unit_file"
      daemon_reload_needed=true
    done
    shopt -u nullglob

    if $daemon_reload_needed; then
      queue_eval_action \
        '重载 systemd 用户服务配置' \
        'systemctl --user daemon-reload >/dev/null 2>&1 || true'
    fi
  fi

  if pgrep -qf 'openclaw.*(gateway|serve)' 2>/dev/null; then
    queue_eval_action \
      '结束残留 Gateway 进程' \
      "pkill -f 'openclaw.*(gateway|serve)' >/dev/null 2>&1 || true"
  fi
}

collect_state_cleanup() {
  log_section "阶段 3 — 状态目录、Profile 与自定义配置"

  local default_state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
  register_removal_target "$default_state_dir" "删除默认状态目录：${default_state_dir}"

  local profile_dir
  shopt -s nullglob
  for profile_dir in "$HOME"/.openclaw-*; do
    [[ -d "$profile_dir" ]] || continue
    register_removal_target "$profile_dir" "删除 Profile 状态目录：${profile_dir}"
  done
  shopt -u nullglob

  if [[ -n "${OPENCLAW_CONFIG_PATH:-}" ]]; then
    if [[ -e "$OPENCLAW_CONFIG_PATH" || -L "$OPENCLAW_CONFIG_PATH" ]]; then
      if path_is_nested_in_registered_dir "$OPENCLAW_CONFIG_PATH"; then
        log_info "自定义 OPENCLAW_CONFIG_PATH 已包含在待删除状态目录内：${OPENCLAW_CONFIG_PATH}"
      else
        register_removal_target "$OPENCLAW_CONFIG_PATH" "删除自定义配置文件：${OPENCLAW_CONFIG_PATH}"
      fi
    else
      log_warn "OPENCLAW_CONFIG_PATH 已设置但目标不存在：${OPENCLAW_CONFIG_PATH}"
    fi
  fi
}

collect_cli_cleanup() {
  log_section "阶段 4 — CLI 全局安装清理"

  if ! $REMOVE_CLI; then
    log_info "已指定 --keep-cli，跳过 CLI 清理"
    return
  fi

  if command -v npm >/dev/null 2>&1 && npm list -g --depth=0 openclaw >/dev/null 2>&1; then
    queue_eval_action \
      '卸载 npm 全局 openclaw' \
      'npm rm -g openclaw >/dev/null 2>&1 || true'
  fi

  if command -v pnpm >/dev/null 2>&1 && pnpm list -g --depth=0 openclaw >/dev/null 2>&1; then
    queue_eval_action \
      '卸载 pnpm 全局 openclaw' \
      'pnpm remove -g openclaw >/dev/null 2>&1 || true'
  fi

  if command -v bun >/dev/null 2>&1 && bun pm ls --global >/dev/null 2>&1; then
    if bun pm ls --global 2>/dev/null | grep -qE '(^|[[:space:]])openclaw@'; then
      queue_eval_action \
        '卸载 bun 全局 openclaw' \
        'bun remove -g openclaw >/dev/null 2>&1 || true'
    fi
  fi

  if command -v openclaw >/dev/null 2>&1; then
    log_info "当前 PATH 中仍可解析 openclaw：$(command -v openclaw)"
  fi
}

collect_shell_rc_cleanup() {
  log_section "阶段 5 — Shell 启动脚本残留清理"

  local rc_file
  for rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc_file" ]] || continue

    if grep -qiE 'openclaw|opennclaw' "$rc_file" 2>/dev/null; then
      queue_eval_action \
        "清理 $(basename "$rc_file") 中包含 openclaw / opennclaw 的行（大小写不敏感）" \
        "cp $(shell_quote "$rc_file") $(shell_quote "${rc_file}.bak.openclaw-uninstall.\$(date +%Y%m%d_%H%M%S)") && perl -i -ne 'print unless /openclaw|opennclaw/i' $(shell_quote "$rc_file")"
    fi
  done
}

collect_windows_linux_leftovers() {
  log_section "阶段 6 — Windows/Linux App 与遗留目录清理"

  if ! $REMOVE_APP; then
    log_info "已指定 --keep-app，跳过 App 与系统目录残留清理"
    return
  fi

  if [[ "$CURRENT_OS" != 'Linux' ]]; then
    log_info '当前系统不是 Linux / WSL，跳过常见 XDG 目录残留清理'
    return
  fi

  local path
  local app_paths=(
    "${XDG_CONFIG_HOME:-$HOME/.config}/OpenClaw"
    "${XDG_CONFIG_HOME:-$HOME/.config}/openclaw"
    "${XDG_CACHE_HOME:-$HOME/.cache}/OpenClaw"
    "${XDG_CACHE_HOME:-$HOME/.cache}/openclaw"
    "${XDG_DATA_HOME:-$HOME/.local/share}/OpenClaw"
    "${XDG_DATA_HOME:-$HOME/.local/share}/openclaw"
    "${XDG_STATE_HOME:-$HOME/.local/state}/OpenClaw"
    "${XDG_STATE_HOME:-$HOME/.local/state}/openclaw"
    "${XDG_DATA_HOME:-$HOME/.local/share}/applications/openclaw.desktop"
  )

  for path in "${app_paths[@]}"; do
    register_removal_target "$path" "删除 Windows/Linux 遗留路径：${path}"
  done
}

collect_all_actions() {
  detect_openclaw_cli
  collect_plugin_cleanup
  collect_gateway_cleanup
  collect_state_cleanup
  collect_cli_cleanup
  collect_shell_rc_cleanup
  collect_windows_linux_leftovers
}

print_scan_summary() {
  local total_actions="${#ACTION_CMDS[@]}"
  local total_paths="${#REGISTERED_PATHS[@]}"
  local i

  log_section "扫描结果汇总"
  printf '  检测到待删除路径：%s 个\n' "$total_paths"
  printf '  检测到待执行动作：%s 条\n\n' "$total_actions"

  if (( total_paths > 0 )); then
    printf '  路径列表：\n'
    for (( i = 0; i < total_paths; i++ )); do
      printf '    [%s] %s\n' "$(( i + 1 ))" "${REGISTERED_PATHS[$i]}"
    done
    printf '\n'
  else
    log_info '未检测到需要删除的文件或目录残留'
  fi

  if (( total_actions > 0 )); then
    printf '  动作列表：\n'
    for (( i = 0; i < total_actions; i++ )); do
      printf '    [%s] %s\n' "$(( i + 1 ))" "${ACTION_DESCS[$i]}"
      printf '         → %s\n' "${ACTION_CMDS[$i]}"
    done
  else
    log_info '未检测到可执行的卸载动作'
  fi
}

confirm_apply() {
  local answer

  $ASSUME_YES && return 0

  if [[ ! -t 0 ]]; then
    log_error '非交互模式下执行 --apply 时必须额外传入 --yes'
    return 1
  fi

  printf '\n'
  read -r -p '即将永久删除以上 OpenClaw 相关文件，是否继续？[y/N]: ' answer
  case "${answer:-N}" in
    y|Y|yes|YES) return 0 ;;
    *) log_warn '用户取消卸载'; return 1 ;;
  esac
}

run_actions() {
  local total="${#ACTION_CMDS[@]}"
  local i

  if (( total == 0 )); then
    log_info '没有需要执行的卸载动作'
    return 0
  fi

  if $DRY_RUN; then
    log_section 'DRY-RUN 预览完成'
    log_info '以上命令仅预览，未实际修改系统。使用 --apply --yes 执行完整卸载'
    return 0
  fi

  confirm_apply || return 1

  log_section '开始执行完整卸载'
  for (( i = 0; i < total; i++ )); do
    log_info "[$(( i + 1 ))/${total}] ${ACTION_DESCS[$i]}"
    if eval "${ACTION_CMDS[$i]}"; then
      log_ok '完成'
    else
      log_warn "执行失败，但脚本将继续：${ACTION_DESCS[$i]}"
    fi
  done

  log_ok 'OpenClaw 卸载流程执行结束'
  log_info '如你使用了自定义 workspace 仓库目录，请按需手动删除对应项目目录'
}

usage() {
  cat <<EOF
用法：$(basename "$0") [选项]

选项：
  （无参数）      仅扫描 OpenClaw 痕迹，不做修改
  --dry-run      预览完整卸载动作，不实际删除
  --apply        执行完整卸载
  --yes          与 --apply 搭配使用，跳过二次确认
  --keep-cli     保留 npm / pnpm / bun 安装的 openclaw CLI
  --keep-app     保留 Windows/Linux 下的常见 XDG 配置、缓存与桌面入口残留
  --help, -h     显示帮助信息

环境变量：
  OPENCLAW_STATE_DIR     指定非默认状态目录（默认：~/.openclaw）
  OPENCLAW_CONFIG_PATH   指定自定义配置文件路径；若位于状态目录之外也会被清理

示例：
  ./openclaw_uninstaller.sh
  ./openclaw_uninstaller.sh --dry-run
  ./openclaw_uninstaller.sh --apply --yes
  ./openclaw_uninstaller.sh --apply --yes --keep-cli
EOF
}

main() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      --apply) APPLY=true ;;
      --yes) ASSUME_YES=true ;;
      --keep-cli) REMOVE_CLI=false ;;
      --keep-app) REMOVE_APP=false ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "未知参数：${arg}"; usage; exit 1 ;;
    esac
  done

  if $DRY_RUN && $APPLY; then
    log_error '--dry-run 与 --apply 不能同时使用'
    exit 1
  fi

  printf '%b\n' "${BOLD}${CYAN}"
  printf '%s\n' '╔══════════════════════════════════════════╗'
  printf '%s\n' '║       OpenClaw Complete Uninstaller      ║'
  printf '%b\n' "╚══════════════════════════════════════════╝${RESET}"
  printf '  系统：%s\n' "$CURRENT_OS"
  if $DRY_RUN; then
    printf '  模式：DRY-RUN（预览）\n'
  elif $APPLY; then
    printf '  模式：APPLY（执行卸载）\n'
  else
    printf '  模式：SCAN（仅扫描）\n'
  fi
  printf '  时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

  collect_all_actions
  print_scan_summary

  if $APPLY || $DRY_RUN; then
    run_actions
  else
    log_section '提示'
    log_info '仅完成扫描。使用 --dry-run 预览卸载动作，或使用 --apply --yes 执行完整卸载'
  fi
}

main "$@"