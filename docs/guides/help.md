# Help

scratch has a built-in help system for browsing guides and asking questions about its features.

## Browsing guides

```bash
scratch help
```

Opens an interactive fuzzy-search picker listing all available guides. Select one to view it formatted in your terminal.

## Asking questions

```bash
scratch help -q "how do I index my project?"
scratch help -q "what does scratch doctor check?"
```

Passes your question to a self-help agent that reads scratch's own documentation to answer. The agent uses the `self-docs` tool to find and read relevant guides.

## Subcommand help

For help on a specific command, use `--help` or `-h`:

```bash
scratch search --help
scratch project --help
scratch index -h
```
