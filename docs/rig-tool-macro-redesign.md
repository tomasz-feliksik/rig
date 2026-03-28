# Proposal: Derive tool schema from Rust types and doc comments

## Problem

The current `#[rig_tool]` macro requires manual annotation of information that already exists in the Rust code:

```rust
#[rig_tool(
    description = "Add two numbers",
    params(a = "First number", b = "Second number"),
    required(a, b)
)]
fn add(a: i32, b: i32) -> Result<i32, ToolError> {
    Ok(a + b)
}
```

- **`description`** duplicates what a doc comment would say
- **`params(...)`** duplicates what parameter doc comments would say
- **`required(...)`** duplicates what the type system already expresses (`T` = required, `Option<T>` = optional)

This creates a maintenance burden and a class of silent bugs where the schema
drifts from the actual code (e.g. forgetting to add a new param to
`required(...)`, or adding a param without a description).

## Proposed behavior

The macro should derive the full JSON Schema from the Rust source, with zero configuration for the common case:

```rust
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

This would generate:

```json
{
  "name": "add",
  "description": "Add two numbers",
  "parameters": {
    "type": "object",
    "properties": {
      "a": { "type": "number", "description": "First number" },
      "b": { "type": "number", "description": "Second number" }
    },
    "required": ["a", "b"]
  }
}
```

### Type mapping

| Rust type        | JSON Schema                       | In `required`? | `#[serde(default)]` on field? |
| ---------------- | --------------------------------- | -------------- | ----------------------------- |
| `T` (non-Option) | `"type": "<json_type>"`           | Yes            | No                            |
| `Option<T>`      | `"type": ["<json_type>", "null"]` | Yes            | Yes (auto-added)              |

The `Option<T>` handling follows OpenAI's strict mode convention: all fields
stay in `required`, but nullable types use `["type", "null"]`. The macro would
also auto-add `#[serde(default)]` on `Option<T>` fields in the generated params
struct so that deserialization succeeds when the LLM sends `null`.

### Description sources

| Source                                 | Fallback                                  |
| -------------------------------------- | ----------------------------------------- |
| Function doc comment (`///`)           | `"Function to {name}"` (current behavior) |
| Parameter doc comment (`///` on param) | `"Parameter {name}"` (current behavior)   |
| Explicit `description = "..."`         | Overrides doc comment                     |
| Explicit `params(x = "...")`           | Overrides doc comment for that param      |

### Required behavior

| Scenario                     | `required` array                         |
| ---------------------------- | ---------------------------------------- |
| No `required(...)` attribute | All parameter names (derived from types) |
| Explicit `required(a, b)`    | Only `a`, `b` (manual override)          |

## Current provider behavior

Both OpenAI and Anthropic providers already force all properties into `required`
at the provider level, overwriting whatever the macro generates:

```rust
// providers/openai/mod.rs (line 54-58)
// Source: https://platform.openai.com/docs/guides/structured-outputs
//         #all-fields-must-be-required
if let Some(Value::Object(properties)) = obj.get("properties") {
    let prop_keys = properties.keys().cloned().map(Value::String).collect();
    obj.insert("required".to_string(), Value::Array(prop_keys));
}

// providers/anthropic/completion.rs (line 928-930) — identical logic
```

This means the `required(...)` macro attribute currently has **no effect** for
OpenAI and Anthropic — the provider silently overwrites it. The attribute only
affects providers that pass the schema through unmodified:

| Provider  | Sanitizes `required`? | `required(...)` has effect? |
| --------- | --------------------- | --------------------------- |
| OpenAI    | Yes — forces all      | No                          |
| Anthropic | Yes — forces all      | No                          |
| Ollama    | No — passes through   | Yes                         |
| Mistral   | No — passes through   | Yes                         |
| xAI       | No — passes through   | Yes                         |
| Together  | No — passes through   | Yes                         |
| Llamafile | No — passes through   | Yes                         |

Defaulting `required` to all params at the macro level aligns the
pass-through providers with what OpenAI and Anthropic already enforce. It also
makes the provider-level sanitization redundant — which could be removed in a
future cleanup.

## Precedent

This approach follows established Rust ecosystem patterns:

- **clap** derives CLI argument descriptions from doc comments via
  `#[derive(Parser)]`
- **schemars** derives JSON Schema from Rust types via `#[derive(JsonSchema)]`
- **serde** uses `#[serde(default)]` to handle optional fields

## Deprecation path

Once doc-comment extraction is implemented, the explicit `description`,
`params`, and `required` attributes become redundant for most use cases. A
gradual deprecation over three releases would give users time to migrate:

### Phase 1: Deprecation warnings (next minor release)

When a user provides `description`, `params`, or `required` and the same
information is already available from doc comments / types, emit a compile-time
warning:

```text
warning: `description = "..."` is redundant when a doc comment is present
  --> src/tools.rs:3:1
   |
3  | #[rig_tool(description = "Add two numbers")]
   |            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   help: remove this and use a doc comment instead
```

The attributes still work — the warning is informational only.

### Phase 2: Soft deprecation (next minor + 1)

Mark the attributes with `#[deprecated]` in the documentation. The macro
continues to accept them but the docs recommend doc comments as the primary
approach.

### Phase 3: Removal (next major release)

Remove `description` and `params` attributes entirely. `required` could be kept
as a niche override for non-OpenAI providers that genuinely need a subset of
params to be optional, but should be reconsidered based on actual usage.

### Migration example

Before:

```rust
#[rig_tool(
    description = "Search documents by query",
    params(
        query = "The search query string",
        limit = "Maximum number of results"
    ),
    required(query, limit)
)]
fn search(query: String, limit: i32) -> Result<Vec<String>, ToolError> { ... }
```

After:

```rust
/// Search documents by query
#[rig_tool]
fn search(
    /// The search query string
    query: String,
    /// Maximum number of results
    limit: i32,
) -> Result<Vec<String>, ToolError> { ... }
```

## Implementation scope

1. **Extract function doc comment** as the tool description
   (parse `#[doc = "..."]` attributes from `input_fn.attrs`)
1. **Extract parameter doc comments** as parameter descriptions
   (parse `#[doc = "..."]` from `FnArg` attrs)
1. **Detect `Option<T>`** and emit `"type": ["inner_type", "null"]` in the
   schema
1. **Auto-add `#[serde(default)]`** on `Option<T>` fields in the generated
   params struct
1. **Default `required` to all params** (already implemented in a separate PR)
1. **Emit deprecation warnings** when explicit attributes duplicate doc comments

Steps 1-2 are the main change. Steps 3-4 complete the type-driven story.
Steps 5-6 handle the transition.
