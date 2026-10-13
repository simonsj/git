#!/bin/sh
#
# divvy.sh -- run a command over files in parallel, preserving output order
#

usage () {
	echo >&2 "usage: $0 <command> [<argument>...] <file-list"
	exit 129
}

run_slice () {
	slice=$1
	shift
	while IFS= read -r file || test -n "$file"
	do
		set -- "$@" "$file"
	done <"$slice.in"
	"$@" >"$slice.out" 2>"$slice.err" &
	cmd_pid=$!
	trap 'kill $cmd_pid 2>/dev/null; exit 1' HUP INT TERM
	wait "$cmd_pid"
}

test $# -gt 0 || usage

if test -n "$NUMBER_OF_PROCESSORS"
then
	jobs=$NUMBER_OF_PROCESSORS
elif ! jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
then
	jobs=1
fi
case "$jobs" in
*[!0-9]*|0*|"")
	jobs=1
	;;
esac

tmp="${TMPDIR:-/tmp}/divvy.$$"
mkdir "$tmp" || exit 1
pids=
trap 'rm -rf "$tmp"' EXIT
trap 'kill $pids 2>/dev/null; exit 1' HUP INT TERM

cat >"$tmp/files" || exit 1
nfiles=$(($(wc -l <"$tmp/files")))
test $nfiles -gt 0 || exit 0

test "$jobs" -le "$nfiles" || jobs=$nfiles
per_slice=$(( (nfiles + jobs - 1) / jobs ))

nslices=0
from=1
while test $from -le $nfiles
do
	nslices=$((nslices + 1))
	end=$((from + per_slice - 1))
	sed -n "${from},${end}p;${end}q" "$tmp/files" \
		>"$tmp/$nslices.in" || exit 1
	run_slice "$tmp/$nslices" "$@" &
	pids="$pids $!"
	from=$((from + per_slice))
done

rc=0
nr=1
for pid in $pids
do
	wait "$pid" || rc=1
	cat "$tmp/$nr.out"
	cat "$tmp/$nr.err" >&2
	nr=$((nr + 1))
done
exit $rc
