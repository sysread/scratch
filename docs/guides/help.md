# Help

scratch has a built-in help system for browsing guides and asking questions about its features.

## Browsing guides

```bash
scratch help
```

Opens an interactive fuzzy-search picker listing all available guides. Select one to view it formatted in your terminal.

## Asking questions

```bash
scratch help "how do I index my project?"
scratch help "what does scratch doctor check?"
```

Passes your question to a self-help agent that reads scratch's own documentation to answer. The agent uses the `self-docs` tool to find and read relevant guides.

## Subcommand help

```bash
scratch help search
scratch help project
```

When the second word is a known subcommand, `scratch help <verb>` shows that subcommand's `--help` output. This is handled by the dispatch system, not the help agent.
