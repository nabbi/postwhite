#!/usr/bin/env bash
#
# Test postwhite and scrape_yahoo without spf-tools, Postfix or network access.
#
# Each test runs the script in a scratch directory whose bin/ holds only the
# system utilities the scripts need, fake despf.sh, postmap and curl commands,
# and whichever summarizers the test asks for.
#
#   AGGREGATE_CIDR=/path   aggregate-cidr to test (default: found on PATH)
#   PERL_AGGREGATE=/path   aggregateCIDR.pl to test (default: found on PATH)
#   REQUIRE_TOOLS=1        fail, rather than skip, tests needing a missing tool
#
# Usage: tests/run.sh [name-pattern]

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
pattern=${1:-}

rust=${AGGREGATE_CIDR:-$(command -v aggregate-cidr || true)}
perl_tool=${PERL_AGGREGATE:-$(command -v aggregateCIDR.pl || true)}

passed=0
failed=0
skipped=0

# scratch space under the repo rather than /tmp: fake commands must be
# executable, and /tmp is often mounted noexec
scratch="$here/.work/$$"
rm -rf "$scratch"
mkdir -p "$scratch"
trap 'rm -rf "$scratch"' EXIT

utils="bash env which mktemp basename dirname cut expr grep sed sort sleep \
	cat uniq wc date rm perl tr head find mv chmod id"

# sandbox [name]: create $sb with bin/, spf/, hosts/, out/ and tmp/, named
# after the calling test by default
sandbox() {
	sb="$scratch/${1:-${FUNCNAME[1]}}"
	mkdir -p "$sb/bin" "$sb/spf" "$sb/hosts" "$sb/out" "$sb/tmp"
	for u in $utils; do
		p=$(command -v "$u") && ln -s "$p" "$sb/bin/$u"
	done

	cat > "$sb/spf/despf.sh" <<-'EOF'
	#!/usr/bin/env bash
	# print the SPF entries recorded for host $1
	cat "$(dirname "$0")/../hosts/$1" 2>/dev/null || true
	EOF
	cat > "$sb/bin/postmap" <<-'EOF'
	#!/usr/bin/env bash
	echo "$@" >> "$(dirname "$0")/../postmap.log"
	EOF
	chmod +x "$sb/spf/despf.sh" "$sb/bin/postmap"

	cat > "$sb/postwhite.conf" <<-EOF
	spftoolspath=$sb/spf
	postfixpath=$sb/out
	postfixbinarypath=$sb/bin
	allowlist=allow.cidr
	denylist=deny.cidr
	yahoo_static_hosts=$sb/yahoo.txt
	custom_hosts=""
	include_yahoo="no"
	enable_denylist=no
	denylist_hosts=""
	reload_postfix=no
	EOF
}

# use <tool-name> <path>: put a summarizer on the sandbox PATH
use() {
	ln -s "$2" "$sb/bin/$1"
}

# conf <line>: append a config option, overriding the defaults above
conf() {
	echo "$1" >> "$sb/postwhite.conf"
}

# run_script <script> [args]: run with only the sandbox on PATH, giving up
# after a minute in case it hangs
run_script() {
	local script=$1
	shift
	(cd "$sb" && timeout 60 env -i PATH="$sb/bin" HOME="$sb" TMPDIR="$sb/tmp" \
		bash "$repo/$script" "$@") > "$sb/stdout" 2>&1
	status=$?
}

run_postwhite() {
	run_script postwhite "$sb/postwhite.conf"
}

# rules <file>: the table without its generated header comments
rules() {
	grep -v '^#' "$1"
}

fail() {
	echo "  $*"
	ok=0
}

assert_status() {
	[ "$status" -eq "$1" ] || fail "exit status $status, expected $1"
}

assert_output() {
	grep -qF -- "$1" "$sb/stdout" || fail "output lacks: $1"
}

assert_no_temp_files() {
	[ -z "$(ls -A "$sb/tmp")" ] || fail "temp files left: $(ls -A "$sb/tmp")"
}

# assert_rules <file> <expected>: compare a table's rules
assert_rules() {
	local got
	got=$(rules "$1" 2>/dev/null)
	if [ "$got" != "$2" ]; then
		fail "rules in $(basename "$1") differ:"
		diff <(echo "$2") <(echo "$got") | sed 's/^/    /'
	fi
}

skip() {
	skip_reason=$1
}

# needs <var>...: skip unless each named summarizer path is set
needs() {
	for v in "$@"; do
		if [ -z "${!v}" ]; then
			skip "${v} not found"
		fi
	done
}

test_case() {
	local name=$1
	# shellcheck disable=SC2053 # the pattern is a glob
	if [ -n "$pattern" ] && [[ $name != $pattern ]]; then
		return
	fi
	ok=1
	skip_reason=
	"$name"
	if [ -n "$skip_reason" ]; then
		if [ -n "${REQUIRE_TOOLS:-}" ]; then
			echo "FAIL $name: $skip_reason (REQUIRE_TOOLS is set)"
			failed=$((failed + 1))
		else
			echo "skip $name: $skip_reason"
			skipped=$((skipped + 1))
		fi
	elif [ "$ok" -eq 1 ]; then
		echo "ok   $name"
		passed=$((passed + 1))
	else
		echo "FAIL $name"
		echo "  --- output:"
		sed 's/^/  | /' "$sb/stdout"
		failed=$((failed + 1))
	fi
}

# mailer fixtures: adjacent prefixes merge, /32 hosts print bare, invalid
# entries are dropped, and duplicates across hosts collapse
mailers() {
	printf '%s\n' ip4:192.0.2.0/25 ip4:192.0.2.128/25 ip4:198.51.100.7/32 \
		ip4:300.1.1.1 ip6:2001:db8::/33 ip6:2001:db8:8000::/33 \
		> "$sb/hosts/google.com"
	printf '%s\n' ip4:198.51.100.7 ip4:203.0.113.0/24 > "$sb/hosts/example.org"
	conf 'custom_hosts="example.org"'
}

expected_allow=$(printf '%s\tpermit\n' 192.0.2.0/24 198.51.100.7 \
	203.0.113.0/24 2001:db8::/32)

# --- tool selection

prefers_aggregate_cidr() {
	needs rust perl_tool
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregate-cidr "$rust"
	use aggregateCIDR.pl "$perl_tool"
	run_postwhite
	assert_status 0
	assert_output "summarization using $sb/bin/aggregate-cidr..."
}
test_case prefers_aggregate_cidr

falls_back_to_perl() {
	needs perl_tool
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregateCIDR.pl "$perl_tool"
	run_postwhite
	assert_status 0
	assert_output "summarization using $sb/bin/aggregateCIDR.pl..."
}
test_case falls_back_to_perl

no_summarizer_is_fatal() {
	sandbox
	run_postwhite
	assert_status 1
	assert_output "fatal: unable to locate aggregate-cidr or aggregateCIDR.pl"
	[ ! -e "$sb/out/allow.cidr" ] || fail "allowlist written"
}
test_case no_summarizer_is_fatal

# --- config file

missing_config_with_space() {
	sandbox
	printf '#!/usr/bin/env bash\ncat\n' > "$sb/bin/aggregate-cidr"
	chmod +x "$sb/bin/aggregate-cidr"
	run_script postwhite "$sb/my conf/postwhite.conf"
	assert_status 1
	assert_output "Can't find $sb/my conf/postwhite.conf"
}
test_case missing_config_with_space

# --- allowlist and denylist, with each summarizer

allowlist_with() {
	sandbox "${FUNCNAME[1]}"
	use "$1" "$2"
	mailers
	run_postwhite
	assert_status 0
	assert_rules "$sb/out/allow.cidr" "$expected_allow"
	assert_output "Writing 4 allowlist rules"
	grep -qx '#     4 total rules\|# 4 total rules' "$sb/out/allow.cidr" ||
		fail "rule count header missing"
	[ "$(cat "$sb/postmap.log")" = "$sb/out/allow.cidr" ] ||
		fail "postmap ran with: $(cat "$sb/postmap.log")"
	assert_no_temp_files
}

allowlist_rust() {
	needs rust
	[ -n "$skip_reason" ] || allowlist_with aggregate-cidr "$rust"
}
test_case allowlist_rust

allowlist_perl() {
	needs perl_tool
	[ -n "$skip_reason" ] || allowlist_with aggregateCIDR.pl "$perl_tool"
}
test_case allowlist_perl

denylist_rust() {
	needs rust
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregate-cidr "$rust"
	mailers
	printf '%s\n' ip4:233.252.0.0/25 ip4:233.252.0.128/25 > "$sb/hosts/spam.test"
	conf 'enable_denylist=yes'
	conf 'denylist_hosts="spam.test"'
	run_postwhite
	assert_status 0
	assert_rules "$sb/out/allow.cidr" "$expected_allow"
	assert_rules "$sb/out/deny.cidr" "$(printf '233.252.0.0/24\treject')"
	grep -qx "$sb/out/deny.cidr" "$sb/postmap.log" || fail "postmap skipped denylist"
	assert_no_temp_files
}
test_case denylist_rust

# --- hardening

# passthrough: a summarizer that accepts every entry, so postwhite's own
# checks are what stand between DNS and the tables
passthrough() {
	printf '#!/usr/bin/env bash\ncat\n' > "$sb/bin/aggregate-cidr"
	chmod +x "$sb/bin/aggregate-cidr"
}

config_is_not_code() {
	sandbox
	passthrough
	mailers
	# shellcheck disable=SC2016 # expansions are for postwhite, not us
	conf 'custom_hosts="$(touch pwned) example.org"'
	conf 'aggregateCIDR=false'
	conf 'permit_line_v4=%s\tOK\n'
	run_postwhite
	assert_status 0
	[ ! -e "$sb/pwned" ] || fail "config ran a command"
	assert_output "ignoring unknown setting aggregateCIDR"
	# shellcheck disable=SC2016
	assert_output 'Skipping invalid host name: $(touch'
	grep -q 'permit$' "$sb/out/allow.cidr" || fail "config replaced the rule format"
}
test_case config_is_not_code

world_writable_config_refused() {
	sandbox
	passthrough
	chmod o+w "$sb/postwhite.conf"
	run_postwhite
	assert_status 1
	assert_output "is world-writable"
	[ ! -e "$sb/out/allow.cidr" ] || fail "allowlist written"
}
test_case world_writable_config_refused

table_name_stays_in_postfixpath() {
	sandbox
	passthrough
	conf 'allowlist=../escaped.cidr'
	run_postwhite
	assert_status 1
	assert_output "allowlist must be a file name"
	[ ! -e "$sb/escaped.cidr" ] || fail "table written outside postfixpath"
}
test_case table_name_stays_in_postfixpath

# despf.sh must never see a host name it could take for an option
host_names_checked() {
	sandbox
	passthrough
	mailers
	cat > "$sb/spf/despf.sh" <<-'EOF'
	#!/usr/bin/env bash
	echo "$1" >> "$(dirname "$0")/../despf.log"
	cat "$(dirname "$0")/../hosts/$1" 2>/dev/null || true
	EOF
	conf 'custom_hosts="-x example.org"'
	run_postwhite
	assert_status 0
	assert_output "Skipping invalid host name: -x"
	! grep -qx -- -x "$sb/despf.log" || fail "despf.sh ran with -x"
	grep -qx example.org "$sb/despf.log" || fail "example.org not queried"
}
test_case host_names_checked

# entries from DNS or the Yahoo! list can't add fields or rules to a table
entries_are_addresses_only() {
	sandbox
	passthrough
	printf '%s\n' 'ip4:192.0.2.1	reject' 'ip4:192.0.2.2,198.51.100.1' \
		ip4:192.0.2.3 > "$sb/hosts/google.com"
	printf 'ip4:203.0.113.1\nnot-an-entry\n' > "$sb/yahoo.txt"
	conf 'include_yahoo="yes"'
	run_postwhite
	assert_status 0
	assert_rules "$sb/out/allow.cidr" "$(printf '%s\tpermit\n' 192.0.2.3 203.0.113.1)"
}
test_case entries_are_addresses_only

# a symlink planted at a table's name is replaced, never written through
table_symlink_not_followed() {
	sandbox
	passthrough
	mailers
	echo precious > "$sb/victim"
	ln -s "$sb/victim" "$sb/out/allow.cidr"
	run_postwhite
	assert_status 0
	[ "$(cat "$sb/victim")" = precious ] || fail "wrote through the symlink"
	{ [ -f "$sb/out/allow.cidr" ] && [ ! -L "$sb/out/allow.cidr" ]; } ||
		fail "allowlist is not a regular file"
	[ -n "$(find "$sb/out/allow.cidr" -perm 0644)" ] ||
		fail "allowlist mode: $(ls -l "$sb/out/allow.cidr")"
	[ -z "$(find "$sb/out" -name '.allow.cidr.*')" ] || fail "temp table left"
}
test_case table_symlink_not_followed

# cron can't answer a password prompt, so sudo must not ask for one
reload_without_prompting() {
	sandbox
	passthrough
	mailers
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/sudo.log"\n' "$sb" > "$sb/bin/sudo"
	printf '#!/usr/bin/env bash\necho "$@" >> "%s/postfix.log"\n' "$sb" > "$sb/bin/postfix"
	chmod +x "$sb/bin/sudo" "$sb/bin/postfix"
	conf 'reload_postfix=yes'
	run_postwhite
	assert_status 0
	if [ "$(id -u)" -eq 0 ]; then
		[ "$(cat "$sb/postfix.log")" = reload ] || fail "postfix not reloaded"
	else
		[ "$(cat "$sb/sudo.log")" = "-n $sb/bin/postfix reload" ] ||
			fail "sudo ran with: $(cat "$sb/sudo.log")"
	fi
}
test_case reload_without_prompting

# both summarizers give the same tables from the bundled Yahoo! list
yahoo_parity() {
	needs rust perl_tool
	[ -n "$skip_reason" ] && return
	local tool tables=()
	for tool in aggregate-cidr aggregateCIDR.pl; do
		sandbox "${FUNCNAME[0]}-$tool"
		use "$tool" "$([ "$tool" = aggregate-cidr ] && echo "$rust" || echo "$perl_tool")"
		cp "$repo/yahoo_static_hosts.txt" "$sb/yahoo.txt"
		conf 'include_yahoo="yes"'
		run_postwhite
		assert_status 0
		tables+=("$(rules "$sb/out/allow.cidr")")
	done
	[ "$(echo "${tables[0]}" | wc -l)" -gt 100 ] || fail "too few Yahoo! rules"
	[ "${tables[0]}" = "${tables[1]}" ] || fail "allowlists differ between tools"
}
test_case yahoo_parity

# BusyBox ps ignores its PID argument and always succeeds, so waiting on it
# for the summarizer to finish would never end
busybox_ps() {
	needs rust
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregate-cidr "$rust"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/bin/ps"
	chmod +x "$sb/bin/ps"
	mailers
	run_postwhite
	assert_status 0
	assert_rules "$sb/out/allow.cidr" "$expected_allow"
}
test_case busybox_ps

# a failing summarizer must not replace the tables with empty ones
summarizer_failure_keeps_tables() {
	sandbox
	cat > "$sb/bin/aggregate-cidr" <<-'EOF'
	#!/usr/bin/env bash
	cat > /dev/null
	echo "aggregate-cidr: read error" >&2
	exit 1
	EOF
	chmod +x "$sb/bin/aggregate-cidr"
	mailers
	printf '# old\n192.0.2.1\tpermit\n' > "$sb/out/allow.cidr"
	run_postwhite
	[ "$status" -ne 0 ] || fail "exit status 0 after summarizer failed"
	assert_rules "$sb/out/allow.cidr" "$(printf '192.0.2.1\tpermit')"
	[ ! -e "$sb/postmap.log" ] || fail "postmap ran"
	assert_no_temp_files
}
test_case summarizer_failure_keeps_tables

# --- scrape_yahoo

scrape_with() {
	sandbox "${FUNCNAME[1]}"
	use "$1" "$2"
	cat > "$sb/bin/curl" <<-'EOF'
	#!/usr/bin/env bash
	echo '<td>192.0.2.0/25</td><td>192.0.2.128/25</td><td>198.51.100.0/24</td>'
	# hosts listed without a prefix
	echo '<td>203.0.113.8</td><td>203.0.113.9</td><td>203.0.113.20</td>'
	EOF
	chmod +x "$sb/bin/curl"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 0
	[ "$(cat "$sb/yahoo.txt")" = "$(printf 'ip4:%s\n' 192.0.2.0/24 198.51.100.0/24 \
		203.0.113.8/31 203.0.113.20)" ] ||
		fail "yahoo list: $(cat "$sb/yahoo.txt")"
}

scrape_yahoo_rust() {
	needs rust
	[ -n "$skip_reason" ] || scrape_with aggregate-cidr "$rust"
}
test_case scrape_yahoo_rust

scrape_yahoo_perl() {
	needs perl_tool
	[ -n "$skip_reason" ] || scrape_with aggregateCIDR.pl "$perl_tool"
}
test_case scrape_yahoo_perl

scrape_yahoo_summarizer_failure() {
	sandbox
	cat > "$sb/bin/aggregate-cidr" <<-'EOF'
	#!/usr/bin/env bash
	cat > /dev/null
	exit 1
	EOF
	cat > "$sb/bin/curl" <<-'EOF'
	#!/usr/bin/env bash
	echo '<td>192.0.2.0/25</td>'
	EOF
	chmod +x "$sb/bin/aggregate-cidr" "$sb/bin/curl"
	echo 'ip4:192.0.2.1' > "$sb/yahoo.txt"
	run_script scrape_yahoo "$sb/postwhite.conf"
	[ "$status" -ne 0 ] || fail "exit status 0 after summarizer failed"
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.1 ] || fail "yahoo list changed"
}
test_case scrape_yahoo_summarizer_failure

# fake_curl <page>: serve <page> as every download
fake_curl() {
	printf '#!/usr/bin/env bash\necho %q\n' "$1" > "$sb/bin/curl"
	chmod +x "$sb/bin/curl"
}

# addresses outside the table, such as in scripts, are not mailers
scrape_yahoo_reads_table_cells() {
	needs rust
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregate-cidr "$rust"
	fake_curl '<script>var n="203.0.113.0/24";</script><table><tr><td class="ip">192.0.2.0/24</td></tr></table>'
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 0
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.0/24 ] ||
		fail "yahoo list: $(cat "$sb/yahoo.txt")"
}
test_case scrape_yahoo_reads_table_cells

# a page with no addresses, such as after a redesign, must not empty the list
scrape_yahoo_nothing_found() {
	sandbox
	printf '#!/usr/bin/env bash\ncat\n' > "$sb/bin/aggregate-cidr"
	chmod +x "$sb/bin/aggregate-cidr"
	fake_curl '<p>Moved to 192.0.2.0/24</p>'
	echo 'ip4:192.0.2.1' > "$sb/yahoo.txt"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 1
	assert_output "fatal: no IPv4 addresses found at"
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.1 ] || fail "yahoo list changed"
}
test_case scrape_yahoo_nothing_found

# IPv6 networks keep their prefix length and use SPF's ip6: mechanism
scrape_yahoo_ipv6() {
	needs rust
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregate-cidr "$rust"
	fake_curl '<td>192.0.2.0/24</td><td>2001:db8::/33</td><td>2001:db8:8000::/33</td><td>2001:db8:1::1</td>'
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 0
	[ "$(cat "$sb/yahoo.txt")" = "$(printf '%s\n' ip4:192.0.2.0/24 ip6:2001:db8::/32)" ] ||
		fail "yahoo list: $(cat "$sb/yahoo.txt")"
}
test_case scrape_yahoo_ipv6

scrape_yahoo_config_with_space() {
	needs rust
	[ -n "$skip_reason" ] && return
	sandbox
	use aggregate-cidr "$rust"
	fake_curl '<td>192.0.2.0/24</td>'
	mkdir "$sb/my conf"
	mv "$sb/postwhite.conf" "$sb/my conf/"
	run_script scrape_yahoo "$sb/my conf/postwhite.conf"
	assert_status 0
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.0/24 ] ||
		fail "yahoo list: $(cat "$sb/yahoo.txt" 2>&1)"
}
test_case scrape_yahoo_config_with_space

scrape_yahoo_no_downloader() {
	sandbox
	printf '#!/usr/bin/env bash\ncat\n' > "$sb/bin/aggregate-cidr"
	chmod +x "$sb/bin/aggregate-cidr"
	echo 'ip4:192.0.2.1' > "$sb/yahoo.txt"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 1
	assert_output "wget or curl required."
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.1 ] || fail "yahoo list changed"
}
test_case scrape_yahoo_no_downloader

scrape_yahoo_no_summarizer() {
	sandbox
	echo 'ip4:192.0.2.1' > "$sb/yahoo.txt"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 1
	assert_output "fatal: unable to locate aggregate-cidr or aggregateCIDR.pl"
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.1 ] || fail "yahoo list changed"
}
test_case scrape_yahoo_no_summarizer

scrape_yahoo_config_is_not_code() {
	sandbox
	passthrough
	fake_curl '<td>192.0.2.0/24</td>'
	# shellcheck disable=SC2016 # expansions are for scrape_yahoo, not us
	conf 'custom_hosts="$(touch pwned)"'
	conf 'aggregateCIDR=false'
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 0
	[ ! -e "$sb/pwned" ] || fail "config ran a command"
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.0/24 ] ||
		fail "yahoo list: $(cat "$sb/yahoo.txt")"
}
test_case scrape_yahoo_config_is_not_code

scrape_yahoo_world_writable_config_refused() {
	sandbox
	passthrough
	fake_curl '<td>192.0.2.0/24</td>'
	echo 'ip4:192.0.2.1' > "$sb/yahoo.txt"
	chmod o+w "$sb/postwhite.conf"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 1
	assert_output "is world-writable"
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.1 ] || fail "yahoo list changed"
}
test_case scrape_yahoo_world_writable_config_refused

# a symlink planted at the list's name is replaced, never written through
scrape_yahoo_symlink_not_followed() {
	sandbox
	passthrough
	fake_curl '<td>192.0.2.0/24</td>'
	echo precious > "$sb/victim"
	ln -s "$sb/victim" "$sb/yahoo.txt"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 0
	[ "$(cat "$sb/victim")" = precious ] || fail "wrote through the symlink"
	{ [ -f "$sb/yahoo.txt" ] && [ ! -L "$sb/yahoo.txt" ]; } ||
		fail "yahoo list is not a regular file"
	[ -n "$(find "$sb/yahoo.txt" -perm 0644)" ] ||
		fail "yahoo list mode: $(ls -l "$sb/yahoo.txt")"
	[ -z "$(find "$sb" -maxdepth 1 -name '.yahoo.txt.*')" ] || fail "temp list left"
}
test_case scrape_yahoo_symlink_not_followed

# a failed download is reported, and leaves the list alone
scrape_yahoo_download_failure() {
	sandbox
	passthrough
	printf '#!/usr/bin/env bash\nexit 22\n' > "$sb/bin/curl"
	chmod +x "$sb/bin/curl"
	echo 'ip4:192.0.2.1' > "$sb/yahoo.txt"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 1
	assert_output "fatal: can't download"
	[ "$(cat "$sb/yahoo.txt")" = ip4:192.0.2.1 ] || fail "yahoo list changed"
}
test_case scrape_yahoo_download_failure

# the download, redirects included, stays on https and has a time limit
scrape_yahoo_https_only() {
	sandbox
	passthrough
	cat > "$sb/bin/curl" <<-EOF
	#!/usr/bin/env bash
	printf '%s\n' "\$@" > "$sb/curl.args"
	echo '<td>192.0.2.0/24</td>'
	EOF
	chmod +x "$sb/bin/curl"
	run_script scrape_yahoo "$sb/postwhite.conf"
	assert_status 0
	local args
	args=$(tr '\n' ' ' < "$sb/curl.args")
	case $args in
		*"--proto =https --proto-redir =https"*"https://"*) ;;
		*) fail "curl ran with: $args" ;;
	esac
	case $args in
		*--max-time*) ;;
		*) fail "no time limit: $args" ;;
	esac
}
test_case scrape_yahoo_https_only

echo
echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
