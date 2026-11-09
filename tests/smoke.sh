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
check "baseline keeps 7 fixed mounts" "7" "$(vols "$out" | wc -l)"
check "baseline home mount last" \
	"$T/base/shared/home:/home:z" "$(vols "$out" | tail -1)"
check "baseline has no vcs config mounts" "0" "$(vols "$out" | grep -cE ':(/home/.config/jj|/home/.gitconfig|/home/.config/git):ro,z$')"

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

# --- pj open: volumes from pi-jail.conf --------------------------------------
out="$T/vols.out"
mkproj "$T/vols" "$out"
cat >"$T/vols/pi-jail.conf" <<EOF
# comment

[foo]
$T/vols/shared/project:/work/shared/project
/tmp:/mnt/tmp:z
$T/vols/shared/home:/home

[bar]
/should-not-mount:/x
EOF
( cd "$T/vols" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >"$T/vols/stdout" 2>&1
check "3 extra mounts appended" "10" "$(vols "$out" | wc -l)"
check "extra mount after fixed ones" \
	"$T/vols/shared/project:/work/shared/project" "$(vols "$out" | sed -n '8p')"
check "other section not mounted" "0" \
	"$(vols "$out" | grep -c 'should-not-mount')"
check "shadowing mount allowed" "1" "$(vols "$out" | grep -c ':/home$')"
check "startup line lists mounts" "1" \
	"$(grep -c 'extra mounts: .*/work/shared/project /tmp:/mnt/tmp:z .*/home)' "$T/vols/stdout")"

# --- pj open: volume specs with spaces work (bash arrays carry them) --------
out="$T/ws.out"
mkproj "$T/ws" "$out"
mkdir -p "$T/ws/my dir"
printf '[foo]\n%s/my dir:/mnt/dir\n' "$T/ws/" >"$T/ws/pi-jail.conf"
( cd "$T/ws" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >/dev/null 2>&1
check "spaced spec mounted" "1" \
	"$(vols "$out" | grep -c 'my dir:/mnt/dir')"

# --- pj open: missing src rejected --------------------------------------------
out="$T/miss.out"
mkproj "$T/miss" "$out"
printf '[foo]\n%s:/mnt/nope\n' "$T/miss/no-such-src" >"$T/miss/pi-jail.conf"
( cd "$T/miss" && HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/cfg" PATH="$PWD/bin:$PATH" "$OLDPWD/pj" open foo ) >"$T/miss/stdout" 2>"$T/miss/stderr"
check "missing src exit code" "1" "$?"
check "missing src never runs podman" "0" "$([ -e "$out" ] && wc -l <"$out" || echo 0)"
check "missing src error names path" "1" \
	"$(grep -c 'no-such-src' "$T/miss/stderr")"

# --- pj config ----------------------------------------------------------------
P="$T/pj-installed" # run pj as if installed on PATH
cp pj "$P"

# body of a pi-jail.conf section (empty when file or section is missing)
conf() { # conf PROJ SECTION
	awk -v s="[$2]" '$0==s{f=1;next} /^\[/{f=0} f' "$1/pi-jail.conf" 2>/dev/null
}

# set: replaces section, preserves other sections and comments
mkrepo "$T/c1"
adopt "$T/c1"
mkdir -p "$T/c1/src"
printf '# top\n[other]\n/a:/b\n\n[foo]\n/old:/old\n' >"$T/c1/pi-jail.conf"
( cd "$T/c1" && "$P" config set foo -v "$T/c1/src:/work/x" -v /tmp:/mnt/tmp:z ) >/dev/null 2>&1
check "set exit code" "0" "$?"
check "set replaces section lines" \
	"$T/c1/src:/work/x
/tmp:/mnt/tmp:z" "$(conf "$T/c1" foo)"
check "set preserves other section" "/a:/b" "$(conf "$T/c1" other)"
check "set preserves comment" "1" "$(grep -c '^# top' "$T/c1/pi-jail.conf")"

# set: creates the section in a new file
mkrepo "$T/c2"
adopt "$T/c2"
mkdir -p "$T/c2/a" "$T/c2/c"
( cd "$T/c2" && "$P" config set foo -v "$T/c2/a:/b" ) >/dev/null 2>&1
check "set exit code (new file)" "0" "$?"
check "set creates section" "$T/c2/a:/b" "$(conf "$T/c2" foo)"

# add: appends to existing section
( cd "$T/c2" && "$P" config add foo -v "$T/c2/c:/d" ) >/dev/null 2>&1
check "add exit code" "0" "$?"
check "add appends" "$T/c2/a:/b
$T/c2/c:/d" "$(conf "$T/c2" foo)"

# add: creates section, keeps others
mkrepo "$T/c3"
adopt "$T/c3"
mkdir -p "$T/c3/one" "$T/c3/three"
printf '[x]\n%s/1:/2\n' "$T/c3" >"$T/c3/pi-jail.conf"
( cd "$T/c3" && "$P" config add y -v "$T/c3/three:/4" ) >/dev/null 2>&1
check "add creates section" "$T/c3/three:/4" "$(conf "$T/c3" y)"
check "add keeps other section" "$T/c3/1:/2" "$(conf "$T/c3" x)"

# print (runs at the fake repo root)
printf '[foo]\n%s/a:/b\n%s/c:/d\n' "$T/c2" "$T/c2" >"$T/c2/pi-jail.conf"
r="$(cd "$T/c2" && "$P" config foo 2>&1)"
check "print exit code" "0" "$?"
check "print lists lines" "$T/c2/a:/b
$T/c2/c:/d" "$r"

# print of a missing section exits nonzero
r="$(cd "$T/c1" && "$P" config nosuch 2>&1)"
check "print missing section exit code" "1" "$?"

# invalid specs are rejected at write time
mkrepo "$T/c4"
adopt "$T/c4"
( cd "$T/c4" && "$P" config set foo -v "$T/c4/no:/mnt" ) >/dev/null 2>&1
check "write rejects missing src" "1" "$?"

# --- pj locates the repo root from any subdir --------------------------------
# given: pj invoked from a workspace (own .jj) or a plain subdir
# then: root-relative state (pi-jail.conf, mounts) lands at the repo root
out="$T/root.out"
mkproj "$T/root" "$out"
mkdir -p "$T/root/ws/foo/.jj" # real workspaces carry their own .jj
( cd "$T/root/ws/foo" && HOME="$T/root/home" XDG_CONFIG_HOME="$T/root/cfg" PATH="$T/root/bin:$PATH" "$OLDPWD/pj" config set foo -v /tmp:/mnt/tmp:z ) >/dev/null 2>&1
check "config from a workspace writes conf at the repo root" "1" "$([ -f "$T/root/pi-jail.conf" ] && echo 1 || echo 0)"
check "config from a workspace leaves no conf in the cwd" "0" "$([ -e "$T/root/ws/foo/pi-jail.conf" ] && echo 1 || echo 0)"

( cd "$T/root/shared" && HOME="$T/root/home" XDG_CONFIG_HOME="$T/root/cfg" PATH="$T/root/bin:$PATH" "$OLDPWD/pj" open foo ) >/dev/null 2>&1
check "open from a subdir mounts the root's workspace" "$T/root/ws/foo:/work/ws/foo:z" "$(vols "$out" | grep -m1 '/work/ws/foo:z')"

( cd "$T/root/shared" && HOME="$T/root/home" XDG_CONFIG_HOME="$T/root/cfg" PATH="$T/root/bin:$PATH" "$OLDPWD/pj" config set foo -v project:/work/sp ) >/dev/null 2>&1
check "relative -v src resolves against the invocation dir" "$T/root/shared/project:/work/sp" "$(conf "$T/root" foo)"

# given: an unadopted repo in a clean location (no pj layout above it)
# when: config is set from a subdir
# then: the conf lands at the repo's own root (the jj-root fallback)
mkdir -p "$X/plain/.jj/repo" "$X/plain/deep"
( cd "$X/plain/deep" && "$P" config set foo -v /tmp:/mnt ) >/dev/null 2>&1
check "config from a subdir of an unadopted repo uses its jj root" "1" "$([ -f "$X/plain/pi-jail.conf" ] && echo 1 || echo 0)"
check "config from a subdir leaves no conf in the cwd" "0" "$([ -e "$X/plain/deep/pi-jail.conf" ] && echo 1 || echo 0)"

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
check "open ws/name from a workspace still resolves (name fallback)" \
	"$T/cwd/ws/foo:/work/ws/foo:z" "$(vols "$out" | grep -m1 '/work/ws/foo:z')"
open_cwd "$T/cwd" .
check "open . at the root dies (root is not a workspace)" "1" "$?"

# --- pj drop removes the section ----------------------------------------------
mkrepo "$T/c5"
adopt "$T/c5"
(cd "$T/c5" && jj workspace add --colocate ws/foo) >/dev/null 2>&1
mkdir -p "$T/c5/a" "$T/c5/c"
printf '[foo]\n%s/a:/b\n[bar]\n%s/c:/d\n' "$T/c5" "$T/c5" >"$T/c5/pi-jail.conf"
( cd "$T/c5" && "$P" drop --force foo ) >/dev/null 2>&1
check "drop removes section" "" "$(conf "$T/c5" foo)"
check "drop keeps other sections" "$T/c5/c:/d" "$(conf "$T/c5" bar)"

# --- root detection, adoption, graph shape (real jj) ---------------------------
if command -v jj >/dev/null 2>&1; then

	# given: a fresh repo in a clean location (no pj layout above it)
	# when: pj init adopts it
	# then: the root is narrowed and the layout dirs exist
	R=$X/init
	mkrepo "$R"
	(cd "$R" && "$P" init) >/dev/null 2>&1
	check "init narrows the root" "ws" "$(cd "$R" && jj sparse list)"
	check "init creates the layout" "1" \
		"$([ -d "$R/ws" ] && [ -d "$R/shared" ] && echo 1 || echo 0)"

	# given: a full-checkout repo with a ws/ dir nested in an adopted root
	# when: config is set from inside it
	# then: the adopted root above wins - a layout look-alike is not a root
	R=$X/lookalike
	mkrepo "$R"
	adopt "$R"
	D=$R/inner
	mkrepo "$D"
	mkdir "$D/ws"
	( cd "$D" && "$P" config set foo -v /tmp:/mnt ) >/dev/null 2>&1
	check "a full-checkout look-alike is not a root" "1" \
		"$([ -f "$R/pi-jail.conf" ] && echo 1 || echo 0)"
	check "no conf at the look-alike" "0" "$([ -e "$D/pi-jail.conf" ] && echo 1 || echo 0)"

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
	check "open heals the sparse pattern" "." "$(cd "$R/ws/task1" && jj sparse list)"
	check "open rematerializes the files" "1" \
		"$([ -f "$R/ws/task1/base" ] && echo 1 || echo 0)"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
