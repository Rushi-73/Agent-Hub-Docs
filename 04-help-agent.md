# Phase 4 — Help agent

**Goal:** a user describes a task in their own words and gets the right agent, with a
reason and a one-click handoff.

**Demo at the end:** "I type 'I need to check why a supplier invoice was rejected' and it
recommends the right agent, explains why, names an alternative, and opens it."

**Prerequisites:** Phase 3 green. At least 10 published agents with good routing blocks —
below that there's nothing to route between and you can't tell if it works.

---

## Steps

### 1. Add vectors to the existing index

No new store. Phase 2 gave you `search_tsv`; add the vector half beside it.

```sql
CREATE EXTENSION IF NOT EXISTS vector;
ALTER TABLE agent_versions ADD COLUMN embedding vector(1536);
CREATE INDEX ix_versions_embedding ON agent_versions
  USING hnsw (embedding vector_cosine_ops);
```

Embed the **routing block only** — summary, use-for, do-not-use-for, example prompts,
keywords. Not the whole card: endpoint config and ops metrics are noise that dilutes the
signal.

```csharp
static string EmbeddingText(AgentCard c) => string.Join("\n", [
    c.Name,
    c.Routing.Summary,
    ..c.Routing.UseFor.Select(u => $"Use for: {u}"),
    ..c.Routing.DoNotUseFor.Select(d => $"Do not use for: {d}"),
    ..c.Routing.ExamplePrompts,
    string.Join(", ", c.Routing.Keywords)
]);
```

Re-embed on publish, inside the same transaction that sets `status = 'published'`. An
agent that's live but unembedded is invisible to the help agent, which is a confusing bug
to chase.

### 2. Hybrid retrieval

```sql
WITH kw AS (
  SELECT agent_id, ts_rank(search_tsv, websearch_to_tsquery('english', @q)) AS score
  FROM agent_versions
  WHERE status = 'published' AND search_tsv @@ websearch_to_tsquery('english', @q)
  ORDER BY score DESC LIMIT 30
),
vec AS (
  SELECT agent_id, 1 - (embedding <=> @qvec) AS score
  FROM agent_versions
  WHERE status = 'published' AND embedding IS NOT NULL
  ORDER BY embedding <=> @qvec LIMIT 30
)
SELECT agent_id, SUM(w) AS fused FROM (
  SELECT agent_id, 1.0 / (60 + ROW_NUMBER() OVER (ORDER BY score DESC)) AS w FROM kw
  UNION ALL
  SELECT agent_id, 1.0 / (60 + ROW_NUMBER() OVER (ORDER BY score DESC)) AS w FROM vec
) f GROUP BY agent_id ORDER BY fused DESC LIMIT 20;
```

That's reciprocal rank fusion — simple, no tuning, and good enough. **Apply the
entitlement filter inside both CTEs**, by reusing the Phase 2 `VisibleTo` predicate. Never
filter after retrieval: an agent the user can't open must never reach the ranker, or it
will eventually be recommended.

### 3. Re-rank and answer

Send the top 20 full routing blocks to the model with the user's query and department.
Demand structured output:

```json
{
  "recommendation": { "agentId": "fin-invoice-triage", "confidence": 0.86,
                      "why": "Explains validation failures for supplier invoices, which is exactly what you described." },
  "alternatives": [ { "agentId": "fin-po-lookup", "when": "if you need the PO rather than the rejection reason" } ],
  "noMatch": false
}
```

Three non-negotiable prompt rules:

1. **Closed world.** Only agent ids present in the supplied candidates may be named. A
   hallucinated agent name is worse than no answer, because the user will go looking for it.
2. **`doNotUseFor` is an exclusion, not a penalty.** If a candidate's do-not-use-for
   matches the query, drop it entirely.
3. **Refuse to guess.** Below a confidence floor (start at 0.55, tune with the eval set),
   return `noMatch: true`. Do not return a weak pick.

### 4. Tools, if you make it agentic

Phase 4 can ship as a plain pipeline — query in, recommendation out — which is simpler and
easier to evaluate. Make it agentic only when you want follow-up conversation:

| Tool | Notes |
|---|---|
| `search_agents(query, filters)` | Entitlement-scoped. The only retrieval path. |
| `get_agent(id)` | Full card, for explaining limits and prerequisites |
| `compare_agents(ids[])` | When two candidates genuinely overlap |
| `check_access(id)` | Does the user have the run entitlement? |
| `request_access(id, justification)` | Turns a dead end into a ticket (Phase 5) |
| `start_session(id, seedPrompt)` | Tier A handoff via the gateway |
| `build_deeplink(id, seedPrompt)` | Tier B handoff |
| `log_gap(query)` | Explicit "nothing exists for this" |

### 5. The eval set — do not skip this

Build **100–200 labelled queries → expected agent id**, harvested from your Phase 2
catalog search logs and from the service desk. Real user phrasing, not phrasings you
invented.

```
db/eval/routing-v1.jsonl
{"query":"why was invoice 4471239 rejected","expect":"fin-invoice-triage"}
{"query":"who approves a PO over 50k","expect":"fin-approval-policy"}
{"query":"book annual leave","expect":null}        // correct answer is noMatch
```

Run it in CI on every change to the router prompt, the fusion weights, the embedding model,
or the confidence floor. **Gate the build on top-1 accuracy.** Include `null`-expected rows
so you also measure false confidence, which is the failure mode that actually loses user
trust.

Target ≥ 85% top-1 before shipping to everyone.

### 6. Surface it where users are

Build the help agent as a **thin API over your registry and gateway**
(`POST /v1/concierge/ask`), not as logic embedded in the React app. Then:

- The hub calls it directly
- In Phase 6, the *same* API becomes the tool backend for a Copilot Studio version of the
  help agent, so it works in Teams with no second implementation

This is the main reason to keep it unprivileged and API-shaped from the start.

### 7. Gap mining

Cluster `noMatch` queries weekly and publish the top clusters. This is the single most
valuable product input you'll get — it's a ranked list of agents your organisation needs
and doesn't have, generated by actual demand.

---

## Database changes

```sql
CREATE EXTENSION IF NOT EXISTS vector;
ALTER TABLE agent_versions ADD COLUMN embedding vector(1536);
CREATE INDEX ix_versions_embedding ON agent_versions
  USING hnsw (embedding vector_cosine_ops);

CREATE TABLE routing_events (
    id                   uuid PRIMARY KEY,
    query_redacted       text        NOT NULL,
    recommended_agent_id varchar(80) REFERENCES agents(id),
    confidence           numeric(4,3),
    no_match             boolean     NOT NULL DEFAULT false,
    accepted             boolean,                 -- null until the user acts
    session_id           uuid REFERENCES sessions(id),
    user_dept            varchar(120),
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_routing_nomatch ON routing_events (created_at DESC)
    WHERE no_match = true;
```

`query_redacted` runs through the same redaction pipeline as prompts. Users will paste
account numbers into the help agent.

---

## Exit criteria

- [ ] Eval set exists with ≥ 100 labelled queries, including `null`-expected rows
- [ ] Top-1 accuracy ≥ 85%, measured in CI and visible in the build output
- [ ] Entitlement filter proven to run **before** retrieval — test: a restricted agent is never recommended to a non-member
- [ ] Closed-world prompt verified: an adversarial query never produces an agent id that isn't in the catalog
- [ ] Confidence floor fires correctly: a nonsense query returns `noMatch` with a request-agent CTA
- [ ] Recommendations hand off correctly for both tiers
- [ ] `routing_events` populated with acceptance outcomes
- [ ] Weekly gap report generates automatically and has been reviewed once with agent owners
