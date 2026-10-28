#!/bin/sh

test_description='pack index v3 has no fanout table'

. ./test-lib.sh

GIT_TEST_MULTI_PACK_INDEX=0
GIT_TEST_MULTI_PACK_INDEX_WRITE_BITMAP=0
GIT_TEST_MULTI_PACK_INDEX_WRITE_INCREMENTAL=0

test_expect_success 'multi-pack-index write reads pack index v3' '
	test_commit one &&
	git rev-list --objects --all >in &&
	git pack-objects --index-version=3 .git/objects/pack/pack <in &&
	git multi-pack-index write &&
	git multi-pack-index verify
'

test_expect_success !WITH_BREAKING_CHANGES 'pack-redundant reads objects from pack index v3' '
	git init --bare redundant.git &&
	echo a >a.txt &&
	echo b >b.txt &&
	git -C redundant.git hash-object -w --stdin <a.txt >a &&
	git -C redundant.git hash-object -w --stdin <b.txt >b &&
	cat a b >both &&
	v2=$(git -C redundant.git pack-objects --index-version=2 \
		objects/pack/pack <a) &&
	git -C redundant.git pack-objects --index-version=3 \
		objects/pack/pack <both >/dev/null &&
	git -C redundant.git pack-redundant --i-still-use-this --all \
		</dev/null >out &&
	test_line_count = 2 out &&
	test_grep "pack-$v2.pack" out
'

test_done
