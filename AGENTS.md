# Agent guidance

## Scope and ownership

- This repository is pi-jail, a generic, portable Pi jail built on rootless Podman.
- Use jj workspaces for independent working copies sharing one project repository and persistent jail home.
- Keep the image generic; do not bake in downstream project toolchains.
- Projects must remain buildable without adopting pi-jail.
- This guide is normal tracked guidance for pi-jail itself. Adoption exclusions below apply only to downstream projects.
- For setup, operation, and security boundaries, use `README.md` as the source of truth.

## Adopted project ownership

- Treat adopted project files and host-side jail configuration as separate ownership domains.
- Keep user-wide pi-jail configuration in `~/.config/pi-jail`; `jail.env` supplies virtual gateway keys to the jail.
- Keep real provider and MCP credentials on the host; never expose them to the jail.
- Keep host-owned `pi-jail.conf` and pi-jail-specific preparation scripts untracked, even when stored at an adopted repo
  root.
- Exclude these local files with local VCS excludes; do not change a downstream tracked `.gitignore` solely for pi-jail.
- Keep portable project requirements, including `go.mod` and `go.sum`, in the downstream project's VCS.

## Jail boundaries and tools

- Keep host configuration outside mounts the agent can write.
- Install tools in the jail, not on the host for the jail's sake.
- Preserve the image's existing `PATH` when adding project paths.
- Each adopted project has persistent `shared/home`, shared by its workspaces.
