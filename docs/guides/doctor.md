# Doctor

`scratch doctor` checks your environment for missing dependencies and reports what needs attention.

## Usage

```bash
scratch doctor
```

Output groups dependencies by where they're declared:

```
=== Runtime Dependencies ===

  ✓ bash 5         (lib)
  ✓ jq             (lib tool:notify)
  ✓ curl           (lib)
  ✓ gum            (lib tool:notify)
  ✓ bc             (lib)
  ✓ sqlite3        (lib)
  ✓ elixir         (embed)
  ✗ parallel        (dev)
```

Each dependency shows its attribution — which component declared it. A single binary may appear under multiple attributions (e.g., `jq` is used by both `lib` and `tool:notify`).

## Fixing missing dependencies

```bash
scratch doctor --fix
```

Prompts to install missing runtime dependencies via your package manager (`brew` on macOS, `apt-get` on Linux).

## Developer dependencies

```bash
scratch doctor --dev
```

Also checks for developer tools (from `.mise.toml`): bats, shellcheck, shfmt, GNU parallel, etc. These are only needed for contributing to scratch, not for using it.

## How it works

Doctor scans six targets for `has-commands` and `require-env-vars` declarations:

1. `bin/scratch-*` — subcommand scripts
2. `lib/*.sh` — library files
3. `helpers/*` — helper scripts
4. `tools/*/is-available` — LLM tool availability gates
5. `agents/*/is-available` — agent availability gates
6. `toolboxes/*/is-available` — toolbox availability gates

The scan is textual (grep-based), so it works even when the dependencies themselves are missing.
