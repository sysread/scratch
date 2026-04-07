# Developer Documentation

Documentation for developers and LLM agents working on scratch.

- [conventions.md](conventions.md) - coding conventions, naming, structure, formatting
- [architecture.md](architecture.md) - how the pieces fit together, entry points, library stack
- [components.md](components.md) - per-component reference for libraries and subcommands

## Keeping These Docs Current

These docs are authoritative.
When you add, remove, rename, or significantly change a component, update the relevant doc in the same commit.

- New library in `lib/` - add an entry to `components.md` and, if it shifts the dependency graph, update `architecture.md`.
- New subcommand in `bin/` - add an entry to `components.md`.
- Change to the build/test pipeline or directory layout - update `architecture.md`.
- Change to a coding convention - update `conventions.md`.

If you're uncertain whether a change warrants a doc update, err on the side of updating.
Stale docs are worse than verbose ones.

## Quick Recipes

### Adding a new top-level subcommand

1. Create `bin/scratch-<verb>` using `cmd.sh`.
2. Respond to `synopsis` before sourcing libraries (it's called frequently to build the help menu).
3. Declare the interface with `cmd:define`, `cmd:required-arg`, `cmd:flag`, etc.
4. Call `cmd:parse "$@"` and `cmd:validate`.
5. `chmod +x`.
6. Add a `test/scratch-<verb>.bats` with meaningful coverage.
7. Add the component to `components.md`.

No changes to the dispatcher are needed.
`dispatch:list "scratch"` globs `bin/scratch-*` automatically.

### Adding a parent command (a subcommand with its own children)

1. Create `bin/scratch-<parent>` as a thin dispatcher.
   Handle `synopsis` manually, source libs, call `dispatch:try "scratch-<parent>" "$@"`, and fall through to `dispatch:usage` or your own default behavior.
2. Create leaves as `bin/scratch-<parent>-<verb>` using `cmd.sh`.
   Each leaf is an independent command script.
3. Verb names cannot contain hyphens (each hyphen in a binary name is a level separator).
4. `chmod +x` on both the parent and leaves.
5. Add tests for each leaf.
6. Update `components.md`.

See `bin/scratch-project` and its children as the reference implementation.

### Adding a new library

1. Create `lib/<name>.sh` with the standard structure (include guard, self-locating scriptdir, dependency validation).
2. Source-time dependencies declared via `has-commands`.
3. Functions in the `<name>:verb-noun` convention, exported with `export -f`.
4. Internal/private functions prefixed with `_`, NOT exported.
5. Multiple-inclusion guard: `[[ "${_INCLUDED_<NAME>:-}" == "1" ]] && return 0; _INCLUDED_<NAME>=1`.
6. Add `test/<name>.bats` mirroring the library structure.
7. Add an entry to `components.md` and, if it affects the dependency graph, update `architecture.md`.
