# Model profile schema (`data/models.json`)

Scratch's internal policy for how to use Venice models.
The file is tracked in the repo and edited by hand.
Updates are code changes, not user configuration.

## Why profiles exist

A "profile" is a named bundle of `(model_id, params, venice_parameters, tooling metadata)` that scratch features reach for instead of hard-coding a model id.
Profiles let us:

- Swap the underlying model for a category of work without touching every call site (change `balanced` once, every caller picks it up).
- Document why a particular set of params makes sense for a use case (the `_comment` field).
- Validate that a profile is internally consistent against the Venice model registry (`model:profile:validate`).
- Compose: variants extend a base and add or override fields, so `coding` can be `smart` plus a lower temperature plus a Venice-specific param tweak.

## File location

`data/models.json` next to the rest of the data dir.
Resolved relative to `lib/model.sh` via `model:profile:data-path`, so it works regardless of the caller's working directory.

## Top-level structure

```json
{
  "_comment": "...",
  "version": 1,
  "base": {
    "<name>": { ... }
  },
  "variants": {
    "<name>": { ... }
  }
}
```

- `_comment` is a free-form note for human readers; ignored by every function.
- `version` is reserved for future schema migrations.
- `base` holds standalone profiles.
- `variants` holds profiles that extend a base via the `extends` field.

## Profile object schema

### Common fields (base and variant)

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `_comment` | string | optional | Free-form documentation; ignored by code. |
| `model` | string | required for base, inherited by variant | The Venice model id. Must exist in the registry cache; `model:profile:validate` enforces this. |
| `params` | object | optional | Top-level chat completion parameters (e.g. `temperature`, `reasoning_effort`). Merged into the request body by `chat:completion`. |
| `venice_parameters` | object | optional | Venice-specific extensions (e.g. `enable_web_search`, `include_venice_system_prompt`). Kept as a nested object in the request body. |
| `chars_per_token` | float | optional | Token-budget tooling metadata. See below. |

### Variant-only fields

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `extends` | string | required | The name of the base profile this variant builds on. Variants extending other variants work transitively. Cycles are not detected, so do not write cyclic definitions. |

## Resolution semantics

`model:profile:resolve <name>` returns the fully-merged JSON for a profile.

For a base profile, the result is the base entry as-is, with `params` and `venice_parameters` normalized to empty objects when absent.

For a variant, the base is recursively resolved first, then the variant is merged with `*` (jq's recursive merge):

- Scalar fields in the variant override the base.
- Nested objects (`params`, `venice_parameters`) are merged key-by-key, not replaced wholesale.
- The `extends` field is dropped from the output.
- Tooling metadata fields like `chars_per_token` follow the same scalar-override rule (variant wins over base, both are optional).

## `chars_per_token` (tooling metadata)

Fractional float, optional, defaults to `4.0` when absent.
Used by token-budgeting code (currently `lib/accumulator.sh`) to estimate request sizes for chunking.

### Why per-profile and not per-model

Different Venice models use different tokenizers; ratios vary.
Storing the field on the profile is the simplest place to override per use case (a code-heavy profile can lower the ratio without affecting a prose-heavy profile that uses the same model).
A future refactor may normalize to a model-level metadata table if many profiles end up sharing the same ratio for the same model.

### Why a float

Token approximations live in a narrow range where integer differences matter.
4.0 vs 3.0 is a 33% budget swing.
Bash has no float support, so callers run the math through `bc -l`.

### Defaults

- `4.0` is the v1 default for English-language text models.
- `3.0` has been observed for Venice's embedding model (`text-embedding-bge-m3`); set explicitly on profiles that target embeddings.
- Code-dense or CJK-heavy contexts may need a lower ratio still.

### What ignores it

`model:profile:validate` does not validate `chars_per_token` because it is not a Venice capability.
The Venice API never sees the field; it stays inside scratch.

## Validation

`model:profile:validate <name>` runs three checks in order, and reports every failure (not just the first):

1. The profile exists in `data/models.json`.
2. The model id named by the profile exists in the registry cache.
   Lazy-fetches the registry if missing.
3. Every `param` and `venice_parameter` in the resolved profile is supported by the model's declared capabilities.
   Capability mapping lives in `_MODEL_PARAM_CAPABILITIES` and `_MODEL_VENICE_PARAM_CAPABILITIES` at the top of the profile section in `lib/model.sh`.

Unknown params (not in the capability mapping) are skipped silently.
We cannot validate what we do not know about, and Venice's API will reject them at request time anyway.

Tooling metadata fields (`chars_per_token`, future additions) are ignored by validation.

## Adding a new profile

1. Decide whether it is a base (standalone) or a variant (composes on an existing base).
2. Add the entry under `base` or `variants` in `data/models.json`.
3. If it is a variant, set `extends` to the parent name.
4. Run `scratch model profile validate <name>` (or call `model:profile:validate <name>` directly) to confirm the model id and capabilities check out.
5. Add or update tests in `test/05-model.bats` if you are exercising new merge behavior.

## See also

- `lib/model.sh` - the resolver, validator, and registry cache code.
- `lib/accumulator.sh` - the first consumer of `chars_per_token`.
- `docs/dev/components.md` - the inventory entry for `lib/model.sh` with cross-references.
