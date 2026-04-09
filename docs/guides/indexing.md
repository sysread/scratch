# File Indexing and Search

scratch can index your project's files so you can search them by meaning rather than by filename or grep pattern. The index stores a summary and embedding for each file, enabling semantic search like "how does retry logic work" to find the relevant source files.

## Setup

Indexing requires a configured project. If you haven't set one up yet:

```bash
scratch project create
```

This walks you through naming the project, setting the root directory, and configuring exclude patterns.

## Indexing

Build or update the index:

```bash
scratch index
```

This detects the project from your current directory. To index a specific project:

```bash
scratch index -p myproject
```

Indexing runs in three phases:

1. **Diff** — compares your files against the index, identifies what's new, changed, or deleted.
2. **Summarize** — runs each file that needs work through an AI summarizer (parallel, bounded by API rate limits).
3. **Embed** — generates vector embeddings from the summaries (parallel, CPU-bound).

Subsequent runs are incremental — only new or changed files are re-processed. Deleted files are cleaned up automatically.

The command prints a summary when done:

```
indexed: 42  failed: 0  orphans_removed: 3  elapsed: 128s  avg: 3s/file
```

## Searching

Search the index with a natural language query:

```bash
scratch search -q "how does the Venice API handle retries"
```

Output is a ranked list of files with relevance scores:

```
0.426   lib/venice.sh
0.293   lib/chat.sh
0.250   lib/model.sh
```

Options:

- `-q`, `--query` — the search query (required)
- `-t`, `--top` — number of results (default: 10)
- `-p`, `--project` — project name (default: detect from cwd)

If the index is stale (not updated in 3+ days), you'll see a warning.

## Checking file status

See the index status of a specific file:

```bash
scratch file-info -f lib/venice.sh
```

Output:

```
status: current

summary:
{"summary":"...","questions":["..."]}
```

Status values:

- **current** — indexed and up to date (SHA matches)
- **stale** — file has changed since last indexing
- **orphaned** — index entry exists but the file was deleted
- **missing** — file exists but hasn't been indexed yet

## How it works

Each file is processed in two steps:

1. **Summarize** — the file content is run through the `summary` agent, which uses the accumulator to handle files of any size. The output is a JSON object with a narrative summary and 5-10 synthetic search questions ("What function handles X?", "Where is Y configured?").

2. **Embed** — the summary text is converted to a 384-dimensional vector using a local sentence transformer model (all-MiniLM-L12-v2 via Elixir/Bumblebee). No API calls — embedding runs entirely on your machine.

Search works by embedding your query with the same model, then computing cosine similarity against all stored embeddings. The ranking happens in a single awk process and takes milliseconds.

## Environment variables

| Variable | Description |
|---|---|
| `SCRATCH_INDEX_PARALLEL_JOBS` | Number of parallel summarization workers (default: 4) |
| `SCRATCH_INDEX_EMBED_WORKERS` | Number of parallel embedding workers (default: 8) |

## Data storage

Index databases are stored per-project at:

```
~/.config/scratch/projects/<name>/index.db
```

These are plain SQLite databases. You can inspect them directly:

```bash
sqlite3 ~/.config/scratch/projects/myproject/index.db "SELECT identifier, content_sha FROM entries WHERE type='file' LIMIT 5;"
```
