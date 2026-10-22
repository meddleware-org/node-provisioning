#!/usr/bin/env bash
# Unit tests for schema types (lib/config.sh) and the strict file parser.
source "$(dirname "$0")/lib.sh"
NP_LIB="${ROOT}/lib"
# shellcheck source=../lib/log.sh
source "${NP_LIB}/log.sh"
# shellcheck source=../lib/config.sh
source "${NP_LIB}/config.sh"

good() { check "type ${1} accepts '${2}'" np_check_type "$1" "$2"; }
nope() { check "type ${1} rejects '${2}'" bash -c '! np_check_type "$0" "$1"' "$1" "$2"; }
export -f np_check_type np_is_ipv4

good ipv4 192.0.2.10;      nope ipv4 192.0.2.256;   nope ipv4 192.0.2.01;   nope ipv4 192.0.2
good cidr4 192.0.2.0/24;   nope cidr4 192.0.2.0/33; nope cidr4 192.0.2.0
good host node1;           good host a.example.invalid; nope host 'a b';       nope host '-bad'
good serial ExampleVendor_Disk_500GB_EX00000001_1; nope serial 'abc*'; nope serial 'ab?d1'; nope serial 'ab[1]x'; nope serial abc
good user admin;           nope user Admin;         nope user 'a;b'
good size 50G;             nope size 50;            nope size 0G
good int 1000;             nope int -1
good bool true;            nope bool yes
good text registry.k8s.io/pause:3.10.2; nope text 'a@@b'; nope text 'a"b'; nope text 'a$(x)'
good version 1.36.3;       nope version 1.36
good tz Europe/London;     nope tz 'Europe/../x'
good enum:abort,offline-install abort; nope enum:abort,offline-install other
good list:text 'a,b,c';    good list:text '';       nope list:ipv4 '192.0.2.1,bad'

# parser: unknown key / duplicate / malformed / whitespace / CRLF
# shellcheck disable=SC2034  # reset for the parser tests; read by lib/config.sh
declare -gA NP_TYPE=() NP_REQ=() NP_DEF=() NP_SECRET=() NP_SCOPE=() CFG=()
np_schema_load "${ROOT}/schema/site.schema.tsv" site
f="${T_TMP}/s.env"
try() { # content -> status of np_load_file in a subshell
  printf '%b' "$1" >"${f}"
  ( np_load_file "${f}" site "${T_TMP}" ) >/dev/null 2>&1
}
check "parser accepts a valid key"        try 'ADMIN_USER=admin\n'
check "parser accepts comments and blanks" try '# c\n\nADMIN_USER=admin\n'
check "parser strips CRLF line endings"   try 'ADMIN_USER=admin\r\n'
for case in 'FOO=bar\n' 'HOSTNAME=node1\n' 'ADMIN_USER=a\nADMIN_USER=b\n' 'not a pair\n' 'ADMIN_USER= admin\n' 'ADMIN_USER=Admin\n' 'lower=x\n'; do
  if try "${case}"; then bad "parser rejects ${case%%\\n*}"; else ok "parser rejects ${case%%\\n*}"; fi
done
finish
