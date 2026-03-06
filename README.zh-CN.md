# OpenClaw Guarder

[English](README.md)

OpenClaw Guarder 提供安装后配置脚本与安全建议，用于加固 OpenClaw 部署环境。安装 OpenClaw 之后，本项目的脚本会调整配置文件与安全默认值，以降低安全风险、防止 Token 意外消耗，并修正常见误配置。

## 主要功能

- 安装后自动检查环境依赖、OpenClaw 安装状态与关键安全配置。
- 以更安全的默认值更新 OpenClaw 配置文件，降低 Token 意外消耗与服务暴露风险。
- 变更简洁可审计，所有修改均可回滚，运维人员可随时审查。

## 使用方法

1. 参照 [OpenClaw 安装文档](https://docs.openclaw.ai/zh-CN/install) 完成安装。
2. 选择以下任意一种方式运行脚本：

**方式一：使用 curl 直接执行（快速体验）**

无需克隆仓库，通过 curl 下载后直接交由 zsh 执行：

```bash
# 仅执行环境与安装状态检查（默认，只读）
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh | zsh

# 预览加固变更，不修改任何文件
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh | zsh -s -- --dry-run

# 执行全部加固操作
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh | zsh -s -- --apply
```

**方式二：curl 下载到本地后执行（推荐，可审阅脚本内容）**

先将脚本下载到本地，审阅无误后再赋权执行：

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh -o openclaw_guarder.sh

# 赋予执行权限
chmod +x ./openclaw_guarder.sh

# 仅执行环境与安装状态检查（默认，只读）
./openclaw_guarder.sh

# 预览加固变更，不修改任何文件
./openclaw_guarder.sh --dry-run

# 执行全部加固操作
./openclaw_guarder.sh --apply
```

## 安全加固项

脚本分三部分顺序执行，涵盖以下配置检查与加固：

### 第一部分 — 基础配置文件安全

| 加固项 | 脚本做了什么 | 防范什么风险 |
|--------|-------------|-------------|
| **`openclaw.json` 文件权限** | 将配置文件权限设为 `600`，配置目录权限设为 `700` | 权限过宽时，同主机其他用户或进程可读取含 API Key 的配置文件，造成凭证泄露 |
| **`.env` 文件权限** | 将 `.env` 文件权限设为 `600` | `.env` 含有 API Key 等敏感信息，过宽权限导致凭证在同主机用户间泄露 |
| **`models.providers` API Key 迁移** | 扫描 `openclaw.json` 中 `models.providers.<name>.apiKey` 明文字段，自动提取到 `.env` 并替换为 `${VAR_NAME}` 占位符 | 硬编码凭证一旦配置文件泄露即全部暴露；迁移至 `.env` 后凭证与配置分离，降低泄露风险 |
| **凭证文件权限** | 将 `credentials/` 目录权限设为 `700`，渠道凭证 JSON 及各 Agent 的 `auth-profiles.json` 权限设为 `600` | 权限过宽时，会话凭证、API Key 及 OAuth Token 可被同主机其他用户直接读取 |
| **日志敏感信息脱敏** | 检查 `logging.redactSensitive` 是否为 `"off"`，是则改回 `"tools"` | `"off"` 时工具摘要（含 URL、命令参数、凭证片段）明文写入日志，日志文件自身成为凭证泄露源 |

### 第二部分 — Gateway 配置加固

| 加固项 | 脚本做了什么 | 防范什么风险 |
|--------|-------------|-------------|
| **默认端口外网暴露检测** | 用 `lsof` 检查端口 `18789` 是否绑定 `0.0.0.0` 并对外监听，是则输出告警 | 默认端口未关闭时，任意公网 IP 可直接访问 WebUI，攻击者无需认证即可操控 Gateway |
| **Gateway 端口加固** | 检测 `gateway.port` 是否为默认值 `18789`，在交互模式下可选择随机生成五位端口或手动指定 | 默认端口是自动化扫描的首选目标，改为非默认端口可大幅降低被探测概率 |
| **Gateway 认证模式** | 检测 `gateway.auth.mode` 是否为 `"none"`，若是则改为 `"token"`；并验证 `gateway.auth.token` / `gateway.auth.password` 是否已配置 | `mode: "none"` 使任何能访问端口的客户端都可无认证调用 Gateway，导致 Token 盗用和费用失控 |
| **Gateway 绑定地址** | 检查 `gateway.mode`（应为 `"local"`）和 `gateway.bind`（应为 `"loopback"`），发现 `lan` / `auto` / `tailnet` 等高风险值时加入修复队列 | 非 `loopback` 绑定会让 Gateway 监听局域网或所有网卡，外网可直接访问 |
| **Control UI 安全标志** | 检查 `dangerouslyDisableDeviceAuth` 是否为 `true`（严重安全降级，输出 ERROR）；检查 `allowInsecureAuth` 是否为 `true`（不安全认证回退，输出 WARN）| 这两项标志会绕过设备身份验证或降级为仅 Token 认证，大幅降低 Control UI 的安全性 |

### 第三部分 — Agents & Channels 配置优化

| 优化项 | 脚本做了什么 | 防范什么风险 |
|--------|-------------|-------------|
| **心跳频率与投递配置** | 检查 `heartbeat.every`（≤10m 时建议改为 `55m`）、`heartbeat.target`（默认 `"none"` 时提示改为 `"last"`）、`heartbeat.lightContext`（建议设为 `true`）| 心跳过密每天产生大量额外 API 调用；`lightContext: true` 仅加载 HEARTBEAT.md，可显著降低每次心跳的 Token 消耗 |
| **compaction 配置** | 检查 `compaction.mode`（应为 `"safeguard"`）、`compaction.identifierPolicy`（应为 `"strict"`）、`compaction.memoryFlush.enabled`（应为 `true`）| 默认 `mode: default` 对长对话历史的压缩质量较低，可能丢失关键信息；`safeguard` 模式使用分块摘要 |
| **channels.defaults 配置** | 检查 `groupPolicy`（默认 `"allowlist"` 为安全值，若改为 `"open"` 则告警）；检查 `heartbeat.showAlerts`（默认 `true`，改为 `false` 则告警）| `groupPolicy: "open"` 绕过群组允许列表，任意群组均可访问 Gateway；关闭 `showAlerts` 会屏蔽降级与错误告警 |

在应用任何修改之前，请务必审查生成的差异预览与备份文件。

## 可审计性与可回滚性

所有修改均有日志记录且可回滚。脚本在修改文件前会自动创建带时间戳的备份（`*.bak.YYYYMMDD_HHMMSS`），并打印变更摘要。运维人员可检查备份文件或使用回滚方式恢复原始状态。

## 参考文档

- Gateway 配置：https://docs.openclaw.ai/gateway
- CLI 用法：https://docs.openclaw.ai/cli

## 贡献

欢迎提交 Issue 或 Pull Request，请在描述中清晰说明配置变更的背景与理由。

## 许可证

详见仓库根目录的 LICENSE 文件。
