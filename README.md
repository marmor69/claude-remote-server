# Claude Code Remote Control Server for Dokploy

A small, Dokploy-friendly Docker setup for running
[`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)
as a headless `remote-control server` on a VPS, with persistent workspace
and config volumes and optional SSH.

## How authentication works

`claude remote-control server` only accepts **subscription** auth obtained
through the interactive `/login` flow. Long-lived OAuth tokens
(`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`) are **not** supported
for Remote Control — the entrypoint will actually unset the variable if it
sees it, to keep it from confusing the real auth flow.

`/login` writes two things:

- `/home/claude/.claude/.credentials.json` — the short-lived subscription
  credentials. This lives inside the `claude-config-data` volume, so it
  survives redeploys.
- `/home/claude/.claude.json` — onboarding state and account identity.
  This file lives at `$HOME`, **outside** the config volume, so a Dokploy
  redeploy would otherwise wipe it.

To keep `.claude.json` across redeploys, the entrypoint regenerates it
on every boot from four env vars:

- `CLAUDE_ACCOUNT_UUID`
- `CLAUDE_EMAIL`
- `CLAUDE_ORGANIZATION_UUID`
- `CLAUDE_ONBOARDING_VERSION` (optional, defaults to `2.1.29`)

If `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` are present in the
environment, the entrypoint unsets them before launching the server so
they can't override subscription auth.

## First-time setup (Dokploy)

You do this exactly once per deployment. After it's done, redeploys just
work without any manual steps.

1. **Create the Compose app.** Point Dokploy at this repository as a
   Docker Compose application.

2. **Deploy in setup mode.** Set:

   ```env
   SETUP_MODE=true
   ```

   and deploy. The container starts up, runs `sleep infinity`, and prints
   instructions to the log.

3. **Run `/login` from inside the container.** Open the Dokploy terminal
   (or `docker exec -it <container> bash`) and run:

   ```bash
   claude
   /login
   /status
   ```

   `/status` must say **Claude subscription authentication** — not API
   key. If it says API key, clear `ANTHROPIC_API_KEY` /
   `ANTHROPIC_AUTH_TOKEN` from your env and redeploy.

4. **Copy the three identity values into Dokploy.** Still inside the
   container:

   ```bash
   jq '.oauthAccount' ~/.claude.json
   ```

   You'll see something like:

   ```json
   {
     "accountUuid": "00000000-0000-0000-0000-000000000000",
     "emailAddress": "you@example.com",
     "organizationUuid": "00000000-0000-0000-0000-000000000000"
   }
   ```

   Paste those three values into Dokploy's env UI as:

   - `CLAUDE_ACCOUNT_UUID`
   - `CLAUDE_EMAIL`
   - `CLAUDE_ORGANIZATION_UUID`

5. **Flip setup mode off and redeploy.** Set:

   ```env
   SETUP_MODE=false
   ```

   and redeploy. On boot the entrypoint verifies that
   `.credentials.json` is in the config volume, regenerates
   `~/.claude.json` from the three env vars, and execs
   `claude remote-control server`. You should see this in the logs:

   ```text
   [entrypoint] persisted credentials: found in /home/claude/.claude
   [entrypoint] wrote /home/claude/.claude.json (onboarding v2.1.29)
   [entrypoint] starting: claude remote-control server --spawn-worktree-sessions 5
   ```

That's it. Subsequent redeploys reuse the persisted credentials and the
env vars, so you don't have to log in again unless Claude Code forces a
re-auth.

## Environment variables

| Variable                    | Default          | Purpose                                                              |
|-----------------------------|------------------|----------------------------------------------------------------------|
| `SETUP_MODE`                | `false`          | `true` = skip the server, wait for manual `/login`.                  |
| `CLAUDE_ACCOUNT_UUID`       | *(empty)*        | Account UUID from `~/.claude.json` → `oauthAccount.accountUuid`.     |
| `CLAUDE_EMAIL`              | *(empty)*        | Email from `~/.claude.json` → `oauthAccount.emailAddress`.           |
| `CLAUDE_ORGANIZATION_UUID`  | *(empty)*        | Org UUID from `~/.claude.json` → `oauthAccount.organizationUuid`.    |
| `CLAUDE_ONBOARDING_VERSION` | `2.1.29`         | Value written to `lastOnboardingVersion` in `~/.claude.json`.        |
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

Note that `~/.claude.json` is **not** on a volume — it's regenerated
from env vars on every boot (see "How authentication works").

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

### `[entrypoint] ERROR: no persisted Claude credentials found`

You haven't completed the first-time setup yet. Follow "First-time setup"
from step 2.

### `[entrypoint] ERROR: no /home/claude/.claude.json and onboarding env vars are missing`

You completed `/login` but forgot to copy `CLAUDE_ACCOUNT_UUID`,
`CLAUDE_EMAIL`, and `CLAUDE_ORGANIZATION_UUID` into Dokploy. Go back to
step 4 of "First-time setup".

### `[entrypoint] WARNING: CLAUDE_CODE_OAUTH_TOKEN is set`

You set a long-lived OAuth token, but `remote-control server` doesn't
accept them. The entrypoint unsets the variable automatically; remove it
from your Dokploy env to silence the warning and use the `SETUP_MODE`
flow instead.

### Login does not persist after redeploy

- Make sure `claude-config-data` is a persistent named volume in Dokploy
  and you aren't deleting it between deploys.
- Log in as the `claude` user, not `root` — `whoami` inside the
  container should return `claude`.
- Don't rename the volume; that creates a new empty volume and orphans
  your previous login.
- Make sure all three onboarding env vars are still set — if any are
  missing, `~/.claude.json` won't be regenerated and Claude Code will
  behave as if onboarding was never completed.

### `/status` inside the container shows API-key auth

The entrypoint already unsets `ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` on boot, but in interactive mode (`SETUP_MODE=true`)
the `claude` you launch manually inherits whatever env you started your
shell with. Explicitly `unset` them before running `claude` in the setup
terminal:

```bash
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
claude
```

## Security notes

- Review the Dockerfile before deployment; only mount paths you trust.
- The `claude` user has passwordless `sudo` inside the container so the
  entrypoint can repair volume ownership. If that matters for your
  threat model, audit before deploying.
- The three onboarding env vars are non-secret identifiers (UUIDs and an
  email). The actual credentials live inside the `claude-config-data`
  volume — keep that volume private.

## Disclaimer

Independent community setup. Not affiliated with, endorsed by, or
maintained by Anthropic. Claude Code, Claude, and related product names
belong to their respective owners.

## License

MIT
