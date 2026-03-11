#!/usr/bin/env zsh
# Generated English version of openclaw_uninstaller.sh — do not overwrite the original.
# =============================================================================
# OpenClaw Uninstaller — complete macOS uninstall and leftover cleanup script
# =============================================================================
# Based on the official docs: https://docs.openclaw.ai/install/uninstall
#
# Goals:
#   1. Prefer the official uninstaller when the openclaw CLI is still available
#   2. Stop and uninstall the Gateway service manually when needed
#   3. Remove state directories, profile directories, and custom config files
#   4. Remove the global CLI install (npm / pnpm / bun)
#   5. Remove macOS app leftovers: Application Support, Caches, Logs, Preferences, etc.
#
# Usage:
#   ./openclaw_uninstaller.sh                 # scan only
#   ./openclaw_uninstaller.sh --dry-run       # preview the full uninstall plan
#   ./openclaw_uninstaller.sh --apply --yes   # perform the full uninstall
# =============================================================================

set -euo pipefail

if [ -z "${ZSH_VERSION:-}" ]; then
  printf '\033[0;31m[ERROR]\033[0m Please run this script with zsh:\n'
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
    "Unload launchd service: ${label}" \
    "launchctl bootout gui/$UID/$(shell_quote "$label") >/dev/null 2>&1 || true"
  register_removal_target "$plist" "Delete LaunchAgent file: ${label}.plist"
}

detect_openclaw_cli() {
  if command -v openclaw &>/dev/null; then
    OPENCLAW_VERSION="$(openclaw --version 2>&1 | head -1)"
    OPENCLAW_INSTALLED=true
    log_ok "Detected openclaw CLI  →  ${OPENCLAW_VERSION}"
  else
    log_warn "openclaw CLI not found; manual cleanup will be used"
  fi
}

collect_plugin_cleanup() {
  log_section "Phase 1 — Uninstall installed plugins"

  if ! $OPENCLAW_INSTALLED; then
    log_info 'openclaw CLI not found; skipping plugin uninstall'
    return
  fi

  local installs_dump plugin_id
  installs_dump="$(openclaw config get plugins.installs 2>/dev/null || true)"

  if [[ -z "$installs_dump" ]]; then
    log_info 'No plugins.installs config detected; skipping plugin uninstall'
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
    log_info 'No installed plugin IDs were parsed; skipping plugin uninstall'
    return
  fi

  for plugin_id in "${plugin_ids[@]}"; do
    queue_eval_action \
      "Uninstall plugin via OpenClaw CLI: ${plugin_id}" \
      "openclaw plugins uninstall $(shell_quote "$plugin_id") >/dev/null 2>&1 || true"
  done
}

collect_gateway_cleanup() {
  log_section "Phase 2 — Gateway service and official uninstall flow"

  if $OPENCLAW_INSTALLED; then
    queue_eval_action \
      'Stop Gateway service (openclaw gateway stop)' \
      'openclaw gateway stop >/dev/null 2>&1 || true'
    queue_eval_action \
      'Uninstall Gateway service (openclaw gateway uninstall)' \
      'openclaw gateway uninstall >/dev/null 2>&1 || true'
    queue_eval_action \
      'Run official full uninstall (openclaw uninstall --all --yes --non-interactive)' \
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
      'Terminate leftover Gateway processes' \
      "pkill -f 'openclaw.*(gateway|serve)' >/dev/null 2>&1 || true"
  fi
}

collect_state_cleanup() {
  log_section "Phase 3 — State directories, profiles, and custom config"

  local default_state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
  register_removal_target "$default_state_dir" "Delete default state directory: ${default_state_dir}"

  local profile_dir
  for profile_dir in "${HOME}"/.openclaw-*(N); do
    [[ -d "$profile_dir" ]] || continue
    register_removal_target "$profile_dir" "Delete profile state directory: ${profile_dir}"
  done

  if [[ -n "${OPENCLAW_CONFIG_PATH:-}" ]]; then
    if [[ -e "$OPENCLAW_CONFIG_PATH" || -L "$OPENCLAW_CONFIG_PATH" ]]; then
      if path_is_nested_in_registered_dir "$OPENCLAW_CONFIG_PATH"; then
        log_info "Custom OPENCLAW_CONFIG_PATH is already covered by a state directory removal: ${OPENCLAW_CONFIG_PATH}"
      else
        register_removal_target "$OPENCLAW_CONFIG_PATH" "Delete custom config file: ${OPENCLAW_CONFIG_PATH}"
      fi
    else
      log_warn "OPENCLAW_CONFIG_PATH is set but the target does not exist: ${OPENCLAW_CONFIG_PATH}"
    fi
  fi
}

collect_cli_cleanup() {
  log_section "Phase 4 — Global CLI cleanup"

  if ! $REMOVE_CLI; then
    log_info "--keep-cli specified; skipping CLI cleanup"
    return
  fi

  if command -v npm &>/dev/null && npm list -g --depth=0 openclaw >/dev/null 2>&1; then
    queue_eval_action \
      'Remove global openclaw from npm' \
      'npm rm -g openclaw >/dev/null 2>&1 || true'
  fi

  if command -v pnpm &>/dev/null && pnpm list -g --depth=0 openclaw >/dev/null 2>&1; then
    queue_eval_action \
      'Remove global openclaw from pnpm' \
      'pnpm remove -g openclaw >/dev/null 2>&1 || true'
  fi

  if command -v bun &>/dev/null && bun pm ls --global >/dev/null 2>&1; then
    if bun pm ls --global 2>/dev/null | grep -qE '(^|[[:space:]])openclaw@'; then
      queue_eval_action \
        'Remove global openclaw from bun' \
        'bun remove -g openclaw >/dev/null 2>&1 || true'
    fi
  fi
}

collect_shell_rc_cleanup() {
  log_section "Phase 5 — Shell startup file cleanup"

  local rc_file
  for rc_file in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
    [[ -f "$rc_file" ]] || continue

    if grep -qiE 'openclaw|opennclaw' "$rc_file" 2>/dev/null; then
      queue_eval_action \
        "Remove case-insensitive openclaw / opennclaw lines from $(basename "$rc_file")" \
        "cp $(shell_quote "$rc_file") $(shell_quote "${rc_file}.bak.openclaw-uninstall.\$(date +%Y%m%d_%H%M%S)") && perl -i -ne 'print unless /openclaw|opennclaw/i' $(shell_quote "$rc_file")"
    fi
  done
}

collect_macos_leftovers() {
  log_section "Phase 6 — macOS app and leftover directories"

  if ! $REMOVE_APP; then
    log_info "--keep-app specified; skipping app and system leftover cleanup"
    return
  fi

  if [[ "$CURRENT_OS" != 'Darwin' ]]; then
    log_info 'Not running on macOS; skipping Application Support / Caches cleanup'
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
    register_removal_target "$path" "Delete macOS leftover path: ${path}"
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

  log_section "Scan summary"
  print "  Paths queued for deletion: ${total_paths}"
  print "  Actions queued: ${total_actions}"
  print ""

  if (( total_paths > 0 )); then
    print '  Paths:'
    for (( i = 1; i <= total_paths; i++ )); do
      print "    [${i}] ${REGISTERED_PATHS[$i]}"
    done
    print ''
  else
    log_info 'No removable files or directories were detected'
  fi

  if (( total_actions > 0 )); then
    print '  Actions:'
    for (( i = 1; i <= total_actions; i++ )); do
      print "    [${i}] ${ACTION_DESCS[$i]}"
      print "         → ${ACTION_CMDS[$i]}"
    done
  else
    log_info 'No uninstall actions were queued'
  fi
}

confirm_apply() {
  local answer

  $ASSUME_YES && return 0

  if [[ ! -t 0 ]]; then
    log_error 'When using --apply in non-interactive mode, you must also pass --yes'
    return 1
  fi

  print ''
  read "answer?This will permanently remove the OpenClaw files above. Continue? [y/N]: "
  case "${answer:-N}" in
    y|Y|yes|YES) return 0 ;;
    *) log_warn 'Uninstall cancelled by user'; return 1 ;;
  esac
}

run_actions() {
  local total="${#ACTION_CMDS[@]}"
  local i

  if (( total == 0 )); then
    log_info 'There are no uninstall actions to execute'
    return 0
  fi

  if $DRY_RUN; then
    log_section 'DRY-RUN preview complete'
    log_info 'Nothing was modified. Use --apply --yes to run the full uninstall'
    return 0
  fi

  confirm_apply || return 1

  log_section 'Starting full uninstall'
  for (( i = 1; i <= total; i++ )); do
    log_info "[${i}/${total}] ${ACTION_DESCS[$i]}"
    if eval "${ACTION_CMDS[$i]}"; then
      log_ok 'Done'
    else
      log_warn "Action failed, but the script will continue: ${ACTION_DESCS[$i]}"
    fi
  done

  log_ok 'OpenClaw uninstall flow finished'
  log_info 'If you used a custom workspace repository, delete that repository directory manually if you no longer need it'
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  no args         Scan for OpenClaw leftovers only
  --dry-run       Preview the full uninstall plan without deleting anything
  --apply         Perform the full uninstall
  --yes           Use with --apply to skip the confirmation prompt
  --keep-cli      Keep the global openclaw CLI installed via npm / pnpm / bun
  --keep-app      Keep OpenClaw.app and macOS Application Support / Caches leftovers
  --help, -h      Show this help text

Environment variables:
  OPENCLAW_STATE_DIR     Non-default state directory (default: ~/.openclaw)
  OPENCLAW_CONFIG_PATH   Custom config file path; if it lives outside the state dir it will also be removed

Examples:
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
      *) log_error "Unknown argument: ${arg}"; usage; exit 1 ;;
    esac
  done

  if $DRY_RUN && $APPLY; then
    log_error '--dry-run and --apply cannot be used together'
    exit 1
  fi

  print "${BOLD}${CYAN}"
  print '╔══════════════════════════════════════════╗'
  print '║       OpenClaw Complete Uninstaller      ║'
  print "╚══════════════════════════════════════════╝${RESET}"
  print "  System: ${CURRENT_OS}"
  print "  Mode: $(if $DRY_RUN; then print 'DRY-RUN'; elif $APPLY; then print 'APPLY'; else print 'SCAN'; fi)"
  print "  Time: $(date '+%Y-%m-%d %H:%M:%S')\n"

  collect_all_actions
  print_scan_summary

  if $APPLY || $DRY_RUN; then
    run_actions
  else
    log_section 'Hint'
    log_info 'Scan only completed. Use --dry-run to preview, or --apply --yes to perform the full uninstall'
  fi
}

main "$@"