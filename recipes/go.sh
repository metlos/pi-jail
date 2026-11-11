#!/bin/sh
# pi-jail recipe: adopt the host's Go installation into this project's jail.
#
# Mounts one verified host GOROOT read-only at /opt/go and prepends its bin to
# the jail PATH. Prompts before writing config; verifies in a workspace's jail
# when run via `pj inject go --verify <ws/name>` (PI_JAIL_VERIFY_WS).
set -u

die() {
	echo "go recipe: $*" >&2
	exit 1
}

note() {
	echo "go recipe: $*"
}

command -v go >/dev/null 2>&1 || die "no go on the host PATH - install Go first (https://go.dev/doc/install)"

goroot=$(GOTOOLCHAIN=local go env GOROOT) || die "go env GOROOT failed"
version=$(GOTOOLCHAIN=local go env GOVERSION) || die "go env GOVERSION failed"
hostos=$(GOTOOLCHAIN=local go env GOHOSTOS) || die "go env GOHOSTOS failed"
hostarch=$(GOTOOLCHAIN=local go env GOHOSTARCH) || die "go env GOHOSTARCH failed"

# A version-manager alias is mutable: host upgrades change the toolchain under
# running builds. Refuse and ask for an immutable version directory. A symlink
# GOROOT (version-manager shim) or a mutable name (current/latest/...) is not
# an immutable version directory.
if [ -L "$goroot" ]; then
	realpath=$(command -v realpath >/dev/null 2>&1 && realpath "$goroot" || echo "$goroot")
	die "GOROOT is a symlink (version-manager alias?): $goroot
resolved to: $realpath
mount an immutable version directory instead (see your version manager's store path)"
fi
case $goroot in
*/current | */current/* | */latest | */latest/* | */stable | */stable/*)
	die "GOROOT looks like a mutable version-manager alias: $goroot
mount an immutable version directory instead (see your version manager's store path)"
	;;
esac

# A usable installation carries the toolchain binaries and standard-library
# sources; a split distro layout cannot be covered by one GOROOT mount.
[ -x "$goroot/bin/go" ] || die "GOROOT has no go binary: $goroot"
[ -d "$goroot/pkg" ] || die "GOROOT has no pkg tree: $goroot"
[ -d "$goroot/src" ] || die "GOROOT has no standard-library sources: $goroot"
[ -x "$(command -v go)" ] || true

[ "$hostos" = linux ] || die "host Go targets $hostos, not linux; the jail is a Linux userspace"
case $hostarch in
amd64 | arm64) ;;
*) die "unsupported host Go architecture: $hostarch" ;;
esac

# Idempotent rerun: the installation is already adopted.
if grep -q "^$goroot:/opt/go:ro$" pi-jail.conf 2>/dev/null; then
	note "$version at $goroot is already adopted; nothing to do"
else
	echo
	echo "Adopt $version at $goroot (mounted read-only at /opt/go, PATH prepended, GOTOOLCHAIN=local)?"
	printf 'Write the project config? [y/N] '
	read -r answer || answer=
	case $answer in
	y | Y | yes) ;;
	*) note "declined; no config written" && exit 0 ;;
	esac
	if ! pj config add -v "$goroot:/opt/go:ro" -p /opt/go/bin -e GOTOOLCHAIN=local; then
		die "pj config add failed; no config written"
	fi
	note "adopted $version: $goroot -> /opt/go (read-only)"
fi

# Verification (skip unless asked): resolve go in the jail, confirm it is the
# adopted installation, and exercise compile+link+run past `go version`.
if [ -n "${PI_JAIL_VERIFY_WS:-}" ]; then
	ws=$PI_JAIL_VERIFY_WS
	note "verifying in jail workspace $ws"
	ok=1
	check() { # check DESC CMD...
		desc=$1
		shift
		if out=$(pj exec "$ws" "$@" 2>&1); then
			echo "  ok: $desc ($out)"
		else
			echo "  FAIL: $desc ($out)" >&2
			ok=0
		fi
	}
	check "go resolves to the mounted installation" sh -c 'x=$(command -v go) && [ "$x" = /opt/go/bin/go ]'
	check "go version reports the adopted toolchain" sh -c 'go version | grep -qF "$(GOTOOLCHAIN=local go env GOVERSION)"'
	check "GOROOT is the mount, GOTOOLCHAIN local, caches in the jail home" \
		sh -c '[ "$(go env GOROOT)" = /opt/go ] && [ "$(go env GOTOOLCHAIN)" = local ] &&
			case "$(go env GOCACHE)$(go env GOMODCACHE)" in /home/*) exit 0 ;; esac; exit 1'
	check "compile, link and run a standard-library test binary" \
		go test -run '^$' fmt
	if [ "$ok" -eq 1 ]; then
		note "verification passed in $ws"
	else
		note "verification failed in $ws; the config was written, fix and re-verify:
  - check the mount in pj config output
  - inspect the jail by hand: pj debug $ws
  - SELinux denials on the mount: see the pi-jail README's volume section"
		exit 1
	fi
fi
