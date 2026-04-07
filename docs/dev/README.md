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
