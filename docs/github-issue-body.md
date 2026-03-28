- [x] I have looked for existing issues (including closed) about this

## Feature Request

I'm willing to implement this, but wanted to confirm with the
maintainers first that this is the right direction before investing
the effort.

Enhance `#[rig_tool]` to derive the JSON Schema from Rust types and
doc comments instead of requiring manual macro attributes, achieving
zero-configuration for the common case.

### Motivation

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

This creates a maintenance burden and a class of silent bugs where the schema
drifts from the actual code (e.g. forgetting to add a new param to
`required(...)`, or adding a param without a description).

Additionally, both OpenAI and Anthropic providers already force all properties
into `required` at the provider level (see `providers/openai/mod.rs` line 54-58
and `providers/anthropic/completion.rs` line 928-930), making the `required(...)`
macro attribute effectively a no-op for the two major providers:

| Provider  | Sanitizes `required`? | `required(...)` has effect? |
| --------- | --------------------- | --------------------------- |
| OpenAI    | Yes — forces all      | No                          |
| Anthropic | Yes — forces all      | No                          |
| Ollama    | No — passes through   | Yes                         |
| Mistral   | No — passes through   | Yes                         |
| xAI       | No — passes through   | Yes                         |
| Together  | No — passes through   | Yes                         |
| Llamafile | No — passes through   | Yes                         |

### Proposal

The macro should derive the full schema from the Rust source:

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

**Description sources** (with fallbacks):

| Source                             | Fallback                    |
| ---------------------------------- | --------------------------- |
| Function doc comment (`///`)       | `"Function to {name}"`      |
| Param doc comment (`///` on param) | `"Parameter {name}"`        |
| Explicit `description = "..."`     | Overrides doc comment       |
| Explicit `params(x = "...")`       | Overrides param doc comment |

**Type mapping:**

| Rust type        | JSON Schema                       | In `required`? |
| ---------------- | --------------------------------- | -------------- |
| `T` (non-Option) | `"type": "<json_type>"`           | Yes            |
| `Option<T>`      | `"type": ["<json_type>", "null"]` | Yes            |

The `Option<T>` handling follows
[OpenAI's strict mode convention](https://platform.openai.com/docs/guides/structured-outputs#all-fields-must-be-required):
all fields stay in `required`, but nullable types use `["type", "null"]`.

**Deprecation path:**

Once doc-comment extraction is implemented, the explicit attributes become
redundant. A gradual deprecation over three releases:

1. **Next minor** — emit compile-time warnings when attributes duplicate doc
   comments
1. **Next minor + 1** — mark attributes as deprecated in docs
1. **Next major** — remove `description` and `params`; keep `required` as a
   niche override

**Implementation scope:**

1. Extract function doc comment as tool description (parse `#[doc = "..."]` from
   `input_fn.attrs`)
1. Extract parameter doc comments as param descriptions (parse `#[doc = "..."]`
   from `FnArg` attrs)
1. Detect `Option<T>` and emit `"type": ["inner_type", "null"]`
1. Auto-add `#[serde(default)]` on `Option<T>` fields in the generated params
   struct
1. Default `required` to all params (separate PR: #1570)
1. Emit deprecation warnings when explicit attributes duplicate doc comments

### Alternatives

**Keep the current manual attributes.** Users continue specifying `description`,
`params`, and `required` by hand. Drawback: boilerplate, drift between schema
and code, and the `required` attribute is silently ignored by OpenAI/Anthropic
providers anyway.

**Use `schemars::JsonSchema` derive on params struct.** Instead of the macro
generating the schema from function params, require users to define a separate
params struct with `#[derive(JsonSchema)]`. Drawback: more boilerplate (separate
struct + function), though it would produce a more accurate schema. This could
complement the doc-comment approach for complex types.

**Only fix `required` defaults (no doc-comment extraction).** Just default
`required` to all params (PR already submitted). This fixes the immediate bug
but doesn't address the broader redundancy of `description` and `params`
attributes. This is the minimum viable change and could be shipped independently
while the larger redesign is discussed.
