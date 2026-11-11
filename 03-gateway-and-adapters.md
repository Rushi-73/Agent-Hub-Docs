# Phase 3 — Gateway & dynamic adapters

**Goal:** chat with your organisation's own agents inside the hub — streaming,
authenticated as the real user, logged, metered.

This is the most important phase. At the end of it you have a working product with **no
Microsoft dependency at all**, and you have proven the adapter contract works before
Copilot Studio ever enters the picture.

**Demo at the end:** "I pick an org-hosted agent from the catalog, ask it a question, watch
the answer stream in, and the session shows up in the admin view with its token cost."

**Prerequisites:** Phase 2 green; `appendix-agent-config.md` read; endpoint details for
2–3 org-hosted agents collected in Phase 0.

---

## Steps

### 1. New service

```powershell
dotnet new web -o src/AgentHub.Gateway
dotnet new classlib -o src/AgentHub.Adapters.Http
dotnet sln add src/AgentHub.Gateway src/AgentHub.Adapters.Http
dotnet add src/AgentHub.Gateway reference src/AgentHub.Core src/AgentHub.Adapters.Http
dotnet add src/AgentHub.Adapters.Http reference src/AgentHub.Core
dotnet add src/AgentHub.Adapters.Http package Json.More.Net   # JSONPath
```

Separate service, not a controller in the registry. Different scaling profile (long-lived
SSE connections), different failure mode, and a gateway outage should degrade the hub to a
catalog rather than taking it down.

### 2. The adapter contract

Put `IAgentAdapter`, `AgentEvent`, `AgentSession` and `AdapterCapabilities` in
`AgentHub.Core/Adapters/` exactly as written in the appendix. Then enforce the dependency
rule with an architecture test so nobody breaks it by accident six months from now:

```csharp
[Fact]
public void Core_does_not_reference_adapters()
{
    var refs = typeof(IAgentAdapter).Assembly.GetReferencedAssemblies()
                                    .Select(a => a.Name);
    Assert.DoesNotContain(refs, n => n!.StartsWith("AgentHub.Adapters"));
}
```

### 3. The generic HTTP adapter

The one piece of real engineering in this phase. Four parts:

```csharp
public sealed class GenericHttpAdapter(
    IHttpClientFactory http,
    ITokenExchange tokens,
    ISecretResolver secrets) : IAgentAdapter
{
    public string Kind => "http.generic";

    public IReadOnlyList<string> ValidateConfig(JsonElement cfg)
    {
        var errors = new List<string>();
        if (!cfg.TryGetProperty("baseUrl", out var b) || !Uri.IsWellFormedUriString(
                b.GetString(), UriKind.Absolute))
            errors.Add("baseUrl must be an absolute URI");
        if (!cfg.TryGetProperty("response", out var r) ||
            !r.TryGetProperty("text", out _))
            errors.Add("response.text (JSONPath) is required");
        // ...auth mode known, streaming mode known, template parses
        return errors;
    }

    public async IAsyncEnumerable<AgentEvent> SendAsync(
        AgentSession s, AgentTurn turn, [EnumeratorCancellation] CancellationToken ct)
    {
        var cfg  = s.Card.Endpoint.Config;
        var body = RequestTemplate.Render(cfg.GetProperty("request")
                                            .GetProperty("template"), s, turn);

        using var req = new HttpRequestMessage(
            HttpMethod.Parse(cfg.Path("invoke.method") ?? "POST"),
            cfg.Path("baseUrl") + cfg.Path("invoke.path"));

        req.Content = JsonContent.Create(body);
        await ApplyAuth(req, cfg, s.Context, ct);

        var mode = cfg.Path("streaming.mode") ?? "none";
        await foreach (var e in mode switch
        {
            "sse"    => ReadSse(req, cfg, ct),
            "ndjson" => ReadNdjson(req, cfg, ct),
            _        => ReadOnce(req, cfg, ct)
        }) yield return e;
    }
}
```

**`RequestTemplate.Render`** walks the template JSON and substitutes `{{...}}`. A
placeholder that is an entire string value substitutes the *typed* value; a placeholder
inside a longer string interpolates as text. Keep this in Core and unit-test it hard —
it's the piece every future adapter reuses.

**`ReadOnce`** for non-streaming: POST, read the body, apply the response JSONPaths, emit
`Token(text)` then `Done`. The UI needs no special case, which is the whole reason the
event model is normalised.

**Check the error path before the text path.** Some internal agents return HTTP 200 with
an error body; if `response.error` resolves to anything non-empty, emit `Error` and stop.

### 4. Token exchange (on-behalf-of)

The security spine of the whole platform. The gateway never calls a downstream agent as
itself when that agent holds per-user data.

```csharp
public interface ITokenExchange
{
    Task<string> OnBehalfOfAsync(string userToken, string scope, CancellationToken ct);
    Task<string> ClientCredentialsAsync(string scope, CancellationToken ct);
}
```

Implement with `Microsoft.Identity.Web`'s downstream token acquisition. Cache per
(user, scope) with the token's own lifetime — do not cache across users, which is the
obvious bug waiting to happen here. Make that a test.

### 5. Gateway endpoints

```
POST /v1/sessions                      # open: {agentId} -> {sessionId, capabilities}
POST /v1/sessions/{id}/messages        # send a turn (idempotency key required)
GET  /v1/sessions/{id}/stream          # SSE
POST /v1/sessions/{id}/feedback        # thumbs + text
GET  /v1/sessions/{id}                 # metadata (not content)
```

`POST /v1/sessions` is where the **run** entitlement is enforced — not in the browser:

```csharp
app.MapPost("/v1/sessions", async (
    OpenSessionRequest req, ClaimsPrincipal user,
    IRegistryClient registry, AdapterResolver adapters, AgentHubDb db) =>
{
    var card = await registry.GetPublishedCardAsync(req.AgentId);
    if (card is null) return Results.NotFound();

    if (!EntitlementCheck.CanRun(user, card))
        return Results.Problem(statusCode: 403, title: "Not entitled",
            detail: $"Request access to {card.Name} from the catalog.");

    var adapter = adapters.For(card);
    var caps    = adapter.Capabilities(card.Endpoint.Config);
    if (!caps.Invocable)
        return Results.Problem(statusCode: 409, title: "Not invocable",
            detail: "This agent opens in Microsoft 365 Copilot. Use /handoff.");

    var session = await adapter.OpenAsync(card, InvocationContext.From(user), default);
    db.Sessions.Add(Session.From(session, user, card));
    await db.SaveChangesAsync();

    return Results.Ok(new { sessionId = session.Id, capabilities = caps });
});
```

Returning **409 with a pointer to `/handoff`** for Tier B agents is better than 403 — the
caller learns what to do instead, and the UI can act on it.

### 6. Cross-cutting pipeline

These live in the gateway once, not in each adapter. Order matters:

1. **Authn/authz** — validate token, resolve entitlement
2. **Idempotency** — reject a duplicate turn key
3. **Redaction** — strip detected secrets and configured PII patterns *before* anything is logged
4. **Timeout & retry** — per-agent from `invoke.timeoutMs`; retry only idempotent reads, never a turn
5. **Metering** — tokens, latency, cost into `turns`
6. **Tracing** — OpenTelemetry span per session → turn → tool call
7. **Transcript** — append to Blob, referenced by `sessions.transcript_uri`

Redaction sits before logging deliberately. Once an unredacted prompt is in your logs it's
in your backups too, and that's the kind of thing that turns into a compliance finding.

### 7. Chat runner UI

```tsx
const es = new EventSource(
  `${API}/v1/sessions/${sessionId}/stream`, { withCredentials: true });

es.addEventListener("token",    e => appendToken(JSON.parse(e.data).text));
es.addEventListener("citation", e => addCitation(JSON.parse(e.data)));
es.addEventListener("card",     e => renderAdaptiveCard(JSON.parse(e.data)));
es.addEventListener("error",    e => showError(JSON.parse(e.data)));
es.addEventListener("done",     () => { finishTurn(); es.close(); });
```

`EventSource` can't send an `Authorization` header. Either mint a short-lived
session-scoped token in the `POST /v1/sessions` response and pass it as a query parameter,
or use `fetch` with a `ReadableStream` reader. The fetch approach is more code but keeps
the token out of URLs and logs — **prefer it**.

Handle `capabilities` honestly: hide file upload when `Files` is false, show a plain
spinner rather than a fake typewriter when `Streaming` is false.

### 8. Onboard the pilot agents

Turn your Phase 0 intake sheet into `endpoint.config` JSON. Target: **the second agent
takes under an hour and requires no code.** If it needs a code change, the generic adapter
is missing a knob — add the knob rather than special-casing the agent.

---

## Database changes

```sql
CREATE TABLE sessions (
    id             uuid PRIMARY KEY,
    agent_id       varchar(80)  NOT NULL REFERENCES agents(id),
    agent_version  varchar(20)  NOT NULL,
    user_oid       uuid         NOT NULL,
    user_dept      varchar(120),
    started_at     timestamptz  NOT NULL DEFAULT now(),
    ended_at       timestamptz,
    turn_count     int          NOT NULL DEFAULT 0,
    total_cost_usd numeric(10,5) NOT NULL DEFAULT 0,
    status         varchar(20)  NOT NULL DEFAULT 'open',
    external_id    varchar(200),          -- the source's own conversation id
    transcript_uri text                   -- blob ref. NOT the content.
);
CREATE INDEX ix_sessions_agent_started ON sessions (agent_id, started_at DESC);
CREATE INDEX ix_sessions_user          ON sessions (user_oid, started_at DESC);

CREATE TABLE turns (
    session_id  uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    idx         int  NOT NULL,
    latency_ms  int,
    in_tokens   int,
    out_tokens  int,
    cost_usd    numeric(10,5),
    tool_calls  jsonb,
    error_code  varchar(60),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, idx)
);
```

Note what isn't here: **message content.** Prompts and responses go to Blob Storage with
lifecycle rules from the card's `transcriptRetentionDays`. `turns` holds metered aggregates
only, so cost attribution works from day one without your OLTP database becoming a
transcript store.

---

## Exit criteria

- [ ] 2–3 org-hosted agents fully working in the hub, at least one of them streaming
- [ ] Onboarding the *second* agent required **config only**, no code change — write down how long it took
- [ ] A user not in an agent's entitlement group gets 403 with a useful message, verified with a real second account
- [ ] A Tier B agent returns 409 pointing at `/handoff`, and the UI handles it
- [ ] Every turn writes a `turns` row with tokens, latency and cost
- [ ] Transcripts land in Blob, with content absent from the database — verified by inspecting both
- [ ] OpenTelemetry traces show session → turn → tool call, with agent id and tier as attributes
- [ ] Redaction verified: post a fake API key in a prompt and confirm it's masked in logs
- [ ] Token cache holds per (user, scope) and cannot leak across users — covered by a test
- [ ] An agent whose endpoint is down fails with a clear user-facing message, not a stack trace
