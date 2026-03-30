## Summary

Replace the hand-rolled `get_json_type()` helper in `#[rig_tool]` with `schemars::JsonSchema` derivation — the same pattern `AgentToolArgs` already uses. This eliminates a limited type mapper (only primitives + `Vec<T>`, everything else fell back to `"type": "object"`) in favor of full JSON Schema generation that supports nested structs, enums, `HashMap`, tuples, and proper `Option<T>` nullable handling.

## Key changes

### Schema generation via schemars

- Derive `JsonSchema` on the generated params struct, use `schema_for!()` in `definition()`
- Delete `get_json_type()` entirely
- Re-export schemars from rig-core as `rig::schemars` (no new dependency — rig-core already depends on schemars 1.0)
- Add `#[schemars(crate = "rig::schemars")]` so downstream crates compile without a direct schemars dependency

### Doc comments as descriptions (zero-config)

- Function `///` doc comments → tool description
- Parameter `///` doc comments → property descriptions in schema
- Explicit `description = "..."` and `params(x = "...")` still work as overrides
- Strips `#[doc]` attrs from function parameters before re-emitting (compiler rejects them on params)

### Required defaults to all parameters

- Previously, omitting `required(...)` produced an empty `required` array, silently breaking strict function calling (OpenAI rejects this)
- Now all parameters are required by default; explicit `required(...)` still works as override
- Aligns pass-through providers (Ollama, xAI, etc.) with what OpenAI/Anthropic sanitizers already enforce

### OpenAI schema sanitizer fix

- OpenAI rejects object schemas without a `"properties"` key (400 error), even for zero-parameter tools
- Added missing-properties injection to `openai::sanitize_schema` (also covers Azure)

## Breaking

- `i32` now correctly produces `"type": "integer"` (was `"number"`) per JSON Schema spec. LLMs handle both, but downstream code matching on `"number"` for integer params will need updating.

## Before / After

```rust
// Before: manual annotation duplicating what the code already expresses
#[rig_tool(
    description = "Add two numbers",
    params(a = "First number", b = "Second number"),
    required(a, b)
)]
fn add(a: i32, b: i32) -> Result<i32, ToolError> {
    Ok(a + b)
}

// After: zero-config, derived from Rust source
/// Add two numbers
#[rig_tool]
fn add(
    /// First number
    a: i32,
    /// Second number
    b: i32,
) -> Result<i32, ToolError> {
    Ok(a + b)
}
```

## Test plan

- [x] 23 unit tests passing: doc comments, `Option<T>`, enums, `HashMap`, nested structs, `Vec`, async, visibility, required defaults, integer vs number, no-params edge case
- [x] Integration tests with real OpenAI and Anthropic APIs (extractor, reasoning roundtrip) — all pass
- [x] `cargo clippy --all-features --all-targets` clean
- [x] `cargo fmt` clean
