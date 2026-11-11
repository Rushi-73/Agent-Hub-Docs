# Phase 1 — Walking skeleton

**Goal:** a React app, signed in with Entra ID, reading real rows from a .NET 10 API
backed by Postgres, deployed and running in CI.

Nothing agent-specific. One trivial entity (`teams`) proves the whole vertical slice works.
Resist the urge to build catalog features here — the point of this phase is that every
layer is wired and deployable before any domain logic exists.

**Demo at the end:** "I log in with my work account, and the app shows a list of teams
that came out of the database."

**Prerequisites:** Phase 0 decisions recorded; Azure subscription; Entra app registrations.

---

## Steps

### 1. Create the solution

```powershell
mkdir agent-hub; cd agent-hub
dotnet new sln -n AgentHub
dotnet new classlib -o src/AgentHub.Core
dotnet new web      -o src/AgentHub.Registry
dotnet sln add src/AgentHub.Core src/AgentHub.Registry
dotnet add src/AgentHub.Registry reference src/AgentHub.Core
```

Packages on `AgentHub.Registry`:

```powershell
dotnet add src/AgentHub.Registry package Npgsql.EntityFrameworkCore.PostgreSQL
dotnet add src/AgentHub.Registry package Microsoft.EntityFrameworkCore.Design
dotnet add src/AgentHub.Registry package Microsoft.Identity.Web
dotnet add src/AgentHub.Registry package Azure.Identity
```

### 2. Postgres locally

Don't wait for a provisioned server to start coding:

```powershell
docker run --name agenthub-db -e POSTGRES_PASSWORD=devonly `
  -e POSTGRES_DB=agenthub -p 5432:5432 -d postgres:17
```

Provision Azure Database for PostgreSQL Flexible Server in parallel; switch the connection
string when it's ready. Use **Managed Identity** against Azure — never a password in config.

### 3. Domain model in Core

Keep `AgentHub.Core` free of EF and ASP.NET references. It holds types only.

```csharp
// src/AgentHub.Core/Teams/Team.cs
namespace AgentHub.Core.Teams;

public sealed class Team
{
    public Guid   Id         { get; init; }
    public string Name       { get; init; } = "";
    public string Contact    { get; init; } = "";
    public string StewardUpn { get; init; } = "";
    public string? Escalation { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
}
```

### 4. DbContext and migration

```csharp
// src/AgentHub.Registry/Data/AgentHubDb.cs
public sealed class AgentHubDb(DbContextOptions<AgentHubDb> o) : DbContext(o)
{
    public DbSet<Team> Teams => Set<Team>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Team>(e =>
        {
            e.ToTable("teams");
            e.HasKey(x => x.Id);
            e.Property(x => x.Name).HasMaxLength(200).IsRequired();
            e.Property(x => x.StewardUpn).HasMaxLength(320).IsRequired();
            e.HasIndex(x => x.Name).IsUnique();
        });
    }
}
```

```powershell
dotnet tool install --global dotnet-ef
dotnet ef migrations add Init --project src/AgentHub.Registry --output-dir ../../db/migrations
dotnet ef database update --project src/AgentHub.Registry
```

**Run migrations from CI, not from app startup.** Auto-migrating on boot will eventually
bite you when two instances start at once.

### 5. API with Entra auth

```csharp
// src/AgentHub.Registry/Program.cs
var b = WebApplication.CreateBuilder(args);

b.Services.AddMicrosoftIdentityWebApiAuthentication(b.Configuration);
b.Services.AddAuthorization();
b.Services.AddDbContext<AgentHubDb>(o =>
    o.UseNpgsql(b.Configuration.GetConnectionString("AgentHub")));
b.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .WithOrigins(b.Configuration["Cors:Origins"]!.Split(','))
    .AllowAnyHeader().AllowAnyMethod()));
b.Services.AddHealthChecks().AddDbContextCheck<AgentHubDb>();

var app = b.Build();
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

app.MapHealthChecks("/health");          // anonymous — for probes

app.MapGet("/v1/teams", async (AgentHubDb db) =>
    await db.Teams.OrderBy(t => t.Name).ToListAsync())
   .RequireAuthorization();

app.MapGet("/v1/me", (ClaimsPrincipal u) => new {
    name   = u.FindFirst("name")?.Value,
    upn    = u.FindFirst("preferred_username")?.Value,
    oid    = u.FindFirst("oid")?.Value,
    groups = u.FindAll("groups").Select(c => c.Value)   // used from Phase 2 onward
}).RequireAuthorization();

app.Run();
```

`/v1/me` returning the user's group claims is worth getting right now — it's the
foundation of every entitlement check later. If `groups` comes back empty, fix the app
registration's token configuration (group claims are not emitted by default, and large
group counts may require Graph instead).

### 6. React app

```powershell
npm create vite@latest src/web -- --template react-ts
cd src/web
npm install @azure/msal-browser @azure/msal-react @tanstack/react-query react-router-dom
```

Minimum viable shape:

```
src/web/src/
├── auth/msal.ts            # MSAL config, scopes, token acquisition
├── api/client.ts           # fetch wrapper that attaches the bearer token
├── api/hooks.ts            # TanStack Query hooks, one per endpoint
├── routes/                 # route components
└── components/             # shared UI
```

```ts
// src/web/src/api/client.ts
import { msal, apiScopes } from "../auth/msal";

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const account = msal.getActiveAccount();
  if (!account) throw new Error("Not signed in");

  const { accessToken } = await msal.acquireTokenSilent({ scopes: apiScopes, account });

  const res = await fetch(`${import.meta.env.VITE_API_BASE}${path}`, {
    ...init,
    headers: { ...init.headers, Authorization: `Bearer ${accessToken}`,
               "Content-Type": "application/json" },
  });

  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}
```

### 7. Design tokens, once

Spend half a day on this and never think about it again: colour tokens, type scale,
spacing scale, and a dark theme, as CSS custom properties. Phase 2 builds a lot of UI;
doing this after means retrofitting it.

Fluent UI is worth adopting even with a custom design — it makes the hub feel native next
to Teams, which matters when you embed it there later.

### 8. CI/CD

Minimum viable pipeline, in this order:

1. `dotnet build` + `dotnet test`
2. `npm ci` + `npm run build` + typecheck
3. `dotnet ef database update` against the target environment
4. Deploy API to Azure Container Apps
5. Deploy the SPA (Static Web Apps or Blob + Front Door)

Add the migration step **now**, while there is exactly one migration and it's trivial
to debug.

---

## Database changes

```sql
CREATE TABLE teams (
    id          uuid PRIMARY KEY,
    name        varchar(200) NOT NULL,
    contact     varchar(320) NOT NULL,
    steward_upn varchar(320) NOT NULL,
    escalation  varchar(200),
    created_at  timestamptz  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ix_teams_name ON teams (name);
```

Seed 3–4 real team rows from your Phase 0 inventory. Real data from the first day makes
every later screen easier to judge.

---

## Exit criteria

- [ ] `GET /health` returns healthy and reports the database connection
- [ ] A user signs in with their work account and `GET /v1/me` returns their UPN, oid, **and group claims**
- [ ] `GET /v1/teams` returns seeded rows, and returns 401 when unauthenticated
- [ ] React app renders the team list from the API, with loading and error states
- [ ] Dark and light themes both render correctly
- [ ] CI builds both projects, runs migrations, and deploys on merge to main
- [ ] A second developer can clone the repo and run everything locally from the README in under 30 minutes

That last one is not optional. If local setup is painful, Phase 2 velocity dies.
