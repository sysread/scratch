# Intuit

`scratch intuit` runs a multi-phase intuition agent that gives you a synthesized gut-reaction to whatever you feed it. It's a sanity gauge — "what does my subconscious think about this?"

## Usage

Pass a prompt as arguments:

```bash
scratch intuit "should I refactor auth before adding the new endpoint?"
```

Or pipe input:

```bash
git log --oneline -20 | scratch intuit
git diff HEAD~5 | scratch intuit
cat design-doc.md | scratch intuit
```

Output is a short first-person directive — usually one paragraph.

## How it works

The intuition agent runs three phases:

1. **Perception** — reads your input and summarizes the situation in a single completion.
2. **Drive reactions** — four parallel completions, each reacting through a different lens:
   - **Curiosity** — what's interesting, what questions arise
   - **Skepticism** — what could go wrong, what's being overlooked
   - **Pragmatism** — what's practical, what's the path of least resistance
   - **Stewardship** — what's the long-term impact, what precedent does this set
3. **Synthesis** — concatenates the four reactions and produces a coherent directive.

All phases use a fast model with thinking disabled for low latency. The value comes from running multiple distinct lenses in parallel, not from any single phase being a deep thinker.

## Debug output

To see each phase's intermediate output:

```bash
SCRATCH_DEBUG_INTUITION=1 scratch intuit "what should I prioritize this week?"
```

This logs perception, each drive reaction, and the synthesis to stderr, labeled by phase.
