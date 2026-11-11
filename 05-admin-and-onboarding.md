# Phase 5 — Admin & self-service onboarding

**Goal:** another team publishes an agent end to end without your involvement, and the
catalog stays honest on its own.

**Demo at the end:** "A team I've never met registered an agent, it passed validation, three
reviewers signed off, it piloted with ten users, and it's now live — and I didn't touch it."

**Prerequisites:** Phase 3 green. Phase 4 helps but isn't required.

---

## Steps

### 1. Two authoring paths, one API

| Path | For | Mechanism |
|---|---|---|
| **Wizard** | Business owners | Guided form in the hub (or Power Apps — see below), writes via the registry API |
| **`agent.yaml`** | Engineering teams | File in their repo, published from their CI, reviewed as a pull request |

Both hit the same `PUT /v1/agents/{id}/versions/{v}` and are validated against the same
JSON Schema from Phase 2. **No second schema, no second code path.**

```yaml
# agent.yaml in the owning team's repo
id: contracts-search
name: Contract Search Assistant
source: org_hosted
owner:
  team: Legal Ops
  contact: legalops-agents@org.example
  stewardUpn: j.kowalski@org.example
routing:
  summary: Finds clauses and obligations across executed supplier contracts.
  useFor:
    - Locating a specific clause type across contracts
    - Checking notice periods and renewal dates
  doNotUseFor:
    - Legal advice or interpretation
    - Drafting new contract language
  examplePrompts:
    - Which supplier contracts auto-renew before March?
  keywords: [contract, clause, renewal, supplier, obligation]
access:
  visibility: org
  entitlementGroup: SG-AGENT-LEGAL-CONTRACTS
data:
  classification: confidential
  pii: processes
  transcriptRetentionDays: 30
endpoint:
  adapter: mcp.http
  config:
    serverUrl: https://legal-agent.internal.example/mcp
    auth: { mode: entra_obo, scope: api://legal-agent/.default }
    tools: { allow: [search_contracts, get_contract] }
```

The wizard's job is to **teach the routing fields by asking the right questions.** Ask
"what should someone *not* use this for?" directly — owners always have an answer and
never think to write it down unprompted. That one question does more for Phase 4's
accuracy than any amount of prompt tuning.

### 2. Automated validation gates

Run on every submit. All must pass before the card can move to review.

| Gate | Check |
|---|---|
| Schema | Valid against `agent-card.v1.json`; routing fields non-empty |
| Adapter config | `IAgentAdapter.ValidateConfig` for the named adapter |
| Reachability | Endpoint responds; auth handshake succeeds |
| Smoke run | Each `examplePrompt` returns a non-error response |
| Duplicate detection | Cosine similarity of the routing embedding against published agents; **flag above 0.9** |
| Entitlement group | The named Entra group exists and resolves |
| Classification | `restricted` classification cannot have `visibility: org` |

Duplicate detection is the one people skip and later regret. Two agents doing the same
thing is how a catalog becomes untrustworthy, and it's much easier to resolve before both
have users.

### 3. Review workflow

Three reviewers, three checklists, recorded against the card version:

- **Security** — auth mode, egress, write-capable tools, human-in-the-loop declared
- **Data** — classification, PII, residency, retention
- **Catalog stewardship** — is the routing block good enough that the help agent will do the right thing?

That third review is unusual and worth keeping. It's a *product* review of discoverability,
and it's the only gate that protects Phase 4's quality as the catalog grows.

### 4. Pilot, then publish

Published to a named pilot group only. Help agent may recommend it to that group. Collect
real queries and feedback for a fixed window, then open up.

### 5. Owner dashboard

Per-agent, for the owning team: sessions, unique users, thumbs-up rate, p95 latency, cost,
eval results, open access requests, days until `reviewDue`.

Give owners the data and most will maintain their own agents. Without it, every
maintenance action has to come from you.

### 6. Keep the catalog honest

Scheduled jobs, and the real output of this phase:

| Job | Cadence | Action |
|---|---|---|
| Health check | 15 min | Smoke the endpoint; three consecutive failures → flag |
| Eval run | Nightly | Run the agent's suite; regression → flag |
| Review due | Daily | `reviewDue` passed → flag, notify owner |
| Grace expiry | Daily | Flagged > 14 days → **unlist** |
| Owner check | Weekly | Steward UPN no longer valid → handover task |

**Published is not a terminal state.** Automatic unlisting is what prevents catalog rot,
which is the most likely way this platform quietly fails. Make it real, not a backlog item.

### 7. Access requests

`request_access(agentId, justification)` → approval by manager + owner → **write to the
Entra group**, not to a table of your own. The `access_requests` table records the paper
trail; Entra holds the truth.

### 8. Optional — Power Apps for this phase

Phase 5 is forms-over-data with approvals, which is exactly where Power Platform wins. A
reasonable split:

- **Canvas app in Teams** — the intake wizard
- **Model-driven app** — review and approval queues
- **Power Automate** — approval routing, notifications, the scheduled jobs above

**One rule: it must call the registry API through a custom connector. Never a parallel
Dataverse table.** Generate an OpenAPI spec from ASP.NET, import it as a custom connector,
and Power Apps becomes just another client of the same API as React. The moment agent
metadata lives in both Postgres and Dataverse you have two sources of truth and a sync
problem that never fully goes away.

Licensing scales with audience, which happens to favour this split — admin screens have
20–50 users (cheap), the hub itself has everyone (not cheap).

---

## Database changes

```sql
CREATE TABLE agent_reviews (
    agent_version_id uuid        NOT NULL REFERENCES agent_versions(id) ON DELETE CASCADE,
    kind             varchar(20) NOT NULL,   -- 'security' | 'data' | 'routing'
    reviewer_upn     varchar(320) NOT NULL,
    decision         varchar(20) NOT NULL,   -- 'approved' | 'changes_requested'
    notes            text,
    decided_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_version_id, kind)
);

CREATE TABLE access_requests (
    id             uuid PRIMARY KEY,
    agent_id       varchar(80)  NOT NULL REFERENCES agents(id),
    requester_upn  varchar(320) NOT NULL,
    justification  text         NOT NULL,
    status         varchar(20)  NOT NULL DEFAULT 'pending',
    approver_upn   varchar(320),
    decided_at     timestamptz,
    expires_at     timestamptz,
    created_at     timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX ix_access_pending ON access_requests (agent_id)
    WHERE status = 'pending';

CREATE TABLE eval_runs (
    id         uuid PRIMARY KEY,
    agent_id   varchar(80) NOT NULL REFERENCES agents(id),
    suite      varchar(120) NOT NULL,
    score      numeric(4,3),
    passed     boolean,
    details    jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent_health (
    agent_id        varchar(80) PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
    last_check_at   timestamptz,
    consecutive_failures int NOT NULL DEFAULT 0,
    flagged_at      timestamptz,
    flag_reason     varchar(200)
);
```

---

## Exit criteria

- [ ] A team outside the platform group published an agent end to end with **zero** help from you — this is the only exit criterion that really matters
- [ ] Both authoring paths (wizard and `agent.yaml`) produce identical cards from the same input
- [ ] All seven validation gates run on submit and block on failure
- [ ] Duplicate detection flagged a deliberate near-duplicate in testing
- [ ] Three-reviewer sign-off recorded against the card version and visible in audit
- [ ] An agent with a failing health check was flagged automatically, and unlisted after the grace period, without anyone intervening
- [ ] An access request flowed through approval and resulted in **Entra group membership**, not a database row
- [ ] Owner dashboard live and at least one owner has used it unprompted
- [ ] Starter repo published: schema, local validator, MCP server template, conformance tests
