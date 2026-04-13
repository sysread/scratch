# Chat

`scratch chat` starts an interactive conversation with an LLM.
Messages are persisted as JSONL, so you can resume where you left off.

## Starting a new conversation

```bash
scratch chat
```

Detects the project from your current directory.
To target a specific project:

```bash
scratch chat -p myproject
```

The conversation is not saved to disk until you send your first message.
Quitting immediately leaves no trace.

## Resuming a conversation

By slug (printed on exit):

```bash
scratch chat -f abc12345
```

Or pick from a list:

```bash
scratch chat -c
```

The picker shows each conversation's slug, last-updated time, round count, and a preview of the first user message.

## The interface

Each turn works the same way:

1. You compose a message in a `gum write` editor.
2. The message is sent to the LLM via the coordinator agent.
3. The assistant's response is rendered to the terminal.
4. A separator line with a timestamp marks the end of the turn.

When resuming, the full conversation history is replayed before the first prompt.

## Exiting

- **`@exit` or `@quit`** - type as a message to exit cleanly.
- **Escape** - opens a menu: "Return to chat" or "Exit". A second Escape in the menu also exits.
- **Ctrl-C** - exits immediately.

On exit, a resume command is printed so you can pick up later.

## Tool calls

The LLM can invoke tools during a conversation.
When it does, each tool call and its result are logged to the terminal before the assistant's final response.
Tool calls are persisted in the conversation history alongside regular messages.

## Managing conversations

List conversations for a project:

```bash
scratch chats list
scratch chats list -p myproject
```

Show a specific conversation:

```bash
scratch chats show -s abc12345
scratch chats show -s abc12345 --raw       # dump JSONL
scratch chats show -s abc12345 --verbose   # include metadata
```

Delete old conversations:

```bash
scratch chats prune --days 30
scratch chats prune -d 7 -p myproject
```

Prune shows a preview table and asks for confirmation before deleting.

## Debug logging

Set `SCRATCH_DEBUG_CHAT=1` to enable file-based debug logging.
Every request/response pair and round boundary is written to `/tmp/scratch/chat-log-<uuid>.log`.
The log path is printed on exit.

```bash
SCRATCH_DEBUG_CHAT=1 scratch chat
```
