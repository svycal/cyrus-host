# cyrus-host

Self-hosted [Cyrus](https://www.atcyrus.com) agent running on Fly.io. This is
**shared infrastructure** — a single always-on worker that serves multiple
SavvyCal repos in our Cyrus account.

Tracking issue: [AP-890](https://linear.app/savvycal/issue/AP-890) (Route B of
[AP-886](https://linear.app/savvycal/issue/AP-886)).

## Why this exists

Cyrus runs a per-issue `cyrus-setup.sh` in a fresh git worktree with a 5-minute,
non-interactive timeout. On Cyrus's hosted cloud runtime the toolchain has to be
bootstrapped on every run, and compiling Erlang/OTP from source can blow that
budget. By self-hosting we own the base image: the host-level prerequisites are
baked in once, and each repo's pinned runtimes are installed via `mise` and
cached on a persistent volume — so the compile cost is **one-time per repo**, not
per issue.

## Design

This is a **thin host**, not a baked monolith. The image contains only:

- `cyrus-ai` + `@anthropic-ai/claude-code` (the agent)
- `git`, `gh`, `jq` (Cyrus prerequisites)
- `mise` + Erlang/Node build dependencies (so per-repo `mise install` works)
- a local PostgreSQL (shared by all worktrees)

It deliberately does **not** bake any app's specific Elixir/OTP/Node versions.
Each onboarded repo keeps its own `.tool-versions` and `cyrus-setup.sh`; the
setup script runs `mise install` to materialize that repo's runtimes. Because the
mise cache, cloned repos, and worktrees all live on the Fly volume mounted at
`/home/cyrus/.cyrus`, subsequent issues on the same repo reuse the cached
toolchain and stay well under the timeout.

### Fly shape

- App `savvycal-cyrus`, **always-on**: no `[http_service]`, so Fly never
  autostops it. Cyrus connects outbound via a Cloudflare tunnel
  (hosted-connected mode) — no public IP or inbound webhooks required.
- A single `performance-2x` / 4 GB VM. One machine ⇒ all worktrees share one
  Postgres, so each worktree must use a uniquely-named DB (derive it from
  `LINEAR_ISSUE_IDENTIFIER` in the repo's `cyrus-setup.sh`).
- A volume `cyrus_data` mounted at `/home/cyrus/.cyrus` holds all persistent
  state: the Cyrus token + `config.json`, cloned repos, worktrees, the mise
  cache, and the Postgres data directory.

## First-time setup

```sh
fly apps create savvycal-cyrus --org savvycal
fly volumes create cyrus_data --region iad --size 20 --app savvycal-cyrus

# Secrets (see below for what each is)
fly secrets set \
  CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat... \
  GH_TOKEN=github_pat_... \
  EZSUITE_AUTH_KEY=... \
  --app savvycal-cyrus

fly deploy
```

### Required secrets

| Secret                    | Purpose                                                       |
| ------------------------- | ------------------------------------------------------------ |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude auth for the agent (subscription token, see below).    |
| `GH_TOKEN`                | PAT used by `gh auth setup-git` so the agent can push PRs.    |
| `EZSUITE_AUTH_KEY`        | Auth for our private `ezsuite` Hex repo (used by repo setup). |

#### Generating the `CLAUDE_CODE_OAUTH_TOKEN`

We authenticate the agent with a Claude **subscription** token, not a metered
`ANTHROPIC_API_KEY`. Generate it locally with the Claude Code CLI:

```sh
npm i -g @anthropic-ai/claude-code   # if not already installed
claude setup-token
```

This launches a browser OAuth flow (requires a Claude Pro or Max subscription)
and prints a long-lived `sk-ant-oat…` token. Because it needs a browser it can't
be minted inside the Fly container — generate it on your machine, then push it as
the `CLAUDE_CODE_OAUTH_TOKEN` secret.

The Cyrus connection token (`cysk…`) is **not** a Fly secret — it's registered
once interactively in the one-time bootstrap below and then persists on the
volume under `/home/cyrus/.cyrus`.

#### Generating the `GH_TOKEN`

This PAT is what the agent uses to clone, push branches, and open PRs on our
private `svycal` repos. The image bakes a git credential helper
(`gh auth git-credential`) for the `cyrus` user, so git and `gh` pick up
`GH_TOKEN` automatically on every boot — no `gh auth setup-git` step required.

> **Tip:** for shared infra, prefer a dedicated bot/service GitHub account added
> to the `svycal` org over a personal PAT — it keeps PR authorship and audit
> trails clean and survives credential rotation. A personal PAT is fine for a
> quick trial.

**Recommended — fine-grained PAT** (GitHub → Settings → Developer settings →
[Fine-grained tokens](https://github.com/settings/personal-access-tokens/new)):

1. **Token name:** e.g. `cyrus-host`.
2. **Resource owner:** select **`svycal`** (the org that owns the repos), not
   your personal account. If it's missing or shows "approval required," an org
   owner must approve it, and the org must permit fine-grained tokens.
3. **Expiration:** a finite window (e.g. 90 days); rotate later via
   `fly secrets set`.
4. **Repository access:** *Only select repositories* → the repos Cyrus will work
   on (e.g. `appointments-app`, `cyrus-host`), or *All repositories*.
5. **Repository permissions** (everything else "No access"):
   - **Contents:** Read and write (clone + push)
   - **Pull requests:** Read and write (open/update PRs)
   - **Metadata:** Read-only (mandatory, auto-selected)
   - **Workflows:** Read and write — *only* if Cyrus may edit
     `.github/workflows/` files.

**Alternative — classic PAT** (if fine-grained tokens are blocked for the org;
[Tokens (classic)](https://github.com/settings/tokens/new)): scopes `repo`,
`workflow` (only if editing workflow files), and `read:org`. If the org enforces
SAML SSO, click **Configure SSO → Authorize** for `svycal` or git operations
will be rejected.

### One-time bootstrap (interactive)

After the first deploy, exec in to pair Cyrus and register repos. This writes to
`~/.cyrus` (`.env`, `config.json`), which only persists if it lands on the volume
at `/home/cyrus/.cyrus` — so **every command must run as the `cyrus` user**.

> ⚠️ `fly ssh console` logs you in as **root**, whose `~/.cyrus` is
> `/root/.cyrus` — ephemeral and ignored by the running agent. Drop to the
> `cyrus` user (with its `HOME`) before running anything:

```sh
fly ssh console --app savvycal-cyrus

# you start as root — switch to the cyrus user FIRST:
gosu cyrus env HOME=/home/cyrus bash -l

# now, as cyrus (state lands on the volume):
cyrus auth cysk...                                   # pair (hosted-connected)
cyrus self-add-repo https://github.com/svycal/appointments-app
```

Notes:

- `cyrus auth` / `self-add-repo` print
  `EADDRINUSE ... 127.0.0.1:3456` after their work. That's harmless: they save
  their state (`.env` / `config.json`) and then try to auto-start a second agent,
  which collides with the always-on one started by the entrypoint.
- **A restart is needed after pairing or adding/registering a repo.** In practice
  the running agent does *not* hot-load a new repo from a `config.json` change
  (whether written by `self-add-repo` or the Cyrus dashboard) — it only reloads
  `.env`. Restart so it boots with the updated config:
  `fly machine restart <id> --app savvycal-cyrus`. On a clean boot it logs
  `📦 Managing N repositories` listing what it picked up. (The repo itself is
  cloned lazily into `~/.cyrus/repos/<name>` on the first issue, not at boot.)
- No `gh auth setup-git` is needed — the credential helper is baked into the
  image (see `GH_TOKEN` above).
- If you accidentally run any of these as root, the state goes to `/root/.cyrus`
  and is lost on restart; just re-run it as the `cyrus` user.

### Verify GitHub access before assigning issues

The repo is cloned lazily on the first issue, so a bad `GH_TOKEN` (e.g. a
fine-grained PAT scoped to your personal account instead of the `svycal` org)
isn't caught until that first run fails at clone. Verify access up front as the
`cyrus` user — both checks should succeed:

```sh
fly ssh console --app savvycal-cyrus -C "/bin/bash -lc '
  gosu cyrus env HOME=/home/cyrus gh api repos/svycal/appointments-app --jq .permissions;
  gosu cyrus env HOME=/home/cyrus git ls-remote https://github.com/svycal/appointments-app refs/heads/main >/dev/null && echo \"git: OK\"
'"
```

A `404` from `gh api` or a `403` from `git ls-remote` means the token can't see
the repo — re-scope the PAT (resource owner `svycal`, Contents + Pull requests
read/write) and `fly secrets set GH_TOKEN=…` (which restarts the machine).

#### Recovering a missing base clone

Cyrus creates the **base clone** at `~/.cyrus/repos/<name>` during the first
issue's worktree setup, then makes a cheap git worktree per issue *from* it. If
that first clone fails (e.g. the bad-token case above), Cyrus does **not** retry
it on later issues — it's left with no base repo and gets stuck (the agent finds
nothing on disk and may fall back to cloning straight into the worktree, skipping
`cyrus-setup.sh` entirely). Recover by creating the base clone manually as the
`cyrus` user, then re-assign the issue:

```sh
fly ssh console --app savvycal-cyrus -C "/bin/bash -lc '
  gosu cyrus env HOME=/home/cyrus git clone https://github.com/svycal/<repo> \
    /home/cyrus/.cyrus/repos/<repo>'"
```

This is exactly why verifying token access (above) **before** the first issue
matters — it avoids the failed-clone-then-stuck state entirely.

## Verified on first boot

- ✅ The image builds and boots: `initdb` → Postgres → the Cyrus agent (v0.2.65)
  start cleanly, and the machine stays up (no `[http_service]`, never autostops).
- ✅ `@anthropic-ai/claude-code` runs alongside `cyrus-ai` (installed explicitly).
- ✅ Hosted-connected mode works with secrets only — no inbound webhooks. Repos
  are registered in local `config.json` (via `cyrus self-add-repo` or the Cyrus
  dashboard); the agent picks them up on the next **restart**, not live — see the
  bootstrap notes above.

## Open questions

- Exact Cloudflare tunnel egress endpoints to allowlist.
- Volume sizing once several repos' mise caches coexist.
- Git commit identity: confirm whether Cyrus sets `user.name`/`user.email` per
  repo, or whether we need a baked global default for the `cyrus` user.
