# Prompt 03: Nucleus Agent Integration (sync, mapping, launch URL)

## Role
You are a senior .NET engineer working in the existing Agent Hub backend (built per prompt-01) and React UI (built per prompt-02). Implement the Nucleus in-house LLM platform as a new agent source. Follow AGENTS.md. Make minimal, additive changes.

## Goal
1. Call the Nucleus "list agents" API with a bearer token from configuration.
2. Map every Nucleus agent to our Agent Card JSON.
3. Store mapped cards as `seed/agents/nucleus-{guid}.json` for now. Postgres comes later, behind an interface.
4. Reload the catalog so `/v1/agents` returns Nucleus agents to the UI.
5. Give each Nucleus agent a launch URL:
   `{Nucleus:EnvironmentUri}/{Nucleus:LaunchPath}?chatbotId={agentId}&orgId={organisationId}`
   The default `LaunchPath` is `talk-2-abs/app/start`.

## Ground rules
- Reuse the existing conventions: `JsonOpts.Default` (snake_case) for ALL JSON, keyed adapters resolved by `endpoint.adapter`, `IAgentCatalogRepository`, ProblemDetails errors.
- `endpoint` must never appear in any API response.
- Never log or return the bearer token.
- The snippets below use the namespace `AgentHub.*`. Change it to the project's root namespace.
- Where a snippet uses placeholder type names (`LaunchResult`, `LaunchContext`), use the EXACT `ILaunchableAdapter` signature and launch result type that the existing Copilot/M365 deep-link adapter uses. Do not change that interface.
- Do not modify existing seed cards or existing adapters.

## Nucleus source schema (GET {BaseUrl}/{AgentsPath})
```json
{
  "agentId": "guid string",
  "agentType": "string",
  "agentName": "string",
  "agentDescription": "string",
  "organisationId": "string",
  "dataConfidentiality": "string",
  "cidallowed": true,
  "agentDependencies": [],
  "mcpServerDependencies": [{ "id": "string" }]
}
```
The response may be a bare array, or wrapped in `agents`, `data`, `items`, `value` or `results`. Support both.

## Mapping rules
| Nucleus | Agent Card | Rule |
|---|---|---|
| agentId | `id` = `nucleus-{guid:D}`, `endpoint.nucleus_agent_id` | Must be a GUID, otherwise skip the record |
| agentName | `name` | Required, otherwise skip |
| agentDescription | `routing.summary` | If empty, use `"{name} (Nucleus agent)"` |
| agentType | `routing.keywords` (+ `"nucleus"`), `endpoint.nucleus_agent_type` | |
| organisationId | `endpoint.organisation_id` | Required, otherwise skip. Used as `orgId` in the launch URL |
| dataConfidentiality | `data.classification` (normalised lower_snake), `access.visibility` | Mapped through config. UNKNOWN becomes `restricted` |
| cidallowed | `data.cid_allowed` | If missing, use `false` |
| agentDependencies[] | `dependencies.agents[]` | Items may be strings or `{agentId|id}`. GUIDs become `nucleus-{guid}`. Drop self-references and duplicates |
| mcpServerDependencies[].id | `dependencies.mcp_servers[]` | Drop empty values and duplicates |
| (none) | version, owner, access.entitlement_group/requestable/approval, interaction | From `Nucleus:Defaults` |
| (none) | `published_at` | Keep the existing card's date if it exists, otherwise today (UTC) |

Interaction: `tier = A`, `invocable = false` (in-hub chat comes with the Phase 2 gateway), `streaming`/`embeddable` from Defaults.

---

## Step 1: Model changes (additive only)

`Models/Cards/Enums.cs`: add `NucleusAgent` to `AgentSource`. It serialises as `nucleus_agent`.

`Models/Cards/AgentCard.cs`:
```csharp
// add to AgentCard
public DataPolicy? Data { get; init; }
public Dependencies? Dependencies { get; init; }

public sealed record DataPolicy
{
    public required string Classification { get; init; }
    public bool CidAllowed { get; init; }
}

public sealed record Dependencies
{
    public IReadOnlyList<string> Agents { get; init; } = [];
    public IReadOnlyList<string> McpServers { get; init; } = [];
}

// add to AgentEndpoint (if Surface or other non-Adapter fields are `required`, make them nullable)
public string? NucleusAgentId { get; init; }
public string? NucleusAgentType { get; init; }
public string? OrganisationId { get; init; }
```

`Infrastructure/JsonOpts.cs`:
```csharp
public static readonly JsonSerializerOptions Indented = new(Default) { WriteIndented = true };
```

## Step 2: Options — `Integrations/Nucleus/NucleusOptions.cs`
```csharp
namespace AgentHub.Integrations.Nucleus;

public sealed class NucleusOptions
{
    public const string Section = "Nucleus";

    public bool Enabled { get; set; }
    public string BaseUrl { get; set; } = "";              // agents API host
    public string AgentsPath { get; set; } = "api/v1/agents";
    public string EnvironmentUri { get; set; } = "";       // chat UI host used for launch URLs
    public string LaunchPath { get; set; } = "talk-2-abs/app/start";
    public string BearerToken { get; set; } = "";          // TEMPORARY until the auth flow exists
    public int TimeoutSeconds { get; set; } = 30;
    public bool SyncOnStartup { get; set; } = true;
    public int SyncIntervalMinutes { get; set; }
    public bool PruneRemoved { get; set; } = true;
    public Dictionary<string, string> VisibilityByConfidentiality { get; set; } = [];
    public NucleusCardDefaults Defaults { get; set; } = new();
}

public sealed class NucleusCardDefaults
{
    public string Version { get; set; } = "1.0.0";
    public string OwnerTeam { get; set; } = "Nucleus Platform";
    public string OwnerContact { get; set; } = "";
    public string StewardUpn { get; set; } = "";
    public string Escalation { get; set; } = "";
    public string EntitlementGroupTemplate { get; set; } = "SG-AGENT-NUCLEUS-{agentId}";
    public bool Requestable { get; set; } = true;
    public string Approval { get; set; } = "manager+owner";
    public bool Streaming { get; set; }
    public bool Embeddable { get; set; } = true;
}
```

## Step 3: DTO — `Integrations/Nucleus/NucleusAgentDto.cs`
`[JsonPropertyName]` overrides the snake_case policy, so `JsonOpts.Default` still works.
```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgentHub.Integrations.Nucleus;

public sealed record NucleusAgentDto
{
    [JsonPropertyName("agentId")] public string? AgentId { get; init; }
    [JsonPropertyName("agentType")] public string? AgentType { get; init; }
    [JsonPropertyName("agentName")] public string? AgentName { get; init; }
    [JsonPropertyName("agentDescription")] public string? AgentDescription { get; init; }
    [JsonPropertyName("organisationId")] public string? OrganisationId { get; init; }
    [JsonPropertyName("dataConfidentiality")] public string? DataConfidentiality { get; init; }
    [JsonPropertyName("cidallowed")] public bool? CidAllowed { get; init; }
    [JsonPropertyName("agentDependencies")] public List<JsonElement>? AgentDependencies { get; init; }
    [JsonPropertyName("mcpServerDependencies")] public List<NucleusMcpServerRef>? McpServerDependencies { get; init; }
}

public sealed record NucleusMcpServerRef
{
    [JsonPropertyName("id")] public string? Id { get; init; }
}
```

## Step 4: Auth (temporary static token) — `Integrations/Nucleus/NucleusAuth.cs`
```csharp
using System.Net.Http.Headers;
using Microsoft.Extensions.Options;

namespace AgentHub.Integrations.Nucleus;

public interface INucleusTokenProvider
{
    ValueTask<string> GetTokenAsync(CancellationToken ct);
}

// Replace this registration when the real auth flow (client credentials / OBO) is ready.
public sealed class StaticNucleusTokenProvider(IOptionsMonitor<NucleusOptions> options) : INucleusTokenProvider
{
    public ValueTask<string> GetTokenAsync(CancellationToken ct)
    {
        var token = options.CurrentValue.BearerToken.Trim();
        if (token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) token = token[7..].Trim();
        if (token.Length == 0) throw new NucleusApiException(null, "Nucleus:BearerToken is not configured.");
        return ValueTask.FromResult(token);
    }
}

public sealed class NucleusBearerTokenHandler(INucleusTokenProvider tokens) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await tokens.GetTokenAsync(ct));
        return await base.SendAsync(request, ct);
    }
}
```

## Step 5: HTTP client — `Integrations/Nucleus/NucleusAgentClient.cs`
```csharp
using System.Net;
using System.Text.Json;
using AgentHub.Infrastructure;
using Microsoft.Extensions.Options;

namespace AgentHub.Integrations.Nucleus;

public interface INucleusAgentClient
{
    Task<IReadOnlyList<NucleusAgentDto>> GetAgentsAsync(CancellationToken ct);
}

public sealed class NucleusApiException(int? statusCode, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public int? StatusCode { get; } = statusCode;
}

public sealed class NucleusAgentClient(HttpClient http, IOptions<NucleusOptions> options) : INucleusAgentClient
{
    static readonly string[] Wrappers = ["agents", "data", "items", "value", "results"];

    public async Task<IReadOnlyList<NucleusAgentDto>> GetAgentsAsync(CancellationToken ct)
    {
        var path = options.Value.AgentsPath.TrimStart('/');
        HttpResponseMessage response;
        try
        {
            response = await http.GetAsync(path, HttpCompletionOption.ResponseHeadersRead, ct);
        }
        catch (TaskCanceledException ex) when (!ct.IsCancellationRequested)
        {
            throw new NucleusApiException(null, $"Nucleus did not respond within {http.Timeout.TotalSeconds:0}s.", ex);
        }
        catch (HttpRequestException ex)
        {
            throw new NucleusApiException(null, $"Could not reach Nucleus: {ex.Message}", ex);
        }

        using (response)
        {
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new NucleusApiException((int)response.StatusCode,
                    "Nucleus rejected the bearer token. Check Nucleus:BearerToken; it may have expired.");
            if (!response.IsSuccessStatusCode)
                throw new NucleusApiException((int)response.StatusCode,
                    $"Nucleus returned {(int)response.StatusCode} for GET {path}.");

            await using var stream = await response.Content.ReadAsStreamAsync(ct);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);
            var array = FindArray(doc.RootElement)
                ?? throw new NucleusApiException(200, "Nucleus response contained no agent array.");
            return array.Deserialize<List<NucleusAgentDto>>(JsonOpts.Default) ?? [];
        }
    }

    static JsonElement? FindArray(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.Array) return root;
        if (root.ValueKind != JsonValueKind.Object) return null;
        foreach (var name in Wrappers)
            if (root.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.Array) return p;
        return null;
    }
}
```

## Step 6: Mapper — `Integrations/Nucleus/NucleusAgentMapper.cs`
```csharp
using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using AgentHub.Adapters;
using AgentHub.Models.Cards;
using Microsoft.Extensions.Options;

namespace AgentHub.Integrations.Nucleus;

public sealed record MappingFailure(string? AgentId, string Reason);
public sealed record MappingResult(IReadOnlyList<AgentCard> Cards, IReadOnlyList<MappingFailure> Failures);

public sealed class NucleusAgentMapper
{
    public const string IdPrefix = "nucleus-";

    readonly NucleusCardDefaults _defaults;
    readonly Dictionary<string, Visibility> _visibility = new(StringComparer.OrdinalIgnoreCase);
    readonly TimeProvider _time;

    public NucleusAgentMapper(IOptions<NucleusOptions> options, TimeProvider time)
    {
        _defaults = options.Value.Defaults;
        _time = time;
        foreach (var (key, value) in options.Value.VisibilityByConfidentiality)
        {
            if (!Enum.TryParse<Visibility>(value, ignoreCase: true, out var vis))
                throw new InvalidOperationException(
                    $"Nucleus:VisibilityByConfidentiality:{key} = '{value}' is invalid. Valid values: org, department, restricted.");
            _visibility[Normalise(key)] = vis;
        }
    }

    public static string ToCardId(Guid agentId) => IdPrefix + agentId.ToString("D");
    public static string? TryCardId(string? agentId) => Guid.TryParse(agentId, out var g) ? ToCardId(g) : null;

    public MappingResult MapAll(IReadOnlyList<NucleusAgentDto> agents, IReadOnlyDictionary<string, DateOnly> knownPublishedAt)
    {
        var cards = new List<AgentCard>();
        var failures = new List<MappingFailure>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var src in agents)
        {
            var id = TryCardId(src.AgentId);
            DateOnly? publishedAt = id is not null && knownPublishedAt.TryGetValue(id, out var p) ? p : null;

            if (!TryMap(src, publishedAt, out var card, out var error)) failures.Add(new(src.AgentId, error));
            else if (!seen.Add(card.Id)) failures.Add(new(src.AgentId, "Duplicate agentId; first occurrence kept."));
            else cards.Add(card);
        }
        return new(cards, failures);
    }

    public bool TryMap(NucleusAgentDto src, DateOnly? publishedAt,
        [NotNullWhen(true)] out AgentCard? card, [NotNullWhen(false)] out string? error)
    {
        card = null;
        if (!Guid.TryParse(src.AgentId, out var guid)) { error = $"agentId '{src.AgentId}' is not a GUID."; return false; }

        var name = src.AgentName?.Trim();
        if (string.IsNullOrEmpty(name)) { error = "agentName is required."; return false; }

        var orgId = src.OrganisationId?.Trim();
        if (string.IsNullOrEmpty(orgId)) { error = "organisationId is required."; return false; }

        var id = ToCardId(guid);
        var classification = string.IsNullOrWhiteSpace(src.DataConfidentiality) ? "unclassified" : Normalise(src.DataConfidentiality);
        var visibility = _visibility.TryGetValue(classification, out var v) ? v : Visibility.Restricted;
        var summary = string.IsNullOrWhiteSpace(src.AgentDescription) ? $"{name} (Nucleus agent)" : src.AgentDescription.Trim();

        string[] keywords = [.. new[] { src.AgentType, "nucleus" }
            .Where(k => !string.IsNullOrWhiteSpace(k)).Select(k => k!.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)];

        string[] agentDeps = [.. (src.AgentDependencies ?? [])
            .Select(DependencyId).Where(d => !string.IsNullOrWhiteSpace(d))
            .Select(d => TryCardId(d) ?? d!.Trim()).Where(d => d != id)
            .Distinct(StringComparer.Ordinal)];

        string[] mcpDeps = [.. (src.McpServerDependencies ?? [])
            .Select(m => m.Id?.Trim()).Where(m => !string.IsNullOrEmpty(m)).Select(m => m!)
            .Distinct(StringComparer.Ordinal)];

        card = new AgentCard
        {
            Id = id,
            Name = name,
            Version = _defaults.Version,
            Source = AgentSource.NucleusAgent,
            Interaction = new Interaction
            {
                Tier = Tier.A, Invocable = false, // set to true when the Phase 2 gateway ships
                Streaming = _defaults.Streaming, Embeddable = _defaults.Embeddable
            },
            Owner = new Owner
            {
                Team = _defaults.OwnerTeam, Contact = _defaults.OwnerContact,
                StewardUpn = _defaults.StewardUpn, Escalation = _defaults.Escalation
            },
            Routing = new Routing
            {
                Summary = summary, UseFor = [], DoNotUseFor = [], Keywords = [.. keywords],
                Audience = [], Related = [], ExamplePrompts = []
            },
            Access = new Access
            {
                Visibility = visibility,
                EntitlementGroup = _defaults.EntitlementGroupTemplate.Replace("{agentId}", guid.ToString("D")),
                Requestable = _defaults.Requestable,
                Approval = _defaults.Approval
            },
            Data = new DataPolicy { Classification = classification, CidAllowed = src.CidAllowed ?? false },
            Dependencies = new Dependencies { Agents = agentDeps, McpServers = mcpDeps },
            Endpoint = new AgentEndpoint
            {
                Adapter = NucleusAgentAdapter.AdapterKind,
                NucleusAgentId = guid.ToString("D"),
                NucleusAgentType = src.AgentType?.Trim(),
                OrganisationId = orgId
            },
            PublishedAt = publishedAt ?? DateOnly.FromDateTime(_time.GetUtcNow().UtcDateTime)
        };
        error = null;
        return true;
    }

    static string? DependencyId(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.String => e.GetString(),
        JsonValueKind.Object when (e.TryGetProperty("agentId", out var a) || e.TryGetProperty("id", out a))
                                  && a.ValueKind == JsonValueKind.String => a.GetString(),
        _ => null
    };

    static string Normalise(string s) => s.Trim().ToLowerInvariant().Replace(' ', '_').Replace('-', '_');
}
```
If `PublishedAt` is a `string` in the existing record, use `.ToString("yyyy-MM-dd")`.

## Step 7: Launch URL builder — `Integrations/Nucleus/NucleusLaunchUrl.cs`
```csharp
namespace AgentHub.Integrations.Nucleus;

public static class NucleusLaunchUrl
{
    // {environmentUri}/{launchPath}?chatbotId={guid}&orgId={organisationId}
    public static Uri Build(string environmentUri, string launchPath, Guid chatbotId, string orgId)
    {
        if (!Uri.TryCreate(environmentUri.TrimEnd('/') + "/", UriKind.Absolute, out var baseUri)
            || baseUri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Nucleus:EnvironmentUri must be an absolute https URL.");
        if (string.IsNullOrWhiteSpace(orgId))
            throw new ArgumentException("orgId is required.", nameof(orgId));

        var target = new Uri(baseUri, launchPath.Trim('/'));   // keeps any base path, e.g. https://host/nucleus/
        return new UriBuilder(target)
        {
            Query = $"chatbotId={chatbotId:D}&orgId={Uri.EscapeDataString(orgId.Trim())}"
        }.Uri;
    }
}
```

## Step 8: Adapter — `Adapters/NucleusAgentAdapter.cs`
It implements `ILaunchableAdapter` and builds the URL each time it's requested, from the current options. Changing environments doesn't require a re-sync.
```csharp
using AgentHub.Integrations.Nucleus;
using AgentHub.Models.Cards;
using Microsoft.Extensions.Options;

namespace AgentHub.Adapters;

public sealed class NucleusAgentAdapter(IOptionsMonitor<NucleusOptions> options) : ILaunchableAdapter
{
    public const string AdapterKind = "nucleus.agent";
    public string Kind => AdapterKind;

    public IReadOnlyList<string> ValidateConfig(AgentEndpoint endpoint)
    {
        var errors = new List<string>();
        if (!Guid.TryParse(endpoint.NucleusAgentId, out _))
            errors.Add("endpoint.nucleus_agent_id is required and must be a GUID.");
        if (string.IsNullOrWhiteSpace(endpoint.OrganisationId))
            errors.Add("endpoint.organisation_id is required.");
        return errors;
    }

    // MATCH the existing ILaunchableAdapter signature/return type (LaunchResult/LaunchContext are placeholders).
    public LaunchResult BuildLaunch(AgentEndpoint endpoint, LaunchContext? context)
    {
        var o = options.CurrentValue;
        var url = NucleusLaunchUrl.Build(o.EnvironmentUri, o.LaunchPath,
            Guid.Parse(endpoint.NucleusAgentId!), endpoint.OrganisationId!);

        // Populate the result exactly like the existing deep-link adapter does
        // (url + open in new tab; no fallback needed).
        return new LaunchResult { Url = url.ToString() /*, Target = new tab, per existing convention */ };
    }
}
```
If the codebase has a launch-host allowlist (for example `Launch:AllowedHosts`), add the `EnvironmentUri` host to it in config.

## Step 9: Writer (temporary JSON storage) — `Repositories/JsonFileAgentCardWriter.cs`
```csharp
using System.Text.Json;
using AgentHub.Infrastructure;
using AgentHub.Models.Cards;

namespace AgentHub.Repositories;

public sealed record CardWriteResult(int Written, int Unchanged, int Removed);

// Replace with a Postgres implementation later; nothing else changes.
public interface IAgentCardWriter
{
    Task<CardWriteResult> WriteAsync(IReadOnlyList<AgentCard> cards, string managedPrefix,
        IReadOnlySet<string>? pruneKeep, CancellationToken ct);
}

public sealed class JsonFileAgentCardWriter(IConfiguration config, IHostEnvironment env,
    ILogger<JsonFileAgentCardWriter> log) : IAgentCardWriter
{
    readonly string _dir = Path.Combine(env.ContentRootPath, config["Catalog:SeedPath"] ?? "seed/agents");

    public async Task<CardWriteResult> WriteAsync(IReadOnlyList<AgentCard> cards, string managedPrefix,
        IReadOnlySet<string>? pruneKeep, CancellationToken ct)
    {
        Directory.CreateDirectory(_dir);
        int written = 0, unchanged = 0, removed = 0;

        foreach (var card in cards)
        {
            if (!card.Id.StartsWith(managedPrefix, StringComparison.Ordinal))
                throw new InvalidOperationException($"Card '{card.Id}' is outside managed prefix '{managedPrefix}'.");

            var path = Path.Combine(_dir, card.Id + ".json");
            var json = JsonSerializer.Serialize(card, JsonOpts.Indented);
            if (File.Exists(path) && await File.ReadAllTextAsync(path, ct) == json) { unchanged++; continue; }

            var tmp = Path.Combine(_dir, $".{card.Id}.{Guid.NewGuid():N}.tmp");  // atomic write
            await File.WriteAllTextAsync(tmp, json, ct);
            File.Move(tmp, path, overwrite: true);
            written++;
        }

        if (pruneKeep is not null)
        {
            var live = cards.Select(c => c.Id).Concat(pruneKeep).ToHashSet(StringComparer.Ordinal);
            foreach (var file in Directory.GetFiles(_dir, managedPrefix + "*.json"))
            {
                var id = Path.GetFileNameWithoutExtension(file);
                if (live.Contains(id)) continue;
                File.Delete(file);
                removed++;
                log.LogInformation("Removed {CardId}: no longer returned by source.", id);
            }
        }
        return new(written, unchanged, removed);
    }
}
```

## Step 10: Sync service + background job — `Integrations/Nucleus/NucleusSyncService.cs`
```csharp
using AgentHub.Models.Cards;
using AgentHub.Repositories;
using Microsoft.Extensions.Options;

namespace AgentHub.Integrations.Nucleus;

public sealed class NucleusSyncInProgressException() : Exception("A Nucleus sync is already running.");

public sealed record SyncPreviewItem(string Id, string Name, Visibility Visibility, string Classification,
    bool CidAllowed, string? LaunchUrl);

public sealed record NucleusSyncResult(int Fetched, int Mapped, int Written, int Unchanged, int Removed, bool DryRun,
    IReadOnlyList<MappingFailure> Skipped, IReadOnlyList<SyncPreviewItem> Preview);

public sealed class NucleusSyncService(
    INucleusAgentClient client, NucleusAgentMapper mapper, IAgentCardWriter writer,
    IAgentCatalogRepository repository, IOptions<NucleusOptions> options, ILogger<NucleusSyncService> log)
{
    static readonly SemaphoreSlim Gate = new(1, 1);

    public async Task<NucleusSyncResult> SyncAsync(bool dryRun, CancellationToken ct)
    {
        if (!await Gate.WaitAsync(0, ct)) throw new NucleusSyncInProgressException();
        try
        {
            var o = options.Value;
            var agents = await client.GetAgentsAsync(ct);

            var publishedAt = new Dictionary<string, DateOnly>(StringComparer.Ordinal);
            foreach (var a in agents)
                if (NucleusAgentMapper.TryCardId(a.AgentId) is { } id && await repository.GetAsync(id, ct) is { } existing)
                    publishedAt[id] = existing.PublishedAt;

            var result = mapper.MapAll(agents, publishedAt);
            foreach (var f in result.Failures)
                log.LogWarning("Skipped Nucleus agent {AgentId}: {Reason}", f.AgentId ?? "<null>", f.Reason);

            var preview = result.Cards.Select(c => new SyncPreviewItem(
                c.Id, c.Name, c.Access.Visibility, c.Data!.Classification, c.Data.CidAllowed,
                TryLaunchUrl(o, c.Endpoint))).ToList();

            if (dryRun) return new(agents.Count, result.Cards.Count, 0, 0, 0, true, result.Failures, preview);

            IReadOnlySet<string>? pruneKeep = null;
            if (o.PruneRemoved && agents.Count > 0)
                pruneKeep = result.Failures.Select(f => NucleusAgentMapper.TryCardId(f.AgentId))
                    .OfType<string>().ToHashSet(StringComparer.Ordinal);   // failed records keep their last good file
            else if (agents.Count == 0)
                log.LogWarning("Nucleus returned zero agents; skipping prune to protect the catalog.");

            var write = await writer.WriteAsync(result.Cards, NucleusAgentMapper.IdPrefix, pruneKeep, ct);
            if (write.Written + write.Removed > 0) await repository.ReloadAsync(ct);

            log.LogInformation("Nucleus sync: fetched {F}, mapped {M}, written {W}, unchanged {U}, removed {R}, skipped {S}.",
                agents.Count, result.Cards.Count, write.Written, write.Unchanged, write.Removed, result.Failures.Count);

            return new(agents.Count, result.Cards.Count, write.Written, write.Unchanged, write.Removed, false, result.Failures, preview);
        }
        finally { Gate.Release(); }
    }

    static string? TryLaunchUrl(NucleusOptions o, AgentEndpoint e)
    {
        try { return NucleusLaunchUrl.Build(o.EnvironmentUri, o.LaunchPath, Guid.Parse(e.NucleusAgentId!), e.OrganisationId!).ToString(); }
        catch { return null; }
    }
}

public sealed class NucleusSyncHostedService(IServiceScopeFactory scopes, IOptions<NucleusOptions> options,
    ILogger<NucleusSyncHostedService> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var o = options.Value;
        if (!o.Enabled) return;
        if (o.SyncOnStartup) await RunOnceAsync(stoppingToken);
        if (o.SyncIntervalMinutes <= 0) return;

        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(o.SyncIntervalMinutes));
        while (await timer.WaitForNextTickAsync(stoppingToken)) await RunOnceAsync(stoppingToken);
    }

    async Task RunOnceAsync(CancellationToken ct)
    {
        try
        {
            await using var scope = scopes.CreateAsyncScope();
            await scope.ServiceProvider.GetRequiredService<NucleusSyncService>().SyncAsync(false, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (NucleusSyncInProgressException) { log.LogInformation("Scheduled Nucleus sync skipped: already running."); }
        catch (Exception ex) { log.LogError(ex, "Nucleus sync failed; catalog keeps the last synced cards."); }
    }
}
```

## Step 11: Admin controller — `Controllers/NucleusAdminController.cs`
```csharp
using AgentHub.Integrations.Nucleus;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace AgentHub.Controllers;

[ApiController]
[Route("v1/admin/nucleus")]
public sealed class NucleusAdminController(NucleusSyncService sync, IOptions<NucleusOptions> options) : ControllerBase
{
    [HttpPost("sync")]
    public async Task<IActionResult> Sync([FromQuery(Name = "dry_run")] bool dryRun, CancellationToken ct)
    {
        if (!options.Value.Enabled)
            return Problem(statusCode: 503, title: "Nucleus integration disabled", detail: "Set Nucleus:Enabled to true.");
        try { return Ok(await sync.SyncAsync(dryRun, ct)); }
        catch (NucleusSyncInProgressException ex) { return Problem(statusCode: 409, title: "Sync already running", detail: ex.Message); }
        catch (NucleusApiException ex) { return Problem(statusCode: 502, title: "Nucleus agents API call failed", detail: ex.Message); }
    }
}
```

## Step 12: AgentsController changes
- Detail endpoint: build `launch` only if the adapter is an `ILaunchableAdapter`, otherwise return `null`. Make `AgentDetailDto.Launch` nullable.
  ```csharp
  var adapter = resolver.Resolve(card.Endpoint.Adapter);
  LaunchDto? launch = adapter is ILaunchableAdapter l ? ToLaunchDto(l.BuildLaunch(card.Endpoint, null), card.Endpoint.Adapter) : null;
  ```
  Nucleus cards now return a launch URL here.
- Add `Data` (and `Dependencies` on the detail DTO) to the DTOs. Put `Data` on the list item too, for badges. Never expose `endpoint`.
- `/v1/agents/{id}/launch`: no code change. Nucleus now returns 200 with the URL. Non-launchable adapters still return 409.

## Step 13: Program.cs
```csharp
builder.Services.AddOptions<NucleusOptions>()
    .Bind(builder.Configuration.GetSection(NucleusOptions.Section))
    .Validate(o => !o.Enabled || IsHttps(o.BaseUrl), "Nucleus:BaseUrl must be an absolute https URL.")
    .Validate(o => !o.Enabled || IsHttps(o.EnvironmentUri), "Nucleus:EnvironmentUri must be an absolute https URL.")
    .Validate(o => !string.IsNullOrWhiteSpace(o.LaunchPath), "Nucleus:LaunchPath is required.")
    .Validate(o => !o.Enabled || !string.IsNullOrWhiteSpace(o.BearerToken), "Nucleus:BearerToken is required until the auth flow exists.")
    .Validate(o => o.TimeoutSeconds is > 0 and <= 300, "Nucleus:TimeoutSeconds must be 1-300.")
    .ValidateOnStart();

static bool IsHttps(string? s) => Uri.TryCreate(s, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps;

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<INucleusTokenProvider, StaticNucleusTokenProvider>();
builder.Services.AddTransient<NucleusBearerTokenHandler>();
builder.Services.AddHttpClient<INucleusAgentClient, NucleusAgentClient>((sp, http) =>
    {
        var o = sp.GetRequiredService<IOptions<NucleusOptions>>().Value;
        if (!string.IsNullOrWhiteSpace(o.BaseUrl)) http.BaseAddress = new Uri(o.BaseUrl.TrimEnd('/') + "/");
        http.Timeout = TimeSpan.FromSeconds(o.TimeoutSeconds);
        http.DefaultRequestHeaders.Accept.Add(new("application/json"));
    })
    .AddHttpMessageHandler<NucleusBearerTokenHandler>();

builder.Services.AddSingleton<NucleusAgentMapper>();
builder.Services.AddSingleton<IAgentCardWriter, JsonFileAgentCardWriter>();
builder.Services.AddScoped<NucleusSyncService>();
builder.Services.AddHostedService<NucleusSyncHostedService>();
// Register the same way as existing adapters, BEFORE the catalog repository loads:
builder.Services.AddKeyedSingleton<IAgentAdapter, NucleusAgentAdapter>(NucleusAgentAdapter.AdapterKind);
```
Put the local function `IsHttps` at the bottom of Program.cs if top-level statements require it.

## Step 14: appsettings.json
```json
"Nucleus": {
  "Enabled": true,
  "BaseUrl": "https://nucleus-api.internal.example",
  "AgentsPath": "api/v1/agents",
  "EnvironmentUri": "https://nucleus.internal.example",
  "LaunchPath": "talk-2-abs/app/start",
  "BearerToken": "REPLACE_WITH_TEMPORARY_TOKEN",
  "TimeoutSeconds": 30,
  "SyncOnStartup": true,
  "SyncIntervalMinutes": 0,
  "PruneRemoved": true,
  "VisibilityByConfidentiality": {
    "public": "org",
    "internal": "org",
    "confidential": "department",
    "strictly_confidential": "restricted",
    "restricted": "restricted"
  },
  "Defaults": {
    "Version": "1.0.0",
    "OwnerTeam": "Nucleus Platform",
    "OwnerContact": "nucleus-platform@org.example",
    "StewardUpn": "nucleus.steward@org.example",
    "Escalation": "nucleus-oncall",
    "EntitlementGroupTemplate": "SG-AGENT-NUCLEUS-{agentId}",
    "Requestable": true,
    "Approval": "manager+owner",
    "Streaming": false,
    "Embeddable": true
  }
}
```
Override `EnvironmentUri` and `BaseUrl` per environment in `appsettings.{Environment}.json`. Do NOT commit a real token. Use `dotnet user-secrets set "Nucleus:BearerToken" "<token>"` or the env var `Nucleus__BearerToken`.

## Step 15: UI (React, per prompt-02)
- `src/types/agent.ts`: add `'nucleus_agent'` to `AgentSource`; add `interface DataPolicy { classification: string; cid_allowed: boolean }`; add `data?: DataPolicy` to the card types; make the detail `launch` nullable (`LaunchInfo | null`).
- AgentCard / detail: if `launch` is present, show the primary red "Launch" button and open `launch.url` in a new tab (`window.open(url, '_blank', 'noopener,noreferrer')`). If `launch === null`, show a disabled "Chat Now" button with the tooltip "Coming soon".
- When `data.cid_allowed === false`, show a "No client data" `<Badge>`. Show `data.classification` as a neutral badge.
- Add a "Nucleus" option to the source filter.
- Mock data: add 2 Nucleus agents (one with `cid_allowed: true`, one with `false`) with launch URLs in the new format.

## Step 16: Tests (xUnit)
`NucleusLaunchUrlTests`:
- `https://host` + `talk-2-abs/app/start` + guid + `ORG1` gives `https://host/talk-2-abs/app/start?chatbotId={guid}&orgId=ORG1`
- A trailing slash on EnvironmentUri and leading/trailing slashes on LaunchPath give the same result
- A base path is kept: `https://host/nucleus` gives `https://host/nucleus/talk-2-abs/app/start?...`
- `orgId = "UBS Ops & Risk"` is escaped (`UBS%20Ops%20%26%20Risk`)
- An http or empty EnvironmentUri throws

`NucleusAgentMapperTests`:
- A valid record maps every field in the mapping table
- A non-GUID agentId, missing name or missing organisationId goes to `Failures`
- An unknown confidentiality value becomes `Visibility.Restricted`; a null `cidallowed` becomes `false`
- Dependencies work as strings and as objects; self-references and duplicates are removed
- An existing `published_at` is kept; a duplicate agentId keeps the first occurrence

`NucleusAgentAdapterTests`: `BuildLaunch` returns the expected URL; `ValidateConfig` reports a bad GUID or missing org.

`NucleusAgentClientTests` (fake `HttpMessageHandler`): bare array, wrapped `{ "agents": [...] }`, 401 gives a `NucleusApiException` with the token message, and the Bearer header is sent.

## Acceptance checks
```bash
dotnet build && dotnet test
curl -X POST "https://localhost:5001/v1/admin/nucleus/sync?dry_run=true"   # preview incl. launch_url, writes nothing
curl -X POST "https://localhost:5001/v1/admin/nucleus/sync"                # writes seed/agents/nucleus-*.json, reloads
curl "https://localhost:5001/v1/agents?source=nucleus_agent"
curl "https://localhost:5001/v1/agents/nucleus-<guid>/launch"              # 200, url = {EnvironmentUri}/talk-2-abs/app/start?chatbotId=<guid>&orgId=<org>
```
Expected seed file `seed/agents/nucleus-<guid>.json` contains `"source": "nucleus_agent"` and `"endpoint": { "adapter": "nucleus.agent", "nucleus_agent_id": "<guid>", "nucleus_agent_type": "...", "organisation_id": "..." }`. It has no stored URL; the URL is built each time it's requested.

## Out of scope
Postgres writer, real auth flow, in-hub chat (Phase 2 gateway), pagination (add only if the Nucleus API paginates).

## Finish
Reply with: the files changed or added, the test results, and any `// ASSUMPTION:` you made. No other explanation.