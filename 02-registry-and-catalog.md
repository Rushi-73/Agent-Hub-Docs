# Phase 2 — Registry & catalog

**Goal:** a real, browsable agent catalog. Users find agents, read what they do, and
launch M365 declarative agents by deep link.

No runtime, no chat. This phase is about **discovery**, which is most of the value and
needs none of the hard integration.

**Demo at the end:** "I search for 'invoice', find three agents, read what each one is for
and what it won't do, and click through to open one in Copilot."

**Prerequisites:** Phase 1 exit criteria all green. Read `appendix-agent-config.md` first.

---

## Steps

### 1. The Agent Card model

The card is a JSON document stored in a JSONB column. Model it in Core as a typed record,
but keep `Endpoint.Config` as a raw `JsonElement` — the registry must never interpret it.

```csharp
// src/AgentHub.Core/Catalog/AgentCard.cs
public sealed record AgentCard
{
    public required string      Id          { get; init; }
    public required string      Version     { get; init; }
    public required string      Name        { get; init; }
    public required AgentSource Source      { get; init; }
    public required Interaction Interaction { get; init; }
    public required Owner       Owner       { get; init; }
    public required Routing     Routing     { get; init; }
    public required Access      Access      { get; init; }
    public required DataPolicy  Data        { get; init; }
    public required Endpoint    Endpoint    { get; init; }
    public Ops?       Ops       { get; init; }
    public Lifecycle? Lifecycle { get; init; }
}

public sealed record Endpoint
{
    public required string      Adapter { get; init; }   // "http.generic", "deeplink.m365", ...
    public required JsonElement Config  { get; init; }   // opaque — adapters only
}

public sealed record Routing
{
    public required string   Summary        { get; init; }
    public required string[] UseFor         { get; init; }
    public required string[] DoNotUseFor    { get; init; }
    public required string[] ExamplePrompts { get; init; }
    public string[]  Keywords { get; init; } = [];
    public string[]  Audience { get; init; } = [];
    public string[]  Related  { get; init; } = [];
}
```

`Routing.UseFor`, `DoNotUseFor` and `ExamplePrompts` are **required** and non-empty.
Enforce it in validation. Phase 4's help agent is only as good as these fields, and
backfilling them across 40 agents later is a miserable job nobody volunteers for.

### 2. EF mapping for the JSONB column

```csharp
b.Entity<AgentVersion>(e =>
{
    e.ToTable("agent_versions");
    e.HasKey(x => x.Id);
    e.Property(x => x.Card)
     .HasColumnType("jsonb")
     .HasConversion(
         v => JsonSerializer.Serialize(v, JsonOpts.Default),
         s => JsonSerializer.Deserialize<AgentCard>(s, JsonOpts.Default)!);
    e.HasIndex(x => new { x.AgentId, x.Semver }).IsUnique();
});
```

Use a single shared `JsonOpts.Default` (camelCase, `JsonStringEnumConverter`,
ignore-null-on-write). Serialiser settings drifting between the registry and the gateway
produces bugs that are genuinely painful to track down.

### 3. JSON Schema for the card

Write `schemas/agent-card.v1.json` and validate every incoming card against it in the API.
This same file is reused in Phase 5 for the `agent.yaml` CI check — one contract, two
enforcement points.

```powershell
dotnet add src/AgentHub.Registry package JsonSchema.Net
```

Validate before deserialising, so a malformed card returns useful field-level errors
rather than a deserialisation exception.

### 4. Registry endpoints

```
GET    /v1/agents                    # list + filter + search (entitlement-scoped)
GET    /v1/agents/{id}               # current published version
GET    /v1/agents/{id}/versions      # version history
POST   /v1/agents                    # create draft
PUT    /v1/agents/{id}/versions/{v}  # update draft card
POST   /v1/agents/{id}/versions/{v}/publish
POST   /v1/agents/{id}/deprecate
GET    /v1/agents/{id}/handoff       # Tier B deep link
GET    /v1/facets                    # for catalog filters
```

`GET /v1/agents` must apply **visibility** filtering server-side from the caller's group
claims. In this phase write it as a reusable query filter — Phase 4's help agent will use
exactly the same predicate, and it must not be reimplemented there.

```csharp
public static IQueryable<AgentVersion> VisibleTo(
    this IQueryable<AgentVersion> q, ClaimsPrincipal user)
{
    var groups = user.FindAll("groups").Select(c => c.Value).ToArray();
    return q.Where(v =>
        v.Status == AgentStatus.Published &&
        (v.Visibility == Visibility.Org ||
         v.EntitlementGroups.Any(g => groups.Contains(g))));
}
```

Note the deliberate split: **visibility** controls whether it appears in the catalog;
**entitlement** controls whether it can run (Phase 3). Visible-but-not-entitled is a
good state — the user sees the agent exists and gets a "request access" button.

### 5. Deep-link handoff (Tier B)

This is the entire Tier B runtime, and it needs no Microsoft API access — just the agent id.

```csharp
public sealed class DeepLinkM365Adapter : IAgentAdapter
{
    public string Kind => "deeplink.m365";

    public AdapterCapabilities Capabilities(JsonElement cfg)
        => new(Invocable: false, Streaming: false, Files: false, Cards: false);

    public string BuildUrl(JsonElement cfg, string? seedPrompt)
    {
        var agentId = cfg.GetProperty("agentId").GetString();
        var url = $"https://m365.cloud.microsoft/chat?agentId={Uri.EscapeDataString(agentId!)}";
        if (!string.IsNullOrWhiteSpace(seedPrompt))
            url += $"&q={Uri.EscapeDataString(seedPrompt)}";
        return url;
    }

    public Task<AgentSession> OpenAsync(...) => throw new NotInvocableException(Kind);
    public IAsyncEnumerable<AgentEvent> SendAsync(...) => throw new NotInvocableException(Kind);
}
```

Verify the deep-link URL format against your tenant before relying on it — this URL shape
has changed before. Keep it in config (`appsettings`) rather than hard-coded so a change
is a config edit, not a release.

### 6. Catalog UI

Four screens, nothing more:

| Screen | Contents |
|---|---|
| **Catalog** | Search box, facets (source, tier, audience, capability), result cards showing name, summary, owner, tier badge |
| **Agent detail** | Full routing block, prominent **"Use for"** / **"Don't use for"**, example prompts, owner, data classification, prerequisites, primary action button |
| **My access** | Agents the user can run; agents visible but not entitled, with request buttons (wired in Phase 5) |
| **Admin list** | All agents including drafts, with status — plain table, platform team only |

The primary action button is driven entirely by `interaction.tier`:

- **Tier A** → "Open chat" — disabled with "Coming in Phase 3" until the gateway ships
- **Tier B** → "Open in Copilot" → `GET /v1/agents/{id}/handoff`

Make the tier visually obvious on every entry. Users need to know *before* clicking
whether they're staying in the hub or leaving for Copilot — a surprise context switch is
the single most common complaint about catalogues like this.

### 7. Seed the catalog

Load your Phase 0 inventory as real cards. Target **at least 10**, including every M365
declarative agent you have, since those are fully functional in this phase.

Keep seeds as JSON files in `db/seed/` applied by an idempotent CLI command, not hand-typed
into the UI. You'll re-seed dev environments often.

---

## Database changes

```sql
CREATE TYPE agent_status AS ENUM
    ('draft','in_review','published','deprecated','retired');
CREATE TYPE visibility   AS ENUM ('org','department','restricted');

CREATE TABLE agents (
    id              varchar(80) PRIMARY KEY,         -- slug, immutable
    owner_team_id   uuid NOT NULL REFERENCES teams(id),
    source          varchar(40) NOT NULL,
    tier            char(1)     NOT NULL,            -- 'A' | 'B'
    current_version varchar(20),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent_versions (
    id            uuid PRIMARY KEY,
    agent_id      varchar(80)  NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    semver        varchar(20)  NOT NULL,
    card          jsonb        NOT NULL,
    status        agent_status NOT NULL DEFAULT 'draft',
    visibility    visibility   NOT NULL DEFAULT 'org',
    published_at  timestamptz,
    superseded_by uuid REFERENCES agent_versions(id),
    created_by    varchar(320) NOT NULL,
    created_at    timestamptz  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ix_versions_agent_semver ON agent_versions (agent_id, semver);
CREATE INDEX ix_versions_status ON agent_versions (status)
    WHERE status = 'published';

-- mapping only. NO per-user rows, ever.
CREATE TABLE agent_entitlements (
    agent_id       varchar(80) NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    entra_group_id uuid        NOT NULL,
    scope          varchar(10) NOT NULL,   -- 'view' | 'run'
    PRIMARY KEY (agent_id, entra_group_id, scope)
);

-- full-text search over the routing block
ALTER TABLE agent_versions ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english',
      coalesce(card->'routing'->>'summary','') || ' ' ||
      coalesce(card->>'name','') || ' ' ||
      coalesce(card->'routing'->>'keywords',''))
  ) STORED;
CREATE INDEX ix_versions_search ON agent_versions USING GIN (search_tsv);
```

The generated `search_tsv` column gives you decent catalog search for free and becomes half
of Phase 4's hybrid retrieval. The vector half is added in Phase 4.

---

## Exit criteria

- [ ] At least 10 real agents published, each with non-empty `useFor`, `doNotUseFor` and `examplePrompts`
- [ ] Catalog search returns sensible results for 10 realistic queries typed by someone who didn't build it
- [ ] `GET /v1/agents` never returns an agent the caller shouldn't see — verified with two test users in different groups
- [ ] Clicking a Tier B agent opens it in Copilot, with the seeded prompt where supported
- [ ] Tier A agents show a clearly disabled action, not a broken one
- [ ] Publishing a card with an invalid `endpoint.config` is rejected with field-level errors
- [ ] A card with an unknown `endpoint.adapter` returns 422 naming the adapter, not a 500
- [ ] Catalog and detail pages render correctly at phone width
