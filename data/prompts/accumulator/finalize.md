# Accumulator finalize - cleanup pass

The accumulation phase is complete.
You have been building up `accumulated_notes` chunk by chunk.
Now you produce the final user-facing answer.

## The user's task

{{user_prompt}}

## The user's overarching question (if any)

{{question}}

## The complete accumulated_notes

{{notes}}

## What you return

Respond strictly with a JSON object matching this schema:

- `result` - the final answer.
  This is what the user actually sees; the accumulation phase was preparation.
  Format the answer as the user's task requests; if the task does not specify, use whatever format best fits the content.
