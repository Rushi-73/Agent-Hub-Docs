# Appendix — Agent configuration contract

**This file is the contract.** It is what makes agents configuration rather than code,
and it is why Phase 6 (Copilot Studio) needs no migrations and no UI changes.

Read this before Phase 2. Refer back to it in Phases 3 and 6.

---

## The rule

Everything source-specific lives inside `endpoint.config`, which is **opaque JSON** to the
registry, the API and the UI. Only the adapter named by `endpoint.adapter` understands it.

```json
"endpoint": {
  "adapter": "http.generic",
  "config":  { "...whatever that adapter needs..." }
}
```

Consequences, and they're the whole point:

- Adding an agent = INSERT a row. No deploy.
- Adding a new *kind* of source = one new adapter class. No migration, no API change, no UI change.
- The registry never needs to know what a "Copilot Studio environment id" is.

**The anti-pattern this exists to prevent:** adding a `copilot_studio_environment_id`
column to the `agents` table. The moment a source-specific field reaches the schema, every
future source needs its own column, and Phase 6 stops being cheap. If someone proposes it,
point them here.

---

## Adapter kinds

| Kind | Tier | Phase | Used for |
|---|---|---|---|
| `deeplink.m365` | B | 2 | M365 Copilot agent-builder declarative agents. Metadata only — no runtime. |
| `http.generic` | A | 3 | Org-hosted agents with a bespoke REST API. The workhorse. |
| `http.openai` | A | 3 | Anything exposing an OpenAI-compatible `/chat/completions`. |
| `mcp.http` | A | 3 | MCP servers — preferred contract for other teams' agents. |
| `copilot.studio` | A | 6 | Copilot Studio agents, via the M365 Agents SDK. |

---

## `deeplink.m365` — Tier B, no runtime

```json
{
  "adapter": "deeplink.m365",
  "config": {
    "agentId": "A1b2C3d4-0000-1111-2222-333344445555",
    "surface": "m365_copilot",
    "seedPromptSupported": true,
    "requiresLicense": "M365 Copilot"
  }
}
```

The adapter builds a URL and nothing else. `requiresLicense` is surfaced on the catalog
entry as a prerequisite badge — important when seat coverage is partial, so users aren't
sent to an agent they can't open.

---

## `http.generic` — the workhorse

This one config shape should cover most org-hosted agents without any code. Design it
carefully in Phase 3 and you'll onboard the rest by filling in JSON.

```json
{
  "adapter": "http.generic",
  "config": {
    "baseUrl": "https://agents.internal.example/invoice-triage",

    "invoke": {
      "method":    "POST",
      "path":      "/v1/chat",
      "headers":   { "X-Agent-Version": "2" },
      "timeoutMs": 60000
    },

    "auth": {
      "mode":      "entra_obo",
      "scope":     "api://invoice-triage/.default",
      "secretRef": "kv://agent-hub/invoice-triage"
    },

    "request": {
      "template": {
        "message":        "{{input.text}}",
        "conversationId": "{{session.externalId}}",
        "history":        "{{input.history}}",
        "user":           { "upn": "{{user.upn}}", "oid": "{{user.oid}}" }
      }
    },

    "response": {
      "text":           "$.answer",
      "citations":      "$.sources[*].url",
      "conversationId": "$.conversationId",
      "error":          "$.error.message"
    },

    "streaming": { "mode": "none" }
  }
}
```

### `auth.mode`

| Mode | Behaviour |
|---|---|
| `none` | No credential. Dev and internal-open endpoints only. |
| `api_key` | Header or query param from `secretRef`. Add `"header": "X-API-Key"`. |
| `static_bearer` | Fixed token from `secretRef`. |
| `entra_obo` | **Preferred.** Exchange the user's token for `scope`. The agent sees the real user. |
| `entra_client_credentials` | Service identity. Only where the agent has no per-user data. |

Secrets are **always** a `kv://` reference, never a literal. The card must stay safe to
read, diff, review in a pull request, and paste into a ticket.

### Request templating

`{{...}}` placeholders, resolved by the gateway at invoke time:

| Placeholder | Value |
|---|---|
| `{{input.text}}` | The user's message for this turn |
| `{{input.history}}` | Prior turns, as `[{role, content}]` |
| `{{input.files}}` | Attachment references, if any |
| `{{session.externalId}}` | The source's own conversation id, if it returned one |
| `{{session.id}}` | The hub's session id |
| `{{user.upn}}` / `{{user.oid}}` / `{{user.name}}` | From the validated token |
| `{{now}}` | ISO-8601 timestamp |

A placeholder as an entire value substitutes the typed value (so `{{input.history}}`
yields a real JSON array). A placeholder inside a longer string interpolates as text.

**Never** put `{{user.*}}` values into a template for an agent that doesn't need them —
you'd be leaking identity to a system with no reason to have it.

### Response mapping

JSONPath against the response body. Only `text` is required.

```json
"response": {
  "text":           "$.answer",
  "citations":      "$.sources[*].url",
  "conversationId": "$.conversationId",
  "error":          "$.error.message"
}
```

If `error` resolves to a non-empty value, the gateway emits an `error` event regardless of
HTTP status — some internal agents return 200 with an error body, and you want that
surfaced rather than shown to the user as an answer.

### Streaming

```json
"streaming": {
  "mode":      "sse",
  "deltaPath": "$.choices[0].delta.content",
  "doneWhen":  { "event": "done" }
}
```

`mode` is `none` | `sse` | `ndjson`. When `none`, the gateway emits one `token` event with
the full text, then `done` — so the UI needs no special case. **Declare `none` honestly**
rather than faking a typewriter effect in the client; a fake stream that stalls for eight
seconds reads worse than an honest spinner.

---

## `http.openai` — OpenAI-compatible endpoints

Many internal LLM gateways expose this shape. Shorter config, since the wire format is known:

```json
{
  "adapter": "http.openai",
  "config": {
    "baseUrl": "https://llm-gw.internal.example/v1",
    "model":   "org-assistant-v3",
    "auth":    { "mode": "api_key", "header": "Authorization",
                 "secretRef": "kv://agent-hub/llm-gw" },
    "systemPrompt": "You are the procurement policy assistant...",
    "params":  { "temperature": 0.2, "max_tokens": 1200 },
    "streaming": { "mode": "sse" }
  }
}
```

`systemPrompt` here is the one place the hub injects behaviour into an agent it doesn't
own. Use it sparingly — if you find yourself writing long prompts in cards, that agent
wants to be a real agent, not a configured endpoint.

---

## `mcp.http` — other teams' agents

The contract to publish to other teams. Tools are discovered, not configured.

```json
{
  "adapter": "mcp.http",
  "config": {
    "serverUrl": "https://team-x-agent.internal.example/mcp",
    "auth":      { "mode": "entra_obo", "scope": "api://team-x-agent/.default" },
    "tools":     { "allow": ["search_contracts", "get_contract"] },
    "streaming": { "mode": "sse" }
  }
}
```

`tools.allow` is a hub-side allowlist. An MCP server adding a new tool should not silently
gain new capability inside your hub — that's a governance boundary, so keep the allowlist
explicit even when it's tedious.

---

## `copilot.studio` — Phase 6

The payoff. Note what it *isn't*: no new columns, no new tables, no API change.

```json
{
  "adapter": "copilot.studio",
  "config": {
    "environmentId":    "8f21aaaa-bbbb-cccc-dddd-eeeeffff0000",
    "agentSchemaName":  "cr1a2_invoiceTriage",
    "auth":             { "mode": "entra_obo",
                          "scope": "https://api.powerplatform.com/.default" },
    "client":           "agents_sdk",
    "streaming":        { "mode": "sse" }
  }
}
```

`client` is `agents_sdk` or `directline`. Prefer `agents_sdk` — Direct Line does not stream
for Copilot Studio agents. Verify both the scope and the client surface when you reach
Phase 6; this part of the Microsoft platform moves.

---

## The .NET contract

One interface. Every adapter implements it; the gateway resolves the right one at runtime
from `endpoint.adapter`.

```csharp
// src/AgentHub.Core/Adapters/IAgentAdapter.cs
namespace AgentHub.Core.Adapters;

public interface IAgentAdapter
{
    /// Matches endpoint.adapter in the card, e.g. "http.generic".
    string Kind { get; }

    /// Validate config at publish time, not at 3am. Return the errors.
    IReadOnlyList<string> ValidateConfig(JsonElement config);

    AdapterCapabilities Capabilities(JsonElement config);

    Task<AgentSession> OpenAsync(
        AgentCard card, InvocationContext ctx, CancellationToken ct);

    IAsyncEnumerable<AgentEvent> SendAsync(
        AgentSession session, AgentTurn turn, CancellationToken ct);
}

public sealed record AdapterCapabilities(
    bool Invocable, bool Streaming, bool Files, bool Cards);

public abstract record AgentEvent
{
    public sealed record Token(string Text)                      : AgentEvent;
    public sealed record ToolCall(string Name, string? Arguments): AgentEvent;
    public sealed record Card(JsonElement Payload)               : AgentEvent;
    public sealed record Citation(string Title, string Url)       : AgentEvent;
    public sealed record Done(UsageInfo Usage)                   : AgentEvent;
    public sealed record Error(string Code, string Message)      : AgentEvent;
}
```

Registration — keyed DI, resolved by the card's adapter string:

```csharp
// Program.cs (Gateway)
builder.Services.AddKeyedSingleton<IAgentAdapter, DeepLinkM365Adapter>("deeplink.m365");
builder.Services.AddKeyedSingleton<IAgentAdapter, GenericHttpAdapter>("http.generic");
builder.Services.AddKeyedSingleton<IAgentAdapter, OpenAiHttpAdapter>("http.openai");
builder.Services.AddKeyedSingleton<IAgentAdapter, McpHttpAdapter>("mcp.http");
// Phase 6 — the only line this phase adds:
builder.Services.AddKeyedSingleton<IAgentAdapter, CopilotStudioAdapter>("copilot.studio");
```

```csharp
public sealed class AdapterResolver(IServiceProvider sp)
{
    public IAgentAdapter For(AgentCard card)
        => sp.GetKeyedService<IAgentAdapter>(card.Endpoint.Adapter)
           ?? throw new UnknownAdapterException(card.Endpoint.Adapter);
}
```

`UnknownAdapterException` should be a clean 422 from the API with the adapter name in the
message — it means a card references an adapter this deployment doesn't have, which is
exactly what you'll see if someone publishes a `copilot.studio` card before Phase 6 ships.
Make that failure obvious and self-explanatory rather than a 500.

---

## Validating config

Run `ValidateConfig` at **publish time** in the registry, and fail the publish with the
errors. This is what stops a broken card reaching the catalog, and it's how Phase 5's
automated onboarding gates work without the registry knowing anything about adapters.

```csharp
app.MapPost("/v1/agents/{id}/versions/{v}/publish",
    async (string id, string v, AgentHubDb db, AdapterResolver adapters) =>
{
    var version = await db.AgentVersions.FindAsync(id, v);
    var card    = version!.Card;

    var errors = adapters.For(card).ValidateConfig(card.Endpoint.Config);
    if (errors.Count > 0) return Results.ValidationProblem(
        new Dictionary<string, string[]> { ["endpoint.config"] = errors.ToArray() });

    version.Status = AgentStatus.Published;
    await db.SaveChangesAsync();
    return Results.NoContent();
});
```
