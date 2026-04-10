[![Test](https://github.com/sysread/scratch/actions/workflows/test.yml/badge.svg)](https://github.com/sysread/scratch/actions/workflows/test.yml)

# scratch

An AI-powered project research and coding tool.

Scratch works on any directory - not just git repos.
Point it at a notes folder, a recipe archive, a pile of scripts in `~/bin`, or a proper code project.
It's a showcase of what a well-organized bash application can look like: clean architecture, proper tests, separation of concerns, and polyglot pragmatism where the shell isn't the right tool for the job.

## Install

```bash
# Clone
git clone git@github.com:sysread/scratch.git
cd scratch

# Install runtime dependencies (bash 5+, jq, gum, curl, elixir)
./bin/scratch setup

# Put scratch on your PATH (pick one)
ln -s "$(pwd)/bin/scratch" ~/bin/scratch             # if ~/bin is on your PATH
# or: echo "export PATH=\"$(pwd)/bin:\$PATH\"" >> ~/.zshrc

# Verify the environment
scratch doctor
```

## Usage

```
$ scratch
scratch <command> [args...]

SUBCOMMANDS
  doctor       Check the runtime environment for missing dependencies and required env vars
  file-info    Show index status and summary for a file
  help         Browse guides or ask questions about scratch
  index        Build or update the project file index
  intuit       Run the intuition agent against a prompt (positional or stdin)
  project      Manage project configurations
  search       Semantic search over the project file index
```

Every subcommand honors `--help`:

```
$ scratch project list --help
scratch project list [options]
```

## Requirements

Runtime:
- [bash](https://www.gnu.org/software/bash/) 5+
- [jq](https://jqlang.org/)
- [gum](https://github.com/charmbracelet/gum)
- [curl](https://curl.se/)
- [bc](https://www.gnu.org/software/bc/) (for log10 backoff math in the Venice client)
- [elixir](https://elixir-lang.org/) (for the embedding helper)

Development (installed via `mise install`):
- [mise](https://mise.jdx.dev/) to manage the other dev tools
- [bats](https://github.com/bats-core/bats-core) for tests
- [shellcheck](https://www.shellcheck.net/) for linting
- [shfmt](https://github.com/mvdan/sh) for formatting
- GNU [parallel](https://www.gnu.org/software/parallel/) for inter-file test parallelism

Run `scratch doctor --dev` to verify the full dev environment.

## Layout

```
bin/        subcommand executables (scratch, scratch-doctor, scratch-project-*, ...)
lib/        sourced bash libraries
helpers/    bash scripts that aren't subcommands (setup, run-tests, root-dispatcher, ...)
libexec/    internal non-bash executables (embed.exs)
test/       bats test suite
docs/       guides/ (user) and dev/ (developer and LLM)
```

See [docs/dev/architecture.md](docs/dev/architecture.md) for the full design and [docs/dev/conventions.md](docs/dev/conventions.md) for the coding rules.

## Development

```bash
mise install        # install pinned dev tools
mise run test       # run the bats suite
mise run lint       # shellcheck
mise run format     # shfmt
mise run fix        # format + enforce file permissions
mise run check      # lint + test
mise run release    # bump patch, tag, push (runs check first)
```

The test suite includes self-reflection tests that catch structural drift: lint, formatting, file permissions, unicode discipline, and a subcommand-contract test that verifies every `bin/scratch-*` honors `--help`.
