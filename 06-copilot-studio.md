# Phase 6 — Copilot Studio

**Goal:** Copilot Studio agents work in the hub exactly like org-hosted ones.

**This phase should be boring.** One adapter class, one DI registration, config rows. If it
turns out to need migrations, API changes or UI changes, something in Phases 2–3 was built
wrong — stop and fix that instead of working around it here.

**Demo at the end:** "I chat with a Copilot Studio agent in the hub and can't tell from the
UI that it's a different source."

**Prerequisites:** Phases 2 and 3 green. Copilot Studio maker + environment access
(requested back in Phase 0). At least one published Copilot Studio agent to point at.

---

## Verify this first

This part of the Microsoft platform moves. Before writing code, confirm against current
docs — a morning's reading saves a week of rework:

1. **Client surface.** Is the Microsoft 365 Agents SDK client still the streaming path?
   Direct Line does **not** stream for Copilot Studio agents, so if you need streaming,
   it's the SDK.
2. **Auth model.** Last verified (Nov 2026): the SDK client supports **delegated user
   auth only** — no app-only / service-principal tokens. If that's still true, there is no
   unattended invocation of Copilot Studio agents. Check whether it's changed; if app-only
   has landed, it unlocks scheduled agents and is worth knowing before you design around
   the limitation.
3. **Scope** for the OBO exchange.
4. **Capacity model** — message consumption per turn, and what your tenant has.

Record what you find in the ADR. The next person will ask.

---

## Steps

### 1. New adapter project

```powershell
dotnet new classlib -o src/AgentHub.Adapters.CopilotStudio
dotnet sln add src/AgentHub.Adapters.CopilotStudio
dotnet add src/AgentHub.Adapters.CopilotStudio reference src/AgentHub.Core
dotnet add src/AgentHub.Gateway reference src/AgentHub.Adapters.CopilotStudio
dotnet add src/AgentHub.Adapters.CopilotStudio package Microsoft.Agents.CopilotStudio.Client
```

Confirm the package name against current Microsoft docs — the Agents SDK packages have
been renamed before.

### 2. Implement `IAgentAdapter`

Same interface as every other adapter. Nothing new to design.

```csharp
public sealed class CopilotStudioAdapter(
    ITokenExchange tokens,
    ICopilotStudioClientFactory clients,
    ILogger<CopilotStudioAdapter> log) : IAgentAdapter
{
    public string Kind => "copilot.studio";

    public IReadOnlyList<string> ValidateConfig(JsonElement cfg)
    {
        var errors = new List<string>();
        if (!cfg.TryGetProperty("environmentId", out var env) ||
            !Guid.TryParse(env.GetString(), out _))
            errors.Add("environmentId must be a GUID");
        if (!cfg.TryGetProperty("agentSchemaName", out _))
            errors.Add("agentSchemaName is required");
        var client = cfg.Path("client") ?? "agents_sdk";
        if (client is not ("agents_sdk" or "directline"))
            errors.Add("client must be 'agents_sdk' or 'directline'");
        if (client == "directline" && cfg.Path("streaming.mode") == "sse")
            errors.Add("Direct Line does not stream for Copilot Studio agents; " +
                       "use client 'agents_sdk' or streaming mode 'none'");
        return errors;
    }

    public AdapterCapabilities Capabilities(JsonElement cfg) => new(
        Invocable: true,
        Streaming: cfg.Path("client") != "directline",
        Files:     false,
        Cards:     true);

    public async Task<AgentSession> OpenAsync(
        AgentCard card, InvocationContext ctx, CancellationToken ct)
    {
        var cfg   = card.Endpoint.Config;
        var scope = cfg.Path("auth.scope")!;

        // Delegated only — the gateway must never call this as itself.
        var token  = await tokens.OnBehalfOfAsync(ctx.UserToken, scope, ct);
        var client = clients.Create(cfg.Path("environmentId")!,
                                    cfg.Path("agentSchemaName")!, token);

        var conversationId = await client.StartConversationAsync(ct);
        return new AgentSession(Guid.NewGuid(), card, ctx, ExternalId: conversationId);
    }

    public async IAsyncEnumerable<AgentEvent> SendAsync(
        AgentSession s, AgentTurn turn, [EnumeratorCancellation] CancellationToken ct)
    {
        var client = clients.ForSession(s);

        await foreach (var activity in client.SendAsync(
                           s.ExternalId!, turn.Text, ct))
        {
            // Map Copilot Studio activities onto the normalised event model.
            // This mapping is the only Copilot-Studio-specific logic in the codebase.
            switch (activity.Type)
            {
                case "typing":
                    continue;

                case "message":
                    if (activity.Text is { Length: > 0 })
                        yield return new AgentEvent.Token(activity.Text);

                    foreach (var att in activity.Attachments ?? [])
                        if (att.ContentType == "application/vnd.microsoft.card.adaptive")
                            yield return new AgentEvent.Card(att.Content);

                    foreach (var c in activity.Citations ?? [])
                        yield return new AgentEvent.Citation(c.Title, c.Url);
                    break;

                case "endOfConversation":
                    yield return new AgentEvent.Done(UsageInfo.FromActivity(activity));
                    yield break;
            }
        }
    }
}
```

### 3. Register it

The only line the gateway gains in this entire phase:

```csharp
builder.Services.AddKeyedSingleton<IAgentAdapter, CopilotStudioAdapter>("copilot.studio");
```

### 4. Add config rows

No migration. Insert cards.

```json
{
  "adapter": "copilot.studio",
  "config": {
    "environmentId":   "8f21aaaa-bbbb-cccc-dddd-eeeeffff0000",
    "agentSchemaName": "cr1a2_invoiceTriage",
    "auth":   { "mode": "entra_obo",
                "scope": "https://api.powerplatform.com/.default" },
    "client": "agents_sdk",
    "streaming": { "mode": "sse" }
  }
}
```

### 5. Capacity metering

The one genuinely new concern in this phase. Copilot Studio consumes **message capacity**
rather than tokens, so your existing per-token cost model doesn't apply.

- Record consumed messages per turn in `turns.tool_calls` or a dedicated column
- Alert on burn rate against your capacity pack — a single popular agent can drain one fast
- Surface it on the owner dashboard next to cost

### 6. Migrate the Tier B agents worth migrating

Now you have the data to make this argument properly. Phase 2 has been counting deep-link
clickthroughs on declarative agents; the heavily-used ones are candidates for rebuilding
in Copilot Studio, which moves them from Tier B to Tier A and buys you streaming,
transcripts, evals and cost attribution.

Rebuild the top 2–3 by clickthrough. Leave the long tail as Tier B — low-traffic
declarative agents are fine where they are, and rebuilding them is work with no payoff.

### 7. Consider moving the help agent here

Phase 4 built the help agent as an API. Wrapping it as a Copilot Studio agent whose tools
call that API puts it in Teams and Copilot, where users already are — **one
implementation, two front doors.** The hub consumes it through the gateway like any other
Tier A agent.

This is optional, and it's the best reason to want Copilot Studio access at all.

---

## Database changes

**None.**

That's the deliverable of Phases 2 and 3. If you find yourself writing a migration here,
the adapter contract leaked — a source-specific field has reached the schema. Push it back
into `endpoint.config`.

The one exception worth allowing: a `messages_consumed` column on `turns` for capacity
metering, since that's a genuinely new *metric*, not a source-specific field. Even that
can live in the existing `tool_calls` JSONB if you'd rather keep the promise clean.

---

## Exit criteria

- [ ] At least one Copilot Studio agent working in the hub, streaming
- [ ] **Zero migrations** in this phase
- [ ] **Zero changes** to the registry API, the catalog UI, or the chat runner
- [ ] Onboarding a second Copilot Studio agent was config-only
- [ ] OBO verified: the agent returns only data the signed-in user can already see, tested with two accounts with different SharePoint access
- [ ] `ValidateConfig` rejects a `directline` + `streaming: sse` combination at publish time
- [ ] Message capacity consumption recorded per turn and visible to owners
- [ ] A user cannot tell from the UI which source an agent came from, except where the tier badge says so
- [ ] Verification findings from the top of this file recorded in the ADR

---

## If this phase was hard

Worth a retrospective, because it's diagnostic. The likely causes:

| Symptom | Root cause |
|---|---|
| Needed a migration | A source-specific field reached the schema instead of `endpoint.config` |
| Needed UI changes | The chat runner reads the source instead of `capabilities` |
| Needed gateway changes | Cross-cutting concerns (auth, retry, metering) were implemented inside an adapter in Phase 3 rather than in the pipeline |
| Needed registry changes | The registry is interpreting `endpoint.config` instead of treating it as opaque |

Each of those is worth fixing properly rather than patching, because the next source you
add — a partner team's agent, a Foundry agent, something that doesn't exist yet — will hit
exactly the same wall.
