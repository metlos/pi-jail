# Pi jail

Runs a preconfigured Pi coding agent in a "jail" preventing it from wreaking havoc in your home.

1. Build the image:

```
podman build . -t pi-jail:latest
```

2. Copy the `./pi` and `./pctl` scripts to your path (do not keep `pctl` inside an adopted repo - the root is
   dematerialized by `pctl init`).

3. Set up the person configuration - LLM gateway and MCP gateways (see [Person configuration](#person-configuration)):

```
podman pull docker.io/maximhq/bifrost:latest
```

4. Adopt a project (from its jj repo root):

```
pctl init
```

`pctl init` adopts the repo in place and turns the root into a bare-ish host: project files live in commits and
workspaces, not on disk at the root.

```
<PROJECT_DIR>           # jj repo (colocated), adopted in place
|- shared/home          # jail home: seeded pi state, persists across runs
|- shared/project       # filled into workspaces by symlink (node_modules, ...)
|- ws/<name>            # colocated jj workspaces
```

5. Create a workspace and start the agent in it:

```
pctl new mytask
pi mytask
```

- `pctl new <name>` - create workspace `ws/<name>` at the root's current state and symlink `shared/project` entries into
  it
- `pctl fill <name>` - symlink new `shared/project` entries into a workspace
- `pctl drop [--force] <name>` - remove a workspace; refuses while it has unlanded work in its working copy (`--force`
  overrides; the working copy is snapshotted into a commit before removal either way). Also removes the workspace's
  extra-mount config (see [Extra mounts](#extra-mounts))
- `pctl config <name>` - print the workspace's extra mounts
- `pctl config set <name> -v <src>:<dst>[:<opts>]...` - replace the workspace's extra mounts
- `pctl config add <name> -v <src>:<dst>[:<opts>]...` - add extra mounts to the workspace
- `pctl uninit [--force]` - remove every workspace and restore a plain full checkout at the repo root, advanced to the
  workspaces' landed work (merged when several diverged); refuses while any workspace has unlanded work (`--force`
  overrides; the working copies are snapshotted and kept either way). `shared/` is left behind - `rm -rf shared` once
  you no longer need the jail home and the shared entries

`shared/project` entries land in workspaces as untracked symlinks. They are expected to be covered by the repo's own
ignore rules (e.g. `node_modules` in `.gitignore`); entries that are not ignored show up as uncommitted changes in the
workspaces.

## How the jail works

`pi ws <worktree>` runs the container with five project mounts: the workspace at `/work/ws/<worktree>` (the working
directory), the repo data at `/work/.jj/repo` and `/work/.git` (the workspace must write there to commit),
`shared/project` at `/work/shared/project` (behind the `../../shared/project` symlinks) and `shared/home` as `/home`.
Every relative reference from the worktree - its `.jj`/`.git` pointers, the shared symlinks - resolves exactly like on
the host, so jj, git and the shared entries all work inside the jail. The jail boundary is one workspace plus the
repository: the agent can read and write its own working copy and every commit (all workspaces share one repository, so
landed work of other workspaces is visible by design), but never sees other workspaces' working copies, the repo root,
or anything outside the project - except the workspace's [extra mounts](#extra-mounts), if any.

The host's jj/git user config (`~/.config/jj`, `~/.gitconfig`, `~/.config/git`, whichever exist) is mounted into the jail
read-only, so jj and git run with the usual identity, aliases and ignores inside - the jail home is per-project and
would otherwise leave them unconfigured. Includes stored inside those dirs work; includes pointing elsewhere do not
(git silently ignores them, jj errors out) - mount such dirs via [extra mounts](#extra-mounts) if needed. Signing keys
never enter the jail: if your config signs commits, shadow it with repo-local config
(`git config --file .git/config commit.gpgsign false`, `jj config set --repo signing.behavior drop`, both set on the
host) and sign when landing work to main on the host - keep signing last, an in-jail rewrite of a signed commit drops
its signature.

Requires rootless podman (`--userns=keep-id` maps your uid into the container) and SELinux relabeling of the mounted
trees (`:z`). Needs jj >= 0.46 (colocated workspaces) and git >= 2.42.

## Extra mounts

A workspace can get additional host directories mounted into the jail - useful when it needs access to files outside the
project (a reference repo, datasets, a tool cache). The mounts are persisted per workspace in `pi-jail.conf` at the repo
root (git-excluded, not mounted into the jail itself, so the agent cannot edit its own mount config):

```
pctl config set mytask -v ~/refs/big-monorepo:/refs:ro -v ~/.cache/pip:/cache
pi mytask
```

Each `-v` takes a podman volume spec `<src>:<dst>[:<opts>]`; `pctl config add` appends, `pctl config <name>` prints.
`pi ws` and `pi debug` both pick the mounts up and announce them on startup. The extra mounts are appended after the
fixed project mounts, so they can shadow them (`/home`, `/work/...`); hand-edits to the file are allowed too - one spec
per line under a `[<workspace>]` header, `#` comments and blank lines are skipped.

Bind sources must exist when the workspace starts (podman would otherwise auto-create them as root-owned junk on the
host; `pctl config` rejects them at write time). `:z` is not added automatically - it persistently relabels the host
directory, so opting in is your call (add it to the spec when SELinux enforcing blocks the access).

## Person configuration

The agent never sees a real API key - LLM or MCP - and nothing person-specific lives in the image or the repo.
Everything person-specific is a bundle in `~/.config/pi-jail/`, injected at `podman run` time:

| file            | contents                                                  | consumed by                      |
| --------------- | --------------------------------------------------------- | -------------------------------- |
| `config.json`   | LLM gateway: providers, virtual key                       | gateway service                  |
| `bifrost.env`   | real LLM API keys + the jail's virtual key                | gateway service, your shell      |
| `models.json`   | model list: providers at the proxy, `$VAR` keys, metadata | jail (mounted read-only)         |
| `jail.env`      | virtual LLM keys                                          | jail environment                 |
| `mcp.json`      | MCP servers: URL entries (host) or stdio (in-jail)        | jail (mounted read-only)         |
| `mcp.env`       | real MCP credentials                                      | host MCP services                |
| `settings.json` | pi settings incl. the default model                       | jail (copied into `shared/home`) |

- `./pi` mounts `models.json` and `mcp.json` read-only over the seeded stubs (curated on the host, pi never writes them)
  and copies `settings.json` into `shared/home` on the project's first run: pi writes settings at runtime
  (`defaultModel`, theme), so changes stay contained in the project instead of mutating the person-global file.
- `./pi` maps the host loopback into the jail (`pasta --map-host-loopback`), because rootless podman blocks loopback by
  default. The proxy and the host MCP services all bind loopback and are reached as `host.containers.internal`.
  Tradeoff: every host loopback service becomes reachable from the jail.
- The jail only ever receives virtual keys and service URLs - real keys (LLM or MCP) never enter it.

Setup:

```
mkdir -p ~/.config/pi-jail ~/.config/systemd/user
cp proxy/config.json.example proxy/models.json.example proxy/settings.json.example proxy/mcp.json.example ~/.config/pi-jail/
mv ~/.config/pi-jail/models.json.example ~/.config/pi-jail/models.json
mv ~/.config/pi-jail/settings.json.example ~/.config/pi-jail/settings.json
mv ~/.config/pi-jail/mcp.json.example ~/.config/pi-jail/mcp.json
cp proxy/jail.env.example ~/.config/pi-jail/jail.env
cp proxy/bifrost.service proxy/mcp-atlassian.service ~/.config/systemd/user/

# real upstream keys; keep this file outside any jail-mounted directory
cp proxy/bifrost.env.example ~/.config/pi-jail/bifrost.env
chmod 600 ~/.config/pi-jail/bifrost.env

# real MCP credentials for the host-side MCP services
cp proxy/mcp.env.example ~/.config/pi-jail/mcp.env
chmod 600 ~/.config/pi-jail/mcp.env

systemctl --user daemon-reload
systemctl --user enable --now bifrost mcp-atlassian
```

The services start on login (`WantedBy=default.target`); they stop at logout unless you `loginctl enable-linger $USER`.

Already-initialized projects keep their seeded home (the entrypoint only adds missing files) and the `settings.json`
copy is no-clobber too - refresh them by hand when your person config changes. The `models.json` mount shadows the old
seeded file automatically; the stale `shared/home/.pi/agent/auth.json` still needs manual removal there, it would
override the `models.json` key.

## LLM gateway

A host-side [Bifrost](https://github.com/maximhq/bifrost) gateway (rootless podman container, `bifrost.service`) holds
the real LLM keys and forwards to the real providers; the jail's `models.json` points its providers at
`http://host.containers.internal:8317` and reads the virtual key (`$VAR` from `jail.env`). Bifrost relays streaming
responses (tool calls, reasoning, usage) unchanged - this is a hard requirement: the previous llm-proxy-server setup
silently dropped all three from streams, which broke every tool-using turn in the jail.

- The gateway binds `127.0.0.1:8317`; `bifrost.env` holds the real upstream keys and is never passed into the jail.
- Routing is by model-id prefix: `myrouter/<model>` in a `models.json` entry selects the `myrouter` provider from
  `config.json`, so the model list exists only in `models.json` - adding a model there needs no gateway change or
  restart. Bare OpenAI-style ids (`gpt-5.4`) resolve through the gateway's model catalog to a provider serving them.
- Claude models speak the Anthropic protocol end to end: the `anthropic` provider in `models.json` points at the
  gateway's `/anthropic_passthrough` endpoint, which forwards `/v1/messages` to the anthropic-protocol upstream
  (`anthropic` provider + `base_url` override in `config.json`).
- The gateway keeps a SQLite store (config + logs) under `~/.local/state/pi-jail/bifrost`; `config.json` is copied there
  on every service start and is the source of truth (`source_of_truth`), so edits to `~/.config/pi-jail/config.json`
  apply on restart - including removals, which prune the stored rows. First start after boot/login takes ~20s (store
  migrations) - until then the jail cannot reach the gateway.

To share the keys with your shell (systemd services never see `.zshrc`, so the flow is inverted: the shell sources the
gateway's file), add to `.zshrc`:

```zsh
# pi-jail LLM gateway keys (real API keys - same file the gateway service reads)
[ -f ~/.config/pi-jail/bifrost.env ] && {
  set -a
  source ~/.config/pi-jail/bifrost.env
  set +a
}
```

Note your shell now exports real keys, so anything that forwards your shell environment (devcontainers, remote tooling)
can see them.

Adding a model: add an entry to `~/.config/pi-jail/models.json`, with the provider prefix in its id (`myrouter/<id>`).
Nothing else - routing works by the id's prefix.

Adding a provider: a `providers` entry in `config.json` (plus its `provider_configs` permission on the virtual key), a
provider block in `models.json`, and the key vars in `bifrost.env` (real) and `jail.env` (virtual). A name not built
into Bifrost also needs `custom_provider_config` with a `base_provider_type`, and a `network_config.base_url` that
excludes `/v1` - Bifrost appends the full `/v1/chat/completions` path itself. Built-in provider names (`openrouter`,
...) are reserved and cannot be reused for custom providers.

## MCP gateways

MCP servers split in two classes:

- **Credential-bearing** (Jira, ...): run on the host like the LLM proxy - one systemd unit per server, keys in
  `mcp.env`, jail connects by URL and never sees them. `mcp-atlassian.service` is the example:
  `uvx mcp-atlassian --transport streamable-http` on `127.0.0.1:8321` (the explicit `--host` is mandatory, the default
  bind is `0.0.0.0`); the jail's `mcp.json` entry is just `"url": "http://host.containers.internal:8321/mcp"`. For
  stdio-only servers of this class, bridge them with `mcp-proxy`/`supergateway`.
- **Project-bound** (code-review-graph): stay stdio inside the jail - they hold no secrets and must read the project
  files, which only exist at jail paths (`/work/ws/...`).

A server that is both secret-bearing and project-bound cannot be protected this way - known limit.

Host MCP endpoints are loopback-bound but unauthenticated: other local users could call them. Single-user machine:
acceptable; otherwise front them with an authenticated reverse proxy.

Adding a host-side MCP server: copy the `mcp-atlassian.service` pattern (own port, env vars in `mcp.env`), then add a
URL entry to the jail's `mcp.json`.
