#!/bin/sh
set -e
if [ -n "${PI_JAIL_PATH_PREPEND:-}" ]; then
  PATH="$PI_JAIL_PATH_PREPEND:$PATH"
  export PATH
fi
unset PI_JAIL_PATH_PREPEND
cp -rn "$HOME_SEED_DIR/." "$HOME"/
# pi install (build time) writes package declarations into the seed's settings.json, but the
# person-provided settings.json (copied here first, no-clobber) shadows it - merge the declarations back in.
jq --slurpfile seed "$HOME_SEED_DIR/.pi/agent/settings.json" \
  '.packages = ((.packages // []) + ($seed[0].packages // []) | unique)' \
  "$HOME/.pi/agent/settings.json" >"$HOME/.pi/agent/settings.json.tmp" &&
  mv "$HOME/.pi/agent/settings.json.tmp" "$HOME/.pi/agent/settings.json"
exec "$@"
