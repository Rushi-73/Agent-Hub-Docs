# Phase 0 — Decisions & prerequisites

**Goal:** settle the handful of things that are expensive to change later, and get access
requests moving so they don't block you.

No code in this phase. It should take a few days, not weeks.

---

## 1. Decisions to record

Write these down somewhere permanent (an ADR file in the repo is ideal). Each one is
cheap now and expensive in three months.

| # | Decision | Default to take unless you have a reason not to |
|---|---|---|
| 1 | Where do entitlements live? | **Entra ID security groups.** Never a `user_agent_access` table — see §11 of the architecture doc. |
| 2 | Primary database | **PostgreSQL** (Flexible Server), relational + JSONB cards + pgvector. Azure SQL if the org mandates it. |
| 3 | Frontend shape | **React + TypeScript + Vite SPA.** No SSR needed; the .NET API is the backend. |
| 4 | Backend | **.NET 10**, two services: Registry and Gateway. |
| 5 | Default catalog visibility | **Org-visible**, execution gated by entitlement. Discovery is the point. |
| 6 | Who owns conversation history? | Hub keeps a transcript for audit and evals; the source keeps its own conversation state. |
| 7 | Agent config contract | The card's `endpoint.adapter` + `endpoint.config` JSON. See `appendix-agent-config.md`. |

### Decision 7 is the one to not compromise on

Everything else can be revisited. This one can't, because every agent row ever written
depends on it. If someone proposes "let's just add a `copilotStudioEnvironmentId` column
to the agents table" — that's the thing this contract exists to prevent. Source-specific
fields go inside `endpoint.config`, never into the schema.

---

## 2. Access to request now

These have lead times. Raise them in Phase 0 so they arrive when you need them, not when
you're blocked.

| What | Needed by | Notes |
|---|---|---|
| Azure subscription + resource group | Phase 1 | Contributor on a dev/test subscription |
| Entra app registrations (×2: SPA + API) | Phase 1 | You can usually create these yourself; confirm your tenant allows it |
| Postgres Flexible Server (dev) | Phase 1 | Or run Postgres in Docker locally for Phase 1 and provision in Phase 2 |
| Endpoint details for 2–3 org-hosted agents | Phase 3 | **Start this now** — see the checklist below. This is the real critical path. |
| Azure OpenAI deployment (chat + embeddings) | Phase 4 | In-tenant, in-region |
| **Copilot Studio maker + environment access** | Phase 6 | Request now, expect delay. Does not block anything before Phase 6. |
| M365 declarative agent IDs | Phase 2 | Just the IDs for deep links — no API access needed |

### Org-hosted agent intake checklist

For each of the 2–3 agents you'll onboard in Phase 3, get this from the owning team.
Chase it early — it's usually the slowest part of Phase 3 and it's all other people's time.

- Base URL (dev and prod)
- Invocation path, HTTP method, and a working sample request/response pair
- Auth mode: API key, Entra (and which scope), or none
- Does it stream? If so, SSE or NDJSON, and what the event shape is
- Does it keep conversation state? If so, what field carries the conversation id
- Rate limits and expected p95 latency
- Owner, contact, escalation path
- Data classification, and whether it processes or stores PII

Capture these in a shared sheet. In Phase 3 they become `endpoint.config` JSON almost
verbatim.

---

## 3. Agent inventory

List every agent that already exists across the three sources, with an owner name against
each. A spreadsheet is fine — it becomes your Phase 2 seed data.

Columns: name, source, owner team, owner contact, what it does, who uses it today,
is it still alive.

Expect two uncomfortable findings, and plan for them rather than being surprised:

- Several agents have **no clear owner**. Resolve ownership before cataloguing, or you'll
  publish entries nobody maintains.
- Some agents **duplicate each other**. Decide which survives now; it's much harder once
  both are listed and have users.

---

## 4. Licensing sanity check

Model this before Phase 3, because it can change the plan:

- **M365 Copilot seats** — who actually has one? Tier B deep links are useless to anyone
  who doesn't. If coverage is partial, Tier B agents need a visible prerequisite on their
  catalog entry.
- **Copilot Studio message capacity** — relevant from Phase 6. A single popular agent can
  consume a capacity pack quickly.
- **Azure OpenAI** tokens for the help agent (Phase 4) — small, but budget it.
- **Power Apps premium** — only if you take the low-code route for Phase 5 admin screens.

---

## Exit criteria

- [ ] All seven decisions recorded, with rationale, in the repo
- [ ] Azure subscription and resource group available
- [ ] Entra app registrations created (SPA + API)
- [ ] Agent inventory complete, every row has a named owner
- [ ] Intake checklist sent to the owners of the 2–3 Phase 3 pilot agents
- [ ] Copilot Studio access **requested** (not received — that's fine)
- [ ] Licensing position understood well enough to not be surprised in Phase 3
