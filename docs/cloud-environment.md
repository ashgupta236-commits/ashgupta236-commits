# Cloud environment tuning

Configuration for Claude Code cloud sessions on this repository. Everything here
is free. No paid plan, upgrade, or infrastructure is required.

## The box

Measured on a session VM on 2026-09-05:

| Resource | Value |
| --- | --- |
| Cores | 4 dedicated vCPU, Intel Xeon at 2.80GHz, no hyperthreading |
| Memory | 16 GB, no swap |
| Writable disk | roughly 30 GB of allowance remaining |
| CPU steal | zero |

The four cores are the binding constraint for heavy work. Memory, disk and
network all have headroom. Hosted VM size is not user-configurable, so the only
free way to get more total compute is to run independent tasks in separate
cloud sessions, each of which gets its own VM at no compute charge.

## Why parallelism is pinned to 4

A 32-unit C++ build, timed at several job counts on this hardware:

| Jobs | Wall time |
| --- | --- |
| -j1 | 27.03 s |
| -j2 | 12.45 s |
| -j4 | 6.48 s |
| -j6 | 7.11 s |
| -j8 | 7.01 s |

Scaling is near-perfect to four jobs, a 4.17x speedup, then it regresses.
Oversubscription costs real time rather than saving it. Node showed the same
shape: one process 1.37 s, four processes 1.66 s, eight processes 3.39 s.

`.claude/settings.json` therefore sets a parallelism ceiling of 4 for the build
tools that read an environment variable. `MAKEFLAGS` was verified to take
effect: eight one-second targets ran in 8022 ms unset and 2010 ms at `-j4`.

Setting `MAKEFLAGS` globally raises a fair objection: in a recursive build,
does each submake claim its own four jobs and oversubscribe the box? It does
not. GNU Make passes a jobserver down to submakes, so the ceiling stays global.
Measured on a three-subdirectory build of twelve one-second targets, the run
took 3013 ms against a theoretical 3000 ms for a true global `-j4`, and peak
concurrency was four. Full oversubscription would have finished in about
1000 ms with twelve jobs at once.

Some runners have no environment variable and need a flag or config entry
instead. Pass these yourself:

- Jest: `--maxWorkers=4`
- Vitest: `poolOptions.threads.maxThreads`
- Ninja: `-j4`, because it defaults to core count plus two, which is the slower
  `-j6` case above
- Maven: `-T4`

`PYTEST_XDIST_AUTO_NUM_WORKERS` only applies once `pytest-xdist` is installed,
which it is not by default.

**If the hardware ever changes**, these values are stale. They are deliberately
static and in one file, so update `.claude/settings.json` to the new core count.

## Why Docker starts from a hook, not a setup script

Docker is installed on the session image but its daemon does not run. A cloud
environment setup script cannot fix this. Setup scripts run only when no
environment cache exists, and that cache is a filesystem snapshot: it preserves
installed files and pulled images, but not running processes.

A daemon has to be started once per session, which is what a SessionStart hook
does. `scripts/start-docker.sh` is wired to that hook. It is idempotent, always
exits 0 so a failure can never block a session from starting, and no-ops
cleanly when Docker is absent or the user is not root. Measured cold start is
about 1.2 seconds, and the hook is asynchronous so it does not delay startup.

A setup script is still the right place to `docker pull` or `docker build`
images, since the cache does keep those on disk.

### Containers and HTTPS

Image pulls work out of the box. HTTPS from inside a container fails
certificate verification, because outbound traffic passes through an agent
proxy whose certificate authority the container does not trust. Mount the
bundle to fix it:

```bash
docker run --rm \
  -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro \
  your-image
```

For Compose, add the same bind mount to the services that make outbound calls.

## Network egress

Measured on a session VM on 2026-09-06. Every outbound HTTPS call from the
box goes through the agent proxy, and the proxy enforces the environment's
network policy at the `CONNECT` step: a host outside the policy gets a `403`
before a single byte of the request is sent. The `WebFetch` tool is behind the
same policy and reports `EGRESS_BLOCKED` for the same hosts, so it is not a
way around it. Connectors (the Netlify and Vercel MCP servers, GitHub MCP)
run outside the box and are not affected.

| Host | Result |
| --- | --- |
| `github.com` | open, via the proxy |
| `*.googleapis.com` (`dns`, `domains`, `oauth2`, `cloudresourcemanager`) | open |
| `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org` | open, bypass the proxy |
| DNS resolution (`8.8.8.8` on UDP 53) | works, including `NS` and `SOA` lookups |
| `api.netlify.com`, `app.netlify.com`, `www.netlify.com` | `CONNECT` refused, 403 |
| `*.netlify.app` (including `netlify-mcp.netlify.app`, the connector's upload path) | `CONNECT` refused, 403 |
| `api.vercel.com`, `vercel.com`, `*.vercel.app` | `CONNECT` refused, 403 |
| `novrafoods.com`, `www.novrafoods.com` | `CONNECT` refused, 403 |
| `dns.google` | `CONNECT` refused, 403 |

What this means for hosting work:

- A hosting provider's API token cannot be used from a session, whatever the
  token's scope. The Netlify token tested on 2026-09-06 never reached Netlify;
  the proxy refused the tunnel first.
- The Netlify connector can create a site and read sites, deploys, teams and
  forms. Its `deploy-site` operation only returns a CLI command, and that
  command uploads through `netlify-mcp.netlify.app`, which is blocked. It has
  no operation for custom domains.
- The Vercel connector can read projects and deployments and link a GitHub
  repository as a project. It has no operation for custom domains either.
- A deployed site cannot be verified from a session: the production domain and
  the provider's preview domains are all refused.

The policy is set per environment under **Claude Code on the web, environment
settings, network policy**, see
<https://code.claude.com/docs/en/claude-code-on-the-web>. To let a session
deploy and verify a site end to end, allow at least `api.netlify.com` and
`*.netlify.app` for Netlify, or `api.vercel.com` and `*.vercel.app` for Vercel,
plus the entity's own domain such as `novrafoods.com`. A new session is needed
after the change; a running session keeps the old policy.

The session also carries a Google Cloud credential in
`CLOUDSDK_AUTH_ACCESS_TOKEN`. The `googleapis.com` hosts are open, but the
auto-mode permission classifier denied the calls that used the credential,
so Cloud DNS changes from a session need an explicit permission rule in
`.claude/settings.json` before they can run.
