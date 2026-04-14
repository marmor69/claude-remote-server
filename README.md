# Claude Code Remote Control Server for Dokploy

A small, Dokploy-friendly Docker setup for running
[`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)
as a headless `remote-control server` on a VPS, with persistent workspace
and config volumes, a proper authentication pipeline, and optional SSH.

## Quick start (Dokploy)

1. Create a **Docker Compose** application in Dokploy and point it at this
   repository.
2. Generate an OAuth token on a machine that has a browser:

   ```bash
   claude setup-token
   ```

   Copy the resulting token into Dokploy's environment UI as
   `CLAUDE_CODE_OAUTH_TOKEN` (treat it as a secret — do not commit it).
3. On that same machine, open `~/.claude.json` and copy the three values
   inside the `oauthAccount` object into Dokploy as
   `CLAUDE_ACCOUNT_UUID`, `CLAUDE_EMAIL`, and `CLAUDE_ORGANIZATION_UUID`.
   The entrypoint uses them to rebuild `~/.claude.json` inside the
   container on every boot.
4. Deploy. The entrypoint logs which auth source it picked; when the
   process is healthy you're done.

That's the whole happy path. Everything below is only needed if you want
SSH, the interactive-login fallback, or a specific tweak.

## How authentication works

Claude Code Remote Control requires **subscription** authentication, not
an API key. The container supports two paths, in priority order:

1. **`CLAUDE_CODE_OAUTH_TOKEN` env var (recommended).** Generate once with
   `claude setup-token` on any machine with a browser, then set the token
   as an environment variable in Dokploy. No interactive step needed on
   the VPS.

   The token alone is not enough, though: `claude-code` also reads
   `~/.claude.json` for onboarding state and account identity. The
   entrypoint rebuilds that file on every boot from these three
   variables (all three required when `CLAUDE_CODE_OAUTH_TOKEN` is set):

   - `CLAUDE_ACCOUNT_UUID`
   - `CLAUDE_EMAIL`
   - `CLAUDE_ORGANIZATION_UUID`

   Find the values on any machine where `claude` is already logged in,
   inside `~/.claude.json` under the `oauthAccount` object:

   ```bash
   jq '.oauthAccount' ~/.claude.json
   ```

   Optionally override `CLAUDE_ONBOARDING_VERSION` (defaults to `2.1.29`)
   if a future `claude-code` release requires a newer value.

2. **Interactive `/login` (fallback).** For users who can't run
   `claude setup-token` elsewhere. Set `SETUP_MODE=true`, deploy, open a
   container terminal, run `claude` and complete `/login` + `/status`,
   then flip `SETUP_MODE` back to `false` and redeploy. The login is
   persisted on the `claude-config-data` volume.

The entrypoint script (`scripts/entrypoint.sh`) resolves the auth source
on every boot and prints one of these lines to the container logs:

- `[entrypoint] auth source: env-var OAuth token (CLAUDE_CODE_OAUTH_TOKEN)`
- `[entrypoint] auth source: persisted credentials in /home/claude/.claude`
- `[entrypoint] ERROR: no Claude authentication available.` (followed by
  instructions, then `exit 1`)

If neither source is available the container fails fast with an
actionable error, instead of silently crash-looping — that's the core
fix for the old "authentication does not work properly" bug.

If `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` are present in the
environment, the entrypoint unsets them before launching the server so
they can't override subscription auth.

## Environment variables

| Variable                    | Default          | Purpose                                                              |
|-----------------------------|------------------|----------------------------------------------------------------------|
| `CLAUDE_CODE_OAUTH_TOKEN`   | *(empty)*        | Primary auth. Generate with `claude setup-token`.                    |
| `CLAUDE_ACCOUNT_UUID`       | *(empty)*        | Account UUID from `~/.claude.json` → `oauthAccount.accountUuid`.     |
| `CLAUDE_EMAIL`              | *(empty)*        | Email from `~/.claude.json` → `oauthAccount.emailAddress`.           |
| `CLAUDE_ORGANIZATION_UUID`  | *(empty)*        | Org UUID from `~/.claude.json` → `oauthAccount.organizationUuid`.    |
| `CLAUDE_ONBOARDING_VERSION` | `2.1.29`         | Value written to `lastOnboardingVersion` in `~/.claude.json`.        |
| `SETUP_MODE`                | `false`          | `true` = don't start the server, wait for manual `/login`.           |
| `SPAWN_WORKTREE_SESSIONS`   | `5`              | Passed straight to `--spawn-worktree-sessions`.                      |
| `ENABLE_SSH`                | `false`          | Start sshd inside the container when `true`.                         |
| `SSH_HOST_PORT`             | `2222`           | Host port mapped to container port 22.                               |
| `CONTAINER_NAME`            | `claude-remote`  | Compose container name.                                              |
| `DOCKERFILE_PATH`           | `Dockerfile`     | Override when forking.                                               |
| `TZ`                        | `Europe/Berlin`  | Container timezone.                                                  |
| `HEALTHCHECK_INTERVAL`      | `30s`            | Compose healthcheck interval.                                        |
| `HEALTHCHECK_TIMEOUT`       | `10s`            | Compose healthcheck timeout.                                         |
| `HEALTHCHECK_RETRIES`       | `5`              | Compose healthcheck retries.                                         |
| `HEALTHCHECK_START_PERIOD`  | `30s`            | Compose healthcheck grace period.                                    |

See `.env.example` for the same list in copy-pasteable form.

## Volumes

Two named volumes, both must stay persistent in Dokploy:

- `claude-workspace-data` → `/home/claude/workspace` (your project files)
- `claude-config-data` → `/home/claude/.claude` (Claude login data, config)

The entrypoint runs `chown -R claude:claude` on both on every boot so a
freshly-mounted volume can never be root-owned in a way that silently
breaks login persistence.

## SSH (optional)

SSH is **off by default**. The `openssh-server` package is installed in
the image, but `sshd` only starts when `ENABLE_SSH=true` — the entrypoint
decides at runtime.

To enable it:

1. Drop a public key into the `claude-config-data` volume's
   `authorized_keys` (for example by using `SETUP_MODE=true` to get a
   shell first), or bake one in via a volume mount.
2. Set `ENABLE_SSH=true`.
3. Redeploy. The entrypoint log will show `sshd started (port 22 inside
   container)`.
4. Connect with:

   ```bash
   ssh -p 2222 claude@your.vps.example
   ```

Password auth is disabled; only public-key auth for the `claude` user is
allowed. The host port is published regardless of `ENABLE_SSH` so you can
toggle SSH from the Dokploy env UI without editing compose — when it's
off, nothing is listening on the inside of the container.

## Troubleshooting

### `[entrypoint] ERROR: no Claude authentication available.`

Either set `CLAUDE_CODE_OAUTH_TOKEN` (recommended) or use the interactive
fallback with `SETUP_MODE=true`. See "How authentication works" above.

### `[entrypoint] ERROR: CLAUDE_CODE_OAUTH_TOKEN is set but onboarding env vars are missing.`

You set the token but forgot one of `CLAUDE_ACCOUNT_UUID`,
`CLAUDE_EMAIL`, or `CLAUDE_ORGANIZATION_UUID`. Grab them from
`~/.claude.json` on a machine where `claude` is already logged in (see
"How authentication works") and set all three in Dokploy.

### Login does not persist after redeploy

- Make sure `claude-config-data` is a persistent named volume in Dokploy
  (don't delete it between deploys).
- Log in as the `claude` user, not `root` — `whoami` inside the
  container should return `claude`.
- Don't rename the volume; that creates a new empty volume and orphans
  your previous login.

### API-key auth interferes with Remote Control

The entrypoint already unsets `ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` on boot, but remove them from your Dokploy env
anyway if you aren't using them — the less moving parts, the better.
Remote Control requires subscription auth, and an API key in the same
process will silently win.

### Container is "running" but something feels off

Check the logs for the `[entrypoint]` lines described in "How
authentication works". They tell you exactly which auth source was used
and whether sshd started.

## Security notes

- Treat `CLAUDE_CODE_OAUTH_TOKEN` as a secret. Store it in Dokploy's env
  UI, never commit it.
- Review the Dockerfile before deployment; only mount paths you trust.
- The `claude` user has passwordless `sudo` inside the container so the
  entrypoint can repair volume ownership. If that matters for your
  threat model, audit before deploying.

## Disclaimer

Independent community setup. Not affiliated with, endorsed by, or
maintained by Anthropic. Claude Code, Claude, and related product names
belong to their respective owners.

## License

MIT
