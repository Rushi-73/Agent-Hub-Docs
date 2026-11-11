# Agent Hub — Build Documentation

Phased build plan. Each phase is **independently shippable** — you can stop after any
phase and still have something that works and demos.

The full architecture reference lives in `../agent-hub-architecture.html`. You do not
need to read it to start. Read it when you want the *why* behind a decision; read these
files to actually build.

---

## The two rules that make this plan work

**1. Agents are configuration, not code.**
Every agent — org-hosted, Copilot Studio, declarative, a partner team's — is a row in
`agent_versions` holding a JSON card. The card names an *adapter kind* and carries that
adapter's config. Adding an agent is an INSERT. Adding a whole new *kind* of agent source
is one new adapter class, with no change to the database, the API, or the UI.

See `appendix-agent-config.md` for the config shapes. That file is the contract.

**2. Copilot Studio is last, and it costs one phase.**
You don't have access yet, and that's fine — nothing before Phase 6 depends on it.
When access arrives, Phase 6 is one adapter class plus config rows. **No migrations,
no UI changes, no gateway changes.** If Phase 6 turns out to need more than that,
something earlier was built wrong.

---

## Phase map

| Phase | You can demo | DB changes | Needs Copilot Studio? |
|---|---|---|---|
| **0** · [Decisions & prerequisites](00-prerequisites.md) | — | — | No |
| **1** · [Walking skeleton](01-walking-skeleton.md) | React app, signed in with Entra, reading real data from .NET + Postgres | `teams` | No |
| **2** · [Registry & catalog](02-registry-and-catalog.md) | Browse and search a real agent catalog; launch M365 declarative agents by deep link | `agents`, `agent_versions`, `agent_entitlements` | No |
| **3** · [Gateway & dynamic adapters](03-gateway-and-adapters.md) | Chat with your **org-hosted agents** inside the hub, streaming, logged, metered | `sessions`, `turns` | No |
| **4** · [Help agent](04-help-agent.md) | "Which agent should I use for X?" → ranked recommendation + one-click handoff | `routing_events`, `+ embedding` column | No |
| **5** · [Admin & self-service](05-admin-and-onboarding.md) | Another team onboards an agent without you | `agent_reviews`, `access_requests`, `eval_runs` | No |
| **6** · [Copilot Studio](06-copilot-studio.md) | Chat with a Copilot Studio agent through the same UI | **none** | Yes |

Rough sizing for a team of 3–5: Phase 1 one week, Phase 2 two weeks, Phase 3 three weeks,
Phase 4 two weeks, Phase 5 three weeks, Phase 6 one week once access lands.

---

## Where the value actually lands

Note what Phase 3 gives you: a working agent hub running your organisation's own agents,
with no Microsoft dependency at all. That is a real product you can put in front of users.

Phases 4 and 5 make it scale. Phase 6 adds a source.

This ordering is deliberate — it means **the blocked dependency is also the least
important one.** Don't let Copilot Studio access become a reason to delay.

---

## How to read a phase file

Every phase file has the same five sections:

- **Goal** — one sentence, and what you can demo at the end
- **Prerequisites** — what must be done first
- **Steps** — numbered, with real commands and code
- **Database changes** — the migration for this phase
- **Exit criteria** — a checklist. Don't start the next phase until these pass.

Code in these files is illustrative and deliberately short — enough to be unambiguous
about shape and naming, not a copy-paste codebase.

---

## Repository layout

Set this up in Phase 1 and don't reorganise it later:

```
agent-hub/
├── src/
│   ├── AgentHub.Core/                  # domain model, card schema, adapter contracts
│   ├── AgentHub.Registry/              # .NET 10 minimal API — catalog CRUD
│   ├── AgentHub.Gateway/               # .NET 10 minimal API — invoke & stream  (Phase 3)
│   ├── AgentHub.Adapters.Http/         # generic HTTP / OpenAI-compatible        (Phase 3)
│   ├── AgentHub.Adapters.Mcp/          # MCP servers                            (Phase 3)
│   ├── AgentHub.Adapters.CopilotStudio/#                                        (Phase 6)
│   └── web/                            # React + TypeScript + Vite
├── db/                                 # EF Core migrations
├── docs/                               # these files
└── tests/
```

`AgentHub.Core` must not reference any adapter project. Adapters reference Core.
That dependency direction is what keeps Phase 6 cheap.
