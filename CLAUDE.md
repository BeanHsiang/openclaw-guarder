# OpenClaw Guarder — AI Instructions

This file guides AI models on the conventions and standards to follow when generating scripts and configurations in this project.

## Reference Documentation

When looking up configuration options or command usage for OpenClaw Gateway or CLI, refer to the following official documentation:

- **Gateway docs**: https://docs.openclaw.ai/gateway
- **CLI docs**: https://docs.openclaw.ai/cli

## Script Generation Conventions

| Convention | Specification |
|------------|---------------|
| Target OS | macOS — no need to support Linux or Windows |
| Script language | Shell / PowerShell |
| Shell type | Zsh / Bash / PowerShell |
| Tool priority | Prefer built-in commands and tools provided by the macOS version where the script runs, implementing features in the way that best matches the current system version |