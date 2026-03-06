# OpenClaw Guarder

[中文版](README.zh-CN.md)

OpenClaw Guarder provides post-install configuration scripts and security recommendations to harden an OpenClaw deployment. After installing OpenClaw, the project's scripts inspect configuration files and safe defaults to reduce security risks, prevent accidental token consumption, and fix common misconfigurations.

## Key Features

- Automated post-install checks for environment dependencies, OpenClaw installation status, and critical security settings.
- Updates OpenClaw configuration files with safer defaults to reduce token waste and minimize service exposure.
- Simple, auditable changes — all modifications are backed up and can be rolled back at any time.

## Usage

1. Install OpenClaw following the [official installation guide](https://docs.openclaw.ai/zh-CN/install).
2. Choose one of the following methods to run the script:

**Option 1: Run directly with curl (quick start)**

No need to clone the repository — download and execute in one step:

```bash
# Check environment and installation status only (default, read-only)
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh | zsh

# Preview hardening changes without modifying any files
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh | zsh -s -- --dry-run

# Apply all hardening operations
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh | zsh -s -- --apply
```

**Option 2: Download locally then execute (recommended — review before running)**

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/BeanHsiang/openclaw-guarder/main/scripts/zh-cn/openclaw_guarder.sh -o openclaw_guarder.sh

# Grant execute permission
chmod +x ./openclaw_guarder.sh

# Check environment and installation status only (default, read-only)
./openclaw_guarder.sh

# Preview hardening changes without modifying any files
./openclaw_guarder.sh --dry-run

# Apply all hardening operations
./openclaw_guarder.sh --apply
```

## Security Hardening

The script runs in three sequential phases covering the following checks and fixes:

### Phase 1 — Core Configuration File Security

| Hardening Item | What the script does | Risk mitigated |
|----------------|---------------------|----------------|
| **`openclaw.json` file permissions** | Sets config file to `600` and config directory to `700` | World-readable config files expose API Keys to other users and processes on the same host |
| **`.env` file permissions** | Sets `.env` file to `600` | `.env` stores API Keys and secrets; overly permissive access leads to credential leakage |
| **`models.providers` API Key migration** | Scans `openclaw.json` for plaintext `models.providers.<name>.apiKey` values, extracts them to `.env`, and replaces them with `${VAR_NAME}` placeholders | Hardcoded credentials are fully exposed if the config file leaks; separating secrets into `.env` reduces exposure |
| **Credential file permissions** | Sets `credentials/` directory to `700` and each channel credential JSON and `auth-profiles.json` to `600` | Overly permissive credential files allow other users on the same host to read session credentials, API Keys, and OAuth tokens |
| **Log sensitive data redaction** | Checks whether `logging.redactSensitive` is `"off"`; if so, reverts it to `"tools"` | `"off"` writes full tool summaries (including URLs, command arguments, and credential fragments) to log files in plaintext |

### Phase 2 — Gateway Configuration Hardening

| Hardening Item | What the script does | Risk mitigated |
|----------------|---------------------|----------------|
| **Default port external exposure** | Uses `lsof` to check if port `18789` is bound to `0.0.0.0` and listening; warns if exposed | When the default port is open to the internet, any public IP can access the WebUI without authentication |
| **Gateway port hardening** | Detects if `gateway.port` is the default `18789`; in interactive mode lets you choose a random five-digit port or enter one manually | The default port is a primary target for automated scanners; changing it significantly reduces detection probability |
| **Gateway authentication mode** | Detects if `gateway.auth.mode` is `"none"`; if so, changes it to `"token"`; verifies `gateway.auth.token` / `gateway.auth.password` are configured | `mode: "none"` allows any client that can reach the port to call the Gateway without authentication, leading to token theft and runaway costs |
| **Gateway bind address** | Checks `gateway.mode` (should be `"local"`) and `gateway.bind` (should be `"loopback"`); queues fixes for high-risk values like `lan`, `auto`, or `tailnet` | Non-`loopback` bindings expose the Gateway to the local network or all interfaces, making it reachable from outside the host |
| **Control UI security flags** | Checks if `dangerouslyDisableDeviceAuth` is `true` (ERROR — severe security downgrade); checks if `allowInsecureAuth` is `true` (WARN — insecure auth fallback) | These flags bypass device authentication or fall back to token-only auth, significantly weakening Control UI security |

### Phase 3 — Agents & Channels Configuration Optimization

| Optimization Item | What the script does | Risk mitigated |
|-------------------|---------------------|----------------|
| **Heartbeat frequency and delivery** | Checks `heartbeat.every` (warns if ≤10m, suggests `55m`); checks `heartbeat.target` (warns if `"none"`, suggests `"last"`); checks `heartbeat.lightContext` (suggests `true`) | Overly frequent heartbeats generate hundreds of extra API calls per day; `lightContext: true` loads only `HEARTBEAT.md`, significantly reducing per-heartbeat token consumption |
| **Compaction configuration** | Checks `compaction.mode` (should be `"safeguard"`), `compaction.identifierPolicy` (should be `"strict"`), `compaction.memoryFlush.enabled` (should be `true`) | The default `mode: default` yields lower-quality compression on long conversation histories and may drop critical information; `safeguard` mode uses chunked summarization |
| **Channel defaults** | Checks `groupPolicy` (default `"allowlist"` is safe; warns if set to `"open"`); checks `heartbeat.showAlerts` (default `true`; warns if set to `false`) | `groupPolicy: "open"` bypasses the group allowlist so any group can reach the Gateway; disabling `showAlerts` hides degradation and error alerts |

Always review the generated diff preview and backup files before applying any modifications.

## Auditability and Reversibility

All modifications are logged and reversible. The script automatically creates timestamped backups (`*.bak.YYYYMMDD_HHMMSS`) before modifying any file and prints a change summary. Operators can inspect the backup files or restore the original state at any time.

## References

- Gateway configuration: https://docs.openclaw.ai/gateway
- CLI usage: https://docs.openclaw.ai/cli

## Contribution

Contributions, bug reports, and suggestions are welcome. Please open issues or pull requests with clear descriptions and rationale for configuration changes.

## License

See the repository LICENSE file for license terms.
