# `#[rig_tool]` Macro Design

## Overview

The `#[rig_tool]` macro transforms a plain Rust function into a `rig::tool::Tool` implementation. It derives JSON Schema from Rust types via `schemars::JsonSchema` and extracts descriptions from doc comments — achieving zero-configuration for the common case.

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

This generates a `Tool` implementation with the following schema:

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

## Schema Generation

The macro derives `schemars::JsonSchema` on the generated params struct and uses `schema_for!()` at runtime — the same pattern `AgentToolArgs` in `rig-core/src/agent/tool.rs` already uses.

This replaces the previous `get_json_type()` helper that only covered primitives and `Vec<T>` (everything else fell back to `"type": "object"`). schemars provides full JSON Schema support for nested structs, enums, `HashMap`, tuples, and `Option<T>` nullable handling out of the box.

### Type Mapping

schemars generates JSON Schema from Rust types automatically:

| Rust type                | JSON Schema                                       | `#[serde(default)]`? |
| ------------------------ | ------------------------------------------------- | -------------------- |
| `i8`..`i64`, `u8`..`u64` | `"type": "integer"`                               | No                   |
| `f32`, `f64`             | `"type": "number"`                                | No                   |
| `String`                 | `"type": "string"`                                | No                   |
| `bool`                   | `"type": "boolean"`                               | No                   |
| `Vec<T>`                 | `"type": "array", "items": {...}`                 | No                   |
| `Option<T>`              | `"type": ["T", "null"]`                           | Yes (auto-added)     |
| `HashMap<String, T>`     | `"type": "object", "additionalProperties": {...}` | No                   |
| Custom struct            | `"type": "object", "properties": {...}` + `$defs` | No                   |
| Enum (serde-tagged)      | `"oneOf": [...]` or `"enum": [...]`               | No                   |

All parameters are included in the `required` array. `Option<T>` fields use the nullable type array `["T", "null"]` following OpenAI's strict mode convention — all fields stay required, but nullable types accept `null`. The macro auto-adds `#[serde(default)]` on `Option<T>` fields so deserialization succeeds when the LLM omits the field or sends `null`.

### `schema_for!()` Output Shape

For a struct like:

```rust
#[derive(schemars::JsonSchema)]
struct SearchParameters {
    /// The search query string
    query: String,
    /// Maximum results
    #[serde(default)]
    limit: Option<i32>,
}
```

`schemars::schema_for!(SearchParameters)` produces:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "SearchParameters",
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "The search query string"
    },
    "limit": {
      "type": ["integer", "null"],
      "format": "int32",
      "default": null,
      "description": "Maximum results"
    }
  }
}
```

Notable characteristics:

- `$schema` and `title` are present at the root — harmless, providers ignore them
- `Option<T>` produces a type array `["T", "null"]`, plus `"default": null` from `#[serde(default)]`
- schemars does **not** add `additionalProperties: false` — provider sanitizers add it downstream
- **No `required` array** — the macro injects it via post-processing
- Integer types include `"format": "int32"` — harmless, providers ignore it

## Description Sources

| Source                                 | Fallback                             |
| -------------------------------------- | ------------------------------------ |
| Function doc comment (`///`)           | `"Function to {name}"` (default)     |
| Parameter doc comment (`///` on param) | `"Parameter {name}"` (default)       |
| Explicit `description = "..."`         | Overrides doc comment                |
| Explicit `params(x = "...")`           | Overrides doc comment for that param |

The macro reads `#[doc = "..."]` attributes from `ItemFn.attrs` (function-level) and `FnArg::Typed.attrs` (parameter-level). schemars 1.0 picks up `#[doc]` attributes automatically for JSON Schema `description` fields.

When `params(x = "...")` is provided, the macro emits `#[schemars(description = "...")]` instead of `#[doc = "..."]` on that field, so the explicit value wins.

The tool-level description lives in `ToolDefinition.description` (not in the JSON schema), so the macro extracts it from the function doc comment or `description = "..."` attribute and passes it directly — schemars is not involved at that level.

## Required Behavior

| Scenario                     | `required` array                |
| ---------------------------- | ------------------------------- |
| No `required(...)` attribute | All parameter names (default)   |
| Explicit `required(a, b)`    | Only `a`, `b` (manual override) |

schemars does not populate the `required` array by default. The macro post-processes the schema to inject it:

```rust
let mut schema = serde_json::to_value(
    rig::schemars::schema_for!(#params_struct_name)
).expect("schema serialization");
schema["required"] = serde_json::json!([#(#required_args),*]);
```

## Dependency Wiring

rig-derive is a proc-macro crate — it cannot depend on schemars directly. It emits code that references schemars types, which compile in the user's crate context. rig-core re-exports schemars:

```rust
// rig-core/src/lib.rs
pub use schemars;
```

The macro emits `rig::schemars::JsonSchema` and `rig::schemars::schema_for!()`. The generated struct also carries `#[schemars(crate = "rig::schemars")]` so downstream crates that don't directly depend on schemars compile correctly.

No new dependency is added — rig-core already depends on schemars 1.0.

## Generated Code

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
#[schemars(crate = "rig::schemars")]
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

## Interface Examples

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

## Provider Behavior

Both OpenAI and Anthropic providers force all properties into `required` at the provider level via their `sanitize_schema()` functions, overwriting whatever the macro generates. The macro's default of "all required" aligns pass-through providers with this behavior.

| Provider   | Sanitizes `required`? | Macro `required(...)` has effect? |
| ---------- | --------------------- | --------------------------------- |
| OpenAI     | Yes — forces all      | No                                |
| Anthropic  | Yes — forces all      | No                                |
| OpenRouter | Yes — forces all      | No                                |
| Ollama     | No — passes through   | Yes                               |
| Mistral    | No — passes through   | Yes                               |
| xAI        | No — passes through   | Yes                               |
| Together   | No — passes through   | Yes                               |
| Llamafile  | No — passes through   | Yes                               |

The OpenAI sanitizer also injects `"properties": {}` on bare object schemas (objects without a `properties` key), since OpenAI rejects them with a 400 error. Anthropic accepts bare `{"type": "object"}` without properties.

## Design Decisions

### Tool name derived from function name

There is no `name = "..."` override attribute. The tool name is the function name as a string (`fn add` → `"add"`). The struct name is PascalCase (`Add`), the static is UPPER_SNAKE (`ADD`). If you need a different name, name the function differently.

### No stateful tools

The macro targets free functions, not methods. The generated struct is a zero-sized unit struct (`struct Add;`) with no fields. Tools that need runtime state (database handles, API clients) should implement the `Tool` trait manually.

### Parameter doc comments stripped from re-emitted function

`/// comment` on function parameters is parsed by syn but rejected by the compiler (`#[doc]` is not an allowed built-in attribute on function parameters). The macro strips `#[doc]` attributes from parameters before re-emitting the function — syn reads the doc comments for schema generation, and the cleaned function compiles without errors.

## Known Quirks

### schemars `Option<T>` representation

schemars 1.0 represents `Option<T>` as `{"type": ["T", "null"]}` (a type array), not the `anyOf` form. This is valid JSON Schema. Both the OpenAI and Anthropic sanitizers recurse into `properties` but do not specifically process type arrays — they pass through unchanged, which is correct.

### schemars `$defs` for nested types

When parameters use custom structs or enums, schemars emits `$defs` at the schema root with referenced definitions. This is valid JSON Schema but some LLM providers may not fully support `$defs` / `$ref`. OpenAI's sanitizer strips sibling keywords next to `$ref`.

### Explicit attribute vs doc comment priority

When both a doc comment and `params(x = "...")` are present on the same parameter, the explicit attribute wins. The macro emits `#[schemars(description = "...")]` instead of `#[doc = "..."]` on that field. schemars gives `#[schemars(description)]` priority over `#[doc]`.

## Test Coverage

23 unit tests in `rig-derive/tests/` covering:

| Test                         | Asserts                                                          |
| ---------------------------- | ---------------------------------------------------------------- |
| `doc_comment_description`    | Function `///` → `definition().description`                      |
| `param_doc_comments`         | Parameter `///` → `properties.x.description` in schema           |
| `explicit_overrides_doc`     | `description = "..."` wins over `///`                            |
| `default_description`        | No doc comment → `"Function to {name}"` fallback                 |
| `option_nullable`            | `Option<i32>` → nullable type array in schema                    |
| `option_deserialization`     | `Option<T>` field absent in JSON → `None`, `null` → `None`       |
| `required_all_by_default`    | All fields in `required` array                                   |
| `explicit_required_override` | `required(a)` only lists `a`                                     |
| `no_params_empty_required`   | Zero-param tool → empty properties, empty required               |
| `nested_struct_param`        | Struct param → proper `$defs` / nested object schema             |
| `vec_param`                  | `Vec<String>` → `{"type": "array", "items": {"type": "string"}}` |
| `integer_vs_number`          | `i32` → `"integer"`, `f64` → `"number"`                          |
| `bool_param`                 | `bool` → `"type": "boolean"`                                     |
| `enum_param`                 | Enum with serde rename → proper enum schema                      |
| `hashmap_param`              | `HashMap<String, T>` → object with `additionalProperties`        |
| `schema_type_object`         | Top-level schema has `"type": "object"`                          |
| `async_tool_with_docs`       | Async function with doc comments works identically               |
| `visibility`                 | pub/private propagation on generated structs                     |
| `calculator`                 | End-to-end tool with explicit attributes                         |

## Future Work

### Deprecation of explicit attributes

With doc-comment extraction in place, the explicit `description`, `params`, and `required` attributes are redundant for the common case. A potential deprecation path:

1. Emit compile-time warnings when attributes duplicate doc comments
1. Mark attributes as deprecated in documentation
1. Remove `description` and `params`; keep `required` as a niche override

### Additional test coverage

- **Snapshot tests** — use `insta` or manual JSON comparison to catch unintentional schema drift across schemars upgrades
- **Compile-fail tests** — verify error messages for missing `Result` return, non-deserializable params, non-JsonSchema param types
- **Provider sanitizer round-trip tests** — verify schemas survive `openai::sanitize_schema()` and `anthropic::sanitize_schema()` intact

### Provider sanitizer cleanup

Since the macro now defaults `required` to all parameters, the provider-level sanitization that forces all properties into `required` is redundant. This could be removed in a future cleanup to simplify the provider code.

## Precedent

This approach follows established Rust ecosystem patterns:

- **clap** derives CLI argument descriptions from doc comments via `#[derive(Parser)]`
- **schemars** derives JSON Schema from Rust types via `#[derive(JsonSchema)]`
- **serde** uses `#[serde(default)]` to handle optional fields

The `AgentToolArgs` struct in `rig-core/src/agent/tool.rs` already demonstrates the exact pattern: `#[derive(JsonSchema)]` on the args struct, `schema_for!()` in `definition()`, doc comments on fields for descriptions.
