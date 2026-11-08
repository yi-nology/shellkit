#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

case "$(os_name)" in
  linux | darwin | other) ;;
  *) _fail "unexpected os_name: $(os_name)" ;;
esac

case "$(os_arch)" in
  x86_64 | aarch64 | other) ;;
  *) _fail "unexpected os_arch: $(os_arch)" ;;
esac

assert_true os_has_cmd bash
assert_false os_has_cmd definitely-not-a-command-shellkit
assert_true os_has_cmd bash sh

d=$(tmpdir)

f="$d/sed.txt"
printf 'a=1\n' >"$f"
os_sed_i 's/a=1/a=2/' "$f"
assert_eq "a=2" "$(cat "$f")" "os_sed_i"

f="$d/abc.txt"
printf 'abc' >"$f"
assert_eq "900150983cd24fb0d6963f7d28e17f72" "$(os_md5 "$f")" "os_md5"
assert_eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(os_sha256 "$f")" "os_sha256"

mgr=$(os_pkg_manager 2>/dev/null || true)
if [ -n "$mgr" ]; then
  case "$mgr" in
    dnf | yum | apt-get | zypper | apk) ;;
    *) _fail "unexpected package manager: $mgr" ;;
  esac
fi
