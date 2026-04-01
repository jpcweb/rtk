# RTK Technical Documentation

> **Start here** for a guided tour of how RTK works end-to-end.
>
> - [CONTRIBUTING.md](../CONTRIBUTING.md) — Design philosophy, PR process, branch naming, testing requirements
> - [ARCHITECTURE.md](../ARCHITECTURE.md) — Deep reference: filtering taxonomy, performance benchmarks, architecture decisions
> - This document is the primary technical index; inspect source files directly for implementation details

---

## 1. Project Vision

LLM-powered coding agents (Claude Code, Copilot, Cursor, etc.) consume tokens for every CLI command output they process. Most command outputs contain boilerplate, progress bars, ANSI escape codes, and verbose formatting that wastes tokens without providing actionable information.

RTK sits between the agent and the CLI, filtering outputs to keep only what matters. This achieves 60-90% token savings per command, reducing costs and increasing effective context window utilization. RTK is a single Rust binary with no runtime dependencies beyond the compiled binary itself, adding less than 10ms overhead per command.

---

## 2. Architecture Overview

```
User / LLM Agent
       |
       v
+--------------------------------------------------+
|  LLM Agent Hook                                  |
|  hooks/{claude,copilot,cursor,...}/               |
|  Intercepts: "git status" -> "rtk git status"    |
+-------------------------+------------------------+
                          |
                          v
+--------------------------------------------------+
|  RTK CLI (main.rs)                               |
|                                                  |
|  +-------------+    +-----------------+          |
|  | Clap Parser | -> | Command Routing |          |
|  | (Commands   |    | (match on enum) |          |
|  |  enum)      |    +--------+--------+          |
|  +-------------+             |                   |
|                    +---------+---------+         |
|                    v         v         v         |
|             +----------+ +--------+ +----------+|
|             |Rust Filter| |TOML DSL| |Passthru  ||
|             |(cmds/**)  | |Filter  | |(fallback)||
|             +-----+----+ +----+---+ +----+-----+|
|                   |           |           |      |
|                   +-----+-----+-----------+      |
|                         v                        |
|              +---------------------+             |
|              |   Token Tracking    |             |
|              |   (core/tracking)   |             |
|              |   SQLite DB         |             |
|              +---------------------+             |
+--------------------------------------------------+
```

**Design principles:**
- Single-threaded, no async (startup < 10ms)
- Graceful degradation: filter failure falls back to raw output
- Exit code propagation: RTK never swallows non-zero exits
- Transparent proxy: unknown commands pass through unchanged

---

## 3. End-to-End Flow

This is the full lifecycle of a command through RTK, from LLM agent to filtered output.

### 3.1 Hook Installation (`rtk init`)

The user runs `rtk init` to set up hooks for their LLM agent. This:

1. Writes a thin shell hook script (e.g., `~/.claude/hooks/rtk-rewrite.sh`)
2. Stores its SHA-256 hash for integrity verification
3. Patches the agent's settings file (e.g., `settings.json`) to register the hook
4. Writes RTK awareness instructions (e.g., `RTK.md`) for prompt-level guidance

RTK supports 7 agents, each with its own installation mode. The hook scripts are embedded in the binary and written at install time.

> **Implementation**: see `src/hooks/init.rs`, `src/hooks/integrity.rs`, and `src/hooks/hook_cmd.rs`.

### 3.2 Hook Interception (Command Rewriting)

When an LLM agent runs a command (e.g., `git status`):

1. The agent fires a `PreToolUse` event (or equivalent) containing the command as JSON
2. The hook script reads the JSON, extracts the command string
3. The hook calls `rtk rewrite "git status"` as a subprocess
4. `rtk rewrite` consults the command registry and returns `rtk git status`
5. The hook sends a response telling the agent to use the rewritten command
6. If anything fails (jq missing, rtk not found, no match), the hook exits silently -- the raw command runs unchanged

All rewrite logic lives in Rust (`src/discover/registry.rs`). Hooks are thin delegates that handle agent-specific JSON formats.

> **Implementation**: agent artifacts live under `hooks/`, and rewrite logic lives in `src/discover/registry.rs`.

### 3.3 CLI Parsing and Routing

Once the rewritten command reaches RTK:

1. **Clap parsing**: `Cli::try_parse()` matches against the `Commands` enum
2. **Hook check**: `hook_check::maybe_warn()` warns if the installed hook is outdated (rate-limited to 1/day)
3. **Integrity check**: `integrity::runtime_check()` verifies the hook's SHA-256 hash for operational commands
4. **Routing**: A `match cli.command` dispatches to the specialized filter module

If Clap parsing fails (command not in the enum), the fallback path runs instead.

### 3.4 Filter Execution

RTK has two filter systems:

**Rust Filters**: Compiled modules in `src/cmds/` that execute the command, parse its output, and apply specialized transformations (regex, JSON, state machines).

**TOML DSL Filters**: Declarative filters in `src/filters/*.toml` that apply regex-based line filtering, truncation, and section extraction. Applied in `run_fallback()` when no Rust filter matches.

Each filter module follows the same pattern:
1. Start a timer (`TimedExecution::start()`)
2. Execute the underlying command (`std::process::Command`)
3. Apply filtering (strip boilerplate, group errors, truncate)
4. On filter error, fall back to raw output
5. Track token savings to SQLite
6. Propagate exit code

> **Implementation**: see `src/main.rs` for routing and `src/cmds/` for the concrete filter modules.

### 3.5 Fallback Path

When Clap parsing fails (unknown command):

1. Guard: check if the command is an RTK meta-command (`gain`, `init`, etc.) -- if so, show Clap error
2. Look up TOML DSL filters via `toml_filter::find_matching_filter()`
3. If TOML match: capture stdout, apply filter pipeline, track savings
4. If no match: pure passthrough with `Stdio::inherit`, track as 0% savings

```
Command received
  -> Clap parse succeeds?
     -> Yes: Route to Rust filter module
     -> No:  run_fallback()
              -> TOML filter match?
                 -> Yes: Capture stdout, apply filter, track savings
                 -> No:  Passthrough (inherit stdio, track 0% savings)
```

> **Implementation**: see `src/core/toml_filter.rs` and `src/hooks/trust.rs`.

### 3.6 Token Tracking

Every command execution records metrics to SQLite (`~/.local/share/rtk/tracking.db`):

- Input tokens (raw output size) and output tokens (filtered size)
- Savings percentage, execution time, project path
- 10-day automatic retention cleanup
- Token estimation: `ceil(chars / 4.0)` approximation

Analytics commands (`rtk gain`, `rtk cc-economics`, `rtk session`) query this database to produce dashboards and ROI reports.

> **Implementation**: analytics queries live in `src/analytics/`, and the storage schema lives in `src/core/tracking.rs`.

### 3.7 Tee Recovery

On command failure (non-zero exit code):

1. Raw unfiltered output is saved to `~/.local/share/rtk/tee/{epoch}_{slug}.log`
2. A hint line is printed: `[full output: ~/.../tee/1234_cargo_test.log]`
3. LLM agents can re-read the file instead of re-running the failed command

Tee is configurable (enabled/disabled, min size, max files, max file size) and never affects command output or exit code on failure.

> **Implementation**: see `src/core/tee.rs`.

---

## 4. Folder Map

Start here, then drill down into the source directories and files for file-level details.

### `src/` — Rust source code

| Directory | What it does | Key implementation entry points |
|-----------|-------------|---------------------------------|
| `main.rs` | CLI entry point, `Commands` enum, routing match | `src/main.rs` |
| `core/` | Shared infrastructure | `src/core/tracking.rs`, `src/core/toml_filter.rs`, `src/core/config.rs`, `src/core/tee.rs` |
| `hooks/` | Hook system | `src/hooks/init.rs`, `src/hooks/integrity.rs`, `src/hooks/hook_cmd.rs`, `src/hooks/permissions.rs` |
| `analytics/` | Token savings analytics | `src/analytics/gain.rs`, `src/analytics/cc_economics.rs`, `src/analytics/session_cmd.rs` |
| `cmds/` | **Command filters (9 ecosystems)** | `src/cmds/` subdirectories plus `src/main.rs` routing |
| `discover/` | History analysis + rewrite registry | `src/discover/registry.rs`, `src/discover/provider.rs` |
| `learn/` | CLI correction detection | `src/learn/mod.rs` |
| `parser/` | Parser infrastructure | `src/parser/` |
| `filters/` | TOML filter configs | `src/filters/*.toml`, `src/core/toml_filter.rs` |

### `hooks/` — Deployed hook artifacts (root directory)

| Directory | Agent | What it contains |
|-----------|-------|------------------|
| `hooks/` | _(parent)_ | Deployed hook artifacts and awareness files emitted by `rtk init` |
| `hooks/claude/` | Claude Code | Shell hook and awareness snippets |
| `hooks/copilot/` | GitHub Copilot | Copilot hook assets |
| `hooks/cursor/` | Cursor IDE | Cursor hook assets |
| `hooks/cline/` | Cline / Roo Code | Prompt-level rules |
| `hooks/windsurf/` | Windsurf / Cascade | Workspace-scoped rules |
| `hooks/codex/` | OpenAI Codex CLI | Awareness document and AGENTS integration assets |
| `hooks/opencode/` | OpenCode | Plugin sources and assets |

---

## 5. Hook System Summary

RTK supports the following LLM agents through hook integrations:

| Agent | Hook Type | Mechanism | Can Modify Command? |
|-------|-----------|-----------|---------------------|
| Claude Code | Shell hook | `PreToolUse` in `settings.json` | Yes (`updatedInput`) |
| GitHub Copilot (VS Code) | Rust binary | `rtk hook copilot` reads JSON | Yes (`updatedInput`) |
| GitHub Copilot CLI | Rust binary | `rtk hook copilot` reads JSON | No (deny + suggestion) |
| Cursor | Shell hook | `preToolUse` hook | Yes (`updated_input`) |
| Gemini CLI | Rust binary | `rtk hook gemini` reads JSON | Yes (`hookSpecificOutput`) |
| Cline/Roo Code | Rules file | Prompt-level guidance | N/A (prompt) |
| Windsurf | Rules file | Prompt-level guidance | N/A (prompt) |
| Codex CLI | Awareness doc | AGENTS.md integration | N/A (prompt) |
| OpenCode | TS plugin | `tool.execute.before` event | Yes (in-place mutation) |

> **Implementation**: see `hooks/` for deployed artifacts and `src/hooks/` for install/runtime logic.

---

## 6. Filter Pipeline Summary

### Rust Filters (cmds/**)

Compiled filter modules for complex transformations with 60-95% token savings.

> **Implementation**: see `src/cmds/` and the corresponding ecosystem subdirectories.

### TOML DSL Filters (src/filters/*.toml)

Declarative filters with an 8-stage pipeline: strip ANSI, regex replace, match output, strip/keep lines, truncate lines, head/tail, max lines, on-empty message. Loaded from three tiers: built-in (compiled), global (`~/.config/rtk/filters.toml`), project-local (`.rtk/filters.toml`, trust-gated).

> **Implementation**: see `src/core/toml_filter.rs`.

---

## 7. Performance Constraints

| Metric | Target | Verification |
|--------|--------|--------------|
| Startup time | < 10ms | `hyperfine 'rtk git status' 'git status'` |
| Memory usage | < 5MB resident | `/usr/bin/time -v rtk git status` |
| Binary size | < 5MB stripped | `ls -lh target/release/rtk` |
| Token savings | 60-90% per filter | Snapshot + token count tests |

Achieved through:
- Zero async overhead (single-threaded, no tokio)
- Lazy regex compilation (`lazy_static!`)
- Minimal allocations (borrow over clone)
- No config file I/O on startup (loaded on-demand)

---

## 8. Testing

Tests live **in the module file itself** inside a `#[cfg(test)] mod tests` block (e.g., tests for `src/cmds/cloud/container.rs` go at the bottom of that same file).

### How to Write Tests

**1. Create a fixture from real command output** (not synthetic data):
```bash
kubectl get pods > tests/fixtures/kubectl_pods_raw.txt
```

**2. Write your test in the same module file** (`#[cfg(test)] mod tests`):
```rust
#[test]
fn test_my_filter() {
    let input = include_str!("../tests/fixtures/my_cmd_raw.txt");
    let output = filter_my_cmd(input);
    assert!(output.contains("expected content"));
    assert!(!output.contains("noise line"));
}
```

**3. Verify token savings** (60% minimum required):
```rust
#[test]
fn test_my_filter_savings() {
    let input = include_str!("../tests/fixtures/my_cmd_raw.txt");
    let output = filter_my_cmd(input);
    let savings = 100.0 - (count_tokens(&output) as f64 / count_tokens(input) as f64 * 100.0);
    assert!(savings >= 60.0, "Expected >=60% savings, got {:.1}%", savings);
}
```

### Test Organization

```
tests/
├── fixtures/           # Real command output (never synthetic)
│   ├── git_log_raw.txt
│   ├── cargo_test_raw.txt
│   └── dotnet/         # Ecosystem-specific fixtures
└── integration_test.rs # Integration tests (#[ignore])
```

- **Unit tests**: `#[cfg(test)] mod tests` embedded in each module
- **Fixtures**: real command output in `tests/fixtures/`
- **Integration tests**: `#[ignore]` attribute, run with `cargo test --ignored`

> For testing requirements, pre-commit gate, and PR checklist, see [CONTRIBUTING.md — Testing](../CONTRIBUTING.md#testing).

---

## 9. Future Improvements

- **Extract cli.rs**: Move `Commands` enum, 13 sub-enums (`GitCommands`, `CargoCommands`, etc.), and `AgentTarget` from main.rs to a dedicated cli.rs module. This would reduce main.rs from ~2600 to ~1500 lines.
- **Split routing**: Extract the `match cli.command { ... }` block into a separate routing module.
- **Streaming filters**: For long-running commands, filter output line-by-line as it arrives instead of buffering.
