# Project Guardrails

This file records repository-level decisions that must remain true in future sessions.

## Distribution and Install

- RTK is distributed from source only.
- `install.sh` must build the current checkout with Cargo and install that local binary.
- Do not reintroduce prebuilt binary downloads, GitHub release installers, Homebrew formulae, or `cargo install --git` flows.

## Platform Support

- Supported platforms are macOS and Linux only.
- Do not reintroduce Windows build, test, release, or documentation paths.

## Telemetry

- Telemetry has been removed from the project.
- Do not reintroduce telemetry code, build-time telemetry URLs/tokens, or telemetry documentation.

## Hooks and Agent Integrations

- Keep only the currently supported integrations: Claude Code, Gemini CLI, Codex, Cline / Roo Code, and OpenCode.
- Copilot, Cursor, and Windsurf have been removed. Do not restore their code paths, assets, CLI flags, or docs.
- The repository-local `.claude/` directory has been removed and should stay removed.
- `CLAUDE.md` has been removed from this repository and should not be recreated as repo metadata.

## Repository Metadata

- The repository-local `.github/` directory has been removed and should stay removed unless explicitly requested.
- OpenClaw integration has been removed and should not be reintroduced.

## Documentation Policy

- Keep `README.md` and `README_fr.md` as the only README variants.
- Do not recreate additional `README*` files unless explicitly requested.
- Keep docs aligned with the current source-only, macOS/Linux-only, no-telemetry state.

## Tracking

- Tracking retention is capped at 10 days maximum.
- Purge behavior must also use the same 10-day maximum.

## Change Discipline

- Prefer updating this file when a user makes a lasting repository-wide decision.
- Before reintroducing any removed subsystem or integration, require an explicit user request.
