#!/usr/bin/env zsh
# Generated English version of openclaw_guarder.sh — do not overwrite the original.
# =============================================================================
# OpenClaw Guarder — macOS security hardening and configuration checker (Zsh)
# =============================================================================
# Purpose: verify environment dependencies, validate OpenClaw installation status,
# and provide modular hardening functions that can be extended into an
# interactive menu.
#
# Usage:
#   ./guarder.sh            # run only checks (default)
#   ./guarder.sh --dry-run  # preview hardening changes without modifying files
#   ./guarder.sh --apply    # apply all hardening actions
# =============================================================================

set -euo pipefail

# This script requires zsh (macOS default shell). If run with bash, show a helpful message.
if [ -z "${ZSH_VERSION:-}" ]; then
  printf '\033[0;31m[ERROR]\033[0m Please run this script with zsh (macOS default shell):\n'
  printf '        zsh %s\n' "$0"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Colors and output helpers
# ─────────────────────────────────────────────────────────────────────────────
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
log_part()    { print "\n${BOLD}${GREEN}┌─────────────────────────────────────────${RESET}"; \
                print "${BOLD}${GREEN}│  $*${RESET}"; \
                print "${BOLD}${GREEN}└─────────────────────────────────────────${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Global state
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
APPLY=false
CHECKS_PASSED=true
OPENCLAW_INSTALLED=false
OPENCLAW_VERSION=""
OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
OPENCLAW_ENV_FILE="${HOME}/.openclaw/.env"

# Command queue (for dry-run preview and apply execution)
typeset -a PENDING_DESCS=()
typeset -a PENDING_CMDS=()

# ─────────────────────────────────────────────────────────────────────────────
# Module 1: Basic environment checks
# ─────────────────────────────────────────────────────────────────────────────

# Check whether a single command exists and print its version
_check_cmd() {
  local cmd="$1"
  local version_flag="${2:---version}"
  if command -v "$cmd" &>/dev/null; then
    local ver
    ver="$(${cmd} ${version_flag} 2>&1 | head -1)"
    log_ok "${cmd} is installed  →  ${ver}"
    return 0
  else
    log_warn "${cmd} not found"
    return 1
  fi
}

# Check Homebrew
check_homebrew() {
  log_section "Check Homebrew"
  if _check_cmd brew --version; then
    log_info "Homebrew prefix: $(brew --prefix)"
  else
    log_warn "Recommended to install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    CHECKS_PASSED=false
  fi
}

# Check Node.js / npm / pnpm
check_node() {
  log_section "Check Node.js / npm / pnpm"

  local node_ok=false npm_ok=false pnpm_ok=false

  if _check_cmd node --version; then
    node_ok=true
    local node_major
    node_major=$(node -e "process.stdout.write(process.version.replace('v','').split('.')[0])")
    if (( node_major < 18 )); then
      log_warn "Node.js version is too old (current v${node_major}), upgrade to v18 or newer is recommended"
      CHECKS_PASSED=false
    fi
  else
    log_error "Node.js is not installed. You can install via Homebrew: brew install node"
    CHECKS_PASSED=false
  fi

  if _check_cmd npm --version; then
    npm_ok=true
  else
    log_error "npm not found (usually installed with Node.js)"
    CHECKS_PASSED=false
  fi

  if _check_cmd pnpm --version; then
    pnpm_ok=true
  else
    log_error "pnpm not installed. Install via npm: npm install -g pnpm"
    CHECKS_PASSED=false
  fi
}

# Check related tools (git / curl)
check_related_tools() {
  log_section "Check related tools"
  local tools=("git" "curl")
  for t in "${tools[@]}"; do
    _check_cmd "$t" --version || log_info "(related tool) ${t} not installed; some features may be limited"
  done
}

# Entry: run prerequisite checks
run_prerequisite_checks() {
  log_section "Phase 1 — Basic dependency checks"
  check_homebrew
  check_node
  check_related_tools

  if $CHECKS_PASSED; then
    log_section "Phase 1 — Summary"
    log_ok "All required dependencies passed ✓"
  else
    log_section "Phase 1 — Summary"
    log_warn "Some dependencies are missing or versions are not sufficient; please fix per hints and re-run"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Module 2: OpenClaw installation checks
# ─────────────────────────────────────────────────────────────────────────────

# Check OpenClaw CLI
check_openclaw_cli() {
  log_info "Checking OpenClaw CLI..."
  if command -v openclaw &>/dev/null; then
    OPENCLAW_VERSION="$(openclaw --version 2>&1 | head -1)"
    log_ok "openclaw CLI installed  →  ${OPENCLAW_VERSION}"
    OPENCLAW_INSTALLED=true
    return 0
  else
    log_warn "openclaw CLI not found (command: openclaw)"
    return 1
  fi
}

# Check Gateway process
check_openclaw_gateway() {
  log_info "Checking OpenClaw Gateway process..."
  if pgrep -qf "openclaw.*(gateway|serve)" 2>/dev/null; then
    log_ok "OpenClaw Gateway process is running"
  else
    log_warn "No running OpenClaw Gateway process detected"
  fi
}

# Check core config file
check_openclaw_config() {
  log_info "Checking OpenClaw core config: ${OPENCLAW_CONFIG_FILE}"
  if [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    log_ok "Config file exists: ${OPENCLAW_CONFIG_FILE}"
  else
    log_warn "Core config file does not exist: ${OPENCLAW_CONFIG_FILE}"
    log_info "If installed in a custom location, please set OPENCLAW_CONFIG_FILE environment variable"
    exit 1
  fi
}

# Check default port exposure
check_port_exposure() {
  log_info "Checking default port 18789 exposure..."
  local exposed=false

  if command -v lsof &>/dev/null; then
    if lsof -nP -iTCP:18789 -sTCP:LISTEN 2>/dev/null | grep -q '\*:18789\|0\\.0\\.0\\.0:18789'; then
      exposed=true
    fi
  elif command -v netstat &>/dev/null; then
    if netstat -an 2>/dev/null | grep -qE '(0\\.0\\.0\\.0|\*)[\.:]18789.*LISTEN'; then
      exposed=true
    fi
  else
    log_warn "Unable to determine port exposure (lsof and netstat both unavailable)"
    return
  fi

  if $exposed; then
    log_warn "⚠️  Port 18789 is currently bound to 0.0.0.0 and is accessible from the network!"
    log_warn "    Recommendation: restrict external access via firewall/security group or bind to 127.0.0.1"
  else
    log_ok "Port 18789 is not exposed externally (not listening or bound to localhost)"
  fi
}

# Check default port in config
check_default_port_in_config() {
  log_info "Checking Gateway port in config..."
  local port_val
  port_val=$(grep -Eo '"port"\s*:\s*[0-9]+' "$OPENCLAW_CONFIG_FILE" 2>/dev/null | grep -Eo '[0-9]+$' | head -1)

  if [[ "$port_val" == "18789" ]]; then
    log_warn "gateway.port is still the default 18789"
    log_warn "    Recommendation: change to a non-default port (1024-65535) to reduce scanning exposure"
  elif [[ -n "$port_val" ]]; then
    log_ok "Gateway port set to non-default value: ${port_val}"
  else
    log_info "gateway.port not found in config (the program may be using default 18789)"
  fi
}

# Entry: run OpenClaw checks
run_openclaw_checks() {
  log_section "Phase 2 — OpenClaw installation checks"
  check_openclaw_cli
  check_openclaw_gateway
  check_openclaw_config
  check_port_exposure
  check_default_port_in_config

  if $OPENCLAW_INSTALLED; then
    log_ok "OpenClaw is installed; you may proceed with hardening"
  else
    log_warn "OpenClaw CLI not installed or not in PATH. Hardening will run in limited mode"
    log_info "See installation docs: https://docs.openclaw.ai/cli"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Module 3: Hardening functions
# ─────────────────────────────────────────────────────────────────────────────

_backup_file() {
  local target="$1"
  if [[ ! -f "$target" ]]; then return; fi
  local backup="${target}.bak.$(date +%Y%m%d_%H%M%S)"

  if $APPLY; then
    if cp "$target" "$backup"; then
      log_ok "Backed up: ${target##*/}  →  ${backup##*/}"
    else
      log_error "Backup failed: ${target##*/}"
      return 1
    fi
  else
    log_info "[preview] Will back up: ${target##*/}  →  ${backup##*/}"
  fi
}

_apply_or_preview() {
  local description="$1"
  shift
  local cmd_str
  cmd_str=$(printf '%q ' "$@")
  PENDING_DESCS+=("$description")
  PENDING_CMDS+=("${cmd_str% }")
}

flush_pending_commands() {
  local total=${#PENDING_CMDS[@]}

  if (( total == 0 )); then
    log_info "No pending commands"
    return
  fi

  log_section "Pending commands summary (total ${total})"
  local i
  for (( i = 1; i <= total; i++ )); do
    print "  ${BOLD}[${i}]${RESET} ${PENDING_DESCS[$i]}"
    print "       ${CYAN}→${RESET} ${PENDING_CMDS[$i]}"
  done
  print ""

  if $DRY_RUN; then
    print "${BOLD}${CYAN}──────────────────────────────────────────${RESET}"
    log_info "This is a DRY-RUN preview; no actual modifications were made. Use --apply to perform changes"
  else
    log_section "Executing all changes (total ${total})"
    for (( i = 1; i <= total; i++ )); do
      log_info "[${i}/${total}] Executing: ${PENDING_DESCS[$i]}"
      if eval "${PENDING_CMDS[$i]}"; then
        log_ok "Done"
      else
        log_error "Failed: ${PENDING_DESCS[$i]}"
      fi
    done
    log_ok "All hardening actions executed. Please check backup files (*.bak.*) and verify services"
  fi
}

harden_gateway_auth() {
  log_section "Ensure Gateway authentication is enabled"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  if grep -qE '"?mode"?\s*:\s*"none"' "$config_file" 2>/dev/null; then
    _apply_or_preview \
      'Change gateway.auth.mode from "none" to "token" (enable token auth)' \
      /usr/bin/sed -i '' -E 's/("?mode"?[[:space:]]*:[[:space:]]*)"none"/\1"token"/g' "$config_file"
    log_warn "Detected gateway.auth.mode = none; queued fix. After change, supply gateway.auth.token in config"
  elif grep -qE '"?token"?\s*:|"?password"?\s*:' "$config_file" 2>/dev/null; then
    log_ok "Gateway authentication configured (token or password)"
  else
    log_warn "No gateway.auth.token / gateway.auth.password found in config"
    log_warn "If Gateway is bound to non-loopback address, startup may be refused; consider adding gateway.auth.token"
  fi
}

harden_gateway_port() {
  log_section "Gateway port hardening"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  local port_val
  port_val=$(grep -Eo '"?port"?\s*:\s*[0-9]+' "$config_file" 2>/dev/null \
    | grep -Eo '[0-9]+$' | head -1) || true

  if [[ -n "$port_val" ]] && [[ "$port_val" != "18789" ]]; then
    log_ok "Gateway port is already non-default: ${port_val}"
    return
  fi

  if [[ -z "$port_val" ]]; then
    log_warn "gateway.port is not explicitly set in config; implicit default 18789 is used"
  else
    log_warn "Gateway port is the default 18789 — subject to targeted scans"
  fi

  if [[ ! -t 0 ]]; then
    log_info "Non-interactive mode: skip port selection. Edit openclaw.json manually to change gateway.port"
    return
  fi

  print ""
  print "  ${BOLD}Choose port modification method:${RESET}"
  print "  ${BOLD}[1]${RESET} Generate a random five-digit port (10000–65535)"
  print "  ${BOLD}[2]${RESET} Enter a port manually"
  print "  ${BOLD}[3]${RESET} Keep current port"
  print ""

  local choice
  read "choice?  Select option [1/2/3] (default 1): "
  choice="${choice:-1}"

  local new_port=""
  case "$choice" in
    1)
      local raw
      raw=$(od -An -N2 -tu2 /dev/urandom | tr -d ' \n') || raw=$$
      new_port=$(( raw % 55536 + 10000 ))
      log_info "Randomly chosen port: ${new_port}"
      ;;
    2)
      read "new_port?  Enter new port (1024–65535): "
      if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1024 || new_port > 65535 )); then
        log_error "Invalid port (${new_port}), skipping port change"
        return
      fi
      log_info "Chosen port: ${new_port}"
      ;;
    3)
      log_info "Keeping current port; skipping change"
      return
      ;;
    *)
      log_warn "Invalid option '${choice}', skipping port change"
      return
      ;;
  esac

  if [[ -n "$port_val" ]]; then
    _apply_or_preview \
      "Change gateway.port from ${port_val} to ${new_port}" \
      /usr/bin/sed -i '' -E \
        "s/(\"?port\"?[[:space:]]*:[[:space:]]*)${port_val}/\\1${new_port}/g" \
        "$config_file"
  else
    log_warn "gateway.port not present in config; cannot safely insert automatically"
    log_info "Manually add in openclaw.json under gateway block:"
    log_info "  port: ${new_port}"
  fi
}

harden_network_bindings() {
  log_section "Gateway binding hardening"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  _extract_gw_field() {
    local field="$1"
    awk -v field="$field" '
      BEGIN { in_gw=0; depth=0 }
      /^[[:space:]]*"?gateway"?[[:space:]]*[:{]/ && !in_gw { in_gw=1 }
      in_gw {
        n = length($0)
        for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (c == "{") depth++
          else if (c == "}") { depth--; if (depth <= 0) { in_gw=0; break } }
        }
        pat = "\"?" field "\"?[[:space:]]*:"
        if (in_gw && depth == 1 && $0 ~ pat) {
          val = $0
          sub(".*\"?" field "\"?[[:space:]]*:[[:space:]]*\"", "", val)
          sub(/\".*/, "", val)
          print val
          exit
        }
      }
    ' "$config_file" 2>/dev/null
  }

  local mode_val bind_val
  mode_val=$(_extract_gw_field "mode") || true
  bind_val=$(_extract_gw_field "bind") || true

  if [[ -z "$mode_val" ]] || [[ "$mode_val" == "local" ]]; then
    log_ok "gateway.mode: \"${mode_val:-local (default)}\" ✓"
  else
    log_warn "gateway.mode is currently \"${mode_val}\" — Gateway is running in non-local mode"
    _apply_or_preview \
      "Change gateway.mode from \"${mode_val}\" to \"local\" (restrict to localhost)" \
      /usr/bin/sed -i '' -E \
        "s/(\"?mode\"?[[:space:]]*:[[:space:]]*)\"${mode_val}\"/\\1\"local\"/g" \
        "$config_file"
  fi

  if [[ -z "$bind_val" ]] || [[ "$bind_val" == "loopback" ]]; then
    log_ok "gateway.bind: \"${bind_val:-loopback (default)}\" ✓"
  else
    case "$bind_val" in
      lan)
        log_warn "gateway.bind=\"lan\" → binds 0.0.0.0; exposed to LAN/Internet — high risk!"
        _apply_or_preview \
          "Change gateway.bind from \"lan\" to \"loopback\" (restrict to localhost)" \
          /usr/bin/sed -i '' -E \
            's/("?bind"?[[:space:]]*:[[:space:]]*)"lan"/\1"loopback"/g' \
            "$config_file"
        ;;
      auto)
        log_warn "gateway.bind=\"auto\" → may bind external interfaces, exposure risk"
        _apply_or_preview \
          "Change gateway.bind from \"auto\" to \"loopback\" (restrict to localhost)" \
          /usr/bin/sed -i '' -E \
            's/("?bind"?[[:space:]]*:[[:space:]]*)"auto"/\1"loopback"/g' \
            "$config_file"
        ;;
      tailnet)
        log_warn "gateway.bind=\"tailnet\" → binds to Tailscale virtual IP; if not using Tailscale, set to loopback"
        _apply_or_preview \
          "Change gateway.bind from \"tailnet\" to \"loopback\" (restrict to localhost)" \
          /usr/bin/sed -i '' -E \
            's/("?bind"?[[:space:]]*:[[:space:]]*)"tailnet"/\1"loopback"/g' \
            "$config_file"
        ;;
      custom)
        log_warn "gateway.bind=\"custom\" → custom bind address; manual review required"
        log_info "If unnecessary, set: bind: \"loopback\""
        ;;
      *)
        log_warn "gateway.bind=\"${bind_val}\" → unknown value; manual check required"
        ;;
    esac
  fi

  local mode_ok=false bind_ok=false
  { [[ -z "$mode_val" ]] || [[ "$mode_val" == "local" ]]; }       && mode_ok=true
  { [[ -z "$bind_val" ]] || [[ "$bind_val" == "loopback" ]]; }    && bind_ok=true

  if $mode_ok && $bind_ok; then
    log_ok "gateway.mode and gateway.bind are both safe; Gateway is localhost-only"
  else
    log_warn "Both gateway.mode=\"local\" and gateway.bind=\"loopback\" must be satisfied to fully restrict to localhost"
  fi
}

harden_config_file_perms() {
  log_section "openclaw.json permissions"
  local config_file="${OPENCLAW_CONFIG_FILE}"
  local config_dir="${OPENCLAW_CONFIG_DIR}"
  local current_user
  current_user="$(id -un)"

  local file_owner file_perm
  file_owner=$(stat -f '%Su' "$config_file" 2>/dev/null || echo "unknown")
  file_perm=$(stat -f '%A' "$config_file" 2>/dev/null || echo "000")

  if [[ "$file_owner" != "$current_user" ]]; then
    log_warn "openclaw.json owner is ${file_owner}, current user is ${current_user}; please verify manually"
  fi

  if [[ "$file_perm" == "600" ]]; then
    log_ok "openclaw.json permissions are 600 (owner read/write)"
  else
    log_warn "openclaw.json currently has permissions ${file_perm}; should be 600"
    _apply_or_preview \
      "Set openclaw.json permissions to 600 (current: ${file_perm})" \
      chmod 600 "$config_file"
  fi

  if [[ -d "$config_dir" ]]; then
    local dir_perm
    dir_perm=$(stat -f '%A' "$config_dir" 2>/dev/null || echo "000")
    if [[ "$dir_perm" == "700" ]]; then
      log_ok "${config_dir} directory permissions are 700"
    else
      log_warn "${config_dir} currently has permissions ${dir_perm}; should be 700"
      _apply_or_preview \
        "Set ${config_dir} directory permissions to 700 (current: ${dir_perm})" \
        chmod 700 "$config_dir"
    fi
  fi
}

harden_env_file_perms() {
  log_section ".env environment file permissions"
  local env_file="${OPENCLAW_ENV_FILE}"
  local current_user
  current_user="$(id -un)"

  if [[ ! -f "$env_file" ]]; then
    log_info ".env file does not exist; skipping (${env_file})"
    return
  fi

  local file_owner file_perm
  file_owner=$(stat -f '%Su' "$env_file" 2>/dev/null || echo "unknown")
  file_perm=$(stat -f '%A' "$env_file" 2>/dev/null || echo "000")

  if [[ "$file_owner" != "$current_user" ]]; then
    log_warn ".env owner is ${file_owner}, current user is ${current_user}; please verify manually"
  fi

  if [[ "$file_perm" == "600" ]]; then
    log_ok ".env permissions are 600 (owner read/write)"
  else
    log_warn ".env currently has permissions ${file_perm}; should be 600"
    _apply_or_preview \
      "Set .env permissions to 600 (current: ${file_perm})" \
      chmod 600 "$env_file"
  fi
}

harden_apikey_to_env() {
  log_section "Models Providers API Key detection & migration"
  local config_file="${OPENCLAW_CONFIG_FILE}"
  local env_file="${OPENCLAW_ENV_FILE}"
  local env_dir
  env_dir="$(dirname "$env_file")"

  if [[ ! -f "$config_file" ]]; then
    log_info "Config file not found; skipping API Key migration check"
    return
  fi

  local -a hits=()
  while IFS= read -r _hit_line; do
    hits+=("$_hit_line")
  done < <(
    awk '
      BEGIN { in_providers=0; rel_depth=0; provider="" }
      !in_providers && /"?providers"?[[:space:]]*:[[:space:]]*\{/ {
        in_providers=1; rel_depth=0; next
      }
      in_providers {
        line = $0
        n = length(line)
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if      (c == "{") rel_depth++
          else if (c == "}") { rel_depth--; if (rel_depth < 0) { in_providers=0; break } }
        }
        if (!in_providers) next
        if (rel_depth == 1 && line ~ /\{[[:space:]]*(\/\/.*)?$/) {
          k = line
          sub(/^[[:space:]]*"?/, "",  k)
          sub(/"?[[:space:]]*:[[:space:]]*\{.*/, "", k)
          provider = k
        }
        if (rel_depth == 1 && provider != "" &&
            line ~ /"?apiKey"?[[:space:]]*:[[:space:]]*"[^$]/) {
          val = line
          sub(/.*"?apiKey"?[[:space:]]*:[[:space:]]*"/, "", val)
          sub(/".*/, "", val)
          if (val != "") print NR ":" provider ":" val
        }
      }
    ' "$config_file" 2>/dev/null || true
  )

  if (( ${#hits[@]} == 0 )); then
    log_ok "No plaintext apiKey found in models.providers; all keys are placeholders or not configured ✓"
    return
  fi

  log_warn "Found ${#hits[@]} plaintext models.providers apiKey entries; they will be extracted to .env and replaced with \\${VAR_NAME}:"

  typeset -A assigned_vars
  local migration_count=0

  for hit in "${hits[@]}"; do
    local lineno="${hit%%:*}"
    local rest="${hit#*:}"
    local provider_name="${rest%%:*}"
    local field_value="${rest#*:}"

    [[ -z "$provider_name" || -z "$field_value" ]] && continue

    local var_base
    var_base=$(printf '%s' "$provider_name" \
      | sed 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' \
      | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    var_base="${var_base}_API_KEY"

    local var_name="$var_base"
    local suffix=2
    while [[ -n "${assigned_vars[$var_name]+_}" ]]; do
      if [[ -f "$env_file" ]]; then
        local existing_val
        existing_val=$(grep -E "^${var_name}=" "$env_file" 2>/dev/null \
          | head -1 | cut -d= -f2-)
        [[ "$existing_val" == "$field_value" ]] && break
      fi
      var_name="${var_base}_${suffix}"
      (( suffix++ ))
    done
    assigned_vars[$var_name]="$field_value"

    log_info "  line ${lineno}: models.providers.${provider_name}.apiKey → \${${var_name}}"

    local already_in_env=false
    if [[ -f "$env_file" ]] && grep -qE "^${var_name}=" "$env_file" 2>/dev/null; then
      already_in_env=true
    fi

    if ! $already_in_env; then
      _apply_or_preview \
        "Write to .env: ${var_name}=<secret>  (from models.providers.${provider_name}.apiKey)" \
        zsh -c "mkdir -p $(printf '%q' "$env_dir") && \
          { [[ -f $(printf '%q' "$env_file") ]] || { touch $(printf '%q' "$env_file") && chmod 600 $(printf '%q' "$env_file"); }; } && \
          printf '%s=%s\\n' $(printf '%q' "$var_name") $(printf '%q' "$field_value") \
          >> $(printf '%q' "$env_file")"
    else
      log_info "  ${var_name} already exists in .env; skipping write"
    fi

    local escaped_value
    escaped_value=$(printf '%s' "$field_value" | sed 's/[[\.*^$()+?{|]/\\&/g')

    _apply_or_preview \
      "Replace plaintext apiKey on line ${lineno} in openclaw.json with \${${var_name}}" \
      perl -i -e \
        "my \\$ln=0; while(<>){ \\$ln++; if(\\$ln==${lineno}){ s/(\"?apiKey\"?\\s*:\\s*)\"${escaped_value}\"/\\\${1}\"\\\\\${${var_name}}\"/; } print; }" \
        "$config_file"

    (( migration_count++ ))
  done

  if (( migration_count > 0 )); then
    log_warn "Total ${migration_count} apiKey entries to migrate. After --apply, restart Gateway to load new config"
    log_info "After migration ensure .env permissions are 600: chmod 600 $(printf '%q' "$env_file")"
  fi
}

optimize_heartbeat() {
  log_section "agents.defaults.heartbeat minimal viable configuration check"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  local heartbeat_every
  heartbeat_every=$(grep -Eo '"every"\s*:\s*"[^"]*"' "$config_file" 2>/dev/null \
    | grep -Eo '"[^"]*"' | tr -d '"' | head -1) || true

  if [[ -n "$heartbeat_every" ]]; then
    local hb_num hb_unit
    hb_num=$(echo "$heartbeat_every" | grep -Eo '^[0-9]+')
    hb_unit=$(echo "$heartbeat_every" | grep -Eo '[a-z]+$')
    local too_frequent=false
    [[ "$hb_unit" == "s" ]] && too_frequent=true
    [[ "$hb_unit" == "m" ]] && (( hb_num <= 10 )) && too_frequent=true

    if $too_frequent; then
      log_warn "heartbeat.every is too short (current: ${heartbeat_every}); each heartbeat consumes full tokens; recommend 55m or longer"
      log_warn "Current frequency roughly generates $(( 1440 / hb_num )) API calls per day"
      _apply_or_preview \
        "Change heartbeat.every from ${heartbeat_every} to 55m" \
        /usr/bin/sed -i '' "s/\"every\": \"${heartbeat_every}\"/\"every\": \"55m\"/g" "$config_file"
    else
      log_ok "heartbeat.every: \"${heartbeat_every}\" ✓"
    fi
  else
    log_info "heartbeat.every not configured (default 30m); recommend explicitly setting to 55m"
  fi

  local target_val
  target_val=$(grep -Eo '"target"\s*:\s*"[^"]*"' "$config_file" 2>/dev/null \
    | grep -Eo '"[^"]*"' | tr -d '"' | head -1) || true

  if [[ -z "$target_val" ]] || [[ "$target_val" == "none" ]]; then
    log_warn "heartbeat.target is \"${target_val:-none (default)}\"; heartbeat results will not be delivered to any channel"
    log_info "If you want to receive heartbeat messages, set: target: \"last\" (deliver to last contact)"
  else
    log_ok "heartbeat.target: \"${target_val}\" ✓"
  fi

  local light_val
  light_val=$(grep -Eo '"lightContext"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true

  if [[ "$light_val" == "true" ]]; then
    log_ok "heartbeat.lightContext: true ✓ (loads only HEARTBEAT.md, saves tokens)"
  else
    log_warn "heartbeat.lightContext is \"${light_val:-false (default)}\"; full bootstrap files will be loaded each heartbeat, consuming more tokens"
    log_info "Recommend setting: lightContext: true"
  fi
}

optimize_compaction() {
  log_section "agents.defaults.compaction configuration"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  if ! grep -qE '"compaction"|compaction[[:space:]]*:' "$config_file" 2>/dev/null; then
    log_warn "agents.defaults.compaction not configured; using built-in mode: default"
    log_info "Recommendation: explicitly add in openclaw.json:"
    log_info "  agents.defaults.compaction.mode: \"safeguard\""
    log_info "  agents.defaults.compaction.identifierPolicy: \"strict\""
    log_info "  agents.defaults.compaction.memoryFlush.enabled: true"
    return
  fi

  local mode_val
  mode_val=$(awk '
    BEGIN { in_c=0; depth=0 }
    /"compaction"[[:space:]]*[:{]|compaction[[:space:]]*[:{]/ && !in_c { in_c=1 }
    in_c {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth <= 0) { in_c=0; break } }
      }
      if (in_c && depth == 1 && $0 ~ /"?mode"?[[:space:]]*:/) {
        val = $0
        sub(".*\"?mode\"?[[:space:]]*:[[:space:]]*\"", "", val)
        sub(/\".*/, "", val)
        print val; exit
      }
    }
  ' "$config_file" 2>/dev/null) || true

  case "${mode_val:-default}" in
    safeguard)
      log_ok "compaction.mode: \"safeguard\" ✓"
      ;;
    default|"")
      log_warn "compaction.mode is \"${mode_val:-default}\"; lower quality for long conversation compression"
      if [[ -n "$mode_val" ]]; then
        _apply_or_preview \
          "Change compaction.mode from \"default\" to \"safeguard\" (chunked summaries to avoid loss)" \
          /usr/bin/sed -i '' -E \
            's/("?mode"?[[:space:]]*:[[:space:]]*)"default"/\1"safeguard"/g' \
            "$config_file"
      else
        log_info "Please manually add: mode: \"safeguard\" in the compaction block"
      fi
      ;;
    *)
      log_info "compaction.mode: \"${mode_val}\" (custom value, verify)"
      ;;
  esac

  local id_policy
  id_policy=$(awk '
    BEGIN { in_c=0; depth=0 }
    /"compaction"[[:space:]]*[:{]|compaction[[:space:]]*[:{]/ && !in_c { in_c=1 }
    in_c {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth <= 0) { in_c=0; break } }
      }
      if (in_c && depth == 1 && $0 ~ /"?identifierPolicy"?[[:space:]]*:/) {
        val = $0
        sub(".*\"?identifierPolicy\"?[[:space:]]*:[[:space:]]*\"", "", val)
        sub(/\".*/, "", val)
        print val; exit
      }
    }
  ' "$config_file" 2>/dev/null) || true

  if [[ -z "$id_policy" ]] || [[ "$id_policy" == "strict" ]]; then
    log_ok "compaction.identifierPolicy: \"${id_policy:-strict (default)}\" ✓"
  elif [[ "$id_policy" == "off" ]]; then
    log_warn "compaction.identifierPolicy=\"off\" — IDs/ports may be omitted during compaction"
    log_info "Recommend: identifierPolicy: \"strict\""
  else
    log_info "compaction.identifierPolicy: \"${id_policy}\""
  fi
}

check_channel_defaults() {
  log_section "channels.defaults configuration checks"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  local group_policy
  group_policy=$(awk '
    BEGIN { in_ch=0; in_def=0; def_depth=0 }
    /"channels"[[:space:]]*[:{]|channels[[:space:]]*[:{]/ && !in_ch { in_ch=1 }
    in_ch && !in_def && (/"defaults"[[:space:]]*[:{]|defaults[[:space:]]*[:{]/) { in_def=1 }
    in_def {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "{") def_depth++
        else if (c == "}") { def_depth--; if (def_depth <= 0) { in_def=0; in_ch=0; break } }
      }
      if (in_def && def_depth == 1 && $0 ~ /"?groupPolicy"?[[:space:]]*:/) {
        val = $0
        sub(".*\"?groupPolicy\"?[[:space:]]*:[[:space:]]*\"", "", val)
        sub(/\".*/, "", val)
        print val; exit
      }
    }
  ' "$config_file" 2>/dev/null) || true

  local show_alerts show_ok use_indicator
  show_alerts=$(grep -Eo '"showAlerts"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true
  show_ok=$(grep -Eo '"showOk"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true
  use_indicator=$(grep -Eo '"useIndicator"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true

  if [[ -z "$group_policy" && -z "$show_alerts" && -z "$show_ok" && -z "$use_indicator" ]]; then
    log_ok "channels.defaults not explicitly configured; using official defaults ✓"
    log_info "  groupPolicy: \"allowlist\" (fail-closed, only allowed groups)"
    log_info "  heartbeat.showAlerts: true  |  heartbeat.showOk: false  |  heartbeat.useIndicator: true"
    return
  fi

  case "${group_policy:-allowlist}" in
    allowlist|"")
      log_ok "channels.defaults.groupPolicy: \"${group_policy:-allowlist (default)}\" ✓ (fail-closed)"
      ;;
    open)
      log_warn "channels.defaults.groupPolicy=\"open\" — allowlist bypassed; all groups can access Gateway"
      log_info "If unnecessary, set back to default: groupPolicy: \"allowlist\""
      ;;
    disabled)
      log_info "channels.defaults.groupPolicy=\"disabled\" (all group messages are blocked)"
      ;;
    *)
      log_info "channels.defaults.groupPolicy: \"${group_policy}\""
      ;;
  esac

  if [[ -z "$show_alerts" ]] || [[ "$show_alerts" == "true" ]]; then
    log_ok "channels.defaults.heartbeat.showAlerts: ${show_alerts:-true (default)} ✓"
  else
    log_warn "channels.defaults.heartbeat.showAlerts=false — degrade/error alerts will be hidden"
    log_info "Official default is true; keep it to ensure alerts are visible"
  fi

  log_info "channels.defaults.heartbeat.showOk: ${show_ok:-false (default)}"
  log_info "channels.defaults.heartbeat.useIndicator: ${use_indicator:-true (default)}"
}

harden_credentials_perms() {
  log_section "Credentials & auth files permissions"
  local config_dir="${OPENCLAW_CONFIG_DIR}"
  local cred_dir="${config_dir}/credentials"
  local any_file=false

  if [[ -d "$cred_dir" ]]; then
    any_file=true
    local dir_perm
    dir_perm=$(stat -f '%A' "$cred_dir" 2>/dev/null || echo "000")
    if [[ "$dir_perm" == "700" ]]; then
      log_ok "credentials/ directory permissions are 700"
    else
      log_warn "credentials/ directory currently ${dir_perm}; should be 700"
      _apply_or_preview \
        "Set credentials/ directory permissions to 700 (current: ${dir_perm})" \
        chmod 700 "$cred_dir"
    fi

    local f
    for f in "$cred_dir"/*.json; do
      [[ -f "$f" ]] || continue
      local fperm
      fperm=$(stat -f '%A' "$f" 2>/dev/null || echo "000")
      if [[ "$fperm" == "600" ]]; then
        log_ok "${f##*/} permissions are 600"
      else
        log_warn "${f##*/} currently ${fperm}; should be 600 (contains channel session credentials)"
        _apply_or_preview \
          "Set ${f##*/} permissions to 600 (current: ${fperm})" \
          chmod 600 "$f"
      fi
    done
  fi

  local profile
  for profile in "${config_dir}"/agents/*/agent/auth-profiles.json(N); do
    [[ -f "$profile" ]] || continue
    any_file=true
    local pperm agent_id
    pperm=$(stat -f '%A' "$profile" 2>/dev/null || echo "000")
    agent_id=$(echo "$profile" | sed 's|.*/agents/\([^/]*\)/agent/.*|\1|')
    if [[ "$pperm" == "600" ]]; then
      log_ok "agents/${agent_id}/agent/auth-profiles.json permissions are 600"
    else
      log_warn "agents/${agent_id}/agent/auth-profiles.json currently ${pperm}; should be 600 (contains API Key/OAuth Token)"
      _apply_or_preview \
        "Set auth-profiles.json permissions to 600 (agent: ${agent_id}, current: ${pperm})" \
        chmod 600 "$profile"
    fi
  done

  if ! $any_file; then
    log_info "No credentials or auth-profiles.json found; skipping"
  fi
}

harden_logging_redact() {
  log_section "Logging sensitive information redaction"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  local redact_val
  redact_val=$(grep -Eo '"?redactSensitive"?\s*:\s*"[^"]*"' "$config_file" 2>/dev/null \
    | grep -Eo '"[^"]*"' | tr -d '"' | head -1) || true

  case "${redact_val}" in
    off)
      log_warn "logging.redactSensitive=\"off\" — tool outputs will be logged in plaintext (may expose URLs, command output, credential fragments)"
      _apply_or_preview \
        "Change logging.redactSensitive from \"off\" to \"tools\" (restore automatic redaction)" \
        /usr/bin/sed -i '' -E \
          's/("?redactSensitive"?[[:space:]]*:[[:space:]]*\")off"/\1tools"/g' \
          "$config_file"
      ;;
    tools|"")
      log_ok "logging.redactSensitive: \"${redact_val:-tools (default)}\" ✓ (tool outputs redacted)"
      ;;
    *)
      log_info "logging.redactSensitive: \"${redact_val}\""
      ;;
  esac
}

harden_controlui_flags() {
  log_section "Gateway Control UI security configuration"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  if grep -qE '"?dangerouslyDisableDeviceAuth"?\s*:\s*true' "$config_file" 2>/dev/null; then
    log_error "gateway.controlUi.dangerouslyDisableDeviceAuth=true — device authentication fully disabled!"
    log_error "This is a severe security downgrade — disable unless actively debugging"
    log_info "Set to false or remove the field"
  else
    log_ok "gateway.controlUi.dangerouslyDisableDeviceAuth: not enabled ✓"
  fi

  if grep -qE '"?allowInsecureAuth"?\s*:\s*true' "$config_file" 2>/dev/null; then
    log_warn "gateway.controlUi.allowInsecureAuth=true — Control UI has fallen back to token-only auth (insecure)"
    log_warn "Recommend using HTTPS (Tailscale Serve) or access on 127.0.0.1 instead of enabling this flag"
    log_info "If not needed, set to false or remove"
  else

    log_ok "gateway.controlUi.allowInsecureAuth: not enabled ✓"
  fi
}

run_hardening() {
  log_section "Phase 3 — Security hardening & optimizations"

  if ! $OPENCLAW_INSTALLED; then
    log_warn "OpenClaw not detected; some hardening items will skip config changes"
  fi

  _backup_file "${OPENCLAW_CONFIG_FILE}"

  log_part "Part 1 — Basic config file security"
  harden_config_file_perms
  harden_env_file_perms
  harden_apikey_to_env
  harden_credentials_perms
  harden_logging_redact

  log_part "Part 2 — Gateway configuration hardening"
  harden_gateway_auth
  harden_gateway_port
  harden_network_bindings
  harden_controlui_flags

  log_part "Part 3 — Agents & Channels configuration optimizations"
  optimize_heartbeat
  optimize_compaction
  check_channel_defaults

  log_part "Execution stage — summarize and apply changes"
  flush_pending_commands
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  (no args)     Run checks only (Phase 1 + 2)
  --dry-run     Preview hardening changes without modifying files
  --apply       Apply all hardening actions (Phase 1 + 2 + 3)
  --help        Show this help

Examples:
  ./guarder.sh              # environment and installation checks
  ./guarder.sh --dry-run    # preview hardening
  ./guarder.sh --apply      # apply hardening
EOF
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      --apply)   APPLY=true   ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "Unknown argument: ${arg}"; usage; exit 1 ;;
    esac
  done

  print "${BOLD}${CYAN}"
  print "╔══════════════════════════════════════════╗"
  print "║         OpenClaw Guarder                 ║"
  print "╚══════════════════════════════════════════╝${RESET}"
  print "  Mode: $(if $DRY_RUN; then print 'DRY-RUN (preview)'; elif $APPLY; then print 'APPLY (apply hardening)'; else print 'Check (read-only)'; fi)"
  print "  Time: $(date '+%Y-%m-%d %H:%M:%S')\n"

  run_prerequisite_checks
  run_openclaw_checks

  if $DRY_RUN || $APPLY; then
    run_hardening
  else
    log_section "Note"
    log_info "Only completed environment checks. Use --dry-run to preview hardening, or --apply to perform it"
  fi
}

main "$@"
