#!/usr/bin/env bash
# Smoke tests for pj: pi-jail.conf volume mounting + config file ops.
# No root, no podman. jj is faked with stubs except in the graph-shape
# section at the end, which needs a real jj.
#
# Usage: tests/smoke.sh
set -u
cd "$(dirname "$0")/.."

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
mkproj() { # mkproj DIR PODMAN_OUT
	mkdir -p "$1/bin" "$1/home" "$1/shared/home" "$1/shared/project" "$1/ws/foo" \
		"$1/.jj/repo" "$1/.git" "$1/cfg/pi-jail"
	: >"$1/cfg/pi-jail/jail.env"
	for f in models.json mcp.json settings.json; do : >"$1/cfg/pi-jail/$f"; done
	cat >"$1/bin/podman" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >>"$2"
EOF
	chmod +x "$1/bin/podman"
}

rm -rf .smoke-tmp
mkdir .smoke-tmp
trap 'rm -rf .smoke-tmp' EXIT
T=$PWD/.smoke-tmp

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
mkdir -p "$T/c1/.jj" "$T/c1/src"
printf '# top\n[other]\n/a:/b\n\n[foo]\n/old:/old\n' >"$T/c1/pi-jail.conf"
( cd "$T/c1" && "$P" config set foo -v "$T/c1/src:/work/x" -v /tmp:/mnt/tmp:z ) >/dev/null 2>&1
check "set exit code" "0" "$?"
check "set replaces section lines" \
	"$T/c1/src:/work/x
/tmp:/mnt/tmp:z" "$(conf "$T/c1" foo)"
check "set preserves other section" "/a:/b" "$(conf "$T/c1" other)"
check "set preserves comment" "1" "$(grep -c '^# top' "$T/c1/pi-jail.conf")"

# set: creates the section in a new file
mkdir -p "$T/c2/.jj" "$T/c2/a" "$T/c2/c"
( cd "$T/c2" && "$P" config set foo -v "$T/c2/a:/b" ) >/dev/null 2>&1
check "set exit code (new file)" "0" "$?"
check "set creates section" "$T/c2/a:/b" "$(conf "$T/c2" foo)"

# add: appends to existing section
( cd "$T/c2" && "$P" config add foo -v "$T/c2/c:/d" ) >/dev/null 2>&1
check "add exit code" "0" "$?"
check "add appends" "$T/c2/a:/b
$T/c2/c:/d" "$(conf "$T/c2" foo)"

# add: creates section, keeps others
mkdir -p "$T/c3/.jj" "$T/c3/one" "$T/c3/three"
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
mkdir -p "$T/c4/.jj"
( cd "$T/c4" && "$P" config set foo -v "$T/c4/no:/mnt" ) >/dev/null 2>&1
check "write rejects missing src" "1" "$?"

# --- pj drop removes the section ----------------------------------------------
mkdir -p "$T/c5/.jj" "$T/c5/a" "$T/c5/c"
printf '[foo]\n%s/a:/b\n[bar]\n%s/c:/d\n' "$T/c5" "$T/c5" >"$T/c5/pi-jail.conf"
mkdir -p "$T/c5/.jj"
cat >"$T/c5/jj" <<'EOF'
#!/bin/sh
[ "$1 $2" = "workspace remove" ] && exit 0
exit 0
EOF
chmod +x "$T/c5/jj"
( cd "$T/c5" && PATH="$PWD:$PATH" "$P" drop --force foo ) >/dev/null 2>&1
check "drop removes section" "" "$(conf "$T/c5" foo)"
check "drop keeps other sections" "$T/c5/c:/d" "$(conf "$T/c5" bar)"

# --- pj new/uninit graph shape (real jj) ---------------------------------------
if command -v jj >/dev/null 2>&1; then

	# given: an adopted repo whose root @ is the usual vacuous placeholder
	# (empty, no description) on top of described history
	# when: a workspace is created
	# then: its working copy sits on the described history, not on the vacuous
	# root @ - basing on it bakes an empty commit into the landed history
	R=$T/graph
	mkdir "$R"
	(cd "$R" && jj git init --colocate) >/dev/null 2>&1
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	(cd "$R" && "$P" init) >/dev/null 2>&1
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
	mkdir "$R"
	(cd "$R" && jj git init --colocate) >/dev/null 2>&1
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	(cd "$R" && echo wip >wip) >/dev/null 2>&1
	(cd "$R" && "$P" init) >/dev/null 2>&1
	(cd "$R" && "$P" new task) >/dev/null 2>&1
	check "new includes the root's unlanded work" \
		"1" "$([ -f "$R/ws/task/wip" ] && echo 1 || echo 0)"

	# given: an adopted repo whose empty root @ carries a description
	# when: a workspace is created
	# then: it bases on the described marker commit, not beside it
	R=$T/marker
	mkdir "$R"
	(cd "$R" && jj git init --colocate) >/dev/null 2>&1
	(cd "$R" && echo base >base && jj commit -m base) >/dev/null 2>&1
	(cd "$R" && jj describe -m marker) >/dev/null 2>&1
	(cd "$R" && "$P" init) >/dev/null 2>&1
	(cd "$R" && "$P" new task) >/dev/null 2>&1
	check "new bases on a described (empty) root @" \
		"$(cd "$R" && jj log -r @ --no-graph -T commit_id)" \
		"$(cd "$R/ws/task" && jj log -r @- --no-graph -T commit_id)"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
