#!/usr/bin/env zsh
# =============================================================================
# OpenClaw Uninstaller — macOS 完整卸载与残留清理脚本
# =============================================================================
# 依据官方文档：https://docs.openclaw.ai/install/uninstall
#
# 目标：
#   1. 优先调用官方卸载命令（若 openclaw CLI 仍可用）
#   2. 手动停止并卸载 Gateway 服务（launchd）
#   3. 删除状态目录、profile 目录、自定义配置文件
#   4. 删除 CLI 全局安装（npm / pnpm / bun）
#   5. 删除 macOS App 与遗留目录：Application Support、Caches、Logs、Preferences 等
#
# 用法：
#   ./openclaw_uninstaller.sh                 # 仅扫描当前系统中的 OpenClaw 痕迹
#   ./openclaw_uninstaller.sh --dry-run       # 预览完整卸载动作，不实际删除
#   ./openclaw_uninstaller.sh --apply --yes   # 执行完整卸载（推荐自动化方式）
# =============================================================================

set -euo pipefail

if [ -z "${ZSH_VERSION:-}" ]; then
  printf '\033[0;31m[ERROR]\033[0m 请使用 zsh 运行本脚本：\n'
  printf '        zsh %s\n' "$0"
  exit 1
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { print -P "%F{cyan}[INFO]%f  $*"; }
log_ok()      { print -P "%F{green}[OK]%f    $*"; }
log_warn()    { print -P "%F{yellow}[WARN]%f  $*"; }
log_error()   { print -P "%F{red}[ERROR]%f $*"; }
log_section() { print "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
                print "${BOLD}  $*${RESET}"; \
                print "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

DRY_RUN=false
APPLY=false
ASSUME_YES=false
REMOVE_CLI=true
REMOVE_APP=true
OPENCLAW_INSTALLED=false
OPENCLAW_VERSION=""
CURRENT_OS="$(uname -s)"

typeset -a ACTION_DESCS=()
typeset -a ACTION_CMDS=()
typeset -a REGISTERED_PATHS=()

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

register_launch_agent_cleanup() {
  local plist="$1"
  local label

  [[ -e "$plist" ]] || return 0
  label="$(basename "$plist" .plist)"

  queue_eval_action \
    "卸载 launchd 服务：${label}" \
    "launchctl bootout gui/$UID/$(shell_quote "$label") >/dev/null 2>&1 || true"
  register_removal_target "$plist" "删除 LaunchAgent 文件：${label}.plist"
}

detect_openclaw_cli() {
  if command -v openclaw &>/dev/null; then
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

  local -a plugin_ids=()
  while IFS= read -r plugin_id; do
    [[ -n "$plugin_id" ]] || continue
    plugin_ids+=("$plugin_id")
  done < <(
    print -r -- "$installs_dump" | awk '
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

  if [[ "$CURRENT_OS" == 'Darwin' ]]; then
    local plist
    for plist in "${HOME}"/Library/LaunchAgents/ai.openclaw*.plist(N) "${HOME}"/Library/LaunchAgents/com.openclaw*.plist(N); do
      register_launch_agent_cleanup "$plist"
    done
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
  for profile_dir in "${HOME}"/.openclaw-*(N); do
    [[ -d "$profile_dir" ]] || continue
    register_removal_target "$profile_dir" "删除 Profile 状态目录：${profile_dir}"
  done

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

  if command -v npm &>/dev/null && npm list -g --depth=0 openclaw >/dev/null 2>&1; then
    queue_eval_action \
      '卸载 npm 全局 openclaw' \
      'npm rm -g openclaw >/dev/null 2>&1 || true'
  fi

  if command -v pnpm &>/dev/null && pnpm list -g --depth=0 openclaw >/dev/null 2>&1; then
    queue_eval_action \
      '卸载 pnpm 全局 openclaw' \
      'pnpm remove -g openclaw >/dev/null 2>&1 || true'
  fi

  if command -v bun &>/dev/null && bun pm ls --global >/dev/null 2>&1; then
    if bun pm ls --global 2>/dev/null | grep -qE '(^|[[:space:]])openclaw@'; then
      queue_eval_action \
        '卸载 bun 全局 openclaw' \
        'bun remove -g openclaw >/dev/null 2>&1 || true'
    fi
  fi

  if command -v openclaw &>/dev/null; then
    log_info "当前 PATH 中仍可解析 openclaw：$(command -v openclaw)"
  fi
}

collect_shell_rc_cleanup() {
  log_section "阶段 5 — Shell 启动脚本残留清理"

  local rc_file
  for rc_file in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
    [[ -f "$rc_file" ]] || continue

    if grep -qiE 'openclaw|opennclaw' "$rc_file" 2>/dev/null; then
      queue_eval_action \
        "清理 $(basename "$rc_file") 中包含 openclaw / opennclaw 的行（大小写不敏感）" \
        "cp $(shell_quote "$rc_file") $(shell_quote "${rc_file}.bak.openclaw-uninstall.\$(date +%Y%m%d_%H%M%S)") && perl -i -ne 'print unless /openclaw|opennclaw/i' $(shell_quote "$rc_file")"
    fi
  done
}

collect_macos_leftovers() {
  log_section "阶段 6 — macOS App 与遗留目录清理"

  if ! $REMOVE_APP; then
    log_info "已指定 --keep-app，跳过 App 与系统目录残留清理"
    return
  fi

  if [[ "$CURRENT_OS" != 'Darwin' ]]; then
    log_info '当前系统不是 macOS，跳过 Application Support / Caches 等目录清理'
    return
  fi

  local path
  local -a app_paths=(
    '/Applications/OpenClaw.app'
    "${HOME}/Applications/OpenClaw.app"
    "${HOME}/Library/Application Support/OpenClaw"
    "${HOME}/Library/Application Support/ai.openclaw.OpenClaw"
    "${HOME}/Library/Application Support/com.openclaw.OpenClaw"
    "${HOME}/Library/Caches/OpenClaw"
    "${HOME}/Library/Caches/ai.openclaw.OpenClaw"
    "${HOME}/Library/Caches/com.openclaw.OpenClaw"
    "${HOME}/Library/Logs/OpenClaw"
    "${HOME}/Library/Logs/ai.openclaw.OpenClaw"
    "${HOME}/Library/Preferences/ai.openclaw.OpenClaw.plist"
    "${HOME}/Library/Preferences/com.openclaw.OpenClaw.plist"
    "${HOME}/Library/Saved Application State/ai.openclaw.OpenClaw.savedState"
    "${HOME}/Library/Saved Application State/com.openclaw.OpenClaw.savedState"
    "${HOME}/Library/HTTPStorages/ai.openclaw.OpenClaw"
    "${HOME}/Library/HTTPStorages/ai.openclaw.OpenClaw.binarycookies"
    "${HOME}/Library/WebKit/ai.openclaw.OpenClaw"
  )

  for path in "${app_paths[@]}"; do
    register_removal_target "$path" "删除 macOS 遗留路径：${path}"
  done
}

collect_all_actions() {
  detect_openclaw_cli
  collect_plugin_cleanup
  collect_gateway_cleanup
  collect_state_cleanup
  collect_cli_cleanup
  collect_shell_rc_cleanup
  collect_macos_leftovers
}

print_scan_summary() {
  local total_actions="${#ACTION_CMDS[@]}"
  local total_paths="${#REGISTERED_PATHS[@]}"
  local i

  log_section "扫描结果汇总"
  print "  检测到待删除路径：${total_paths} 个"
  print "  检测到待执行动作：${total_actions} 条"
  print ""

  if (( total_paths > 0 )); then
    print '  路径列表：'
    for (( i = 1; i <= total_paths; i++ )); do
      print "    [${i}] ${REGISTERED_PATHS[$i]}"
    done
    print ''
  else
    log_info '未检测到需要删除的文件或目录残留'
  fi

  if (( total_actions > 0 )); then
    print '  动作列表：'
    for (( i = 1; i <= total_actions; i++ )); do
      print "    [${i}] ${ACTION_DESCS[$i]}"
      print "         → ${ACTION_CMDS[$i]}"
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

  print ''
  read "answer?即将永久删除以上 OpenClaw 相关文件，是否继续？[y/N]: "
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
  for (( i = 1; i <= total; i++ )); do
    log_info "[${i}/${total}] ${ACTION_DESCS[$i]}"
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
  --keep-app     保留 OpenClaw.app 与 macOS Application Support / Caches 等目录
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

  print "${BOLD}${CYAN}"
  print '╔══════════════════════════════════════════╗'
  print '║       OpenClaw Complete Uninstaller      ║'
  print "╚══════════════════════════════════════════╝${RESET}"
  print "  系统：${CURRENT_OS}"
  print "  模式：$(if $DRY_RUN; then print 'DRY-RUN（预览）'; elif $APPLY; then print 'APPLY（执行卸载）'; else print 'SCAN（仅扫描）'; fi)"
  print "  时间：$(date '+%Y-%m-%d %H:%M:%S')\n"

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