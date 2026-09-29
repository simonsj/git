#!/bin/sh

test_description='explicit delete refspec matching on push

Measure client-side matching of explicit delete refspecs with "git push
--dry-run" against a server that advertises lots of refs.  An empty client
(no local refs) and a mirror client (full local copy of the server refs)
are tested pushing 1, 10, and 100 refspecs each.
'
. ./perf-lib.sh

test_perf_fresh_repo

ref_count=100000

test_expect_success 'create server with many refs and two clients' '
	test_commit base &&
	git clone --bare --ref-format=reftable . server &&
	test_seq -f "create refs/heads/b%d HEAD" $ref_count |
	git -C server update-ref --stdin &&
	git init --bare client_empty &&
	git -C client_empty remote add origin "$PWD/server" &&
	git clone --mirror --ref-format=reftable "$PWD/server" client_mirror &&
	git -C client_mirror config --unset remote.origin.mirror
'

for client in client_empty client_mirror
do
	case "$client" in
	client_empty)
		local_refs=local:empty
		;;
	client_mirror)
		local_refs=local:mirror
		;;
	esac

	for nr_refspecs in 1 10 100
	do
		test_expect_success "create $nr_refspecs refspecs" '
			test_seq -f ":refs/heads/b%d" $nr_refspecs >refspecs
		'

		refs=$(printf '%-13s' "$local_refs")
		refspecs=$(printf '%-12s' "refspecs:$nr_refspecs")
		pad=$(printf '%*s' $((test_count + 1 < 10)) '')
		test_perf "${pad}$refs $refspecs" '
			git -C '"$client"' push --dry-run origin $(cat refspecs)
		'
	done
done

test_done
