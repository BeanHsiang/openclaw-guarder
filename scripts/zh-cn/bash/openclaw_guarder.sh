#!/usr/bin/env bash
# =============================================================================
# OpenClaw Guarder — macOS 安全加固与配置检查脚本（Bash 版本）
# =============================================================================
# 用途：检查环境依赖、验证 OpenClaw 安装状态，并提供分块式安全加固函数，
#       便于后续扩展为交互式菜单设计。
#
# 用法：
#   ./guarder.sh            # 仅运行环境检查（默认）
#   ./guarder.sh --dry-run  # 预览加固变更，不实际修改
#   ./guarder.sh --apply    # 执行全部加固操作
# =============================================================================

set -euo pipefail

# 本脚本仅支持 bash。
if [ -z "${BASH_VERSION:-}" ]; then
  printf '\033[0;31m[ERROR]\033[0m 请使用 bash 运行本脚本：\n'
  printf '        bash %s\n' "$0"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 颜色与输出工具
# ─────────────────────────────────────────────────────────────────────────────
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
log_part()    { printf '\n%b\n' "${BOLD}${GREEN}┌─────────────────────────────────────────${RESET}"; \
                printf '%b\n' "${BOLD}${GREEN}│  $*${RESET}"; \
                printf '%b\n' "${BOLD}${GREEN}└─────────────────────────────────────────${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# 全局状态
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
APPLY=false
CHECKS_PASSED=true
OPENCLAW_INSTALLED=false
OPENCLAW_VERSION=""
OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
OPENCLAW_ENV_FILE="${HOME}/.openclaw/.env"

# 命令队列（用于 dry-run 预览与 apply 批量执行）
declare -a PENDING_DESCS=()
declare -a PENDING_CMDS=()

# ─────────────────────────────────────────────────────────────────────────────
# 模块 1：基础环境检查
# ─────────────────────────────────────────────────────────────────────────────

# 检查单个命令是否存在，并打印版本
_check_cmd() {
  local cmd="$1"
  local version_flag="${2:---version}"
  if command -v "$cmd" &>/dev/null; then
    local ver
    ver="$(${cmd} ${version_flag} 2>&1 | head -1)"
    log_ok "${cmd} 已安装  →  ${ver}"
    return 0
  else
    log_warn "${cmd} 未找到"
    return 1
  fi
}

# 检查 Homebrew（macOS 首选包管理器）
check_homebrew() {
  log_section "检查 Homebrew"
  if _check_cmd brew --version; then
    log_info "Homebrew prefix: $(brew --prefix)"
  else
    log_warn "建议安装 Homebrew：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    CHECKS_PASSED=false
  fi
}

# 检查 Node.js / npm / pnpm
check_node() {
  log_section "检查 Node.js / npm / pnpm"

  local node_ok=false npm_ok=false pnpm_ok=false

  if _check_cmd node --version; then
    node_ok=true
    local node_major
    node_major=$(node -e "process.stdout.write(process.version.replace('v','').split('.')[0])")
    if (( node_major < 18 )); then
      log_warn "Node.js 版本过低（当前 v${node_major}），建议升级至 v18 或更高版本"
      CHECKS_PASSED=false
    fi
  else
    log_error "Node.js 未安装。可通过 Homebrew 安装：brew install node"
    CHECKS_PASSED=false
  fi

  if _check_cmd npm --version; then
    npm_ok=true
  else
    log_error "npm 未找到（通常随 Node.js 一同安装）"
    CHECKS_PASSED=false
  fi

  if _check_cmd pnpm --version; then
    pnpm_ok=true
  else
    log_error "pnpm 未安装。可通过 npm 安装：npm install -g pnpm"
    CHECKS_PASSED=false
  fi
}

# 检查相关联动工具（git / curl）
check_related_tools() {
  log_section "检查相关工具"
  local tools=("git" "curl")
  for t in "${tools[@]}"; do
    _check_cmd "$t" --version || log_info "（相关工具）${t} 未安装，部分功能可能受限"
  done
}

# 汇总入口：运行全部基础检查
run_prerequisite_checks() {
  log_section "阶段 1 — 基础依赖检查"
  check_homebrew
  check_node
  check_related_tools

  if $CHECKS_PASSED; then
    log_ok "所有必要依赖检查通过 ✓"
  else
    log_warn "部分依赖缺失或版本不满足要求，请按提示修复后重新运行"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 模块 2：OpenClaw 安装状态检查
# ─────────────────────────────────────────────────────────────────────────────

# 检查 OpenClaw CLI
check_openclaw_cli() {
  log_info "检查 OpenClaw CLI..."
  if command -v openclaw &>/dev/null; then
    OPENCLAW_VERSION="$(openclaw --version 2>&1 | head -1)"
    log_ok "openclaw CLI 已安装  →  ${OPENCLAW_VERSION}"
    OPENCLAW_INSTALLED=true
    return 0
  else
    log_warn "openclaw CLI 未找到（命令: openclaw）"
    return 1
  fi
}

# 检查 OpenClaw Gateway（进程或服务是否运行）
check_openclaw_gateway() {
  log_info "检查 OpenClaw Gateway 进程..."
  if pgrep -qf "openclaw.*(gateway|serve)" 2>/dev/null; then
    log_ok "OpenClaw Gateway 进程正在运行"
  else
    log_warn "未检测到 OpenClaw Gateway 运行中的进程"
  fi
}

# 检查 OpenClaw 核心配置文件
check_openclaw_config() {
  log_info "检查 OpenClaw 核心配置文件：${OPENCLAW_CONFIG_FILE}"
  if [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    log_ok "配置文件存在：${OPENCLAW_CONFIG_FILE}"
  else
    log_warn "核心配置文件不存在：${OPENCLAW_CONFIG_FILE}"
    log_info "如果已通过非默认方式安装，请手动指定 OPENCLAW_CONFIG_FILE 环境变量"
    exit 1
  fi
}

# 检查默认端口 18789 是否对外（0.0.0.0）暴露（A-2）
check_port_exposure() {
  log_info "检查默认端口 18789 网络暴露状态..."
  local exposed=false

  # 优先使用 lsof（macOS 内置），回退到 netstat
  if command -v lsof &>/dev/null; then
    if lsof -nP -iTCP:18789 -sTCP:LISTEN 2>/dev/null | grep -q '\*:18789\|0\.0\.0\.0:18789'; then
      exposed=true
    fi
  elif command -v netstat &>/dev/null; then
    if netstat -an 2>/dev/null | grep -qE '(0\.0\.0\.0|\*)[\.:]18789.*LISTEN'; then
      exposed=true
    fi
  else
    log_warn "无法检测端口暴露状态（lsof 和 netstat 均不可用）"
    return
  fi

  if $exposed; then
    log_warn "⚠️  端口 18789 当前绑定在 0.0.0.0，可被外网直接访问！"
    log_warn "    建议：通过防火墙/安全组限制外网访问，或将绑定地址改为 127.0.0.1"
  else
    log_ok "端口 18789 未对外暴露（未监听或仅绑定本机）"
  fi
}

# 检查配置文件中是否使用默认端口 18789（B-3）
check_default_port_in_config() {
  log_info "检查配置文件中的 Gateway 端口..."
  local port_val
  port_val=$(grep -Eo '"port"\s*:\s*[0-9]+' "$OPENCLAW_CONFIG_FILE" 2>/dev/null | grep -Eo '[0-9]+$' | head -1)

  if [[ "$port_val" == "18789" ]]; then
    log_warn "配置文件中 gateway.port 仍为默认值 18789"
    log_warn "    建议修改为非默认端口（1024-65535），降低被扫描暴露风险"
  elif [[ -n "$port_val" ]]; then
    log_ok "Gateway 端口已修改为非默认值：${port_val}"
  else
    log_info "未在配置文件中检测到 gateway.port 字段（可能使用程序默认值 18789）"
  fi
}

# 汇总入口：运行 OpenClaw 安装检查
run_openclaw_checks() {
  log_section "阶段 2 — OpenClaw 安装状态检查"
  check_openclaw_cli
  check_openclaw_gateway
  check_openclaw_config
  check_port_exposure
  check_default_port_in_config

  if $OPENCLAW_INSTALLED; then
    log_ok "OpenClaw 已安装，可继续执行加固操作"
  else
    log_warn "OpenClaw CLI 未安装或未在 PATH 中。加固脚本将以受限模式运行"
    log_info "请参考安装文档：https://docs.openclaw.ai/cli"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 模块 3：安全加固函数集（各函数独立，便于菜单调用）
# ─────────────────────────────────────────────────────────────────────────────

# 通用：备份文件——将备份操作加入命令队列
_backup_file() {
  local target="$1"
  if [[ ! -f "$target" ]]; then return; fi
  local backup="${target}.bak.$(date +%Y%m%d_%H%M%S)"
  PENDING_DESCS+=("备份文件：${target##*/}  →  ${backup##*/}")
  PENDING_CMDS+=("cp $(printf '%q' "$target") $(printf '%q' "$backup")")
}

# 通用：将待执行命令加入队列（无论 dry-run 还是 apply 模式均只入队）
_apply_or_preview() {
  local description="$1"
  shift
  local cmd_str
  cmd_str=$(printf '%q ' "$@")
  PENDING_DESCS+=("$description")
  PENDING_CMDS+=("${cmd_str% }")
}

# 统一展示或执行队列中的全部命令
flush_pending_commands() {
  local total=${#PENDING_CMDS[@]}

  if (( total == 0 )); then
    log_info "无待执行命令"
    return
  fi

  log_section "待执行命令汇总（共 ${total} 条）"
  local i
  for (( i = 0; i < total; i++ )); do
    printf "  %b[%d]%b %s\n" "${BOLD}" "$((i+1))" "${RESET}" "${PENDING_DESCS[$i]}"
    printf "       %b→%b %s\n" "${CYAN}" "${RESET}" "${PENDING_CMDS[$i]}"
  done
  printf "\n"

  if $DRY_RUN; then
    printf "%b──────────────────────────────────────────%b\n" "${BOLD}${CYAN}" "${RESET}"
    log_info "以上为 DRY-RUN 预览，未做任何实际修改。使用 --apply 执行变更"
  else
    log_section "开始执行全部变更（共 ${total} 条）"
    for (( i = 0; i < total; i++ )); do
      log_info "[$((i+1))/${total}] 执行：${PENDING_DESCS[$i]}"
      if eval "${PENDING_CMDS[$i]}"; then
        log_ok "完成"
      else
        log_error "失败：${PENDING_DESCS[$i]}"
      fi
    done
    log_ok "所有加固操作已执行。请检查备份文件（*.bak.*）并验证服务是否正常"
  fi
}

# ── 加固项 1：禁用匿名 / 公共 Token ─────────────────────────────────────────
harden_gateway_auth() {
  log_section "确保 Gateway 认证模式已启用"
  # 参考文档：https://docs.openclaw.ai/gateway/configuration-reference#gateway
  # OpenClaw 通过 gateway.auth.mode 控制认证，合法值：none | token | password | trusted-proxy
  # mode: "none" 表示完全不鉴权，任何能访问端口的客户端均可使用 Gateway，需修复。
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # 检测 mode: "none"（JSON5）或 "mode": "none"（JSON）两种写法
  if grep -qE '"?mode"?\s*:\s*"none"' "$config_file" 2>/dev/null; then
    _apply_or_preview \
      '将 gateway.auth.mode 由 "none" 改为 "token"（启用 Token 认证）' \
      /usr/bin/sed -i '' -E 's/("?mode"?[[:space:]]*:[[:space:]]*)"none"/\1"token"/g' "$config_file"
    log_warn "检测到 gateway.auth.mode 为 none，已加入修复队列；修复后请在配置中补充 gateway.auth.token"
  elif grep -qE '"?token"?\s*:|"?password"?\s*:' "$config_file" 2>/dev/null; then
    log_ok "Gateway 认证已配置（token 或 password）"
  else
    log_warn "未检测到 gateway.auth.token / gateway.auth.password 配置"
    log_warn "若 Gateway 绑定非回环地址，将拒绝启动；建议在配置中添加 gateway.auth.token"
  fi
}

# ── Gateway 第二部分 2：非默认端口检查与修改 ─────────────────────────────────
harden_gateway_port() {
  log_section "Gateway 端口加固"
  # 参考文档：https://docs.openclaw.ai/gateway/configuration-reference#gateway
  # 默认端口 18789 容易被针对 OpenClaw 的定向扫描发现，建议修改为非默认端口
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # 提取 gateway.port 配置值（兼容 JSON5 和 JSON 两种写法）
  local port_val
  port_val=$(grep -Eo '"?port"?\s*:\s*[0-9]+' "$config_file" 2>/dev/null \
    | grep -Eo '[0-9]+$' | head -1) || true

  # 端口非默认值时直接通过
  if [[ -n "$port_val" ]] && [[ "$port_val" != "18789" ]]; then
    log_ok "Gateway 端口已为非默认值：${port_val}"
    return
  fi

  if [[ -z "$port_val" ]]; then
    log_warn "配置文件未显式设置 gateway.port，当前隐式使用默认值 18789"
  else
    log_warn "Gateway 端口为默认值 18789，存在被定向扫描的风险"
  fi

  # 非交互式终端（如管道重定向）时跳过交互，避免挂起
  if [[ ! -t 0 ]]; then
    log_info "非交互模式，跳过端口选择；可手动修改 openclaw.json 中的 gateway.port"
    return
  fi

  # ── 交互式端口选择 ────────────────────────────────────────────────────────────
  printf "\n"
  printf "  %b请选择端口修改方式：%b\n" "${BOLD}" "${RESET}"
  printf "  %b[1]%b 随机生成一个五位端口号（10000–65535）\n" "${BOLD}" "${RESET}"
  printf "  %b[2]%b 手动输入端口号\n" "${BOLD}" "${RESET}"
  printf "  %b[3]%b 保持现状，不修改端口\n" "${BOLD}" "${RESET}"
  printf "\n"

  local choice
  read -p "  请输入选项 [1/2/3]（默认 1）: " choice
  choice="${choice:-1}"

  local new_port=""
  case "$choice" in
    1)
      # 使用 /dev/urandom 生成 10000–65535 范围内的随机端口
      local raw
      raw=$(od -An -N2 -tu2 /dev/urandom | tr -d ' \n') || raw=$$
      new_port=$(( raw % 55536 + 10000 ))
      log_info "随机生成端口：${new_port}"
      ;;
    2)
      read -p "  请输入新端口号（1024–65535）: " new_port
      if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1024 || new_port > 65535 )); then
        log_error "端口号无效（${new_port}），跳过端口修改"
        return
      fi
      log_info "已指定端口：${new_port}"
      ;;
    3)
      log_info "已选择保持现状，跳过端口修改"
      return
      ;;
    *)
      log_warn "无效选项 '${choice}'，跳过端口修改"
      return
      ;;
  esac

  # ── 将端口变更加入执行队列 ────────────────────────────────────────────────────
  if [[ -n "$port_val" ]]; then
    # 配置文件中已有显式 port 字段，直接替换 18789
    _apply_or_preview \
      "将 gateway.port 由 ${port_val} 改为 ${new_port}" \
      /usr/bin/sed -i '' -E \
        "s/(\"?port\"?[[:space:]]*:[[:space:]]*)${port_val}/\\1${new_port}/g" \
        "$config_file"
  else
    # 未显式设置 port，无法安全自动插入，给出手动操作提示
    log_warn "配置文件中不存在 gateway.port 字段，无法自动插入"
    log_info "请在 openclaw.json 的 gateway 配置块中手动添加："
    log_info "  port: ${new_port}"
  fi
}

# ── 加固项 2：Gateway 绑定地址加固 ──────────────────────────────────────────
harden_network_bindings() {
  log_section "Gateway 绑定地址加固"
  # 目标：确保 gateway.mode 为 "local" 且 gateway.bind 为 "loopback"
  # 两项须同时满足，Gateway 才真正仅对本机开放；缺少任一项均视为安全风险
  # 参考文档：https://docs.openclaw.ai/gateway/configuration-reference#gateway
  #   gateway.mode  合法值：local（仅本机）| 其他值（对外暴露）
  #   gateway.bind  合法值（来自文档）：
  #     loopback（默认）— 仅本机回环，最安全 ✓
  #     auto            — 自动探测网络接口，存在对外暴露风险
  #     lan             — 绑定 0.0.0.0，局域网/公网均可访问，危险
  #     tailnet         — 仅 Tailscale 虚拟 IP，暴露给 Tailscale 网络
  #     custom          — 自定义地址，需人工评估
  # 注意：仅提取 gateway {} 顶层（花括号深度 = 1）字段，不会误匹配 gateway.auth.mode 等子项
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # 通用 awk 提取函数：仅在 gateway { } 块内（深度 = 1）提取指定字段的字符串值
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
          sub(/".*/, "", val)
          print val
          exit
        }
      }
    ' "$config_file" 2>/dev/null
  }

  local mode_val bind_val
  mode_val=$(_extract_gw_field "mode") || true
  bind_val=$(_extract_gw_field "bind") || true

  # ── 检查 gateway.mode ────────────────────────────────────────────────────────
  if [[ -z "$mode_val" ]] || [[ "$mode_val" == "local" ]]; then
    log_ok "gateway.mode：\"${mode_val:-local（默认）}\"  ✓"
  else
    log_warn "gateway.mode 当前为 \"${mode_val}\"，Gateway 以非本地模式运行"
    _apply_or_preview \
      "将 gateway.mode 由 \"${mode_val}\" 改为 \"local\"（限制仅本机访问）" \
      /usr/bin/sed -i '' -E \
        "s/(\"?mode\"?[[:space:]]*:[[:space:]]*)\"${mode_val}\"/\\1\"local\"/g" \
        "$config_file"
  fi

  # ── 检查 gateway.bind ────────────────────────────────────────────────────────
  if [[ -z "$bind_val" ]] || [[ "$bind_val" == "loopback" ]]; then
    log_ok "gateway.bind：\"${bind_val:-loopback（默认）}\"  ✓"
  else
    case "$bind_val" in
      lan)
        log_warn "gateway.bind=\"lan\" → 绑定 0.0.0.0，Gateway 对局域网/公网完全暴露，高危！"
        _apply_or_preview \
          "将 gateway.bind 由 \"lan\" 改为 \"loopback\"（限制仅本机访问）" \
          /usr/bin/sed -i '' -E \
            's/("?bind"?[[:space:]]*:[[:space:]]*)"lan"/\1"loopback"/g' \
            "$config_file"
        ;;
      auto)
        log_warn "gateway.bind=\"auto\" → 自动探测网络接口，可能绑定对外地址，存在暴露风险"
        _apply_or_preview \
          "将 gateway.bind 由 \"auto\" 改为 \"loopback\"（限制仅本机访问）" \
          /usr/bin/sed -i '' -E \
            's/("?bind"?[[:space:]]*:[[:space:]]*)"auto"/\1"loopback"/g' \
            "$config_file"
        ;;
      tailnet)
        log_warn "gateway.bind=\"tailnet\" → 仅 Tailscale 虚拟网络可访问，如不使用 Tailscale 建议改为 loopback"
        _apply_or_preview \
          "将 gateway.bind 由 \"tailnet\" 改为 \"loopback\"（限制仅本机访问）" \
          /usr/bin/sed -i '' -E \
            's/("?bind"?[[:space:]]*:[[:space:]]*)"tailnet"/\1"loopback"/g' \
            "$config_file"
        ;;
      custom)
        log_warn "gateway.bind=\"custom\" → 自定义绑定地址，需人工确认是否仅限本机"
        log_info "若非必要，建议改为：bind: \"loopback\""
        ;;
      *)
        log_warn "gateway.bind=\"${bind_val}\" → 未知值，无法自动评估，请人工检查"
        ;;
    esac
  fi

  # ── 综合判定：两项须同时安全 ──────────────────────────────────────────────────
  local mode_ok=false bind_ok=false
  { [[ -z "$mode_val" ]] || [[ "$mode_val" == "local" ]]; }       && mode_ok=true
  { [[ -z "$bind_val" ]] || [[ "$bind_val" == "loopback" ]]; }    && bind_ok=true

  if $mode_ok && $bind_ok; then
    log_ok "gateway.mode 与 gateway.bind 均安全，Gateway 仅对本机开放"
  else
    log_warn "需同时满足 gateway.mode=\"local\" 与 gateway.bind=\"loopback\"，才能完全限制本机访问"
  fi
}

# ── 第一部分 1：openclaw.json 文件及目录权限 ─────────────────────────────────
harden_config_file_perms() {
  log_section "openclaw.json 文件权限"
  # 目标：仅当前用户可读写（600），配置目录仅当前用户可访问（700）
  local config_file="${OPENCLAW_CONFIG_FILE}"
  local config_dir="${OPENCLAW_CONFIG_DIR}"
  local current_user
  current_user="$(id -un)"

  # ── 配置文件 ──────────────────────────────────────────────────────────────────
  local file_owner file_perm
  file_owner=$(stat -f '%Su' "$config_file" 2>/dev/null || echo "unknown")
  file_perm=$(stat -f '%A' "$config_file" 2>/dev/null || echo "000")

  if [[ "$file_owner" != "$current_user" ]]; then
    log_warn "openclaw.json 所有者为 ${file_owner}，当前用户为 ${current_user}，请手动确认"
  fi

  if [[ "$file_perm" == "600" ]]; then
    log_ok "openclaw.json 权限已为 600（仅所有者读写）"
  else
    log_warn "openclaw.json 当前权限为 ${file_perm}，应设置为 600"
    _apply_or_preview \
      "设置 openclaw.json 权限为 600（当前：${file_perm}）" \
      chmod 600 "$config_file"
  fi

  # ── 配置目录 ──────────────────────────────────────────────────────────────────
  if [[ -d "$config_dir" ]]; then
    local dir_perm
    dir_perm=$(stat -f '%A' "$config_dir" 2>/dev/null || echo "000")
    if [[ "$dir_perm" == "700" ]]; then
      log_ok "${config_dir} 目录权限已为 700"
    else
      log_warn "${config_dir} 目录当前权限为 ${dir_perm}，应设置为 700"
      _apply_or_preview \
        "设置 ${config_dir} 目录权限为 700（当前：${dir_perm}）" \
        chmod 700 "$config_dir"
    fi
  fi
}

# ── 第一部分 2：.env 环境变量文件权限 ────────────────────────────────────────
harden_env_file_perms() {
  log_section ".env 环境变量文件权限"
  # 目标：.env 含有 API Key 等敏感信息，仅当前用户可读写（600）
  local env_file="${OPENCLAW_ENV_FILE}"
  local current_user
  current_user="$(id -un)"

  if [[ ! -f "$env_file" ]]; then
    log_info ".env 文件不存在，跳过（${env_file}）"
    return
  fi

  local file_owner file_perm
  file_owner=$(stat -f '%Su' "$env_file" 2>/dev/null || echo "unknown")
  file_perm=$(stat -f '%A' "$env_file" 2>/dev/null || echo "000")

  if [[ "$file_owner" != "$current_user" ]]; then
    log_warn ".env 所有者为 ${file_owner}，当前用户为 ${current_user}，请手动确认"
  fi

  if [[ "$file_perm" == "600" ]]; then
    log_ok ".env 权限已为 600（仅所有者读写）"
  else
    log_warn ".env 当前权限为 ${file_perm}，应设置为 600"
    _apply_or_preview \
      "设置 .env 权限为 600（当前：${file_perm}）" \
      chmod 600 "$env_file"
  fi
}

# ── 第一部分 3：将 models.providers.*.apiKey 迁移到 .env ──────────────────────
harden_apikey_to_env() {
  log_section "Models Providers API Key 检测与迁移"
  # 目标：仅扫描 openclaw.json 中 models.providers.<name>.apiKey 字段，
  #       当值为明文字符串（非 ${...} 占位符）时：
  #         1. 将 <PROVIDER_UPPER>_API_KEY=<value> 追加写入 .env
  #         2. 将 openclaw.json 中的明文值替换为 ${<PROVIDER_UPPER>_API_KEY}
  # 变量名规则：provider 名转为大写下划线 + _API_KEY
  #   lmstudio     → LMSTUDIO_API_KEY
  #   custom-proxy → CUSTOM_PROXY_API_KEY
  #   minimax      → MINIMAX_API_KEY
  # 参考：https://docs.openclaw.ai/gateway/configuration-examples#common-patterns
  local config_file="${OPENCLAW_CONFIG_FILE}"
  local env_file="${OPENCLAW_ENV_FILE}"
  local env_dir
  env_dir="$(dirname "$env_file")"

  if [[ ! -f "$config_file" ]]; then
    log_info "配置文件不存在，跳过 API Key 迁移检查"
    return
  fi

  # 用 awk 扫描 models.providers.<name>.apiKey 明文值
  # 输出格式：<行号>:<provider名称>:<明文值>
  # 深度跟踪：进入 providers: { 后，rel_depth=0；
  #   provider 名称行（如 lmstudio: {）时 rel_depth 变为 1；
  #   在 rel_depth==1 时看到 apiKey 行即为目标
  local -a hits=()
  # bash 使用 mapfile（bash 4.0+）或 while read
  while IFS= read -r _hit_line; do
    hits+=("$_hit_line")
  done < <(
    awk '
      BEGIN { in_providers=0; rel_depth=0; provider="" }

      # 进入 models.providers 块（JSON / JSON5 均兼容）
      !in_providers && /"?providers"?[[:space:]]*:[[:space:]]*\{/ {
        in_providers=1; rel_depth=0; next
      }

      in_providers {
        line = $0
        # 按字符统计花括号，更新相对深度
        n = length(line)
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if      (c == "{") rel_depth++
          else if (c == "}") { rel_depth--; if (rel_depth < 0) { in_providers=0; break } }
        }
        if (!in_providers) next

        # rel_depth==1 且行以 { 结尾 → 记录 provider 名称
        # 兼容：  "custom-proxy": {   或   lmstudio: {
        if (rel_depth == 1 && line ~ /\{[[:space:]]*(\/\/.*)?$/) {
          k = line
          sub(/^[[:space:]]*"?/, "",  k)
          sub(/"?[[:space:]]*:[[:space:]]*\{.*/, "", k)
          provider = k
        }

        # rel_depth==1，apiKey 字段，值不以 ${ 开头（即明文）
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
    log_ok "models.providers 中未发现明文 apiKey，已全部使用占位符或未配置  ✓"
    return
  fi

  log_warn "发现 ${#hits[@]} 处 models.providers apiKey 明文值，将提取至 .env 并替换为 \${VAR_NAME}："

  declare -A assigned_vars=()
  local migration_count=0

  for hit in "${hits[@]}"; do
    local lineno="${hit%%:*}"
    local rest="${hit#*:}"
    local provider_name="${rest%%:*}"
    local field_value="${rest#*:}"

    [[ -z "$provider_name" || -z "$field_value" ]] && continue

    # provider 名 → UPPER_SNAKE_CASE + _API_KEY
    local var_base
    var_base=$(printf '%s' "$provider_name" \
      | sed 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' \
      | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    var_base="${var_base}_API_KEY"

    # 同名冲突处理：已分配则追加 _2, _3 …
    local var_name="$var_base"
    local suffix=2
    while [[ -n "${assigned_vars[$var_name]+_}" ]]; do
      if [[ -f "$env_file" ]]; then
        local existing_val
        existing_val=$(grep -E "^${var_name}=" "$env_file" 2>/dev/null \
          | head -1 | cut -d= -f2-)
        [[ "$existing_val" == "$field_value" ]] && break  # 同值可复用
      fi
      var_name="${var_base}_${suffix}"
      (( suffix++ ))
    done
    assigned_vars[$var_name]="$field_value"

    log_info "  第 ${lineno} 行：models.providers.${provider_name}.apiKey → \${${var_name}}"

    # ── 队列操作 1：写入 .env ────────────────────────────────────────────────
    local already_in_env=false
    if [[ -f "$env_file" ]] && grep -qE "^${var_name}=" "$env_file" 2>/dev/null; then
      already_in_env=true
    fi

    if ! $already_in_env; then
      # 若 .env 不存在，先创建并设置 600 权限，再追加内容
      _apply_or_preview \
        "写入 .env：${var_name}=<secret>  (来自 models.providers.${provider_name}.apiKey)" \
        bash -c "mkdir -p $(printf '%q' "$env_dir") && \
          { [[ -f $(printf '%q' "$env_file") ]] || { touch $(printf '%q' "$env_file") && chmod 600 $(printf '%q' "$env_file"); }; } && \
          printf '%s=%s\n' $(printf '%q' "$var_name") $(printf '%q' "$field_value") \
          >> $(printf '%q' "$env_file")"
    else
      log_info "  .env 中已存在 ${var_name}，跳过写入"
    fi

    # ── 队列操作 2：替换 openclaw.json 中的明文值为 ${VAR_NAME} ──────────────
    local escaped_value
    escaped_value=$(printf '%s' "$field_value" | sed 's/[[\.*^$()+?{|]/\\&/g')

    _apply_or_preview \
      "替换 openclaw.json 第 ${lineno} 行 apiKey 明文值为 \${${var_name}}" \
      perl -i -e \
        "my \$ln=0; while(<>){ \$ln++; if(\$ln==${lineno}){ s/(\"?apiKey\"?\\s*:\\s*)\"${escaped_value}\"/\${1}\"\\\${${var_name}}\"/; } print; }" \
        "$config_file"

    (( migration_count++ ))
  done

  if (( migration_count > 0 )); then
    log_warn "共 ${migration_count} 处 apiKey 待迁移。请在 --apply 后重启 Gateway 以加载新配置"
    log_info "迁移后请确认 .env 权限为 600：chmod 600 $(printf '%q' "$env_file")"
  fi
}

# ── 心跳频率检查 ────────────────────────────────────────────────────────────
optimize_heartbeat() {
  log_section "agents.defaults.heartbeat 最小可用配置检查"
  # 参考文档：https://docs.openclaw.ai/gateway/heartbeat
  # 最小可用配置（Quick Start）：
  #   every:       心跳间隔，默认 30m；过短浪费 token
  #   target:      投递目标；默认 "none"（只运行不投递），建议改为 "last"（投递给最近联系人）
  #   lightContext: 仅加载 HEARTBEAT.md，减少每次心跳的 token 消耗；建议 true
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # ── 检查 heartbeat.every ───────────────────────────────────────────────────
  local heartbeat_every
  heartbeat_every=$(grep -Eo '"every"\s*:\s*"[^"]*"' "$config_file" 2>/dev/null \
    | grep -Eo '"[^"]*"$' | tr -d '"' | head -1) || true

  if [[ -n "$heartbeat_every" ]]; then
    local hb_num hb_unit
    hb_num=$(echo "$heartbeat_every" | grep -Eo '^[0-9]+')
    hb_unit=$(echo "$heartbeat_every" | grep -Eo '[a-z]+$')
    local too_frequent=false
    [[ "$hb_unit" == "s" ]] && too_frequent=true
    [[ "$hb_unit" == "m" ]] && (( hb_num <= 10 )) && too_frequent=true

    if $too_frequent; then
      log_warn "heartbeat.every 过短（当前：${heartbeat_every}），每次心跳均消耗完整 token，建议改为 55m 或更长"
      log_warn "当前频率每天约产生 $(( 1440 / hb_num )) 次 API 调用"
      _apply_or_preview \
        "将 heartbeat.every 由 ${heartbeat_every} 改为 55m" \
        /usr/bin/sed -i '' "s/\"every\": \"${heartbeat_every}\"/\"every\": \"55m\"/g" "$config_file"
    else
      log_ok "heartbeat.every：\"${heartbeat_every}\"  ✓"
    fi
  else
    log_info "未配置 heartbeat.every（使用默认值 30m，建议显式设置为 55m）"
  fi

  # ── 检查 heartbeat.target ──────────────────────────────────────────────────
  # 默认值 "none"：心跳运行但不向任何渠道投递消息
  local target_val
  target_val=$(grep -Eo '"target"\s*:\s*"[^"]*"' "$config_file" 2>/dev/null \
    | grep -Eo '"[^"]*"$' | tr -d '"' | head -1) || true

  if [[ -z "$target_val" ]] || [[ "$target_val" == "none" ]]; then
    log_warn "heartbeat.target 为 \"${target_val:-none（默认）}\"\uff0c心跳运行结果不会投递给任何渠道"
    log_info "如需接收心跳消息，建议设置：target: \"last\"（投递给最近联系人）"
  else
    log_ok "heartbeat.target：\"${target_val}\"  ✓"
  fi

  # ── 检查 heartbeat.lightContext ────────────────────────────────────────────
  # lightContext: true 时心跳仅加载 HEARTBEAT.md，显著降低每次心跳的 token 消耗
  local light_val
  light_val=$(grep -Eo '"lightContext"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true

  if [[ "$light_val" == "true" ]]; then
    log_ok "heartbeat.lightContext：true  ✓（仅加载 HEARTBEAT.md，节省 token）"
  else
    log_warn "heartbeat.lightContext 为 \"${light_val:-false（默认）}\"\uff0c每次心跳加载全量 bootstrap 文件，消耗更多 token"
    log_info "建议设置：lightContext: true"
  fi
}

# ── agents.defaults.compaction 配置检查 ─────────────────────────────────────
optimize_compaction() {
  log_section "agents.defaults.compaction 配置"
  # 参考文档：https://docs.openclaw.ai/gateway/configuration-reference#agents-defaults-compaction
  # 官方推荐配置：
  #   mode: "safeguard"          — 对长对话历史用分块摘要，防止关键信息丢失
  #   identifierPolicy: "strict" — 压缩时保留 ID、端口等不可变标识符（默认值）
  #   memoryFlush.enabled: true  — 压缩前自动触发一次记忆写入
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # ── 检查 compaction 块是否存在 ──────────────────────────────────────────────
  if ! grep -qE '"compaction"|compaction[[:space:]]*:' "$config_file" 2>/dev/null; then
    log_warn "未配置 agents.defaults.compaction，当前使用内置 mode: default"
    log_info "官方推荐在 openclaw.json 中显式添加："
    log_info "  agents.defaults.compaction.mode: \"safeguard\""
    log_info "  agents.defaults.compaction.identifierPolicy: \"strict\""
    log_info "  agents.defaults.compaction.memoryFlush.enabled: true"
    return
  fi

  # ── 检查 compaction.mode ────────────────────────────────────────────────────
  # 使用 awk 提取 compaction {} 块内（深度=1）的 mode 字段
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
        sub(/".*/, "", val)
        print val; exit
      }
    }
  ' "$config_file" 2>/dev/null) || true

  case "${mode_val:-default}" in
    safeguard)
      log_ok "compaction.mode：\"safeguard\"  ✓"
      ;;
    default|"")
      log_warn "compaction.mode 为 \"${mode_val:-default}\"，对长对话历史压缩质量较低"
      if [[ -n "$mode_val" ]]; then
        _apply_or_preview \
          "将 compaction.mode 由 \"default\" 改为 \"safeguard\"（分块摘要，防止长对话信息丢失）" \
          /usr/bin/sed -i '' -E \
            's/("?mode"?[[:space:]]*:[[:space:]]*)"default"/\1"safeguard"/g' \
            "$config_file"
      else
        log_info "请在 compaction 配置块中手动添加：mode: \"safeguard\""
      fi
      ;;
    *)
      log_info "compaction.mode：\"${mode_val}\"（自定义值，请确认符合预期）"
      ;;
  esac

  # ── 检查 identifierPolicy ───────────────────────────────────────────────────
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
        sub(/".*/, "", val)
        print val; exit
      }
    }
  ' "$config_file" 2>/dev/null) || true

  if [[ -z "$id_policy" ]] || [[ "$id_policy" == "strict" ]]; then
    log_ok "compaction.identifierPolicy：\"${id_policy:-strict（默认）}\"  ✓"
  elif [[ "$id_policy" == "off" ]]; then
    log_warn "compaction.identifierPolicy=\"off\"，压缩时 ID / 端口等标识符可能被省略"
    log_info "建议改为：identifierPolicy: \"strict\""
  else
    log_info "compaction.identifierPolicy：\"${id_policy}\""
  fi
}

# ── channels.defaults 配置检查 ───────────────────────────────────────────────
check_channel_defaults() {
  log_section "channels.defaults 配置检查"
  # 参考文档：https://docs.openclaw.ai/gateway/configuration-reference#channel-defaults-and-heartbeat
  # 官方默认值均为安全/推荐值，无需额外修改：
  #   groupPolicy: "allowlist"   — 群组仅允许列表内成员（fail-closed）
  #   heartbeat.showAlerts: true — 心跳报告显示降级/错误状态（保持告警可见性）
  #   heartbeat.showOk: false    — 不显示正常状态（减少噪音）
  #   heartbeat.useIndicator: true — 紧凑指示器风格输出
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # ── 提取 channels.defaults.groupPolicy（限 defaults 块内，避免误匹配 per-channel 覆盖）
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
        sub(/".*/, "", val)
        print val; exit
      }
    }
  ' "$config_file" 2>/dev/null) || true

  # ── 提取 heartbeat.* 子字段（在 channels.defaults.heartbeat 中唯一，直接 grep）
  local show_alerts show_ok use_indicator
  show_alerts=$(grep -Eo '"showAlerts"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true
  show_ok=$(grep -Eo '"showOk"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true
  use_indicator=$(grep -Eo '"useIndicator"\s*:\s*(true|false)' "$config_file" 2>/dev/null \
    | grep -Eo '(true|false)$' | head -1) || true

  # ── 所有字段均未配置 → 完全采用官方默认值 ────────────────────────────────────
  if [[ -z "$group_policy" && -z "$show_alerts" && -z "$show_ok" && -z "$use_indicator" ]]; then
    log_ok "channels.defaults 未显式配置，当前采用官方全部默认值  ✓"
    log_info "  groupPolicy: \"allowlist\"（fail-closed，仅允许列表内群组）"
    log_info "  heartbeat.showAlerts: true  |  heartbeat.showOk: false  |  heartbeat.useIndicator: true"
    return
  fi

  # ── groupPolicy ───────────────────────────────────────────────────────────
  case "${group_policy:-allowlist}" in
    allowlist|"")
      log_ok "channels.defaults.groupPolicy：\"${group_policy:-allowlist（默认）}\"  ✓（fail-closed，仅允许列表内群组）"
      ;;
    open)
      log_warn "channels.defaults.groupPolicy=\"open\"，群组允许列表已被绕过，所有群组均可访问 Gateway"
      log_info "如无必要，建议改回官方默认值：groupPolicy: \"allowlist\""
      ;;
    disabled)
      log_info "channels.defaults.groupPolicy=\"disabled\"（所有群组消息被屏蔽）"
      ;;
    *)
      log_info "channels.defaults.groupPolicy：\"${group_policy}\""
      ;;
  esac

  # ── heartbeat.showAlerts ──────────────────────────────────────────────────
  # 默认 true；改为 false 会屏蔽降级/错误告警，降低可见性
  if [[ -z "$show_alerts" ]] || [[ "$show_alerts" == "true" ]]; then
    log_ok "channels.defaults.heartbeat.showAlerts：${show_alerts:-true（默认）}  ✓"
  else
    log_warn "channels.defaults.heartbeat.showAlerts=false，降级/错误状态将不出现在心跳报告中"
    log_info "官方默认值为 true，建议保持以确保告警可见性"
  fi

  # ── heartbeat.showOk / heartbeat.useIndicator（仅提示当前值）────────────────
  log_info "channels.defaults.heartbeat.showOk：${show_ok:-false（默认）}"
  log_info "channels.defaults.heartbeat.useIndicator：${use_indicator:-true（默认）}"
}

# ── 第一部分 3：凭证文件与认证配置权限 ──────────────────────────────────────
harden_credentials_perms() {
  log_section "凭证与认证文件权限"
  # 目标：渠道凭证及 auth-profiles.json 仅当前用户可读写（600）
  # 参考文档：https://docs.openclaw.ai/zh-CN/gateway/security#0.7
  # security audit --fix 会收紧这些文件的权限
  local config_dir="${OPENCLAW_CONFIG_DIR}"
  local cred_dir="${config_dir}/credentials"
  local any_file=false

  # ── credentials/ 目录 ────────────────────────────────────────────────────
  if [[ -d "$cred_dir" ]]; then
    any_file=true
    local dir_perm
    dir_perm=$(stat -f '%A' "$cred_dir" 2>/dev/null || echo "000")
    if [[ "$dir_perm" == "700" ]]; then
      log_ok "credentials/ 目录权限已为 700"
    else
      log_warn "credentials/ 目录当前权限为 ${dir_perm}，应设置为 700"
      _apply_or_preview \
        "设置 credentials/ 目录权限为 700（当前：${dir_perm}）" \
        chmod 700 "$cred_dir"
    fi

    # ── credentials/*.json ───────────────────────────────────────────────
    # bash 使用 nullglob 选项来处理无匹配情况
    shopt -s nullglob
    local f
    for f in "$cred_dir"/*.json; do
      [[ -f "$f" ]] || continue
      local fperm
      fperm=$(stat -f '%A' "$f" 2>/dev/null || echo "000")
      if [[ "$fperm" == "600" ]]; then
        log_ok "${f##*/} 权限已为 600"
      else
        log_warn "${f##*/} 当前权限为 ${fperm}，应设置为 600（包含渠道会话凭证）"
        _apply_or_preview \
          "设置 ${f##*/} 权限为 600（当前：${fperm}）" \
          chmod 600 "$f"
      fi
    done
    shopt -u nullglob
  fi

  # ── agents/*/agent/auth-profiles.json（含 API Key / OAuth Token）────────
  # bash 使用 nullglob 选项来处理无匹配情况
  shopt -s nullglob
  local profile
  for profile in "${config_dir}"/agents/*/agent/auth-profiles.json; do
    [[ -f "$profile" ]] || continue
    any_file=true
    local pperm agent_id
    pperm=$(stat -f '%A' "$profile" 2>/dev/null || echo "000")
    agent_id=$(echo "$profile" | sed 's|.*/agents/\([^/]*\)/agent/.*|\1|')
    if [[ "$pperm" == "600" ]]; then
      log_ok "agents/${agent_id}/agent/auth-profiles.json 权限已为 600"
    else
      log_warn "agents/${agent_id}/agent/auth-profiles.json 当前权限为 ${pperm}，应设置为 600（含 API Key / OAuth Token）"
      _apply_or_preview \
        "设置 auth-profiles.json 权限为 600（agent: ${agent_id}，当前：${pperm}）" \
        chmod 600 "$profile"
    fi
  done
  shopt -u nullglob

  if ! $any_file; then
    log_info "未找到凭证文件或 auth-profiles.json，跳过"
  fi
}

# ── 日志敏感信息脱敏检查 ─────────────────────────────────────────────────────
harden_logging_redact() {
  log_section "日志敏感信息脱敏"
  # 参考文档：https://docs.openclaw.ai/zh-CN/gateway/security#0.8
  # logging.redactSensitive 合法值：
  #   "tools"（默认）— 工具摘要中的 URL、命令输出等自动脱敏后再写入日志
  #   "off"          — 完整工具摘要明文写入日志，可能暴露 URL、命令参数、凭证片段
  # security audit --fix 会将 "off" 恢复为 "tools"
  local config_file="${OPENCLAW_CONFIG_FILE}"

  local redact_val
  redact_val=$(grep -Eo '"?redactSensitive"?[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null \
    | grep -Eo '"[^"]*"$' | tr -d '"' | head -1) || true

  case "${redact_val}" in
    off)
      log_warn "logging.redactSensitive=\"off\"，工具摘要将明文写入日志（可能暴露 URL、命令输出、凭证片段）"
      _apply_or_preview \
        "将 logging.redactSensitive 由 \"off\" 改为 \"tools\"（恢复自动脱敏）" \
        /usr/bin/sed -i '' -E \
          's/("?redactSensitive"?[[:space:]]*:[[:space:]]*")off"/\1tools"/g' \
          "$config_file"
      ;;
    tools|"")
      log_ok "logging.redactSensitive：\"${redact_val:-tools（默认）}\"  ✓（工具摘要自动脱敏）"
      ;;
    *)
      log_info "logging.redactSensitive：\"${redact_val}\""
      ;;
  esac
}

# ── Gateway Control UI 危险标志检查 ──────────────────────────────────────────
harden_controlui_flags() {
  log_section "Gateway Control UI 安全配置"
  # 参考文档：https://docs.openclaw.ai/zh-CN/gateway/security#controlui
  # 两项危险标志均被 openclaw security audit 明确检查：
  #   dangerouslyDisableDeviceAuth: true — 完全绕过设备身份验证（严重安全降级）
  #   allowInsecureAuth: true            — 回退到仅 token 认证，跳过 HTTPS 安全上下文检查
  local config_file="${OPENCLAW_CONFIG_FILE}"

  # ── dangerouslyDisableDeviceAuth ─────────────────────────────────────────
  if grep -qE '"?dangerouslyDisableDeviceAuth"?[[:space:]]*:[[:space:]]*true' "$config_file" 2>/dev/null; then
    log_error "gateway.controlUi.dangerouslyDisableDeviceAuth=true，设备身份验证已被完全禁用！"
    log_error "这是严重安全降级——除非正在主动调试，否则必须立即关闭"
    log_info "请将其设置为 false 或删除该字段"
  else
    log_ok "gateway.controlUi.dangerouslyDisableDeviceAuth：未启用  ✓"
  fi

  # ── allowInsecureAuth ────────────────────────────────────────────────────
  if grep -qE '"?allowInsecureAuth"?[[:space:]]*:[[:space:]]*true' "$config_file" 2>/dev/null; then
    log_warn "gateway.controlUi.allowInsecureAuth=true，Control UI 已回退到仅 token 认证（不安全模式）"
    log_warn "建议通过 HTTPS（Tailscale Serve）或在 127.0.0.1 上访问 UI，而非启用此标志"
    log_info "如不需要，请将其设置为 false 或删除该字段"
  else
    log_ok "gateway.controlUi.allowInsecureAuth：未启用  ✓"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 模块 4：加固汇总入口（全部加固项顺序执行）
# ─────────────────────────────────────────────────────────────────────────────
run_hardening() {
  log_section "阶段 3 — 安全加固与优化"

  if ! $OPENCLAW_INSTALLED; then
    log_warn "OpenClaw 未检测到安装，部分加固项将跳过配置文件修改"
  fi

  # 在所有加固操作开始前，统一备份配置文件
  _backup_file "${OPENCLAW_CONFIG_FILE}"

  # ══ 第一部分：基础配置文件安全 ════════════════════════════════════════════════
  log_part "第一部分 — 基础配置文件安全"
  harden_config_file_perms   # openclaw.json 及目录权限（仅所有者读写）
  harden_env_file_perms      # .env 文件权限（仅所有者读写）
  harden_apikey_to_env       # 明文 API Key / Token 迁移至 .env
  harden_credentials_perms   # 凭证文件与 auth-profiles.json 权限
  harden_logging_redact      # 日志敏感信息脱敏开关

  # ══ 第二部分：Gateway 配置加固 ════════════════════════════════════════════════
  log_part "第二部分 — Gateway 配置加固"
  harden_gateway_auth        # 认证模式（禁止 mode: none）
  harden_gateway_port        # 监听端口（禁止默认端口 18789，交互式选择）
  harden_network_bindings    # 绑定地址限制
  harden_controlui_flags     # Control UI 危险标志

  # ══ 第三部分：agents.defaults 配置优化 ════════════════════════════════════════
  log_part "第三部分 — Agents & Channels 配置优化"
  optimize_heartbeat         # 心跳频率（heartbeat.every）
  optimize_compaction        # compaction 模式与标识符策略
  check_channel_defaults     # channels.defaults 群组策略与心跳显示配置

  flush_pending_commands
}

# ─────────────────────────────────────────────────────────────────────────────
# 入口：解析参数并分派执行
# ─────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
用法：$(basename "$0") [选项]

选项：
  （无参数）     仅运行环境检查（阶段 1 + 2）
  --dry-run     预览加固变更，不实际修改任何文件
  --apply       执行全部加固操作（阶段 1 + 2 + 3）
  --help        显示此帮助信息

示例：
  ./guarder.sh              # 环境与安装检查
  ./guarder.sh --dry-run    # 预览加固内容
  ./guarder.sh --apply      # 应用加固
EOF
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      --apply)   APPLY=true   ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "未知参数：${arg}"; usage; exit 1 ;;
    esac
  done

  printf "%b" "${BOLD}${CYAN}"
  printf "╔══════════════════════════════════════════╗\n"
  printf "║       OpenClaw Guarder — macOS           ║\n"
  printf "╚══════════════════════════════════════════╝%b\n" "${RESET}"
  printf "  模式：%s\n" "$(if $DRY_RUN; then echo 'DRY-RUN（预览）'; elif $APPLY; then echo 'APPLY（应用加固）'; else echo '检查（只读）'; fi)"
  printf "  时间：%s\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"

  # 阶段 1：基础依赖检查
  run_prerequisite_checks

  # 阶段 2：OpenClaw 安装检查
  run_openclaw_checks

  # 阶段 3：安全加固（仅在 --dry-run 或 --apply 时执行）
  if $DRY_RUN || $APPLY; then
    run_hardening
  else
    log_section "提示"
    log_info "仅完成环境检查。使用 --dry-run 预览加固，或 --apply 执行加固"
  fi
}

main "$@"
