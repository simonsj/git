#!/bin/sh

test_description='performance of push with many remote refs

Build a bare server with many refs, clone it, and time "git push --dry-run"
for a growing number of delete refspecs. Each count is timed twice, once as a
plain push and once with --force-with-lease for every refspec, since the two
exercise different client-side scans. The dry run does all of the matching
but changes nothing, so every repetition measures the same work.
'
. ./perf-lib.sh

test_perf_fresh_repo

ref_count=20000

test_expect_success 'create server with many refs and clone it' '
	test_commit base &&
	git clone --bare . server &&
	test_seq -f "create refs/heads/b%d HEAD" $ref_count |
	git -C server update-ref --stdin &&
	git clone server client
'

for nr_refspecs in 1 256 1024 4096 16384
do
	test_expect_success "create $nr_refspecs refspecs" '
		oid=$(git -C server rev-parse HEAD) &&
		test_seq -f ":refs/heads/b%d" $nr_refspecs >refspecs &&
		test_seq -f "--force-with-lease=refs/heads/b%d:$oid" \
			$nr_refspecs >leases
	'

	test_perf "push --dry-run ($nr_refspecs refspecs)" '
		git -C client push --dry-run origin $(cat refspecs)
	'

	test_perf "push --dry-run --force-with-lease ($nr_refspecs refspecs)" '
		git -C client push --dry-run origin $(cat leases) $(cat refspecs)
	'
done

test_done
