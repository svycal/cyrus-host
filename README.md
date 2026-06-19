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
  ANTHROPIC_API_KEY=sk-ant-... \
  GH_TOKEN=ghp_... \
  EZSUITE_AUTH_KEY=... \
  --app savvycal-cyrus

fly deploy
```

### Required secrets

| Secret              | Purpose                                                      |
| ------------------- | ----------------------------------------------------------- |
| `ANTHROPIC_API_KEY` | Claude auth for the agent (or `CLAUDE_CODE_OAUTH_TOKEN`).    |
| `GH_TOKEN`          | PAT used by `gh auth setup-git` so the agent can push PRs.   |
| `EZSUITE_AUTH_KEY`  | Auth for our private `ezsuite` Hex repo (used by repo setup).|

The Cyrus connection token (`cysk…`) is **not** a Fly secret — it's registered
once interactively in the one-time bootstrap below and then persists on the
volume under `/home/cyrus/.cyrus`.

### One-time bootstrap (interactive)

After the first deploy, exec into the machine to authenticate the long-lived
state that lives on the volume:

```sh
fly ssh console --app savvycal-cyrus

# inside the machine, as the cyrus user:
gh auth setup-git
cyrus auth cysk...        # pair with our Cyrus account (hosted-connected)
# then add repos via the Cyrus dashboard, or: cyrus self-add-repo
```

## Open questions (verify on first boot)

These were unknowns when this repo was scaffolded — confirm and update this
README:

- Is `@anthropic-ai/claude-code` bundled with `cyrus-ai`, or must it be installed
  separately? (We install it explicitly for now.)
- In hosted-connected mode, are repos configured via the dashboard or via local
  `config.json` / `cyrus self-add-repo`?
- Exact Cloudflare tunnel egress endpoints to allowlist.
- Volume sizing once several repos' mise caches coexist.
