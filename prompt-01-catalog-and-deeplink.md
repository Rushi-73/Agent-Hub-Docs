# Prompt 01 — Agent catalog API with deep-link info for the UI

Build on the existing ASP.NET Core Web API project. `Controllers/` and `Models/` already exist
and are empty — fill them, and add the other folders below. Target `net10.0`, `Nullable` on.

**Out of scope for this prompt** (later tasks): auth, JSON Schema validation, telemetry,
database, agent invocation/streaming. No EF Core, no Npgsql. If a step below seems to need one,
stop and say so.

---

## 1. Folder layout

```
Controllers/
  HealthController.cs
  AgentsController.cs
  FacetsController.cs
  AdminController.cs
Models/
  Cards/      AgentCard.cs, AgentEndpoint.cs, Interaction.cs, Owner.cs,
              Routing.cs, Access.cs, Enums.cs
  Dtos/       AgentListItemDto.cs, AgentDetailDto.cs, LaunchDto.cs, FacetsDto.cs
  Queries/    CatalogQuery.cs
Adapters/
  IAgentAdapter.cs, ILaunchableAdapter.cs, LaunchTarget.cs, AdapterResolver.cs
  DeepLinkOptions.cs, DeepLinkUrlBuilder.cs
  CopilotStudioDeepLinkAdapter.cs
  M365DeclarativeDeepLinkAdapter.cs
Repositories/
  IAgentCatalogRepository.cs, JsonFileAgentCatalogRepository.cs
Infrastructure/
  Json/JsonOpts.cs
  Exceptions/UnknownAdapterException.cs
seed/agents/*.json
```

## 2. The card model

Model this JSON as immutable `sealed record` types in `Models/Cards/`. Required members use
`required`. This is the exact shape on disk:

```json
{
  "id": "fin-invoice-triage",
  "name": "Invoice Triage Assistant",
  "version": "1.0.0",
  "source": "copilot_studio",

  "interaction": { "tier": "A", "invocable": true, "streaming": true, "embeddable": true },

  "owner": {
    "team": "Finance Ops Automation",
    "contact": "finops-agents@org.example",
    "steward_upn": "a.nowak@org.example",
    "escalation": "finops-oncall"
  },

  "routing": {
    "summary": "Classifies inbound supplier invoices, extracts header and line data, and explains validation failures before they reach the AP queue.",
    "use_for": [
      "Finding out why a specific invoice failed validation",
      "Pulling PO number and line items out of a scanned invoice",
      "Checking which AP policy applies to a supplier document"
    ],
    "do_not_use_for": [
      "Approving or releasing payment - use the AP approval workflow",
      "Vendor master-data changes",
      "Anything involving payroll or employee expenses"
    ],
    "keywords": ["invoice", "accounts payable", "AP", "supplier", "PO match", "three-way match"],
    "audience": ["finance", "procurement"],
    "related": ["fin-po-lookup", "fin-vendor-360"],
    "example_prompts": [
      "Why did invoice INV-10423 fail validation?",
      "Extract the PO number and line items from this invoice"
    ],
    "escalates_to": "human:ap-service-desk"
  },

  "access": {
    "visibility": "org",
    "entitlement_group": "SG-AGENT-FIN-INVOICE",
    "requestable": true,
    "approval": "manager+owner"
  },

  "endpoint": {
    "adapter": "copilot_studio.deeplink",
    "surface": "teams_chat",
    "teams_app_id": "fxxxxxxx-0xxx-4xxx-8xxx-cxxxxxxxxxxx",
    "teams_bot_id": "47345678-2134-6534-9143-65146789012",
    "stored_url": null,
    "seed_prompt_supported": true,
    "requires_license": "M365 Copilot",
    "open_in_new_tab": true,
    "environment_id": "8f21aaaa-bbbb-cccc-dddd-eeeeffff0000",
    "agent_schema_name": "cr1a2_invoiceTriage"
  },

  "published_at": "2026-09-14"
}
```

Enums (serialised snake_case): `AgentSource` = `m365_agent_builder | copilot_studio | org_hosted
| federated`; `Tier` = `A | B`; `Visibility` = `org | department | restricted`.

`Models/Cards/Enums.cs` also holds `DeepLinkSurface` = `teams_chat | teams_app_chat |
teams_install | demo_website | custom_website | m365_copilot`.

Add `Infrastructure/Json/JsonOpts.cs` with a single `static JsonSerializerOptions Default`:
`JsonNamingPolicy.SnakeCaseLower`, a `JsonStringEnumConverter` using the same policy,
`DefaultIgnoreCondition = WhenWritingNull`, case-insensitive reads. **Every** serialise and
deserialise in the solution uses it — never a bare two-arg `JsonSerializer` call.

## 3. The adapters — where the deep link is built

```csharp
public interface IAgentAdapter
{
    string Kind { get; }
    IReadOnlyList<string> ValidateConfig(AgentEndpoint endpoint);
}

public interface ILaunchableAdapter : IAgentAdapter
{
    LaunchTarget BuildLaunch(AgentEndpoint endpoint, string? seedPrompt);
}

public sealed record LaunchTarget(
    string Url,
    string Surface,
    bool OpenInNewTab,
    string? RequiresLicense,
    bool SeedPromptSupported,
    bool SeedPromptApplied,
    string? SeedPromptNote);
```

`AdapterResolver` resolves by `endpoint.adapter` from keyed DI and throws
`UnknownAdapterException(kind)` naming the adapter when the deployment has none.

### `CopilotStudioDeepLinkAdapter` — `Kind => "copilot_studio.deeplink"`

| `surface` | Requires | URL | Seed prompt |
|---|---|---|---|
| `teams_chat` | `teams_bot_id` | `TeamsChat` template | yes |
| `teams_app_chat` | `teams_app_id` | `TeamsAppChat` template | no |
| `teams_install` | `teams_app_id` | `TeamsInstall` template | no |
| `demo_website` | `stored_url` | returned verbatim | no |
| `custom_website` | `stored_url` | returned verbatim | no |

### `M365DeclarativeDeepLinkAdapter` — `Kind => "deeplink.m365"`

One surface, `m365_copilot`. Requires `stored_url` (the "Copy chat link" value from the M365
Copilot Share dialog). Returned verbatim, host-allowlisted. No seed prompt.

### URL templates live in `appsettings.json`, never in code

```json
"DeepLinks": {
  "TenantId": "00000000-0000-0000-0000-000000000000",
  "TeamsChat":          "https://teams.microsoft.com/l/chat/0/0?users=28:{botId}",
  "TeamsChatSeedParam": "message",
  "TeamsAppChat":       "https://teams.microsoft.com/l/entity/{appId}/conversations",
  "TeamsInstall":       "https://teams.microsoft.com/l/app/{appId}",
  "AllowedStoredUrlHosts": [
    "copilotstudio.microsoft.com",
    "m365.cloud.microsoft",
    "teams.microsoft.com"
  ]
}
```

Bind to `DeepLinkOptions`. Append `tenantId={TenantId}` to the two `l/entity` and `l/app`
templates when `TenantId` is set.

### Rules — put these in `DeepLinkUrlBuilder`, shared by both adapters

- URL-encode every substituted value with `Uri.EscapeDataString`.
- Seed prompt applies **only** when the surface supports it **and**
  `seed_prompt_supported == true`. Cap at 500 chars, reject control characters.
- Set `SeedPromptApplied` honestly. When it is true for `teams_chat`, set
  `SeedPromptNote = "Pre-fills the Teams compose box; the user must press Send."` —
  the `message=` parameter does not send the message.
- `stored_url` surfaces: parse the URL, require `https`, require the host to be in
  `AllowedStoredUrlHosts`. Reject in `ValidateConfig` **and** again in `BuildLaunch`.
  Without this the launch endpoint is an open redirector.
- `ValidateConfig` returns one message per problem, naming the field. An unknown `surface`
  lists the valid values.

## 4. Repository

```csharp
public interface IAgentCatalogRepository
{
    Task<IReadOnlyList<AgentCard>> ListAsync(CatalogQuery query, CancellationToken ct);
    Task<AgentCard?> GetAsync(string id, CancellationToken ct);
    Task ReloadAsync(CancellationToken ct);
}

public sealed record CatalogQuery(
    string? Search = null, AgentSource? Source = null,
    Tier? Tier = null, string? Audience = null);
```

`JsonFileAgentCatalogRepository`: on startup read every `*.json` under `Catalog:SeedPath`
(default `seed/agents`), deserialise with `JsonOpts.Default`, cache in memory.

- A file that fails to deserialise is **logged with its filename and skipped** — one bad file
  must not take down the catalog.
- A duplicate `id` across files throws at load.
- Run each card's adapter `ValidateConfig` at load; log and skip cards that fail.
- `Search` is case-insensitive substring over `name`, `routing.summary`, `routing.keywords`.
  Crude on purpose.
- All methods `async` with a `CancellationToken` even where nothing awaits — suppress the
  "async without await" warning rather than changing the signatures. This is what makes a
  database implementation a drop-in replacement for this one class later.

## 5. Endpoints

```
GET  /health                        seed file count + load errors
GET  /v1/agents                     ?search=&source=&tier=&audience=
GET  /v1/agents/{id}                404 if absent
GET  /v1/agents/{id}/launch         ?seed_prompt=
GET  /v1/facets                     distinct sources, tiers, audiences
POST /v1/admin/reload               re-reads the seed directory
```

All errors return `ProblemDetails`.

### `GET /v1/agents` — trimmed list for the catalog grid

`id`, `name`, `version`, `source`, `tier`, `routing.summary`, `routing.keywords`,
`routing.audience`, `owner.team`, `access.visibility`, `endpoint.requires_license`,
`endpoint.surface`. **Never the full `endpoint` object.**

### `GET /v1/agents/{id}` — everything the UI needs on the detail page

Full card **plus** a `launch` block, so the UI can render the button without a second call:

```json
{
  "id": "fin-invoice-triage",
  "name": "Invoice Triage Assistant",
  "version": "1.0.0",
  "source": "copilot_studio",
  "interaction": { "tier": "A", "invocable": true, "streaming": true, "embeddable": true },
  "owner": { "...": "as on the card" },
  "routing": { "...": "as on the card" },
  "access": { "...": "as on the card" },
  "published_at": "2026-09-14",

  "launch": {
    "url": "https://teams.microsoft.com/l/chat/0/0?users=28:47345678-2134-6534-9143-65146789012",
    "surface": "teams_chat",
    "adapter": "copilot_studio.deeplink",
    "open_in_new_tab": true,
    "requires_license": "M365 Copilot",
    "seed_prompt_supported": true,
    "seed_prompt_applied": false,
    "seed_prompt_note": null
  }
}
```

Expose `environment_id`, `agent_schema_name`, `teams_app_id`, `teams_bot_id` and `stored_url`
**nowhere in any response**. The UI needs the finished `url` and the metadata around it, not the
identifiers it was built from.

### `GET /v1/agents/{id}/launch?seed_prompt=...` — the one the button calls

1. Load the card. Absent → **404**.
2. Resolve the adapter. Unknown → **422**, naming the adapter.
3. Not `ILaunchableAdapter` → **409**, with a `detail` saying the agent is invoked in-hub.
4. `BuildLaunch(endpoint, seedPrompt)` → **200** with the `launch` object above.

Return the URL as JSON. **Do not 302** — a redirect makes this an open redirector if the host
allowlist is ever weakened, and the UI needs `requires_license` and `open_in_new_tab` to decide
how to open it.

## 6. Seed cards

Write five files into `seed/agents/`, named `{id}.json`, covering every branch:

| File | Adapter | Surface |
|---|---|---|
| `fin-invoice-triage.json` | `copilot_studio.deeplink` | `teams_chat` (the card above) |
| `fin-po-lookup.json` | `copilot_studio.deeplink` | `teams_app_chat` |
| `fin-vendor-360.json` | `copilot_studio.deeplink` | `demo_website` |
| `hr-policy-finder.json` | `deeplink.m365` | `m365_copilot` |
| `legal-contract-search.json` | `copilot_studio.deeplink` | `teams_install` |

Use real team names and routing text. Fill `do_not_use_for` properly on all five — the help
agent ranks on those fields later and backfilling them across 40 cards is a job nobody wants.

## 7. Done when

- `dotnet build` and `dotnet run` both succeed.
- `GET /v1/agents` returns all five cards with no `endpoint` object in the payload.
- `GET /v1/agents/fin-invoice-triage` returns the card plus a populated `launch` block.
- `GET /v1/agents/fin-invoice-triage/launch?seed_prompt=Why%20did%20INV-10423%20fail` returns a
  URL ending `&message=Why%20did%20INV-10423%20fail` with `seed_prompt_applied: true`.
- `GET /v1/agents/fin-vendor-360/launch?seed_prompt=x` returns `seed_prompt_applied: false`.
- A card whose `stored_url` host is off the allowlist is skipped at load with a logged error,
  and the other four still load.
- An unknown `surface` is rejected with a message listing the valid values.

---

## 8. Execution rules — keep token use low

Follow these. They are part of the task, not advice.

**Do not ask me anything.** Every decision is already in this document. If something is genuinely
missing, pick the obvious option, write one line at the end saying what you picked, and continue.

**Do not read files to orient yourself.** Read exactly two: the `.csproj` and `Program.cs`.
Everything else in this project is empty. Do not list directories, do not search the codebase,
do not look for existing patterns, do not fetch anything from the web.

**Do not narrate.** No plan, no running commentary, no "now I'll create X". No summary after each
file. No printing file contents back into the chat after writing them — I can open the file.
One short paragraph at the very end is all I want.

**Write each file once, complete, first try.** No stubs you come back to, no TODOs, no
placeholder bodies. Creating a file and then editing it three times costs more than thinking for
a moment first.

**Build once, at the end.** Not after each file. If it fails, fix only the reported errors —
do not re-read files that compiled fine.

**No comments, no XML doc comments, no regions.** The code is small enough to read. The only
exception: one line above the `stored_url` host check saying why it exists.

**No tests in this pass.** They come in the next prompt.

**Consolidate files** to cut tool calls. Use these groupings instead of one type per file:

| File | Holds |
|---|---|
| `Models/Cards/AgentCard.cs` | `AgentCard`, `Interaction`, `Owner`, `Routing`, `Access`, `AgentEndpoint` |
| `Models/Cards/Enums.cs` | all four enums |
| `Models/Dtos/Dtos.cs` | all DTO records |
| `Adapters/Contracts.cs` | `IAgentAdapter`, `ILaunchableAdapter`, `LaunchTarget`, `AdapterResolver`, `UnknownAdapterException` |
| `Adapters/DeepLinkUrlBuilder.cs` | `DeepLinkOptions` + `DeepLinkUrlBuilder` |
| `Adapters/CopilotStudioDeepLinkAdapter.cs` | that adapter only |
| `Adapters/M365DeclarativeDeepLinkAdapter.cs` | that adapter only |
| `Repositories/AgentCatalogRepository.cs` | `IAgentCatalogRepository`, `CatalogQuery`, `JsonFileAgentCatalogRepository` |
| `Infrastructure/JsonOpts.cs` | `JsonOpts` |
| `Controllers/AgentsController.cs` | agents + launch endpoints |
| `Controllers/MiscController.cs` | health, facets, admin reload |

That is 11 code files plus 5 seed JSON files plus `Program.cs` and `appsettings.json` edits.
**18 writes total.** If you are making more writes than that, stop and reconsider.

**Build in this order** so nothing needs rework: `Enums` → `AgentCard` → `JsonOpts` →
`Contracts` → `DeepLinkUrlBuilder` → the two adapters → `AgentCatalogRepository` → `Dtos` →
the two controllers → `Program.cs` → `appsettings.json` → the 5 seed files.

**Seed files:** write `fin-invoice-triage.json` in full. For the other four, copy that structure
and change only `id`, `name`, `source`, `owner`, `routing`, `access` and `endpoint`. Do not
compose each one from scratch.
