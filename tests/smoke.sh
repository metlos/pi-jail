#!/usr/bin/env bash
# Smoke tests for pj: pi-jail.conf volume mounting + config file ops.
# No root, no podman. Fixtures are real colocated jj repos (root detection
# needs jj); podman is stubbed.
#
# Usage: tests/smoke.sh
set -u
cd "$(dirname "$0")/.."
command -v jj >/dev/null 2>&1 || {
	echo "tests/smoke.sh: jj is required" >&2
	exit 1
}

REAL_JJ=$(command -v jj)
pass=0
fail=0

check() { # check NAME EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL: $1" >&2
		echo "  expected: $2" >&2
		echo "  actual:   $3" >&2
	fi
}

# Volume specs of the stubbed podman run, in order (stub prints one arg per
# line; the line after each "-v" line is the spec).
vols() { # vols PODMAN_OUT
	awk 'p=="-v"{print} {p=$0}' "$1"
}

# Fake project root: ./pj checks the jail config dir, then execs stub podman.
# A real adopted jj root (see adopt) so cd_root detects the fixture; files
# are created after adoption, when the narrowed pattern keeps jj's
# auto-tracking from absorbing and deleting them.
mkproj() { # mkproj DIR PODMAN_OUT
	mkdir "$1"
	(cd "$1" && jj git init --colocate) >/dev/null 2>&1
	adopt "$1"
	mkdir -p "$1/bin" "$1/home" "$1/shared/home" "$1/shared/project" "$1/ws/foo" \
		"$1/cfg/pi-jail"
	: >"$1/cfg/pi-jail/jail.env"
	for f in models.json mcp.json settings.json; do : >"$1/cfg/pi-jail/$f"; done
	cat >"$1/bin/podman" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >>"$2"
EOF
	chmod +x "$1/bin/podman"
}

# Fixture repos: a fresh colocated repo, and adoption - what pj init leaves
# behind (ws/ + a narrowed root) so cd_root detects the fixture.
mkrepo() { # mkrepo DIR
	mkdir "$1"
	(cd "$1" && jj git init --colocate) >/dev/null 2>&1
}
adopt() { # adopt DIR
	mkdir -p "$1/ws"
	(cd "$1" && jj sparse set --clear --add ws) >/dev/null 2>&1
}

rm -rf .smoke-tmp
mkdir .smoke-tmp
T=$PWD/.smoke-tmp
X=$(mktemp -d) # clean location: no pj layout above (jj-root fallback tests)
trap 'rm -rf .smoke-tmp "$X"' EXIT

# --- pj open: baseline without config ----------------------------------------
out="$T/base.out"
mkproj "$T/base" "$out"
( cd "$T/base" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >/dev/null 2>&1
check "baseline includes initialized jj parent and repo mounts" "9" "$(vols "$out" | wc -l)"
check "baseline home mount last" \
	"$T/base/shared/home:/home:z" "$(vols "$out" | tail -1)"
check "baseline mounts newly initialized jj config read-only" "1" \
	"$(vols "$out" | grep -cE ':(/home/.config/jj|/home/.gitconfig|/home/.config/git):ro,z$')"

# --- pj open: host VCS user config is mounted read-only -----------------------
out="$T/vcs.out"
mkproj "$T/vcs" "$out"
mkdir -p "$T/vcs/home" "$T/vcs/cfg/jj" "$T/vcs/cfg/git"
touch "$T/vcs/home/.gitconfig"
( cd "$T/vcs" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >/dev/null 2>&1
check "vcs config gets 3 ro mounts" "3" "$(vols "$out" | grep -cE ':(/home/.config/jj|/home/.gitconfig|/home/.config/git):ro,z$')"
check "jj config dir mounted" "$T/vcs/cfg/jj:/home/.config/jj:ro,z" \
	"$(vols "$out" | grep -m1 '/home/.config/jj:ro,z')"
check "gitconfig mounted" "$T/vcs/home/.gitconfig:/home/.gitconfig:ro,z" \
	"$(vols "$out" | grep -m1 '/home/.gitconfig:ro,z')"
check "git config dir mounted" "$T/vcs/cfg/git:/home/.config/git:ro,z" \
	"$(vols "$out" | grep -m1 '/home/.config/git:ro,z')"

# --- repo config: real host jj initializes and selects one writable child ----
for state in existing absent foreign; do
	out="$T/repo-config-$state.out"
	R="$T/repo-config-$state"
	mkproj "$R" "$out"
	# With ordinary metadata, host jj should keep this sibling behind the read-only parent.
	mkrepo "$R/other"
	other_config=$(cd "$R/other" && HOME="$R/home" XDG_CONFIG_HOME="$R/cfg" "$REAL_JJ" config path --repo)
	if [ "$state" = existing ]; then
		config=$(cd "$R" && HOME="$R/home" XDG_CONFIG_HOME="$R/cfg" "$REAL_JJ" config path --repo)
		expected_id=$(<"$R/.jj/repo/config-id")
		printf '[signing]\nbehavior = "drop"\n' >"$config"
	elif [ "$state" = foreign ]; then
		other_id=${other_config%/config.toml}
		other_id=${other_id##*/}
		printf '%s' "$other_id" >"$R/.jj/repo/config-id"
	else
		check "absent repo starts without config-id" "0" "$([ -e "$R/.jj/repo/config-id" ] && echo 1 || echo 0)"
	fi
	for command in open debug exec; do
		rm -f "$out"
		args=("$command" foo)
		[ "$command" != exec ] || args+=(true)
		(cd "$R/shared" && HOME="$R/home" XDG_CONFIG_HOME="$R/cfg" PATH="$R/bin:$PATH" \
			"$OLDPWD/pj" "${args[@]}") >"$R/stdout" 2>"$R/stderr"
		check "$state $command succeeds" "0" "$?"
		id=$([ ! -f "$R/.jj/repo/config-id" ] || printf '%s' "$(<"$R/.jj/repo/config-id")")
		check "$state $command initializes valid config-id" "1" \
			"$([[ "$id" =~ ^[0-9a-f]{20}$ ]] && echo 1 || echo 0)"
		check "$state $command has repo metadata" "1" \
			"$([ -f "$R/cfg/jj/repos/$id/metadata.binpb" ] && echo 1 || echo 0)"
		check "$state $command mounts jj parent read-only" "$R/cfg/jj:/home/.config/jj:ro,z" \
			"$(vols "$out" | grep -F ':/home/.config/jj:ro,z')"
		check "$state $command mounts only host-resolved repo-config directory writable" \
			"$R/cfg/jj/repos/$id:/home/.config/jj/repos/$id:rw,z" \
			"$(vols "$out" | grep ':rw,z$')"
		check "$state $command never mounts all repos writable" "0" \
			"$(vols "$out" | grep -cF ':/home/.config/jj/repos:rw,z')"
		check "$state $command does not mount other repo writable" "0" \
			"$(vols "$out" | grep -Fc "${other_config%/config.toml}:/home/.config/jj/repos/")"
	done
	case "$state" in
	existing) check "launches preserve existing config-id" "$expected_id" "$id" ;;
	foreign)
		check "host jj repairs foreign config-id with ordinary writable metadata" "1" \
			"$([ "$id" != "$other_id" ] && echo 1 || echo 0)"
		;;
	absent)
		check "launches need no actual repo config file" "0" \
			"$([ -e "$R/cfg/jj/repos/$id/config.toml" ] && echo 1 || echo 0)"
		;;
	esac
done

# Selectively intercept path lookup; all root/sparse handling still uses real jj.
R="$T/repo-config-invalid"
out="$T/repo-config-invalid.out"
mkproj "$R" "$out"
{
	printf '#!/bin/bash\nREAL_JJ=%q\n' "$REAL_JJ"
	cat <<'JJ_WRAPPER'
if [ "$*" = "config path --repo" ]; then
	printf '%s\n' "$PWD" >"$TEST_JJ_CWD"
	[ "$TEST_JJ_MODE" != failure ] || exit 42
	printf '%s\n' "$TEST_JJ_PATH"
else
	exec "$REAL_JJ" "$@"
fi
JJ_WRAPPER
} >"$R/bin/jj"
chmod +x "$R/bin/jj"
id=0123456789abcdef0123
mkdir -p "$R/cfg/jj/repos" "$R/outside/$id" "$R/cfg/jj/repos-escape/$id"
ln -s "$R/cfg/jj/repos-escape/$id" "$R/cfg/jj/repos/$id"
mkdir -p "$R/cfg/jj/repos/33333333333333333333"
ln -s "$R/cfg/jj/repos/33333333333333333333" "$R/cfg/jj/repos/22222222222222222222"
for mode in failure empty malformed outside missing nested traversal symlink alias; do
	case "$mode" in
	failure|empty) config= ;;
	malformed) config="$R/cfg/jj/repos/not-an-id/config.toml" ;;
	outside) config="$R/outside/$id/config.toml" ;;
	missing) config="$R/cfg/jj/repos/11111111111111111111/config.toml" ;;
	nested) config="$R/cfg/jj/repos/$id/extra/config.toml" ;;
	traversal) config="$R/cfg/jj/repos/$id/../$id/config.toml" ;;
	symlink) config="$R/cfg/jj/repos/$id/config.toml" ;;
	alias) config="$R/cfg/jj/repos/22222222222222222222/config.toml" ;;
	esac
	rm -f "$out" "$R/lookup-cwd"
	(cd "$R/shared" && HOME="$R/home" XDG_CONFIG_HOME="$R/cfg" PATH="$R/bin:$PATH" \
		TEST_JJ_MODE="$mode" TEST_JJ_PATH="$config" TEST_JJ_CWD="$R/lookup-cwd" \
		"$OLDPWD/pj" open foo) >"$R/stdout" 2>"$R/stderr"
	check "$mode repo path fails" "1" "$?"
	check "$mode repo path never starts Podman" "0" "$([ -e "$out" ] && echo 1 || echo 0)"
	check "$mode lookup runs at project root" "$R" \
		"$([ ! -f "$R/lookup-cwd" ] || printf '%s' "$(<"$R/lookup-cwd")")"
done

# --- pj open: volumes from pi-jail.conf --------------------------------------
out="$T/vols.out"
mkproj "$T/vols" "$out"
cat >"$T/vols/pi-jail.conf" <<EOF
# comment

[volumes]
$T/vols/shared/project:/work/shared/project
/tmp:/mnt/tmp:z
$T/vols/shared/home:/home

[env]
KEEP=value
EOF
( cd "$T/vols" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >"$T/vols/stdout" 2>&1
check "3 extra mounts appended" "12" "$(vols "$out" | wc -l)"
check "extra mount after fixed ones" \
	"$T/vols/shared/project:/work/shared/project" "$(vols "$out" | head -10 | tail -1)"
check "env section not mounted" "0" "$(vols "$out" | grep -c 'KEEP=value')"
check "shadowing mount allowed" "1" "$(vols "$out" | grep -c ':/home$')"
check "startup line lists mounts" "1" \
	"$(grep -c 'extra mounts: .*/work/shared/project /tmp:/mnt/tmp:z .*/home)' "$T/vols/stdout")"

# --- pj open: volume specs with spaces work (bash arrays carry them) --------
out="$T/ws.out"
mkproj "$T/ws" "$out"
mkdir -p "$T/ws/my dir"
printf '[volumes]\n%s/my dir:/mnt/dir\n' "$T/ws/" >"$T/ws/pi-jail.conf"
( cd "$T/ws" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >/dev/null 2>&1
check "spaced spec mounted" "1" \
	"$(vols "$out" | grep -c 'my dir:/mnt/dir')"

# --- pj open: missing src rejected --------------------------------------------
out="$T/miss.out"
mkproj "$T/miss" "$out"
printf '[volumes]\n%s:/mnt/nope\n' "$T/miss/no-such-src" >"$T/miss/pi-jail.conf"
( cd "$T/miss" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >"$T/miss/stdout" 2>"$T/miss/stderr"
check "missing src exit code" "1" "$?"
check "missing src never runs podman" "0" "$([ -e "$out" ] && wc -l <"$out" || echo 0)"
check "missing src error names path" "1" \
	"$(grep -c 'no-such-src' "$T/miss/stderr")"
check "missing src error names global section" "1" "$(grep -Fc 'pi-jail.conf [volumes]' "$T/miss/stderr")"

# --- pj config ----------------------------------------------------------------
P="$T/pj-installed" # run pj as if installed on PATH
cp pj "$P"

# body of a pi-jail.conf section (empty when file or section is missing)
conf() { # conf PROJ SECTION
	awk -v s="[$2]" '$0==s{f=1;next} /^\[/{f=0} f' "$1/pi-jail.conf" 2>/dev/null
}

# set: replaces project volumes, preserves global sections and comments
mkrepo "$T/c1"
adopt "$T/c1"
mkdir -p "$T/c1/src"
printf '# top\n[env]\nKEEP=value\n[path-prepend]\n/keep\n\n[volumes]\n# first note\n\n/old:/old\n# last note\n\n' \
	>"$T/c1/pi-jail.conf"
( cd "$T/c1" && "$P" config set -v "$T/c1/src:/work/x" -v /tmp:/mnt/tmp:z ) >/dev/null 2>&1
check "set exit code" "0" "$?"
check "set replaces section lines" \
	"$T/c1/src:/work/x
/tmp:/mnt/tmp:z" "$(cd "$T/c1" && "$P" config)"
check "set preserves env section" "KEEP=value" "$(conf "$T/c1" env)"
check "set preserves path section" "/keep" "$(conf "$T/c1" path-prepend)"
check "set preserves comments including inside volumes" "# top
# first note
# last note" "$(grep '^#' "$T/c1/pi-jail.conf")"
check "set preserves blank lines including inside volumes" "3" "$(grep -cx '' "$T/c1/pi-jail.conf")"

# set: creates the section in a new file
mkrepo "$T/c2"
adopt "$T/c2"
mkdir -p "$T/c2/a" "$T/c2/c"
( cd "$T/c2" && "$P" config set -v "$T/c2/a:/b" ) >/dev/null 2>&1
check "set exit code (new file)" "0" "$?"
check "set creates section" "$T/c2/a:/b" "$(conf "$T/c2" volumes)"

# add: appends to existing section
( cd "$T/c2" && "$P" config add -v "$T/c2/c:/d" ) >/dev/null 2>&1
check "add exit code" "0" "$?"
check "add appends" "$T/c2/a:/b
$T/c2/c:/d" "$(conf "$T/c2" volumes)"

# Repeated headers read as one list; edits emit that list once, retaining comments and globals.
while IFS='|' read -r mode first second; do
	R="$T/repeated-$mode"
	mkrepo "$R"
	adopt "$R"
	printf '[volumes]\n/tmp:/mnt/first\n# first note\n\n[env]\nKEEP=value\n' >"$R/pi-jail.conf"
	printf '[volumes]\n/tmp:/mnt/second\n# second note\n\n[path-prepend]\n/keep\n' >>"$R/pi-jail.conf"
	(cd "$R" && "$P" config "$mode" -v /tmp:/mnt/new) >/dev/null 2>&1
	check "$mode repeated volume sections succeeds" "0" "$?"
	expected="${first:+$first$'\n'}${second:+$second$'\n'}/tmp:/mnt/new"
	check "$mode repeated sections print exact ordered list once" "$expected" "$(cd "$R" && "$P" config)"
	check "$mode repeated sections emit one header" "1" "$(grep -cxF '[volumes]' "$R/pi-jail.conf")"
	check "$mode repeated sections preserve globals and comments" "[volumes]
$expected
# first note

[env]
KEEP=value
# second note

[path-prepend]
/keep" "$(<"$R/pi-jail.conf")"
	(cd "$R" && "$P" config add -v /tmp:/mnt/after) >/dev/null 2>&1
	check "$mode repeated sections roundtrip add succeeds" "0" "$?"
	check "$mode repeated sections roundtrip does not multiply mounts" "$expected
/tmp:/mnt/after" "$(cd "$R" && "$P" config)"
done <<'REPEATED'
set||
add|/tmp:/mnt/first|/tmp:/mnt/second
REPEATED

# add: creates section, keeps others
mkrepo "$T/c3"
adopt "$T/c3"
mkdir -p "$T/c3/three"
printf '# keep\n[env]\nKEEP=value\n[path-prepend]\n/keep\n' >"$T/c3/pi-jail.conf"
( cd "$T/c3" && "$P" config add -v "$T/c3/three:/4" ) >/dev/null 2>&1
check "add creates section" "$T/c3/three:/4" "$(conf "$T/c3" volumes)"
check "add keeps env section" "KEEP=value" "$(conf "$T/c3" env)"
check "add keeps path section" "/keep" "$(conf "$T/c3" path-prepend)"
check "add keeps comments" "1" "$(grep -c '^# keep' "$T/c3/pi-jail.conf")"

# print (runs at the fake repo root)
printf '[volumes]\n%s/a:/b\n%s/c:/d\n' "$T/c2" "$T/c2" >"$T/c2/pi-jail.conf"
r="$(cd "$T/c2" && "$P" config 2>&1)"
check "print exit code" "0" "$?"
check "print lists lines" "$T/c2/a:/b
$T/c2/c:/d" "$r"

# print of missing project volumes exits nonzero
printf '[env]\nKEEP=value\n' >"$T/c3/pi-jail.conf"
r="$(cd "$T/c3" && "$P" config 2>&1)"
check "print missing section exit code" "1" "$?"
check "print missing section explains project volumes" "1" "$(printf '%s\n' "$r" | grep -c 'no project volumes')"

# invalid specs are rejected at write time
mkrepo "$T/c4"
adopt "$T/c4"
( cd "$T/c4" && "$P" config set -v "$T/c4/no:/mnt" ) >"$T/c4/stdout" 2>"$T/c4/stderr"
check "write rejects missing src" "1" "$?"
check "write missing src names section and path" "1" \
	"$(grep -Fc "pi-jail.conf [volumes]: no such host path: $T/c4/no" "$T/c4/stderr")"
check "invalid write creates no config" "0" "$([ -e "$T/c4/pi-jail.conf" ] && echo 1 || echo 0)"

# Set/add require at least one entry; invalid invocation never writes.
cp "$T/c2/pi-jail.conf" "$T/c2/original.conf"
for mode in set add; do
	(cd "$T/c2" && "$P" config "$mode") >/dev/null 2>&1
	check "config $mode needs entries" "2" "$?"
	check "config $mode without entries leaves config intact" "0" \
		"$(cmp -s "$T/c2/original.conf" "$T/c2/pi-jail.conf"; echo $?)"
done

# --- pj locates the repo root from any subdir --------------------------------
# given: pj invoked from a workspace (own .jj) or a plain subdir
# then: root-relative state (pi-jail.conf, mounts) lands at the repo root
out="$T/root.out"
mkproj "$T/root" "$out"
mkdir -p "$T/root/ws/foo/.jj" # real workspaces carry their own .jj
( cd "$T/root/ws/foo" && "$P" config set -v .:/mnt/workspace ) >/dev/null 2>&1
check "config from a workspace writes conf at the repo root" "1" "$([ -f "$T/root/pi-jail.conf" ] && echo 1 || echo 0)"
check "config from a workspace leaves no conf in the cwd" "0" \
	"$([ -e "$T/root/ws/foo/pi-jail.conf" ] && echo 1 || echo 0)"
check "workspace source resolves against invocation dir" "$T/root/ws/foo/.:/mnt/workspace" \
	"$(conf "$T/root" volumes)"

( cd "$T/root/shared" && HOME="$T/root/home" XDG_CONFIG_HOME="$T/root/cfg" PATH="$T/root/bin:$PATH" "$OLDPWD/pj" open foo ) >/dev/null 2>&1
check "open from a subdir mounts the root's workspace" "$T/root/ws/foo:/work/ws/foo:z" "$(vols "$out" | grep -m1 '/work/ws/foo:z')"

( cd "$T/root/shared" && "$P" config set -v project:/work/sp ) >/dev/null 2>&1
check "relative -v src resolves against the invocation dir" "$T/root/shared/project:/work/sp" \
	"$(conf "$T/root" volumes)"
(cd "$T/root" && "$P" config set -v shared/project:/work/root) >/dev/null 2>&1
check "root-relative source resolves against invocation dir" "$T/root/shared/project:/work/root" \
	"$(conf "$T/root" volumes)"

# given: an unadopted repo in a clean location (no pj layout above it)
# when: config is set from a subdir
# then: the conf lands at the repo's own root (the jj-root fallback)
mkrepo "$X/plain"
mkdir -p "$X/plain/deep"
printf 'project-cache/\n' >"$X/plain/.gitignore"
(cd "$X/plain" && jj commit -m 'Project ignore baseline') >/dev/null 2>&1
cp "$X/plain/.gitignore" "$X/plain-original.gitignore"
( cd "$X/plain/deep" && "$P" config set -v .:/mnt ) >/dev/null 2>&1
check "config from a subdir of an unadopted repo uses its jj root" "1" "$([ -f "$X/plain/pi-jail.conf" ] && echo 1 || echo 0)"
check "config from a subdir leaves no conf in the cwd" "0" \
	"$([ -e "$X/plain/deep/pi-jail.conf" ] && echo 1 || echo 0)"
check "unadopted source resolves against invocation dir" "$X/plain/deep/.:/mnt" "$(conf "$X/plain" volumes)"
# Both mutation modes must protect config before any jj snapshot, not only after init.
(cd "$X/plain" && "$P" config add -v /tmp:/mnt/extra) >/dev/null 2>&1
check "pre-init add succeeds" "0" "$?"
check "pre-init config exclusion is idempotent" "1" "$(grep -cxF pi-jail.conf "$X/plain/.git/info/exclude")"
cp "$X/plain/pi-jail.conf" "$X/plain-original.conf"
status=$(cd "$X/plain" && jj status)
check "pre-init snapshot succeeds" "0" "$?"
check "pre-init snapshot does not report config" "0" "$(printf '%s\n' "$status" | grep -cF pi-jail.conf)"
check "pre-init config remains untracked" "0" "$(cd "$X/plain" && jj file list | grep -cxF pi-jail.conf)"
(cd "$X/plain" && "$P" init) >/dev/null 2>&1
check "init after pre-init config succeeds" "0" "$?"
check "init preserves pre-init config bytes" "0" "$(cmp -s "$X/plain-original.conf" "$X/plain/pi-jail.conf"; echo $?)"
check "init does not duplicate pre-init exclusion" "1" "$(grep -cxF pi-jail.conf "$X/plain/.git/info/exclude")"
(cd "$X/plain" && jj sparse set --clear --add .) >/dev/null 2>&1
check "pre-init config leaves tracked gitignore unchanged" "0" \
	"$(cmp -s "$X/plain-original.gitignore" "$X/plain/.gitignore"; echo $?)"
check "pre-init config leaves no gitignore diff" "" "$(cd "$X/plain" && jj diff --types .gitignore)"

# Each write mode protects new pre-init config independently; print is read-only.
for mode in set add; do
	R="$X/preinit-$mode"
	mkrepo "$R"
	cp "$R/.git/info/exclude" "$X/exclude-$mode.before"
	(cd "$R" && "$P" config) >/dev/null 2>&1
	check "pre-init print without config fails normally ($mode)" "1" "$?"
	check "pre-init print does not change local exclusion ($mode)" "0" \
		"$(cmp -s "$X/exclude-$mode.before" "$R/.git/info/exclude"; echo $?)"
	(cd "$R" && "$P" config "$mode" -v "$R/missing:/mnt") >/dev/null 2>&1
	check "pre-init $mode rejects missing source" "1" "$?"
	check "pre-init invalid $mode does not change exclusion" "0" \
		"$(cmp -s "$X/exclude-$mode.before" "$R/.git/info/exclude"; echo $?)"
	check "pre-init invalid $mode does not create config" "0" "$([ -e "$R/pi-jail.conf" ] && echo 1 || echo 0)"
	(cd "$R" && "$P" config "$mode" -v /tmp:/mnt) >/dev/null 2>&1
	check "pre-init $mode creates config" "0" "$?"
	(cd "$R" && jj status) >/dev/null 2>&1
	check "pre-init $mode snapshot succeeds" "0" "$?"
	check "pre-init $mode config untracked after snapshot" "0" "$(cd "$R" && jj file list | grep -cxF pi-jail.conf)"
done

# Without safe local excludes, mutations fail before writing; never invent .git.
mkdir -p "$X/noncolocated/.jj/repo"
for mode in set add; do
	(cd "$X/noncolocated" && "$P" config "$mode" -v /tmp:/mnt) >"$X/native.out" 2>"$X/native.err"
	check "noncolocated $mode fails" "1" "$?"
	check "noncolocated $mode explains init prerequisite" "1" "$(grep -c 'run pj init' "$X/native.err")"
	check "noncolocated $mode creates no config" "0" \
		"$([ -e "$X/noncolocated/pi-jail.conf" ] && echo 1 || echo 0)"
	check "noncolocated $mode creates no git dir" "0" "$([ -e "$X/noncolocated/.git" ] && echo 1 || echo 0)"
	check "noncolocated $mode creates no config temp file" "0" \
		"$([ -e "$X/noncolocated/.pi-jail.conf.tmp" ] && echo 1 || echo 0)"
done
printf '[volumes]\n/tmp:/mnt\n' >"$X/noncolocated/pi-jail.conf"
cp "$X/noncolocated/pi-jail.conf" "$X/noncolocated-original.conf"
r=$(cd "$X/noncolocated" && "$P" config)
check "noncolocated print still succeeds" "0" "$?"
check "noncolocated print returns config" "/tmp:/mnt" "$r"
check "noncolocated print creates no git dir" "0" "$([ -e "$X/noncolocated/.git" ] && echo 1 || echo 0)"
for mode in set add; do
	(cd "$X/noncolocated" && "$P" config "$mode" -v /tmp:/other) >/dev/null 2>&1
	check "noncolocated $mode with existing config fails" "1" "$?"
	check "noncolocated $mode preserves existing config" "0" \
		"$(cmp -s "$X/noncolocated-original.conf" "$X/noncolocated/pi-jail.conf"; echo $?)"
done

# --- workspace resolution is invocation-dir aware ----------------------------
# given: pj open invoked from inside a workspace or from ws/
# then: "." and sibling paths resolve to the workspace around/beside the cwd,
# and a bare name still resolves as before
out="$T/cwd.out"
mkproj "$T/cwd" "$out"
mkdir -p "$T/cwd/ws/foo/deep" "$T/cwd/ws/bar"
open_cwd() { # open_cwd DIR ARGS...
	( cd "$1" && HOME="$T/cwd/home" XDG_CONFIG_HOME="$T/cwd/cfg" PATH="$T/cwd/bin:$PATH" \
		"$OLDPWD/pj" open "${@:2}" ) >/dev/null 2>&1
}
open_cwd "$T/cwd/ws/foo" .
check "open . inside a workspace mounts it" "$T/cwd/ws/foo:/work/ws/foo:z" \
	"$(vols "$out" | grep -m1 '/work/ws/foo:z')"
open_cwd "$T/cwd/ws/foo/deep" .
check "open . deep inside a workspace mounts it" "$T/cwd/ws/foo:/work/ws/foo:z" \
	"$(vols "$out" | grep -m1 '/work/ws/foo:z')"
open_cwd "$T/cwd/ws/bar" ../foo
check "open ../sibling from a workspace mounts the sibling" "$T/cwd/ws/foo:/work/ws/foo:z" \
	"$(vols "$out" | grep -m1 '/work/ws/foo:z')"
open_cwd "$T/cwd/ws" foo
check "open bare name from ws/ mounts it" "$T/cwd/ws/foo:/work/ws/foo:z" \
	"$(vols "$out" | grep -m1 '/work/ws/foo:z')"
open_cwd "$T/cwd/ws/bar" .
check "open . in another workspace mounts that one" "$T/cwd/ws/bar:/work/ws/bar:z" \
	"$(vols "$out" | grep -m1 '/work/ws/bar:z')"
open_cwd "$T/cwd/ws/bar" ws/foo
check "open ws/name from a workspace exits 0 (name fallback)" "0" "$?"
check "open ws/name from a workspace still resolves (name fallback)" \
	"$T/cwd/ws/foo:/work/ws/foo:z" "$(vols "$out" | grep -m1 '/work/ws/foo:z')"
open_cwd "$T/cwd" .
check "open . at the root dies (root is not a workspace)" "1" "$?"

# --- pj drop owns only the workspace -----------------------------------------
mkrepo "$T/c5"
adopt "$T/c5"
(cd "$T/c5" && jj workspace add --colocate ws/volumes) >/dev/null 2>&1
printf '# keep\r\n[volumes]\r\n/tmp:/mnt\r\n[env]\r\nKEEP=value\r\n[path-prepend]\r\n/keep' \
	>"$T/c5/pi-jail.conf"
cp "$T/c5/pi-jail.conf" "$T/c5/original.conf"
( cd "$T/c5" && "$P" drop --force volumes ) >/dev/null 2>&1
check "drop volumes succeeds" "0" "$?"
check "drop leaves entire config byte-for-byte" "0" "$(cmp -s "$T/c5/original.conf" "$T/c5/pi-jail.conf"; echo $?)"
check "drop removes workspace" "0" "$([ -d "$T/c5/ws/volumes" ] && echo 1 || echo 0)"
rm "$T/c5/pi-jail.conf"
(cd "$T/c5" && jj workspace add --colocate ws/foo) >/dev/null 2>&1
( cd "$T/c5" && "$P" drop --force foo ) >/dev/null 2>&1
check "drop without config succeeds" "0" "$?"
check "drop creates no config" "0" "$([ -e "$T/c5/pi-jail.conf" ] && echo 1 || echo 0)"

# --- root detection, adoption, graph shape (real jj) ---------------------------
if command -v jj >/dev/null 2>&1; then

	# given: a fresh repo in a clean location (no pj layout above it)
	# when: pj init adopts it
	# then: the root is narrowed and the layout dirs exist
	R=$X/init
	mkrepo "$R"
	printf 'project-cache/\n' >"$R/.gitignore"
	(cd "$R" && jj commit -m 'Project ignore baseline') >/dev/null 2>&1
	(cd "$R" && "$P" init) >/dev/null 2>&1
	check "init narrows the root" "ws" "$(cd "$R" && jj sparse list)"
	check "init creates the layout" "1" \
		"$([ -d "$R/ws" ] && [ -d "$R/shared" ] && echo 1 || echo 0)"

	# Given host-owned global config, uninit must retain it outside VCS snapshots.
	config='[env]
PROJECT_TOKEN=host-owned
[path-prepend]
/home/project tools/bin
[volumes]
/tmp:/mnt/tmp'
	printf '%s\n' "$config" >"$R/pi-jail.conf"
	(cd "$R" && "$P" uninit) >/dev/null 2>&1
	check "uninit with global config succeeds" "0" "$?"
	check "uninit preserves global config contents" "$config" "$(<"$R/pi-jail.conf")"
	check "uninit retains config exclusion" "1" "$(grep -cxF pi-jail.conf "$R/.git/info/exclude")"
	check "uninit still removes ws exclusion" "0" "$(grep -cxF ws/ "$R/.git/info/exclude")"
	check "uninit still removes shared exclusion" "0" "$(grep -cxF shared/ "$R/.git/info/exclude")"
	status=$(cd "$R" && jj status)
	check "next snapshot after uninit succeeds" "0" "$?"
	check "next snapshot does not add config to status" "0" "$(printf '%s\n' "$status" | grep -cF pi-jail.conf)"
	files=$(cd "$R" && jj file list)
	check "file list after uninit succeeds" "0" "$?"
	check "global config stays untracked after snapshot" "0" "$(printf '%s\n' "$files" | grep -cxF pi-jail.conf)"
	check "uninit leaves project gitignore contents unchanged" "project-cache/" "$(<"$R/.gitignore")"
	check "uninit leaves no tracked gitignore changes" "" "$(cd "$R" && jj diff --types .gitignore)"

	# given: a full-checkout repo with a ws/ dir nested in an adopted root
	# when: config is set from inside it
	# then: the adopted root above wins - a layout look-alike is not a root
	R=$X/lookalike
	mkrepo "$R"
	adopt "$R"
	D=$R/inner
	mkrepo "$D"
	mkdir "$D/ws"
	( cd "$D" && "$P" config set -v /tmp:/mnt ) >/dev/null 2>&1
	check "a full-checkout look-alike is not a root" "1" \
		"$([ -f "$R/pi-jail.conf" ] && echo 1 || echo 0)"
	check "no conf at the look-alike" "0" "$([ -e "$D/pi-jail.conf" ] && echo 1 || echo 0)"

	# given: an adopted repo
	# when: a workspace is created with the ws/name argument form (path-shaped
	# arg whose path resolution misses; ws_name falls back to the name form)
	# then: it succeeds instead of tripping set -u on the unassigned local
	R=$T/newform
	mkrepo "$R"
	adopt "$R"
	(cd "$R" && "$P" new ws/task1) >/dev/null 2>&1
	check "new accepts the ws/name form" "0" "$?"
	check "new ws/name creates the workspace" "1" \
		"$([ -d "$R/ws/task1" ] && echo 1 || echo 0)"

	# given: an adopted repo whose root @ is the usual vacuous placeholder
	# (empty, no description) on top of described history
	# when: a workspace is created
	# then: its working copy sits on the described history, not on the vacuous
	# root @ - basing on it bakes an empty commit into the landed history
	R=$T/graph
	mkrepo "$R"
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	adopt "$R"
	(cd "$R" && "$P" new task1) >/dev/null 2>&1
	check "new bases on described history, not the vacuous root @" \
		"$(cd "$R" && jj log -r @- --no-graph -T commit_id)" \
		"$(cd "$R/ws/task1" && jj log -r @- --no-graph -T commit_id)"

	# given: the workspace landed work and was dropped
	# when: the repo is unadopted
	# then: the dropped workspace's landed work is in the restored root
	(cd "$R/ws/task1" && echo work >work && jj commit -m work1) >/dev/null 2>&1
	(cd "$R" && "$P" drop task1) >/dev/null 2>&1
	(cd "$R" && "$P" uninit) >/dev/null 2>&1
	check "uninit restores a dropped workspace's landed work" \
		"1" "$([ -f "$R/work" ] && echo 1 || echo 0)"

	# given: an adopted repo whose root @ still holds unlanded work
	# when: a workspace is created
	# then: it starts on the root's unlanded work, not beside it
	R=$T/wip
	mkrepo "$R"
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	(cd "$R" && echo wip >wip) >/dev/null 2>&1
	adopt "$R"
	(cd "$R" && "$P" new task) >/dev/null 2>&1
	check "new includes the root's unlanded work" \
		"1" "$([ -f "$R/ws/task/wip" ] && echo 1 || echo 0)"

	# given: an adopted repo whose empty root @ carries a description
	# when: a workspace is created
	# then: it bases on the described marker commit, not beside it
	R=$T/marker
	mkrepo "$R"
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	(cd "$R" && jj describe -m marker) >/dev/null 2>&1
	adopt "$R"
	(cd "$R" && "$P" new task) >/dev/null 2>&1
	check "new bases on a described (empty) root @" \
		"$(cd "$R" && jj log -r @ --no-graph -T commit_id)" \
		"$(cd "$R/ws/task" && jj log -r @- --no-graph -T commit_id)"

	# given: a workspace narrowed by a stray `jj sparse set` run inside it
	# (patterns are workspace-root-relative, so nothing matches, the
	# materialized files vanish, and a clean copy leaves no oplog trace)
	# when: the jail is opened
	# then: the sparse pattern is healed to full before podman runs
	# the fixture reproduces pj new's end state with raw jj (adopted root,
	# full workspace), then the narrowing accident
	R=$T/sparse
	mkrepo "$R"
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	adopt "$R"
	(cd "$R" && jj workspace add --colocate ws/task1) >/dev/null 2>&1
	(cd "$R/ws/task1" && jj sparse set --clear --add .) >/dev/null 2>&1 # pj new's reset
	(cd "$R/ws/task1" && jj sparse set --clear --add ws) >/dev/null 2>&1 # the accident
	check "stray narrow empties the workspace" "0" \
		"$([ -e "$R/ws/task1/base" ] && echo 1 || echo 0)"
	printf '#!/bin/sh\nexit 0\n' >"$T/podman"
	chmod +x "$T/podman"
	mkdir -p "$R/home" "$R/cfg/pi-jail" "$R/shared/project"
	: >"$R/cfg/pi-jail/jail.env"
	for f in models.json mcp.json settings.json; do : >"$R/cfg/pi-jail/$f"; done
	(cd "$R" && HOME="$R/home" XDG_CONFIG_HOME="$R/cfg" PATH="$T:$PATH" "$P" open task1) >/dev/null 2>&1
	check "open succeeds on a narrowed workspace" "0" "$?"
	check "open heals the sparse pattern" "." \
		"$(cd "$R/ws/task1" && HOME="$R/home" XDG_CONFIG_HOME="$R/cfg" jj sparse list)"
	check "open rematerializes the files" "1" \
		"$([ -f "$R/ws/task1/base" ] && echo 1 || echo 0)"
fi

# --- project-wide env and PATH: literal data, shared by every jail -----------
out="$T/env.out"
mkproj "$T/env" "$out"
mkdir -p "$T/env/ws/bar"
project_pj() {
	( cd "$T/env" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$P" "$@" )
}
# Extract actual argument pairs, not substrings that could hide ordering bugs.
env_args() {
	local arg previous=
	while IFS= read -r arg; do
		case $previous in --env | --env-file) printf '%s\n%s\n' "$previous" "$arg" ;; esac
		previous=$arg
	done <"$out"
}
literal='LITERAL= spaces = "quotes" $HOME $(touch env-payload) `touch env-backtick` '
printf '[env]\r\n# ignored\r\n\r\nEMPTY=\r\nEQUALS=a=b=c\r\n%s\r\nDUP=first\r\nDUP=last\r\n' \
	"$literal" >"$T/env/pi-jail.conf"
printf '[path-prepend]\r\n/container/not-on-host\r\n/container/with spaces\r\n' >>"$T/env/pi-jail.conf"
printf '[volumes]\r\n# shared mounts\r\n\r\n/tmp:/mnt/all\r\n/tmp:/mnt/last' >>"$T/env/pi-jail.conf"
expected_env="--env-file
$T/env/cfg/pi-jail/jail.env
--env
EMPTY=
--env
EQUALS=a=b=c
--env
$literal
--env
DUP=first
--env
DUP=last
--env
PI_JAIL_PATH_PREPEND=/container/not-on-host:/container/with spaces"
printf 'DUP=user\nPI_JAIL_PATH_PREPEND=/hijack\n' >"$T/env/cfg/pi-jail/jail.env"
for invocation in 'open foo' 'debug foo' 'open bar' 'debug bar'; do
	: >"$out"
	read -r command workspace <<<"$invocation"
	project_pj "$command" "$workspace" >"$T/env/stdout" 2>&1
	check "$invocation accepts global env and paths" "0" "$?"
	check "$invocation env-file precedes literal ordered overrides" "$expected_env" "$(env_args)"
	check "$invocation shares ordered project mounts" "/tmp:/mnt/all
/tmp:/mnt/last" "$(vols "$out" | grep '/mnt/')"
done
check "config payloads never execute" "1" \
	"$([ ! -e "$T/env/env-payload" ] && [ ! -e "$T/env/env-backtick" ] && echo 1 || echo 0)"
check "project config not mounted" "0" "$(vols "$out" | grep -c 'pi-jail.conf')"

# Given globals, mount edits must leave both sections alone.
for edit_case in 'set 1' 'add 2'; do
	read -r mode count <<<"$edit_case"
	project_pj config "$mode" -v /tmp:/mnt/new >/dev/null 2>&1
	check "config $mode with globals succeeds" "0" "$?"
	: >"$out"
	project_pj open foo >/dev/null 2>&1
	check "config $mode preserves globals" "$expected_env" "$(env_args)"
	check "config $mode retains mount semantics" "$count" "$(vols "$out" | grep -c '/mnt/new')"
done
rmdir "$T/env/ws/bar"
(cd "$T/env" && jj workspace add --colocate ws/bar) >/dev/null 2>&1
cp "$T/env/pi-jail.conf" "$T/env/original.conf"
project_pj drop --force bar >/dev/null 2>&1
check "drop with globals succeeds" "0" "$?"
: >"$out"
project_pj open foo >/dev/null 2>&1
check "drop preserves globals" "$expected_env" "$(env_args)"
check "drop preserves all global config" "0" "$(cmp -s "$T/env/original.conf" "$T/env/pi-jail.conf"; echo $?)"

# Given bad entries between valid entries, validation must fail before Podman.
while IFS='|' read -r section bad diagnostic; do
	printf '[%s]\n' "$section" >"$T/env/pi-jail.conf"
	if [ "$section" = env ]; then
		printf 'VALID=before\n%s\nAFTER=after\n' "$bad" >>"$T/env/pi-jail.conf"
	else
		printf '/valid\n%s\n/after\n' "$bad" >>"$T/env/pi-jail.conf"
	fi
	: >"$out"
	project_pj open foo >"$T/env/stdout" 2>"$T/env/stderr"
	check "[$section] rejects $bad" "1" "$?"
	check "[$section] $bad never invokes Podman" "0" "$(wc -l <"$out")"
	check "[$section] diagnostic names section" "1" "$(grep -Fc "[$section]" "$T/env/stderr")"
	check "[$section] diagnostic names entry" "1" "$(grep -Fc "$bad" "$T/env/stderr")"
	check "[$section] helpful diagnostic for $bad" "1" "$(grep -Fc "$diagnostic" "$T/env/stderr")"
done <<'INVALID'
env|NO_EQUALS|assignment
env|1BAD=value|name
env|BAD-NAME=value|name
env|BAD NAME=value|name
env|=value|name
env|PATH=/replacement|[path-prepend]
env|PI_JAIL_PATH_PREPEND=/hijack|reserved
env|[BROKEN|assignment
env|[env]junk|assignment
path-prepend|[BROKEN|absolute
path-prepend|[env]junk|absolute
path-prepend|relative/bin|absolute
path-prepend|~/bin|absolute
path-prepend|$HOME/bin|absolute
path-prepend|/one:/two|colon
path-prepend|/one:|colon
path-prepend|:/two|colon
INVALID

# No globals still overrides a user env-file carrier with an empty value.
printf '[volumes]\n/tmp:/mnt/all\n' >"$T/env/pi-jail.conf"
: >"$out"
project_pj open foo >/dev/null 2>&1
check "missing path section sends empty carrier" "--env-file
$T/env/cfg/pi-jail/jail.env
--env
PI_JAIL_PATH_PREPEND=" "$(env_args)"

# Section names are ordinary workspace names; config is independent of them.
printf '[env]\nKEEP=value\n[path-prepend]\n/keep\n[volumes]\n/tmp:/mnt/all\n' >"$T/env/pi-jail.conf"
cp "$T/env/pi-jail.conf" "$T/env/original.conf"
for workspace in env path-prepend volumes; do
	project_pj new "$workspace" >/dev/null 2>&1
	check "new accepts workspace $workspace" "0" "$?"
	project_pj fill "$workspace" >/dev/null 2>&1
	check "fill accepts workspace $workspace" "0" "$?"
	for command in open debug; do
		: >"$out"
		project_pj "$command" "$workspace" >"$T/env/stdout" 2>"$T/env/stderr"
		check "$command accepts workspace $workspace" "0" "$?"
		check "$command $workspace keeps project volumes" "/tmp:/mnt/all" "$(vols "$out" | grep '/mnt/')"
		check "$command $workspace keeps global env" "KEEP=value" "$(env_args | grep '^KEEP=')"
		check "$command $workspace keeps global paths" "PI_JAIL_PATH_PREPEND=/keep" \
			"$(env_args | grep '^PI_JAIL_PATH_PREPEND=')"
	done
	project_pj drop --force "$workspace" >/dev/null 2>&1
	check "drop accepts workspace $workspace" "0" "$?"
	check "drop $workspace leaves config intact" "0" \
		"$(cmp -s "$T/env/original.conf" "$T/env/pi-jail.conf"; echo $?)"
done

# --- config env/path CLI: literal ordered updates, one atomic replacement ----
rm "$T/env/pi-jail.conf"
project_pj config set --env "$literal" -e EMPTY= -e EQUALS=a=b=c -e DUP=first >/dev/null 2>&1
check "env-only set creates config without volumes" "0" "$?"
check "env-only set preserves literal entries" "$literal
EMPTY=
EQUALS=a=b=c
DUP=first" "$(conf "$T/env" env)"
project_pj config add -e DUP=last --env AFTER=value >/dev/null 2>&1
check "env-only add succeeds" "0" "$?"
check "env-only add keeps duplicate order" "$literal
EMPTY=
EQUALS=a=b=c
DUP=first
DUP=last
AFTER=value" "$(conf "$T/env" env)"
project_pj config >/dev/null 2>&1
check "bare config still prints volumes only" "1" "$?"
project_pj config set -p '/container/not-on-host:/container/with spaces' --path /last >/dev/null 2>&1
check "path-only set needs no host directories or volumes" "0" "$?"
project_pj config add --path /added:/final -p /tail >/dev/null 2>&1
check "path-only add succeeds" "0" "$?"
check "path flags split and append in order" "/container/not-on-host
/container/with spaces
/last
/added
/final
/tail" "$(conf "$T/env" path-prepend)"
for command in open debug; do
	: >"$out"
	project_pj "$command" foo >/dev/null 2>&1
	check "$command CLI-created config succeeds" "0" "$?"
	check "$command CLI-created env order and final carrier" "--env-file
$T/env/cfg/pi-jail/jail.env
--env
$literal
--env
EMPTY=
--env
EQUALS=a=b=c
--env
DUP=first
--env
DUP=last
--env
AFTER=value
--env
PI_JAIL_PATH_PREPEND=/container/not-on-host:/container/with spaces:/last:/added:/final:/tail" "$(env_args)"
done
check "CLI payloads never execute" "1" \
	"$([ ! -e "$T/env/env-payload" ] && [ ! -e "$T/env/env-backtick" ] && echo 1 || echo 0)"

# Untouched sections retain CRLF, comments, blanks, and missing final newline.
printf '# top\r\n[volumes]\r\n/tmp:/mnt/keep\r\n\r\n[env]\nOLD=value\n[path-prepend]\r\n/keep' \
	>"$T/env/pi-jail.conf"
printf '# top\r\n[volumes]\r\n/tmp:/mnt/keep\r\n\r\n[env]\nNEW=value\n[path-prepend]\r\n/keep' \
	>"$T/env/expected.conf"
project_pj config set -e NEW=value >/dev/null 2>&1
check "env set succeeds with untouched CRLF sections" "0" "$?"
check "env set leaves untouched bytes exact" "0" \
	"$(cmp -s "$T/env/expected.conf" "$T/env/pi-jail.conf"; echo $?)"

while IFS='|' read -r mode old_env old_paths old_volumes; do
	printf -v old_env '%b' "$old_env"
	printf -v old_paths '%b' "$old_paths"
	printf -v old_volumes '%b' "$old_volumes"
	printf '# top\n[env]\nOLD=first\n# env note\n\n[volumes]\n/tmp:/mnt/old\n' >"$T/env/pi-jail.conf"
	printf '[path-prepend]\n/old\n[env]\nOLD=last\n# repeat note\n[path-prepend]\n/second\n' \
		>>"$T/env/pi-jail.conf"
	project_pj config "$mode" -p /one:/two -e A=first --volume /tmp:/mnt/new \
		--env A=last --path /three -v /tmp:/mnt/final >/dev/null 2>&1
	check "mixed $mode accepts repeated short and long flags" "0" "$?"
	check "mixed $mode consolidates sections, preserves comments, orders lists" "# top
[env]
${old_env}A=first
A=last
# env note

[volumes]
${old_volumes}/tmp:/mnt/new
/tmp:/mnt/final
[path-prepend]
${old_paths}/one
/two
/three
# repeat note" "$(<"$T/env/pi-jail.conf")"
	project_pj config add -e A=after -p /after >/dev/null 2>&1
	check "mixed $mode roundtrip env does not multiply entries" "${old_env}A=first
A=last
A=after" "$(conf "$T/env" env | grep -vE '^(#|$)')"
done <<'MIXED'
set|||
add|OLD=first\nOLD=last\n|/old\n/second\n|/tmp:/mnt/old\n
MIXED

# Path updates retain all other bytes, even unknown/empty section headers.
printf '[path-prepend]\n/old\n# path note\n[env]\r\nKEEP=value\r\n[]\r\n# unknown\r\n' \
	>"$T/env/pi-jail.conf"
printf '[volumes]\r\n/tmp:/mnt/keep' >>"$T/env/pi-jail.conf"
project_pj config set -p /new >"$T/env/stdout" 2>"$T/env/stderr"
check "path set with empty unknown header succeeds" "0" "$?"
check "path set with empty unknown header emits no errors" "" "$(<"$T/env/stderr")"
project_pj config add --path /next >/dev/null 2>&1
check "path add with untouched sections succeeds" "0" "$?"
printf '[path-prepend]\n/new\n/next\n# path note\n[env]\r\nKEEP=value\r\n[]\r\n# unknown\r\n' \
	>"$T/env/expected.conf"
printf '[volumes]\r\n/tmp:/mnt/keep' >>"$T/env/expected.conf"
check "path set/add leaves other sections byte exact" "0" \
	"$(cmp -s "$T/env/expected.conf" "$T/env/pi-jail.conf"; echo $?)"

# Late bad entries cannot partially commit earlier valid sections.
for mode in set add; do
	while IFS='|' read -r flag bad; do
		cp "$T/env/pi-jail.conf" "$T/env/before.conf"
		project_pj config "$mode" -v /tmp:/mnt/valid -e VALID=value -p /valid "$flag" "$bad" \
			>/dev/null 2>&1
		check "mixed $mode rejects $flag $bad" "1" "$?"
		check "invalid $mode $flag $bad leaves all bytes intact" "0" \
			"$(cmp -s "$T/env/before.conf" "$T/env/pi-jail.conf"; echo $?)"
	done <<'INVALID_CLI'
-e|NO_EQUALS
-e|1BAD=value
-e|BAD-NAME=value
-e|BAD NAME=value
-e|=value
-e|PATH=/replacement
-e|PI_JAIL_PATH_PREPEND=/hijack
-p|
-p|relative/bin
-p|~/bin
-p|$HOME/bin
-p|/one:
-p|:/two
-p|/one::/two
-p|/one:relative
-v|/no-such-pj-host-directory:/mnt
INVALID_CLI
	for flag in -v --volume -e --env -p --path; do
		for bad in $'A=x\n[volumes]\n/tmp:/injected' $'/valid\r\n[env]\nA=injected' $'/valid\r'; do
			project_pj config "$mode" -v /tmp:/mnt/valid -e VALID=value -p /valid "$flag" "$bad" \
				>/dev/null 2>&1
			check "$mode $flag rejects CR/newline before serialization/splitting" "1" "$?"
			check "$mode $flag CR/newline keeps config intact" "0" \
				"$(cmp -s "$T/env/before.conf" "$T/env/pi-jail.conf"; echo $?)"
		done
		project_pj config "$mode" -e VALID=value "$flag" >/dev/null 2>&1
		check "$mode $flag missing value is usage error" "2" "$?"
		project_pj config "$mode" "$flag" --env VALID=value >/dev/null 2>&1
		check "$mode $flag missing value before next flag is usage error" "2" "$?"
	done
	for flag in --unknown bare; do
		project_pj config "$mode" -e VALID=value "$flag" >/dev/null 2>&1
		check "$mode rejects unknown argument $flag" "2" "$?"
	done
	check "$mode usage errors keep config intact" "0" \
		"$(cmp -s "$T/env/before.conf" "$T/env/pi-jail.conf"; echo $?)"
done

# Add validates retained entries in every selected section before writing.
while IFS='|' read -r section bad; do
	printf '[%s]\n%s\n' "$section" "$bad" >"$T/env/pi-jail.conf"
	cp "$T/env/pi-jail.conf" "$T/env/before.conf"
	project_pj config add -v /tmp:/mnt/valid -e VALID=value -p /valid >/dev/null 2>&1
	check "add rejects retained invalid $section" "1" "$?"
	check "add retains invalid $section without mutation" "0" \
		"$(cmp -s "$T/env/before.conf" "$T/env/pi-jail.conf"; echo $?)"
done <<'INVALID_RETAINED'
env|BAD-NAME=value
path-prepend|relative
volumes|/no-such-pj-host-directory:/mnt
INVALID_RETAINED

# One final rename for mixed updates; failure removes temp without touching config.
real_mv=$(command -v mv)
printf '#!/bin/sh\nprintf "rename\\n" >>"$MV_LOG"\n[ "${FAIL_MV:-0}" = 0 ] || exit 1\nexec "%s" "$@"\n' \
	"$real_mv" >"$T/env/bin/mv"
chmod +x "$T/env/bin/mv"
export MV_LOG="$T/env/mv.log"
: >"$MV_LOG"
project_pj config set -v /tmp:/mnt/valid -e VALID=value -p /valid >/dev/null 2>&1
check "mixed update succeeds through rename stub" "0" "$?"
check "mixed update performs one final rename" "1" "$(wc -l <"$MV_LOG")"
cp "$T/env/pi-jail.conf" "$T/env/before.conf"
FAIL_MV=1 project_pj config set -v /tmp:/mnt/new -e NEW=value -p /new >/dev/null 2>&1
check "rename failure fails mixed update" "1" "$?"
check "rename failure preserves config bytes" "0" \
	"$(cmp -s "$T/env/before.conf" "$T/env/pi-jail.conf"; echo $?)"
rm "$T/env/pi-jail.conf"
FAIL_MV=1 project_pj config add -v /tmp:/mnt/new -e NEW=value -p /new >/dev/null 2>&1
check "new config rename failure fails mixed update" "1" "$?"
check "failed mixed creation leaves no config or temp" "" \
	"$(printf '%s\n' "$T/env"/{pi-jail.conf,.pi-jail.conf.tmp*} | while IFS= read -r f; do
		[ ! -e "$f" ] || printf '%s\n' "$f"
	done)"
rm "$T/env/bin/mv"
unset MV_LOG

# Real write errors (not just rename errors) also leave no partial replacement.
printf '#!/bin/sh\nln -s /dev/full .pi-jail.conf.tmp.full\nprintf ".pi-jail.conf.tmp.full\\n"\n' \
	>"$T/env/bin/mktemp"
chmod +x "$T/env/bin/mktemp"
printf '[env]\nKEEP=value\n' >"$T/env/pi-jail.conf"
cp "$T/env/pi-jail.conf" "$T/env/before.conf"
project_pj config set -v /tmp:/mnt/new -e NEW=value -p /new >/dev/null 2>&1
check "existing config write failure fails mixed update" "1" "$?"
check "existing config write failure cleans temp" "0" \
	"$([ -L "$T/env/.pi-jail.conf.tmp.full" ] && echo 1 || echo 0)"
check "write failure preserves existing config bytes" "0" \
	"$(cmp -s "$T/env/before.conf" "$T/env/pi-jail.conf"; echo $?)"
rm "$T/env/pi-jail.conf"
project_pj config set -v /tmp:/mnt/new -e NEW=value -p /new >/dev/null 2>&1
check "new config write failure fails mixed update" "1" "$?"
check "new config write failure cleans temp" "0" \
	"$([ -L "$T/env/.pi-jail.conf.tmp.full" ] && echo 1 || echo 0)"
check "write failure creates no config" "0" "$([ -e "$T/env/pi-jail.conf" ] && echo 1 || echo 0)"
rm "$T/env/bin/mktemp"

for flag in '-v' '--volume' '-e' '--env' '-p' '--path'; do
	"$P" >"$T/help.out" 2>&1
	check "help lists $flag" "1" "$(grep -qF -- "$flag" "$T/help.out" && echo 1 || echo 0)"
done

# --- pj inject: recipe library dispatch --------------------------------------
# given: recipe scripts in the user's recipe dir (~/.config/pi-jail/recipes)
# when: pj inject runs them or lists them
# then: recipes are found by name, run at the project root with free args,
# and --verify <ws> is passed via PI_JAIL_VERIFY_WS
mkrepo "$T/inj"
adopt "$T/inj"
INJ="$T/inj"
mkdir -p "$INJ/cfg/pi-jail/recipes" "$INJ/bin"
cat >"$INJ/cfg/pi-jail/recipes/upper.sh" <<'EOF'
#!/bin/sh
printf 'cwd=%s\n' "$(basename "$PWD")"
printf 'verify=%s\n' "${PI_JAIL_VERIFY_WS-unset}"
for a in "$@"; do printf 'arg=%s\n' "$a"; done
printf 'args_done\n'
EOF
chmod +x "$INJ/cfg/pi-jail/recipes/upper.sh"
inj_pj() {
	( cd "$INJ" && XDG_CONFIG_HOME="$INJ/cfg" PATH="$INJ/bin:$PATH" "$P" inject "$@" )
}
r=$(inj_pj)
check "bare inject lists recipe names" "upper" "$r"
printf '#!/bin/sh\ntrue\n' >"$INJ/cfg/pi-jail/recipes/notexec.sh"
r=$(inj_pj)
check "bare inject lists only executable recipes" "upper" "$r"
r=$(inj_pj notexec 2>&1)
check "inject non-executable recipe fails" "1" "$?"
check "inject non-executable names it" "1" "$(printf '%s\n' "$r" | grep -c 'notexec.sh')"
rm "$INJ/cfg/pi-jail/recipes/notexec.sh"
r=$(inj_pj upper one two)
check "inject runs recipe and passes args" "cwd=inj
verify=unset
arg=one
arg=two
args_done" "$r"
r=$(inj_pj upper --verify ws/foo extra)
check "inject exports PI_JAIL_VERIFY_WS" "cwd=inj
verify=ws/foo
arg=extra
args_done" "$r"
r=$(inj_pj upper --verify)
check "inject --verify without value is usage error" "2" "$?"
r=$(inj_pj nope 2>&1)
check "inject unknown recipe fails" "1" "$?"
check "inject unknown recipe names it and the dir" "1" \
	"$(printf '%s\n' "$r" | grep -c "nope.*$INJ/cfg/pi-jail/recipes")"

# given: a recipe is a library, not a one-shot config writer
# when: inject runs it
# then: pj stays usable inside (recipes call pj config add themselves)
cat >"$INJ/cfg/pi-jail/recipes/cfgw.sh" <<EOF
#!/bin/sh
"$P" config add -v "$INJ/src:/mnt/x"
EOF
chmod +x "$INJ/cfg/pi-jail/recipes/cfgw.sh"
mkdir -p "$INJ/src" "$INJ/cfg/pi-jail/recipes"
printf '[volumes]\n/tmp:/mnt/keep\n' >"$INJ/pi-jail.conf"
inj_pj cfgw >/dev/null 2>&1
check "recipe can call pj config add" "0" "$?"
check "recipe config lands in project pi-jail.conf" \
	"/tmp:/mnt/keep
$INJ/src:/mnt/x" "$(conf "$INJ" volumes)"

# --- pj exec: non-interactive jail run ----------------------------------------
# given: a stubbed podman
# when: pj exec runs a command in a workspace's jail
# then: the same mounts as open/debug but no -it flags
out="$T/exec.out"
mkproj "$T/exec" "$out"
exec_pj() {
	( cd "$T/exec" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" \
		"$P" exec "${@}" )
}
exec_pj foo go version >/dev/null 2>&1
check "exec runs podman" "1" "$([ -s "$out" ] && echo 1 || echo 0)"
check "exec has no -it flags" "0" "$(grep -cE '^-(i|t)+$' "$out")"
check "exec runs the given command" "go
version" "$(grep -A2 '^pi-jail:latest$' "$out" | tail -2)"
exec_pj >/dev/null 2>&1
check "exec without args is usage error" "2" "$?"

# --- open/debug are interactive; exec is not -----------------------------------
# given: a stubbed podman
# when: pj open or pj debug runs
# then: both pass -it - without a tty, pi and bash exit immediately
out="$T/tty.out"
mkproj "$T/tty" "$out"
for command in open debug; do
	: >"$out"
	( cd "$T/tty" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" \
		"$P" "$command" foo ) >/dev/null 2>&1
	check "$command attaches -it" "1" "$(grep -c '^-it$' "$out")"
done

# --- go recipe: discovery, apply, verify --------------------------------------
# given: a fake host Go installation and a stubbed pj
# when: recipes/go.sh runs
# then: it discovers go, prompts before writing config, and verifies in-jail
GOROOT_FAKE="$T/goroot"
mkdir -p "$GOROOT_FAKE/bin" "$GOROOT_FAKE/pkg" "$GOROOT_FAKE/src"
cat >"$GOROOT_FAKE/bin/go" <<EOF
#!/bin/sh
case "\$*" in
"env GOROOT") printf '%s\n' "$GOROOT_FAKE" ;;
"env GOVERSION") printf 'go1.99.1\n' ;;
"env GOHOSTOS") printf 'linux\n' ;;
"env GOHOSTARCH") printf 'amd64\n' ;;
esac
EOF
chmod +x "$GOROOT_FAKE/bin/go"
mkrepo "$T/gorec"
adopt "$T/gorec"
GOREC="$T/gorec"
mkdir -p "$GOREC/bin"
ln -s "$(command -v grep)" "$GOREC/bin/grep"
cat >"$GOREC/bin/pj" <<EOF
#!/bin/sh
case "\$1" in
config) printf 'pj config called with: %s\n' "\$*" ;;
exec) printf 'pj exec called with: %s\n' "\$2" ;;
esac
EOF
chmod +x "$GOREC/bin/pj"
go_recipe() { # go_recipe -- runs the go recipe at the project root
	( cd "$GOREC" && PATH="$GOREC/bin:$GOROOT_FAKE/bin" "$OLDPWD/recipes/go.sh" )
}
# no go on the host PATH: fail, point at the install docs
( cd "$GOREC" && PATH="$GOREC/bin" "$OLDPWD/recipes/go.sh" ) \
	</dev/null >"$T/gorec.stdout" 2>&1
check "go recipe fails without host go" "1" "$?"
check "go recipe failure names go" "1" "$(grep -c 'go' "$T/gorec.stdout")"
# declined prompt: clean exit, no config write
go_recipe </dev/null >"$T/gorec.stdout" 2>&1
check "go recipe declined exits 0" "0" "$?"
check "go recipe prompts before writing" "1" "$(grep -c 'Adopt' "$T/gorec.stdout")"
check "go recipe declined writes no config" "0" "$(grep -c 'pj config' "$T/gorec.stdout")"
# accepted: writes the adoption config via pj
go_recipe <<<"y" >"$T/gorec.stdout" 2>&1
check "go recipe accepted calls pj config add" "1" \
	"$(grep -q "pj config called with: config add -v $GOROOT_FAKE:/opt/go:ro -p /opt/go/bin -e GOTOOLCHAIN=local" \
		"$T/gorec.stdout" && echo 1 || echo 0)"
# already adopted: idempotent rerun, no second write
printf '[volumes]\n%s:/opt/go:ro\n' "$GOROOT_FAKE" >"$GOREC/pi-jail.conf"
go_recipe <<<"y" >"$T/gorec.stdout" 2>&1
check "go recipe rerun exits 0" "0" "$?"
check "go recipe rerun skips config write" "0" "$(grep -c 'pj config' "$T/gorec.stdout")"
# verification: PI_JAIL_VERIFY_WS drives pj exec in the jail
( cd "$GOREC" && PATH="$GOREC/bin:$GOROOT_FAKE/bin" \
	PI_JAIL_VERIFY_WS=ws/foo "$OLDPWD/recipes/go.sh" ) <<<"y" >"$T/gorec.stdout" 2>&1
check "go recipe verifies via pj exec" "1" \
	"$(grep -q 'pj exec called with: ws/foo' "$T/gorec.stdout" && echo 1 || echo 0)"
# alias GOROOT (version-manager symlink): refuse, name the path
ln -s "$GOROOT_FAKE" "$T/go-alias"
mkdir -p "$T/aliased-bin"
cat >"$T/aliased-bin/go" <<EOF
#!/bin/sh
case "\$*" in
"env GOROOT") printf '%s\n' "$T/go-alias" ;;
"env GOVERSION") printf 'go1.99.1\n' ;;
"env GOHOSTOS") printf 'linux\n' ;;
"env GOHOSTARCH") printf 'amd64\n' ;;
esac
EOF
chmod +x "$T/aliased-bin/go"
( cd "$GOREC" && PATH="$GOREC/bin:$T/aliased-bin" \
	"$OLDPWD/recipes/go.sh" ) <<<"y" >"$T/gorec.stdout" 2>&1
check "go recipe refuses alias GOROOT" "1" "$?"
check "go recipe alias failure names the path" "1" \
	"$(grep -q "$T/go-alias" "$T/gorec.stdout" && echo 1 || echo 0)"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
