# Proposal: Derive tool schema from Rust types and doc comments

## Problem

The current `#[rig_tool]` macro requires manual annotation of information that
already exists in the Rust code:

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
- **`required(...)`** duplicates what the type system already expresses
  (`T` = required, `Option<T>` = optional)

This creates a maintenance burden and a class of silent bugs where the schema
drifts from the actual code (e.g. forgetting to add a new param to
`required(...)`, or adding a param without a description).

Additionally, the macro hand-rolls JSON Schema via a `get_json_type()` helper
that only covers primitives and `Vec<T>` — everything else falls back to
`"type": "object"`. Meanwhile, rig-core already depends on schemars 1.0.4 and
uses `#[derive(JsonSchema)]` + `schema_for!()` in `AgentToolArgs`
(`rig-core/src/agent/tool.rs`). Two schema generation paths exist for the same
purpose.

## Proposed behavior

The macro should derive the full JSON Schema from the Rust source, with zero
configuration for the common case:

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

This generates:

```json
{
  "name": "add",
  "description": "Add two numbers",
  "parameters": {
    "type": "object",
    "properties": {
      "a": { "type": "integer", "description": "First number" },
      "b": { "type": "integer", "description": "Second number" }
    },
    "required": ["a", "b"]
  }
}
```

### Core change: schemars replaces hand-rolled schema

Instead of `get_json_type()`, the macro derives `schemars::JsonSchema` on the
generated params struct and uses `schema_for!()` at runtime — the same pattern
`AgentToolArgs` already uses:

```rust
// Current (hand-rolled)
#[derive(serde::Deserialize)]
struct AddParameters { a: i32, b: i32 }
// + serde_json::json!({...}) with manual type mapping

// Proposed (schemars-derived)
#[derive(serde::Deserialize, rig::schemars::JsonSchema)]
struct AddParameters {
    /// First number
    a: i32,
    /// Second number
    b: i32,
}
// + serde_json::to_value(rig::schemars::schema_for!(AddParameters))
```

This immediately gains support for nested structs, enums, `HashMap`, tuples,
`Option<T>` nullable handling — anything schemars supports.

### Type mapping (via schemars)

schemars generates JSON Schema from Rust types automatically. Key mappings:

| Rust type                | JSON Schema                                       | In `required`? | `#[serde(default)]`? |
| ------------------------ | ------------------------------------------------- | -------------- | -------------------- |
| `i8`..`i64`, `u8`..`u64` | `"type": "integer"`                               | Yes            | No                   |
| `f32`, `f64`             | `"type": "number"`                                | Yes            | No                   |
| `String`                 | `"type": "string"`                                | Yes            | No                   |
| `bool`                   | `"type": "boolean"`                               | Yes            | No                   |
| `Vec<T>`                 | `"type": "array", "items": {...}`                 | Yes            | No                   |
| `Option<T>`              | `"anyOf": [{"type": "T"}, {"type": "null"}]`      | Yes            | Yes (auto-added)     |
| `HashMap<String, T>`     | `"type": "object", "additionalProperties": {...}` | Yes            | No                   |
| Custom struct            | `"type": "object", "properties": {...}` + `$defs` | Yes            | No                   |
| Enum (serde-tagged)      | `"oneOf": [...]` or `"enum": [...]`               | Yes            | No                   |

The `Option<T>` handling follows OpenAI's strict mode convention: all fields
stay in `required`, but nullable types get an `anyOf` with `null`. The macro
auto-adds `#[serde(default)]` on `Option<T>` fields in the generated params
struct so that deserialization succeeds when the LLM omits the field or sends
`null`.

### Breaking change: integer types

The current `get_json_type()` maps all numeric types (including integers) to
`"type": "number"`. schemars correctly distinguishes `i32` -> `"integer"` from
`f64` -> `"number"` per JSON Schema spec. This is a **schema-level breaking
change** for existing tools that use integer parameters. LLMs handle both fine,
but downstream code that matches on `"number"` will need updating.

### Description sources

| Source                                 | Fallback                                  |
| -------------------------------------- | ----------------------------------------- |
| Function doc comment (`///`)           | `"Function to {name}"` (current behavior) |
| Parameter doc comment (`///` on param) | `"Parameter {name}"` (current behavior)   |
| Explicit `description = "..."`         | Overrides doc comment                     |
| Explicit `params(x = "...")`           | Overrides doc comment for that param      |

The macro reads `#[doc = "..."]` attributes from `ItemFn.attrs` (function-level)
and `FnArg::Typed.attrs` (parameter-level). syn already parses these. schemars
1.0 picks up `#[doc]` attributes automatically for JSON Schema `description`
fields.

When an explicit `params(x = "...")` is provided, the macro emits
`#[schemars(description = "...")]` instead of `#[doc = "..."]` on that field,
so the explicit value wins.

The tool-level description lives in `ToolDefinition.description` (not in the
JSON schema), so the macro extracts it from the function doc comment or
`description = "..."` attribute and passes it directly — schemars is not
involved at that level.

### Required behavior

| Scenario                     | `required` array                         |
| ---------------------------- | ---------------------------------------- |
| No `required(...)` attribute | All parameter names (derived from types) |
| Explicit `required(a, b)`    | Only `a`, `b` (manual override)          |

schemars does NOT populate the `required` array by default. The macro
post-processes the schema to inject it:

```rust
let mut schema = serde_json::to_value(rig::schemars::schema_for!(#params_struct_name))
    .expect("schema serialization");
schema["required"] = serde_json::json!([#(#required_args),*]);
```

This is cleaner than adding `#[schemars(required)]` on every field in codegen.

## Dependency wiring

rig-derive is a proc-macro crate — it cannot depend on schemars directly. It
emits code that references schemars types, which compile in the user's crate
context. rig-core must re-export schemars so the generated code resolves:

```rust
// rig-core/src/lib.rs
pub use schemars;
```

The macro then emits `rig::schemars::JsonSchema` and
`rig::schemars::schema_for!()`. No new dependency is added to the ecosystem —
rig-core already depends on schemars 1.0.4.

## Generated code (full example)

For this input:

```rust
/// Search documents by query
#[rig_tool]
fn search(
    /// The search query string
    query: String,
    /// Maximum number of results
    limit: Option<i32>,
) -> Result<Vec<String>, ToolError> { ... }
```

The macro generates:

```rust
#[derive(serde::Deserialize, rig::schemars::JsonSchema)]
pub struct SearchParameters {
    /// The search query string
    pub query: String,
    /// Maximum number of results
    #[serde(default)]
    pub limit: Option<i32>,
}

fn search(query: String, limit: Option<i32>) -> Result<Vec<String>, ToolError> { ... }

#[derive(Default)]
pub struct Search;

impl rig::tool::Tool for Search {
    const NAME: &'static str = "search";

    type Args = SearchParameters;
    type Output = Vec<String>;
    type Error = ToolError;

    fn name(&self) -> String {
        "search".to_string()
    }

    async fn definition(&self, _prompt: String) -> rig::completion::ToolDefinition {
        let mut schema = serde_json::to_value(
            rig::schemars::schema_for!(SearchParameters)
        ).expect("schema serialization");
        schema["required"] = serde_json::json!(["query", "limit"]);

        rig::completion::ToolDefinition {
            name: "search".to_string(),
            description: "Search documents by query".to_string(),
            parameters: schema,
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        search(args.query, args.limit)
    }
}

pub static SEARCH: Search = Search;
```

## Interface examples

### Zero-config (common case)

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

### Optional parameter

```rust
/// Search documents
#[rig_tool]
fn search(
    /// The search query
    query: String,
    /// Maximum results (defaults to 10)
    limit: Option<i32>,
) -> Result<Vec<String>, ToolError> { ... }
```

### Complex parameter types

```rust
#[derive(serde::Deserialize, schemars::JsonSchema)]
pub enum SortOrder {
    #[serde(rename = "asc")]
    Ascending,
    #[serde(rename = "desc")]
    Descending,
}

/// List items with sorting
#[rig_tool]
fn list_items(
    /// Field to sort by
    sort_by: String,
    /// Sort direction
    order: SortOrder,
    /// Filter tags
    tags: Vec<String>,
) -> Result<Vec<String>, ToolError> { ... }
```

### Explicit override (escape hatch)

```rust
#[rig_tool(
    description = "Override the doc comment",
    params(query = "Override this param's doc comment"),
    required(query)
)]
fn search(
    /// This doc comment is ignored because params() overrides it
    query: String,
    limit: Option<i32>,
) -> Result<Vec<String>, ToolError> { ... }
```

## Current provider behavior

Both OpenAI and Anthropic providers already force all properties into `required`
at the provider level, overwriting whatever the macro generates:

```rust
// providers/openai/mod.rs — sanitize_schema()
if let Some(Value::Object(properties)) = obj.get("properties") {
    let prop_keys = properties.keys().cloned().map(Value::String).collect();
    obj.insert("required".to_string(), Value::Array(prop_keys));
}

// providers/anthropic/completion.rs — identical logic
```

This means the `required(...)` macro attribute currently has **no effect** for
OpenAI and Anthropic — the provider silently overwrites it. The attribute only
affects providers that pass the schema through unmodified:

| Provider   | Sanitizes `required`? | `required(...)` has effect? |
| ---------- | --------------------- | --------------------------- |
| OpenAI     | Yes — forces all      | No                          |
| Anthropic  | Yes — forces all      | No                          |
| OpenRouter | Yes — forces all      | No                          |
| Ollama     | No — passes through   | Yes                         |
| Mistral    | No — passes through   | Yes                         |
| xAI        | No — passes through   | Yes                         |
| Together   | No — passes through   | Yes                         |
| Llamafile  | No — passes through   | Yes                         |

Defaulting `required` to all params at the macro level aligns the pass-through
providers with what OpenAI and Anthropic already enforce. It also makes the
provider-level sanitization redundant — which could be removed in a future
cleanup.

## Known quirks

### Q1: schemars `Option<T>` representation vs OpenAI strict mode

schemars 1.0 represents `Option<T>` as
`{"anyOf": [{"type": "T"}, {"type": "null"}]}`, not
`{"type": ["T", "null"]}`. OpenAI's sanitizer already handles `anyOf`, and the
`anyOf` form is valid JSON Schema. Verify with integration tests that the
schema round-trips through both OpenAI and Anthropic sanitizers without loss.

### Q2: schemars does not populate `required`

schemars does NOT add fields to `required` by default — only fields annotated
with `#[schemars(required)]`. Since we want all fields required (OpenAI/
Anthropic convention), the macro post-processes the schema to inject the
`required` array rather than annotating every field.

### Q3: Parameter doc comment syntax

`/// comment` on function parameters is stable Rust syntax but uncommon. syn
parses it correctly. rustfmt preserves parameter attributes in Rust 2024
edition.

### Q4: Explicit attribute vs doc comment conflict

When both a doc comment and `params(x = "...")` are present on the same
parameter, the explicit attribute must win. The macro handles this by emitting
`#[schemars(description = "...")]` instead of `#[doc = "..."]` on the
generated struct field when an explicit param description is provided. schemars
gives `#[schemars(description)]` priority over `#[doc]`.

### Q5: schemars `$defs` for nested types

When parameters use custom structs or enums, schemars emits `$defs` at the
schema root with referenced definitions. This is valid JSON Schema but some LLM
providers may not support `$defs` / `$ref`. OpenAI's sanitizer strips sibling
keywords next to `$ref`. Test with complex types against all providers.

### Q6: Re-exporting schemars from rig-core

The macro emits `rig::schemars::JsonSchema` and `rig::schemars::schema_for!()`.
This requires `pub use schemars;` in rig-core's lib.rs. Users who also depend
on schemars directly won't conflict — it's the same version from workspace.

## Precedent

This approach follows established Rust ecosystem patterns:

- **clap** derives CLI argument descriptions from doc comments via
  `#[derive(Parser)]`
- **schemars** derives JSON Schema from Rust types via `#[derive(JsonSchema)]`
- **serde** uses `#[serde(default)]` to handle optional fields

The `AgentToolArgs` struct in `rig-core/src/agent/tool.rs` already demonstrates
the exact pattern: `#[derive(JsonSchema)]` on the args struct, `schema_for!()`
in `definition()`, doc comments on fields for descriptions.

## Testing strategy

### Unit tests (rig-derive/tests/)

Schema correctness tests — each generates a tool via `#[rig_tool]`, calls
`definition()`, and asserts on the resulting JSON:

| Test                         | Asserts                                                           |
| ---------------------------- | ----------------------------------------------------------------- |
| `doc_comment_description`    | Function `///` -> `definition().description`                      |
| `param_doc_comments`         | Parameter `///` -> `properties.x.description` in schema           |
| `explicit_overrides_doc`     | `description = "..."` wins over `///`                             |
| `param_override_doc`         | `params(x = "...")` wins over `/// on x`                          |
| `option_nullable`            | `Option<i32>` -> nullable `anyOf` in schema                       |
| `option_deserialization`     | `Option<T>` field absent in JSON -> `None`, `null` -> `None`      |
| `required_all_by_default`    | All fields in `required` array (update existing test)             |
| `required_explicit_override` | `required(a)` only lists `a` (update existing test)               |
| `nested_struct_param`        | Struct param -> proper `$defs` / nested object schema             |
| `vec_param`                  | `Vec<String>` -> `{"type": "array", "items": {"type": "string"}}` |
| `integer_vs_number`          | `i32` -> `"integer"`, `f64` -> `"number"`                         |
| `no_params`                  | Zero-param tool -> empty properties, empty required               |
| `enum_param`                 | Enum with serde rename -> proper enum schema                      |
| `hashmap_param`              | `HashMap<String, T>` -> object with `additionalProperties`        |
| `async_tool`                 | Async function works identically (update existing test)           |
| `visibility`                 | pub/private propagation unchanged (update existing test)          |

### Integration tests (schema round-trip through provider sanitizers)

```rust
#[test]
fn schema_survives_openai_sanitization() {
    // 1. Generate schema via #[rig_tool] with Option<T> and nested types
    // 2. Run through openai::sanitize_schema()
    // 3. Verify properties, required, and nullable fields survive intact
}

#[test]
fn schema_survives_anthropic_sanitization() {
    // Same as above but through anthropic::sanitize_schema()
}
```

### Snapshot tests (optional, high-value)

Use `insta` or manual JSON comparison to snapshot the exact schema output for
key tool definitions. Catches unintentional schema drift across schemars
upgrades.

### Compile-fail tests

| Test                      | Expected error                     |
| ------------------------- | ---------------------------------- |
| Missing `Result` return   | "Function must have a return type" |
| Non-deserializable param  | serde error on generated struct    |
| Non-JsonSchema param type | schemars error on generated struct |

### Example updates

Update all examples in `rig-derive/examples/rig_tool/`:

- `simple.rs` — add doc comments (zero-config style)
- `full.rs` — switch from explicit attrs to doc comments
- `with_description.rs` — demonstrate explicit override as escape hatch
- `async_tool.rs` — add doc comments
- Add `complex_types.rs` — enum, nested struct, `Option<T>`, `Vec<T>`

## Implementation sequence

### Step 1: Re-export schemars from rig-core

Add `pub use schemars;` to `rig-core/src/lib.rs`. No functional change — just
makes schemars available as `rig::schemars` for the macro's generated code.

### Step 2: Extract doc comments in the macro

Parse `#[doc = "..."]` attributes from:

- `input_fn.attrs` — join trimmed lines with spaces for tool description
- `pat_type.attrs` on each `FnArg::Typed` — for parameter descriptions

Fallback to current defaults when no doc comment is present.

### Step 3: Generate params struct with `#[derive(JsonSchema)]`

Change the generated struct from:

```rust
#[derive(serde::Deserialize)]
```

to:

```rust
#[derive(serde::Deserialize, rig::schemars::JsonSchema)]
```

Propagate doc comments as `#[doc = "..."]` attrs on struct fields. When
`params(x = "...")` overrides a parameter, emit `#[schemars(description)]`
instead.

### Step 4: Detect `Option<T>` and auto-add `#[serde(default)]`

When a parameter type is `Option<T>`, add `#[serde(default)]` on the
corresponding field in the generated struct. This ensures deserialization
succeeds when the LLM omits the field or sends `null`.

### Step 5: Replace `definition()` body with schemars

Replace the hand-built `serde_json::json!({...})` with:

```rust
let mut schema = serde_json::to_value(
    rig::schemars::schema_for!(#params_struct_name)
).expect("schema serialization");
schema["required"] = serde_json::json!([#(#required_args),*]);
```

### Step 6: Delete `get_json_type()`

The entire `get_json_type()` function (lines 121-162 in current lib.rs) is no
longer needed. Remove it.

### Step 7: Handle explicit attribute overrides

When `description = "..."` is provided, use it instead of the function doc
comment for `ToolDefinition.description`. When `params(x = "...")` is
provided, emit `#[schemars(description = "...")]` on that field instead of
the doc comment.

### Step 8: Update tests

Migrate existing tests (`calculator.rs`, `required_defaults.rs`,
`visibility.rs`) to the new interface. Add new tests from the matrix above.

### Step 9: Update examples

Convert examples to doc-comment style. Keep one example demonstrating the
explicit override escape hatch. Add a complex-types example.

### Step 10: Emit deprecation warnings (Phase 1)

When a user provides `description`, `params`, or `required` and the same
information is already available from doc comments / types, emit a compile-time
warning via `proc_macro::Diagnostic` (or `compile_warning!` pattern):

```text
warning: `description = "..."` is redundant when a doc comment is present
  --> src/tools.rs:3:1
   |
3  | #[rig_tool(description = "Add two numbers")]
   |            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   help: remove this and use a doc comment instead
```

## Deprecation path

### Phase 1: Deprecation warnings (this release)

Explicit attributes continue to work. Informational warnings when they
duplicate doc comments.

### Phase 2: Soft deprecation (next minor)

Mark attributes with `#[deprecated]` in documentation. Docs recommend doc
comments as primary approach.

### Phase 3: Removal (next major)

Remove `description` and `params` attributes. Keep `required` as a niche
override for providers that need partial required lists.

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
