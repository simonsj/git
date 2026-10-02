# Review: speed up client-side `git push` refspec matching

Branch: `simonsj/self-review/20261001-speedup-client-push-with-refspecs`
Base: `origin/master` (`c46c1e3772`, "Start Git 2.98 cycle")
Commits reviewed (oldest first):

| # | SHA | Subject |
|---|-----|---------|
| 1 | `eaf355508b` | remote: validate --force-with-lease <refname> argument |
| 2 | `f679d82ab3` | t5516: demonstrate push with "./"-prefixed source |
| 3 | `10ec13e5b3` | t5510: test "./"-prefixed branch.<name>.merge values |
| 4 | `33b5e08cc8` | t/perf: add explicit delete refspec matching test |
| 5 | `a348a36cae` | refs: reuse match_parse_rule() in refname_match() |
| 6 | `78135aaeab` | remote: use a strmap for check_push_refs() |
| 7 | `6069da79e5` | remote: use strmap for match_explicit_refs() |

## What I did

- Read every diff and commit message, plus the untracked planning notes
  (`planned-git-commits.md`, `git-push-refname-match-fastpath.md`,
  `commit-message-remote.txt`) for intent.
- Built HEAD in-tree (`make DEVELOPER=1`; cargo target dir had to be pointed
  back at `./target` because the sandbox overrides `CARGO_TARGET_DIR`).
- Ran the three touched regression scripts against the HEAD build:
  `t5533-push-cas.sh` (24/24), `t5516-fetch-push.sh` (130/130),
  `t5510-fetch.sh` (242/242). All pass.
- Did not re-run `p5516`; the timing tables in the messages are the author's.
- Traced the "./" behavior through `mkpath()` -> `cleanup_path()` in `path.c`
  and through every `refname_match()` caller rather than empirically testing
  the pre-series binary.

## TL;DR

No blatant bugs. The C changes are semantically equivalent to the code they
replace (details below), the tests are sound, and the timing tables are
internally consistent across commits.

The main weaknesses are in the prose:

1. **The series contains a user-visible behavior change** (a leading `./` on
   a fully-qualified refname no longer aliases the refname in push refspecs,
   `branch.<name>.merge`, and `--force-with-lease`), and it is introduced by a
   commit whose subject reads like a pure refactor (#5). The three test
   commits that document it (#1-#3) never say *why* the alias exists
   (`mkpath()` runs `cleanup_path()`), and #3 describes the *old* behavior in
   its bullets while its test titles assert the *new* behavior, which reads as
   a contradiction until you notice the `test_expect_failure`.
2. **Two ordering dependencies are undocumented**: #1 must land before #5
   (otherwise #5 makes `--force-with-lease=./refs/heads/x:...` silently
   provide no lease), and #5 must land before #6/#7 (otherwise the strmap
   lookups silently drop the alias before the tests flip). A reviewer who
   reorders or drops #1 as "unrelated" would be wrong, but nothing in the
   messages tells them so.
3. The two strmap commits never state the equivalence that makes them
   correct: after #5, `refname_match(pattern, name)` is true exactly when
   `name` is one of the `expand_ref_prefix(pattern)` expansions.

Proposed rewrites for every message are below; #3 (`10ec13e5b3`) gets the
most attention as requested.

## Series-level observations

### The "./" alias and where it came from

```c
/* path.c */
static const char *cleanup_path(const char *path)
{
	if (skip_prefix(path, "./", &path)) {
		while (*path == '/')
			path++;
	}
	return path;
}

const char *mkpath(const char *fmt, ...)
{
	...
	strbuf_vaddf(pathname, fmt, args);
	return cleanup_path(pathname->buf);
}
```

Pre-series `refname_match()` did `strcmp(full_name, mkpath(rule, len, abbrev))`.
Only the first rule, `"%.*s"`, yields a string that *starts* with the
abbreviation, so only that rule was affected: `"./<full refname>"` (and
`".//x"`, `".///x"`, ...) compared equal to `"<full refname>"`. Nothing else in
git accepts such a name (`check_refname_format()` rejects a component starting
with `.`), so the alias was reachable only via:

| Caller of `refname_match()` | Input path | Covered by |
|---|---|---|
| `count_refspec_match()` (push src/dst) | push refspec src is not validated for push | #2 (t5516) |
| `branch_merge_matches()` (fetch, mark for merge) | `branch.<name>.merge` is not validated | #3 (t5510 test 1) |
| `find_ref_by_name_abbrev()` via `get_remote_ref()` (fetch, look up merge source) | same | #3 (t5510 test 3) |
| `apply_cas()` (`--force-with-lease=<ref>:<expect>`) | option arg was not validated | #1 now rejects it |
| `builtin/push.c set_refspecs()` (colon-less args), `submodule--helper.c push_check()` | a colon-less `git push origin ./refs/heads/main` hit the alias here too, but the outcome is decided by the later `match_explicit()` pass, which #2 tests; these callers keep the linear `count_refspec_match()` | #2, indirectly |

Fetch refspec LHS is validated at parse time (`parse_refspec()` for fetch), so
`git fetch origin ./refs/heads/main` was never accepted.

Supporting facts worth a sentence somewhere in the series (probably #5 or a
cover letter), for a config of `branch.main.merge = ./refs/heads/main`:

- `@{upstream}`, `git status` upstream info, `git rebase`/`git merge` with
  no arguments, and `git push` with `push.default=simple` never worked.
  `set_merge()` runs the value through `remote_find_tracking()`, i.e. the
  fetch refspec pattern `refs/heads/*`, which `./refs/heads/main` does not
  match, so `branch->merge[0]->dst` stays NULL ("upstream branch
  './refs/heads/main' not stored as a remote-tracking branch"), and
  `setup_push_simple()` dies because `merge[0]->src` differs from the
  branch's refname.
- `git pull` *did* work before the series, because it reads FETCH_HEAD and
  the for-merge marking went through `refname_match()` (t5510 test 1). After
  #5 it reports no merge candidates. This is the one user-facing loss, and it
  only affects hand-edited config that every other upstream-aware command
  already rejected.

### Ordering dependencies (should be stated in the messages)

- **#1 before #5.** `apply_cas()` silently ignores a lease entry that matches
  no remote ref. Before the series, `--force-with-lease=./refs/heads/main:<oid>`
  matched `refs/heads/main`. After #5 alone it would match nothing, and the
  push would proceed with no lease on that ref: a fast-forward update goes
  through even if the remote is not at the expected value, and a
  non-fast-forward one is rejected as plain non-FF instead of being applied
  under the lease. (With `+` or `--force` the lease is already defeated by
  design, see `set_ref_status_for_push()` and the `--force` docs, so that
  case does not change.) #1 turns the silent no-op into a hard error before
  #5 lands. This is the whole reason #1 exists and it is not stated.
- **#5 before #6/#7.** `expand_ref_prefix()` uses `strvec_pushf()`, not
  `mkpath()`, so it never produced `./`-cleaned names. The strmap lookups are
  equivalent to the linear `refname_match()` scan only once #5 has removed
  the `cleanup_path()` behavior. The planning note says "commits 4 and 5
  depend on nothing in commit 3"; that is not quite true, and the series as
  ordered is correct, but the messages should pin the order.

### What the series does not cover (fine, but say so or follow up)

- `apply_cas()` / `apply_push_cas()` is still O(R x N) over remote refs and
  lease entries (planned "commit 5" in the notes). Each comparison is cheap
  after #5, so this is a reasonable deferral.
- `count_refspec_match()` remains exported for `builtin/push.c` and
  `builtin/submodule--helper.c`, which still do the linear scan over *local*
  refs once per command-line refspec. Also fine.

## Per-commit review

### 1. `eaf355508b` remote: validate --force-with-lease <refname> argument

**Code.** Correct and minimal. `REFNAME_ALLOW_ONELEVEL` is right (`main`,
`HEAD` must stay legal). The message string `'%s' is not a valid refname`
already exists in `sequencer.c` and `replay.c`, so no new translation is
needed. Side effects beyond the `./` case are improvements: an empty refname
(`--force-with-lease=:oid`) or a glob (`refs/heads/*`) used to be a silent
no-op lease and now errors.

**Test nit.** `test_commit D` and the `:main^` value are not needed; the error
fires during option parsing before `main^` is resolved. Harmless, but a reader
may wonder what role D plays. Consider dropping both, or add a comment that
the point is only to reach option parsing.

**Prose.** The message says *what* but not *why now*. Without the motivation
a reviewer may treat it as unrelated and reorder it after #5, which would open
a window where the lease is silently ignored.

Proposed:

```
remote: validate --force-with-lease <refname> argument

Run check_refname_format() on the <refname> part of
'git push --force-with-lease=<refname>[:<expect>]' and reject
malformed names such as "./refs/heads/main".

apply_cas() silently ignores a lease entry that matches no remote
ref, so a lease with an unusable name quietly protects nothing.
Today "./refs/heads/main" happens to match refs/heads/main because
refname_match() formats candidates with mkpath(), which strips a
leading "./".  A later commit stops using mkpath() there, after which
such a lease would be ignored rather than honored.  Fail up front so
the user gets an error either way.
```

### 2. `f679d82ab3` t5516: demonstrate push with "./"-prefixed source

**Code.** Fine. `test_grep "src refspec ./refs/heads/main does not match any"`
is a regex with unescaped `.`; it still matches the intended line.

**Prose.** "interprets a ... source component of its given refspec as though
it were provided a refname without the "./" prefix" is hard to parse, and the
mechanism is missing.

Proposed:

```
t5516: demonstrate push with "./"-prefixed source

'git push testrepo ./refs/heads/main:refs/heads/frotz' succeeds today
and pushes refs/heads/main.  count_refspec_match() compares the source
against local refs with refname_match(), which formats each candidate
with mkpath(), and mkpath()'s cleanup_path() strips a leading "./".
"./refs/heads/main" is not a valid refname; check_refname_format()
rejects it.

Add a test_expect_failure asserting that such a source is rejected
with "src refspec ./refs/heads/main does not match any".  A later
commit removes the mkpath() call from refname_match() and flips this
test to test_expect_success.
```

### 3. `10ec13e5b3` t5510: test "./"-prefixed branch.<name>.merge values

**Code.** All three tests are correct and I traced each path:

- *Test 1 (default refspec, `test_expect_failure`).* `refs/heads/main` is in
  the ref map via `+refs/heads/*:refs/remotes/origin/*`. `add_merge_config()`
  calls `branch_merge_matches()` -> `refname_match("./refs/heads/main",
  "refs/heads/main")`, which matches today, so `main` is marked for merge and
  the test (which expects `not-for-merge` on both lines) fails as intended.
  Protocol-independent: the ref is advertised either way because the client
  also sends the `refs/heads/` prefix.
- *Test 2 (v2, `remote.origin.fetch` unset, `--no-tags`, `test_expect_success`).*
  `do_fetch()` pushes `branch->merge[i]->src` verbatim into `ref_prefixes`
  (`builtin/fetch.c:1971-1974`); with no refspec, no tags and no `HEAD`
  (`do_set_head` stays 0) it is the *only* prefix. `ls-refs` matches nothing,
  `remote_refs` is NULL, `get_ref_map()` still enters the "has_merge" block
  and `add_merge_config()` -> `get_fetch_map(NULL, ..., missing_ok=1)` adds
  nothing. Passes before and after the series.
- *Test 3 (v0, refspec omits main, `test_expect_failure`).* Ref map holds only
  `other`; `branch_merge_matches()` fails for it; the fallback
  `get_fetch_map(remote_refs, {src="./refs/heads/main"}, tail, 1)` ->
  `get_remote_ref()` -> `find_ref_by_name_abbrev()` -> `refname_match()`
  finds `refs/heads/main` today and fetches it for merge, producing a second
  FETCH_HEAD line. `-c protocol.version=0` correctly overrides
  `GIT_TEST_PROTOCOL_VERSION`.

FETCH_HEAD ordering in test 1 (`main` before `other`) is deterministic: both
entries share a status, and within a status `store_updated_refs()` writes in
ref-map order, which follows the sorted advertisement.

Tags created by `test_commit` (`one`, `two`) do not appear in FETCH_HEAD
because the clone already has them, so auto-follow adds nothing. Worth knowing
but not worth a comment.

**Prose: what is unclear today.**

1. The bullets describe the *current* behavior ("that ref is marked for
   merge", "fetches refs/heads/main for merge") while the test titles assert
   the *opposite* ("does not mark any ref for merge", "does not match any
   remote ref"). The reconciliation is `test_expect_failure`, but the message
   never says which tests are expected failures or why.
2. The mechanism is absent. Nothing explains *why* `./refs/heads/main`
   matches `refs/heads/main` in bullets 1 and 2 but not in bullet 3. The
   reader needs: client-side matching goes through `refname_match()` ->
   `mkpath()` -> `cleanup_path()`, which strips `./`; server-side `ls-refs`
   prefix filtering does not.
3. "resolves the same value against the server's refs" is vague; the actual
   path is `add_merge_config()` falling back to `get_remote_ref()`, which also
   uses `refname_match()`. Naming it tells the reader why test 3 is a *second*
   distinct code path and not a duplicate of test 1.
4. The message does not state what the tests are *for*: pinning current
   behavior ahead of the `refname_match()` rework, and showing that the alias
   was never consistently supported (bullet 3 is the evidence). Without that,
   bullet 3 looks unrelated to the other two.
5. Minor: subject says "test" but two of three are documented known-bugs;
   "document" is more accurate. `branch.<name>.merge` is hand-edit-only here
   (`git branch --set-upstream-to` would never produce `./`), which is worth a
   word since it bounds who is affected.

**Proposed (full).**

```
t5510: document fetch handling of "./"-prefixed branch.<name>.merge

refname_match() builds each candidate name with mkpath(), whose
cleanup_path() strips a leading "./".  As a side effect, a hand-edited
branch.<name>.merge value of "./refs/heads/main" is treated as
"refs/heads/main" wherever the client does the matching, but not where
the server does.  Pin down the current behavior with three tests
before refname_match() is reworked:

 - Default fetch refspec: refs/heads/main is fetched by the refspec,
   and add_merge_config() marks it for merge via
   branch_merge_matches().  test_expect_failure, as the test asserts
   that nothing is marked for merge.

 - Fetch refspec that omits refs/heads/main, protocol v0: the ref is
   not in the ref map, so add_merge_config() falls back to
   get_remote_ref(), which also uses refname_match().  Under v0 the
   server advertises every ref, so the fallback finds refs/heads/main
   and fetches it for merge.  test_expect_failure, as the test asserts
   that only the refspec's ref lands in FETCH_HEAD.

 - remote.<name>.fetch unset, 'fetch --no-tags', protocol v2: the only
   ref-prefix sent is the verbatim "./refs/heads/main".  No ref has
   that prefix, so the server advertises nothing and FETCH_HEAD is
   empty.  This already passes and is unaffected by the rework.

The first two flip to test_expect_success once refname_match() stops
using mkpath().  "./refs/heads/main" is not a valid refname, and the
third test shows the alias already fails whenever the server rather
than the client has to interpret it, so no supported usage is lost.
```

**Proposed (condensed).** If the above is too long, this keeps the three
facts a reader cannot reconstruct from the diff (mechanism, which tests are
expected failures, and why test 3 is there):

```
t5510: document fetch handling of "./"-prefixed branch.<name>.merge

refname_match() formats candidates with mkpath(), which strips a
leading "./", so a branch.<name>.merge of "./refs/heads/main" is
matched as "refs/heads/main" wherever the client does the matching.
Pin down the current behavior before refname_match() is reworked:

 - default fetch refspec: the fetched refs/heads/main is marked for
   merge (test_expect_failure; the test asserts nothing is marked);

 - refspec omitting refs/heads/main, protocol v0: add_merge_config()
   falls back to get_remote_ref(), finds refs/heads/main among the
   advertised refs and fetches it for merge (test_expect_failure; the
   test asserts only the refspec's ref is fetched);

 - remote.<name>.fetch unset, --no-tags, protocol v2: the value goes
   out verbatim as the only ref-prefix, nothing has that prefix, and
   the server advertises nothing (passes already; unaffected).

The two expected failures flip once refname_match() stops using
mkpath().  "./refs/heads/main" is not a valid refname, so nothing
supported is lost.
```

### 4. `33b5e08cc8` t/perf: add explicit delete refspec matching test

**Code.** Runs as designed (the author's numbers come from it). Notes:

- `test_seq -f` exists in this tree (`t/test-lib-functions.sh:1472`). A 100k
  iteration shell loop is slow-ish for setup but acceptable.
- `--ref-format=reftable` is a sensible choice for 100k refs; reftable is
  always built now, so no prereq is needed.
- The `create $mode refspecs` setup test is identical for both modes. Keeping
  it per mode is what produces the odd-numbered perf test ids (`5516.3`,
  `.5`, ...) that the later messages cite, so it is consistent; just
  redundant.
- Quoting is inconsistent but correct: `'"$client"'` is interpolated at
  definition time while `$nr_refspecs` is expanded at eval time. Both work
  because the body is eval'd inside the loop iteration.
- Perf script name `p5516` mirrors `t5516`; existing transport perf scripts
  are `p5550`/`p5551`. Either convention is defensible.

**Prose.** The message does not say why *delete* refspecs, why *two* clients,
or why `--dry-run`. Those three choices are the design of the benchmark and a
reader comparing the two timing columns in #6 needs to know that the empty
client only exercises remote-ref (dst) matching and the mirror client also
exercises local-ref (src) matching.

Proposed:

```
t/perf: add explicit delete refspec matching test

Add p5516 to measure the client-side cost of matching explicit
refspecs on 'git push' against a server that advertises many refs.

The server gets 100k branches.  Two clients push 1, 10 and 100 delete
refspecs (":refs/heads/bN") with --dry-run: an empty client, whose
cost is matching against the advertised refs only, and a mirror
client, which adds an equally large set of local refs to match
against.  Delete refspecs and --dry-run keep object transfer and ref
updates out of the measurement, so every repetition does the same
matching work.

The next three commits use it to show their effect.  Baseline on my
machine:

  Test                           this tree
  ----------------------------------------------
  5516.3: empty:refspecs:1       0.14(0.08+0.10)
  5516.5: empty:refspecs:10      0.38(0.32+0.10)
  5516.7: empty:refspecs:100     2.50(2.44+0.10)
  5516.9: mirror:refspecs:1      0.21(0.14+0.11)
  5516.11: mirror:refspecs:10    0.80(0.73+0.11)
  5516.13: mirror:refspecs:100   6.85(6.78+0.12)
```

### 5. `a348a36cae` refs: reuse match_parse_rule() in refname_match()

**Code.** Correct. Checked:

- `match_parse_rule()` is moved verbatim; the `"%.*s"` rule degenerates to an
  exact comparison (empty prefix, empty suffix); `"refs/remotes/%.*s/HEAD"`
  is handled by `strip_suffix()`. A `full_name` shorter than a rule's prefix
  terminates the prefix loop on NUL mismatch, so there is no over-read.
- The returned precedence `&ref_rev_parse_rules[num_rules] - p` is unchanged,
  so `find_ref_by_name_abbrev()` ranking and the weak/strong classification
  in `count_refspec_match()` are unaffected.
- `abbrev_name_len` goes `int` -> `size_t`; harmless.
- The only semantic difference is the loss of `cleanup_path()`, which is
  exactly what the three flipped tests cover.

**Prose.** This is the commit that changes behavior, and the message buries
it in one sentence that says the old behavior was "unusual handling" without
saying what it was. A reader of `git log` for a future "./ stopped working"
report must be able to find this commit. The subject could also hint at the
change; "reuse match_parse_rule()" describes the mechanism only.

Proposed (subject alternative: `refs: stop using mkpath() in refname_match()`):

```
refs: reuse match_parse_rule() in refname_match()

refname_match() formats every ref_rev_parse_rules entry through
mkpath() and strcmp()s the result against full_name.  That formatting
dominates the client-side cost of matching explicit refspecs against
a remote with many refs.

refs_shorten_unambiguous_ref() already has match_parse_rule(), which
strips a rule's literal prefix and suffix off a full refname and
returns what is left.  Move it next to ref_rev_parse_rules[] and use
it here: for each rule, strip it off full_name and compare the
remainder to abbrev_name with a length check and memcmp().  Most
candidates are rejected on the first byte.  The returned precedence
is unchanged.

One behavior changes.  mkpath() runs cleanup_path(), which strips a
leading "./", so "./refs/heads/main" used to match "refs/heads/main"
through the "%.*s" rule.  match_parse_rule() does no such cleanup, and
neither does expand_ref_prefix(), which the next two commits rely on
to enumerate refname_match() candidates.  Flip the t5510 and t5516
tests that document the old aliasing to test_expect_success.

Timings from the test added in the previous commit:

  Test                           HEAD~1            HEAD
  -----------------------------------------------------------------------
  5516.3: empty:refspecs:1       0.15(0.09+0.11)   0.14(0.07+0.11) -6.7%
  5516.5: empty:refspecs:10      0.38(0.32+0.11)   0.17(0.11+0.11) -55.3%
  5516.7: empty:refspecs:100     2.50(2.43+0.11)   0.49(0.42+0.11) -80.4%
  5516.9: mirror:refspecs:1      0.21(0.15+0.11)   0.16(0.09+0.11) -23.8%
  5516.11: mirror:refspecs:10    0.80(0.73+0.11)   0.26(0.19+0.11) -67.5%
  5516.13: mirror:refspecs:100   6.68(6.59+0.13)   1.18(1.11+0.11) -82.3%
```

### 6. `78135aaeab` remote: use a strmap for check_push_refs()

**Code.** Correct. Checked:

- Equivalence: `refname_match(pattern, name)` is nonzero iff
  `name == prefix(rule) + pattern + suffix(rule)` for some rule, and
  `expand_ref_prefix(pattern)` produces exactly that set. The six expansions
  are pairwise distinct (prefix+suffix lengths 0, 5, 10, 11, 13, 18), so no
  ref can be counted twice. Holds only after #5 (see ordering note above).
- Last-match semantics (`matched`/`matched_weak` point at the *last* hit)
  change from list order to rule order, but this is only observable when the
  count is >1, which every caller already treats as an error without using
  the pointer.
- `strmap_init_with_options(map, NULL, 0)`: keys alias `ref->name`, which
  outlives the map; `strmap_clear(map, 0)` matches. Fine.
- `check_push_refs()` early-returns when no item is explicit; equivalent to
  the old empty loop.
- `add_refspec_match()` switches `patlen`/`namelen` to `size_t`. The
  `namelen - 5` can only be evaluated when `namelen != patlen`, and any match
  with `namelen < 5` is necessarily an exact match, so the unsigned wrap is
  never reached. Equivalent, but reviewers on the list often ask about
  `int` -> `size_t` arithmetic; a `namelen >= 5 &&` guard or a one-line
  comment would pre-empt the question.
- `bool` is already used in `remote.c` on master, so the new helpers match
  the file.
- Duplicate names in a ref list would be collapsed by `strmap_put()` (old
  code would report "matches more than one"). Neither local refs nor a sane
  advertisement contain duplicates; not a concern, noted for completeness.
- The moved weak/strong comment keeps the old `/* text on first line` style.
  Acceptable for moved code.

**Prose.** Mostly good. Issues: the R/N letters are swapped relative to the
planning notes and to common usage (R for remote refs), which trips up a
reader of the series as a whole; the correctness argument (why six lookups
equal a full scan) is missing; "for the sake of preserving the other callsite"
is wordy. "a strmap" here vs "strmap" in #7's subject is a consistency nit.

Proposed:

```
remote: use a strmap for check_push_refs()

check_push_refs() runs count_refspec_match() for each explicit
refspec, and each call scans all local refs with refname_match():
O(L * R) for L local refs and R refspecs.

Since the previous commit, refname_match(pattern, name) is true
exactly when name is one of the ref_rev_parse_rules expansions of
pattern, which is what expand_ref_prefix() produces.  So build a
strmap of the local refs once, O(L), and resolve each refspec with
six lookups, O(R).  The weak/strong classification is unchanged and
is applied to the hits.

match_explicit_lhs_map() temporarily sits beside match_explicit_lhs()
so that match_explicit() keeps working on the list form; the next
commit converts it and merges the two.

Only the mirror client, which has 100k local refs, is expected to
benefit here:

  Test                           HEAD~1            HEAD
  -----------------------------------------------------------------------
  5516.3: empty:refspecs:1       0.14(0.07+0.11)   0.13(0.07+0.10) -7.1%
  5516.5: empty:refspecs:10      0.16(0.10+0.10)   0.16(0.10+0.10) +0.0%
  5516.7: empty:refspecs:100     0.47(0.41+0.10)   0.47(0.41+0.10) +0.0%
  5516.9: mirror:refspecs:1      0.16(0.09+0.11)   0.16(0.10+0.11) +0.0%
  5516.11: mirror:refspecs:10    0.26(0.19+0.11)   0.22(0.16+0.11) -15.4%
  5516.13: mirror:refspecs:100   1.19(1.13+0.10)   0.82(0.75+0.11) -31.1%
```

### 7. `6069da79e5` remote: use strmap for match_explicit_refs()

**Code.** Correct. Checked:

- The `strmap_put()` in `case 0:` is the one non-mechanical part and it is
  right: both `make_linked_ref()` branches (literal `refs/` dst and
  `guess_ref()` dst) flow into it, and it uses `matched_dst->name` (the
  ref's own copy), not the freed `dst_guess`.
- Cross-refspec aliasing still works: `main:refs/heads/new other:heads/new`
  and `main:new other:new` both end in "receives from more than one src"
  because the second pattern's expansions include the name the first one
  inserted.
- Non-ref sources (`HEAD~2`, OIDs, empty for delete) fall through to
  `try_explicit_object_name()` exactly as before; their expansions are never
  map keys.
- Maps are built only when at least one item is explicit; the `dst` map is
  O(remote refs) once per push, which is the cost that replaces the
  per-refspec scan (the +7.7% on `empty:refspecs:1` is this, in the noise).
- The new t5516 test fails without the `strmap_put()`: the second
  `main:refs/heads/new` would create a second dst ref instead of hitting the
  error.

**Prose.** The second paragraph is hard to read ("call sites match_explicit()
and check_push_refs() have been updated to use the new strmap variation
introduced in the previous commit, so the separate _map form is removed").
The third paragraph has the right content but could say *what goes wrong*
without the `strmap_put()`. The intro could also point out that this is the
commit that removes the per-refspec scan of the *advertised* refs, so both
clients benefit (the table shows it, the text does not).

Proposed:

```
remote: use strmap for match_explicit_refs()

match_explicit() scans the local refs for each refspec's source and
the remote refs for its destination.  The latter is the dominant cost
of pushing explicit refspecs to a remote with many refs.  Build a
strmap of each list once in match_explicit_refs() and look up the
expansions, as the previous commit did for check_push_refs().

Both callers of match_explicit_lhs() now pass a strmap, so fold the
temporary match_explicit_lhs_map() back into it.

One subtlety: when a destination does not exist, match_explicit()
creates it and appends it to the dst list, and later refspecs must
see it so that "dst ref %s receives from more than one src" still
fires.  Insert such refs into the map as well, and add a t5516 test
that fails without that strmap_put().

Both clients now benefit, since the 100k advertised refs are no
longer scanned per refspec:

  Test                           HEAD~1            HEAD
  -----------------------------------------------------------------------
  5516.3: empty:refspecs:1       0.13(0.07+0.10)   0.14(0.07+0.10) +7.7%
  5516.5: empty:refspecs:10      0.17(0.10+0.11)   0.14(0.07+0.11) -17.6%
  5516.7: empty:refspecs:100     0.47(0.41+0.10)   0.15(0.08+0.10) -68.1%
  5516.9: mirror:refspecs:1      0.17(0.10+0.11)   0.17(0.10+0.11) +0.0%
  5516.11: mirror:refspecs:10    0.23(0.16+0.11)   0.17(0.10+0.11) -26.1%
  5516.13: mirror:refspecs:100   0.87(0.80+0.11)   0.18(0.11+0.11) -79.3%
```

## Consolidated nits

- `t5533`: drop `test_commit D` and `:main^` from the new test, or comment why
  they are there.
- Subjects: "use a strmap" (#6) vs "use strmap" (#7).
- `add_refspec_match()`: consider a guard or comment for `namelen - 5` with
  `size_t`.
- `count_refspec_match_in_map()`: the parameter named `refs` is a
  `struct strmap *`; `map` or `ref_map` would read better next to the
  list-taking `count_refspec_match()`.
- `p5516`: `nr_refspecs` is expanded at eval time while `client` is
  interpolated at definition time; pick one for consistency.
- Untracked notes at the repo root (`planned-git-commits.md`,
  `commit-message-remote.txt`, `refs-change1.txt`, etc.) should not be
  committed. `git status` currently shows them as untracked, which is fine.

## Suggested follow-ups (not blockers)

- `apply_push_cas()` / `apply_cas()`: the planned strmap conversion
  (`commit-message-remote.txt` has a draft message) would finish the O(R x N)
  removal for `--force-with-lease`.
- If this goes to the list, a short cover letter stating the behavior change
  and the two ordering dependencies would save a round-trip.
