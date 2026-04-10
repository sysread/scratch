# Projects

A project in scratch is a directory you want to work with — a git repo, a notes folder, a collection of scripts, anything. Projects are registered with scratch so it knows where your files are, what to exclude, and where to store per-project data like the search index.

## Creating a project

From inside the directory you want to register:

```bash
scratch project create
```

Or specify a path:

```bash
scratch project create /path/to/my/project
```

This interactively prompts for:

- **Name** — a short identifier (e.g., `myapp`, `notes`, `scratch`)
- **Exclude patterns** — glob patterns for files to ignore (e.g., `node_modules/**`, `*.log`)

Git status is detected automatically. For git repos, `.gitignore` is respected by default during indexing.

## Listing projects

```bash
scratch project list
```

Prints all configured projects with their root paths.

## Showing project config

```bash
scratch project show
```

Auto-detects the project from your current directory (including git worktrees). Or specify by name:

```bash
scratch project show myapp
```

Shows the project's root path, git status, and exclude patterns.

## Editing a project

```bash
scratch project edit
```

Interactively prompts to update the project's settings. Auto-detects from cwd, or specify a name.

## Deleting a project

```bash
scratch project delete
```

Removes the project configuration (with a confirmation prompt). This does not delete any source files — only scratch's record of the project.

## How projects are stored

Project configs live at:

```
~/.config/scratch/projects/<name>/settings.json
```

The settings file contains:

```json
{
  "root": "/path/to/project",
  "is_git": true,
  "exclude": [".git/**"]
}
```

Per-project data (like the search index database) is stored alongside the settings file in the same directory.

## Worktree support

A project is always registered against the main repo root, never a worktree path. Worktrees are treated as views of the same project — they share the same config, search index, and settings. When you run any scratch command from a worktree, it automatically resolves to the parent repository's project.

This means:
- `scratch project show` from a worktree shows the main project
- `scratch index` from a worktree indexes the main repo's files
- `scratch search` from a worktree searches the main project's index
- One project registration covers all of its worktrees automatically
