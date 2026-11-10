#!/usr/bin/env bash
# Run the real POSIX entrypoint without an image or Podman.
set -u
cd "$(dirname "$0")/.."
entrypoint=$PWD/scripts/entrypoint.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
	fi
}
mkdir -p "$T/seed/.pi/agent" "$T/baseline" "$T/project tools"
printf '{"packages": ["seed-package"]}\n' >"$T/seed/.pi/agent/settings.json"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$PATH" >"$GRAPH_PATH"' \
	'printf "%s\n" "${PI_JAIL_PATH_PREPEND-unset}" >"$GRAPH_CARRIER"' >"$T/baseline/code-review-graph"
printf '#!/bin/sh\nprintf "%%s\\n" "$PATH" "${PI_JAIL_PATH_PREPEND-unset}" "$PROJECT_VALUE" "$@"\n' \
	>"$T/baseline/inspect-env"
chmod +x "$T/baseline/code-review-graph" "$T/baseline/inspect-env"
cp "$T/baseline/code-review-graph" "$T/project tools/"
printf '#!/bin/sh\nprintf "project-command\\n"\nexec "%s/baseline/inspect-env" "$@"\n' "$T" \
	>"$T/project tools/inspect-env"
chmod +x "$T/project tools/inspect-env"
baseline="$T/baseline:/usr/bin:/bin"
payload='$HOME/$(touch path-payload)/`touch path-backtick`'
prefix="$T/project tools:/container/$payload:/missing container dir"
for mode in prefix empty unset; do
	mkdir -p "$T/$mode/.pi/agent"
	printf '{"packages": ["user-package"]}\n' >"$T/$mode/.pi/agent/settings.json"
	(
		cd "$T"
		export HOME="$T/$mode" HOME_SEED_DIR="$T/seed" PATH="$baseline"
		export GRAPH_PATH="$T/graph-path" GRAPH_CARRIER="$T/graph-carrier"
		export PROJECT_VALUE=' literal = "quotes" $HOME $(touch env-payload) '
		case $mode in
		prefix) export PI_JAIL_PATH_PREPEND="$prefix" ;;
		empty) export PI_JAIL_PATH_PREPEND= ;;
		unset) unset PI_JAIL_PATH_PREPEND ;;
		esac
		/bin/sh "$entrypoint" inspect-env 'argument with spaces' 'equals=a=b'
	) >"$T/output" 2>"$T/stderr"
	check "$mode entrypoint executes command" "0" "$?"
	expected_path=$baseline
	mapfile -t actual <"$T/output"
	check "$mode graph build runs" "building code review graph" "${actual[0]-}"
	actual=("${actual[@]:1}")
	if [ "$mode" = prefix ]; then
		expected_path="$prefix:$baseline"
		check "$mode command resolves from prepended directory" "project-command" "${actual[0]-}"
		actual=("${actual[@]:1}")
	fi
	check "$mode child PATH preserves inherited baseline" "$expected_path" "${actual[0]-}"
	check "$mode child cannot propagate carrier" "unset" "${actual[1]-}"
	check "$mode env inherited literally" ' literal = "quotes" $HOME $(touch env-payload) ' "${actual[2]-}"
	check "$mode command receives spaced argument" 'argument with spaces' "${actual[3]-}"
	check "$mode command receives equals argument" 'equals=a=b' "${actual[4]-}"
	check "$mode graph build sees final PATH" "$expected_path" "$(<"$T/graph-path")"
	check "$mode graph build cannot propagate carrier" "unset" "$(<"$T/graph-carrier")"
	check "$mode settings still seeded and merged" '["seed-package","user-package"]' \
		"$(jq -c .packages "$T/$mode/.pi/agent/settings.json")"
done
check "shell payloads never execute" "1" \
	"$([ ! -e "$T/path-payload" ] && [ ! -e "$T/path-backtick" ] && [ ! -e "$T/env-payload" ] && echo 1 || echo 0)"
printf '\npassed: %s, failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
