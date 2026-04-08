# Prompt storage

LLM prompt assets used by `lib/` libraries and (eventually) by agents live as flat markdown files under this directory.
Storing prompts as files instead of bash heredocs keeps them out of the way of shell escaping rules, lets editors render them as the documents they are, and lets the anti-slop scan treat them like any other tracked text.

## Layout

```
data/prompts/
  README.md            (this file)
  <feature>/
    <name>.md          (one prompt per file)
```

One prompt per file.
Per-feature subdirectories - so `accumulator/system.md`, not a top-level `accumulator-system.md`.
This keeps growth manageable as more libraries and agents land their own prompts.

`<feature>` is typically the library or agent that owns the prompt: `accumulator/`, `agent-foo/`, etc.

## Loading

Prompts are loaded via `lib/prompt.sh`:

```bash
source "$SCRATCH_HOME/lib/prompt.sh"

# Static load
prompt:load accumulator/system

# Render with {{var}} substitution
prompt:render accumulator/system \
  user_prompt="$prompt" \
  question="$question" \
  notes="$accumulated_notes"
```

The lookup root is `data/prompts/` next to the repo's `lib/` directory by default.
Tests override this via `SCRATCH_PROMPTS_DIR` to point at a fixture root under the test tmpdir.

## Placeholder syntax

`prompt:render` substitutes `{{var}}` placeholders with the values supplied as `var=value` arguments.
Substitution is literal:

- No nesting (substituted values are not re-scanned for placeholders).
- No HTML or JSON escaping.
- Variables not supplied are left as-is in the output, so missing placeholders are visible during testing rather than silently dropped.
- Special characters in values (`/`, `&`, `|`, `\`) are handled correctly.

## Conventions

- Markdown extension (`.md`) because LLMs handle markdown natively and editors render it nicely.
- Subject to the anti-slop scan (no smart quotes, no em dashes) - same rules as the rest of the tracked text.
- Comments inside prompts use HTML comment syntax (`<!-- ... -->`) so they survive markdown rendering but are visually quiet.
- Prompts should explain themselves to the model from a cold start.
  Assume the model has no shared context with the rest of scratch.
