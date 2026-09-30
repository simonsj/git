# Review: `simonsj/20260929-speedup-client-push-with-refspecs`

Range reviewed: `origin/main..HEAD` (`a018953688..a254a852f4`, 5 commits).

```
a254a852f4 remote: use strmap for match_explicit_refs()
b0df126676 remote: use a strmap for check_push_refs()
80665ccc31 refs: reuse match_parse_rule() in refname_match()
0ece2a3868 t/perf: add explicit delete refspec matching test
ca0c7034b0 t5516: demonstrate push with "./"-prefixed source
```

## Verdict

No blatant bugs. I read every hunk against the pre-image, argued the
semantic equivalence of each replacement (details per commit below), and
verified behavior empirically with a release binary (Homebrew git 2.55.0)
as "before" and the `./git` built from HEAD as "after":

- `t/t5516-fetch-push.sh`: 130/130 pass.
- 20 related suites via `prove -j8` (t5510, t5533 push-cas, t5505, t5518,
  t5541 http-push-smart, t5523, t5528, t5536, t5548, t5560, t7406, t5407,
  t1430, t1401, t6300, t5514, t5512, t5511, t5583, t7400): 1,370 tests pass.
- `p5516-push-delete-refspec.sh` smoke-run with `ref_count=2000`: all 13
  steps OK.

Before/after matrix (scratch repos under `/tmp`):

| Command | git 2.55.0 (before) | HEAD (after) |
|---|---|---|
| `git push dst ./refs/heads/main:refs/heads/frotz` | **accepted**, pushes `frotz` | `error: src refspec ./refs/heads/main does not match any` |
| `git push dst .///refs/heads/main:refs/heads/frotz2` | **accepted** | rejected (same error) |
| `git push dst ./main:refs/heads/frotz3` | rejected | rejected |
| `git rev-parse --verify ./refs/heads/main` | rejected | rejected |
| `git fetch dst ./refs/heads/main:refs/heads/x` | `fatal: invalid refspec` | `fatal: invalid refspec` |
| `git check-ref-format ./refs/heads/main` | invalid | invalid |
| `git push --dry-run EMPTY main:refs/heads/new main:refs/heads/new` | **exit 0**, prints `[new branch] main -> new` twice | `error: dst ref refs/heads/new receives from more than one src` |
| `git push EMPTY main:refs/heads/new main:refs/heads/new` | rejected only by the **server**: `remote: error: multiple updates for ref 'refs/heads/new' not allowed` | rejected client-side (same error as above) |
| `git push NONEMPTY main:refs/heads/new main:refs/heads/new` | `dst ref refs/heads/new receives from more than one src` | same |

Rows 1-3 confirm the `./` bug and its exact scope (only `./` + a *full*
refname, plus any extra slashes; `./main` was never accepted). Rows 7-8 are
a behavior change in 5/5 that the commit message does not mention (see
below); it is an improvement.

### Findings, by importance

1. **1/5 commit message** needs the history and the argument for why this is
   a bug. Proposed replacement text is in [Proposed message for 1/5](#proposed-message-for-15).
2. **3/5 commit message** understates and slightly mis-scopes the visible
   change. It should (a) say that only the bare `%.*s` rule was affected and
   why, (b) say it applies to *every* caller of `refname_match()` (push
   `<src>`, `--force-with-lease=<ref>`, fetch-side `find_ref_by_name_abbrev()`,
   `branch.<name>.merge` matching), and (c) arguably lead with the fix rather
   than the speedup, since it is the user-visible part. Suggested text in
   [Suggested message for 3/5](#suggested-message-for-35).
3. **5/5 undocumented behavior change**: two refspecs targeting the same *new*
   `<dst>` against an *empty* remote are now caught client-side (and under
   `--dry-run`), where before the client let both through. Positive, but it
   should be in the message and it deserves a test (it is the one case where
   the old and new code actually differ; the test that was added guards the
   `strmap_put()` but passes on the old code too). Details and a proposed
   test in [5/5](#55-a254a852f4-remote-use-strmap-for-match_explicit_refs).
4. **2/5 commit message** should explain the fixture choices (`reftable`,
   delete refspecs, `--dry-run`, unsetting `remote.origin.mirror`) and note
   that `--ref-format=reftable` means `t/perf/run` against pre-2.45 binaries
   will fail in setup.
5. Nits in 4/5 (naming, moved-comment style, one subtle `size_t` equivalence
   worth a comment).

---

## Per-commit review

### 1/5 `ca0c7034b0` t5516: demonstrate push with "./"-prefixed source

**Code**: correct. Before the fix, `git push` succeeds, `test_must_fail`
returns non-zero, the body fails, and `test_expect_failure` reports "still
broken". `mk_test` re-creates `testrepo` for the next test so the stray
`refs/heads/frotz` does not leak. `2>err` and `test_grep` are the right
idiom; the `.` in the pattern is an unanchored regex metachar but harmless.

**Message**: too thin for what this commit is asserting. It says "the bug"
without establishing that it *is* a bug, and this is exactly the commit
where a reviewer on the list will ask "who says `./refs/heads/main` is not a
valid `<src>`?" The proposed replacement below carries the history and the
case. (Alternative structure the project also accepts: drop this commit and
add the test as `test_expect_success` in 3/5. I would keep it as-is given
the message is where the archaeology belongs.)

### 2/5 `0ece2a3868` t/perf: add explicit delete refspec matching test

**Code**: correct and it runs (`GIT_PERF_REPEAT_COUNT=1` smoke run with a
reduced `ref_count`: 13/13 OK). `test_seq -f` exists in
`test-lib-functions.sh`. `p5516` pairs with `t5516` per perf naming
convention and does not collide. `$(cat refspecs)` is evaluated at run time
inside `test_perf`, `'"$client"'` at definition time; both are right.
Unsetting `remote.origin.mirror` on the mirror clone is necessary (otherwise
`push` implies `--mirror`) and correct.

**Message**: state *why* the fixture looks the way it does, because none of
it is obvious from the title:

- `--ref-format=reftable` on `server` and `client_mirror`: with 100k refs the
  files backend's advertisement/enumeration would dominate the timing;
  reftable keeps the server side and local ref listing cheap so the client's
  refspec matching is what is measured.
- `:refs/heads/bN` delete refspecs with `--dry-run`: no pack is built or
  sent and there is no object negotiation, so wall clock is essentially
  `check_push_refs()` + `match_push_refs()`.
- `empty` vs `mirror` clients isolate the `dst`-side (remote refs) cost from
  the `src`-side (local refs) cost; this is why 4/5 only moves `mirror` and
  5/5 moves both.
- Requires a binary with reftable support (2.45+); `t/perf/run` against older
  versions will fail in the setup step. Say so, or fall back to
  `--ref-format=files` when `reftable` is unavailable.

Title nit: "explicit delete refspec matching test" is opaque to someone not
already in this code; "push: measure client-side matching of explicit
refspecs" or similar.

### 3/5 `80665ccc31` refs: reuse match_parse_rule() in refname_match()

**Code**: correct, and equivalence holds except for the intended `./` change.

Argument: every rule has the shape `{prefix}%.*s{suffix}`. Old:
`full == prefix + abbrev + suffix`. New: `full` starts with `prefix`, the
remainder ends with `suffix`, and what is between has `abbrev`'s length and
bytes. Same predicate. Edge cases checked:

- `abbrev == ""` (delete refspecs): matches only `""`, `refs/`, `refs/tags/`,
  ..., `refs/remotes//HEAD` in both versions, none of which is a real ref.
- `full_name` shorter than the prefix: `match_parse_rule()` compares byte by
  byte and returns `NULL` at the terminating NUL before reading past it.
- Rule `refs/remotes/%.*s/HEAD` vs `refs/remotes/HEAD`: `strip_suffix()` fails
  on length (4 < 5), same as the old `strcmp()`.
- The six expansions of one abbrev are pairwise distinct strings (the added
  prefix+suffix lengths are 0, 5, 10, 11, 13, 18), so the precedence returned
  is unchanged.
- Only `./` differs: `mkpath()` runs `cleanup_path()` on the *formatted*
  result, so only rule `%.*s` (abbrev at offset 0) was ever affected. That is
  the whole scope of the behavior change and matches the empirical matrix
  (`./main` was never accepted).

`match_parse_rule()` is moved verbatim (the removed and added hunks are
byte-identical). `BUG()` on a
rule without `%` is unreachable with the static table. `path.h` is still
needed in `refs.c` for `repo_common_path_append()`.

Optional: split the pure move of `match_parse_rule()` into its own commit or
forward-declare it, so the functional hunk is ~15 lines. Reviewer's taste.

**Message**:

- The `./` bullet says the *abbrev_name argument* was subject to
  `cleanup_path()`. It was the formatted result, which is why only the `%.*s`
  rule was affected, and why the match was reported at the highest
  precedence (an "exact" match). Say that precisely.
- It is not only push. Every `refname_match()` caller changes:
  `count_refspec_match()` (push `<src>`; `<dst>` was already validated by the
  refspec parser), `apply_cas()` (`--force-with-lease=./refs/heads/x` used to
  bind to `refs/heads/x`; now it binds to nothing), `find_ref_by_name_abbrev()`
  (fetch-side; its command-line inputs already pass `check_refname_format()`),
  and `branch_merge_matches()` (`branch.<name>.merge = ./refs/heads/x` used
  to mark `refs/heads/x` for merge). All consistent with "this is not a
  refname", but list them.
- Consider leading with the correctness change. As written, the title and
  first two paragraphs say "perf refactor", and the behavior change appears
  as a bullet about a test. The maintainer will want the user-visible change
  to be the headline of the commit that makes it.
- "Timings from the test added in the previous commit" is good; keep the
  table.

### 4/5 `b0df126676` remote: use a strmap for check_push_refs()

**Code**: correct.

- `add_refspec_match()`/`finish_refspec_match()` preserve the weak/strong
  logic exactly. One subtlety worth a comment: `namelen`/`patlen` went from
  `int` to `size_t`, so `patlen != namelen - 5` now compares against a
  wrapped value when `namelen < 5`. The truth value is the same as the old
  `patlen != <negative>` (always true), so behavior is unchanged, but a
  reader will stop on it. Either add a short comment or write
  `namelen < 5 || patlen != namelen - 5`. (The magic `5` is `strlen("refs/")`;
  pre-existing.)
- `count_refspec_match_in_map()`: `expand_ref_prefix()` yields exactly the
  six candidate full names, each corresponding to one rule, pairwise
  distinct, so no ref is double counted and the counts equal what a linear
  `refname_match()` scan produces. Result order differs (rule order vs list
  order) but the returned `*matched_ref` only matters when the count is 1,
  where it is the same ref. A one-line comment stating this equivalence
  would help the next reader; `expand_ref_prefix()`'s name suggests prefixes
  for `ls-refs`, not exact names.
- `ref_map_init()` uses `strdup_strings = 0`; keys point into `ref->name`,
  which outlives the map in both callers, and `strmap_clear(map, 0)` frees
  only the entries. Correct.
- Duplicate names in the input list collapse to one entry (last wins) where
  the linear scan counted each. A remote cannot advertise the same ref twice
  with a well-formed protocol, so this is unreachable; noting for
  completeness.
- Early `return 0` when no item is explicit: equivalent, avoids building the
  map for pattern-only pushes. Good.
- `bool` is already used in `remote.c` at `origin/main`; fine.

**Nits**:

- `struct refspec_match` reads like it belongs to `refspec.h`; something like
  `struct refspec_match_counts` avoids the collision in grep results.
- The moved `/* A match is "weak" ...` comment keeps the pre-2007 style
  (`/* text` on the first line). Since the block is being relocated into a
  new function anyway, reformatting to the CodingGuidelines style is
  reasonable; leaving it verbatim is also defensible.

**Message**: clear. O(R\*N) → O(N)+O(R) is right (each lookup is six probes).
The "match_explicit_lhs_map() is introduced ... recombined in the next
commit" note is exactly what a reviewer wants.

### 5/5 `a254a852f4` remote: use strmap for match_explicit_refs()

**Code**: correct, and it fixes a latent inconsistency.

- `strmap_put(dst, matched_dst->name, matched_dst)` after `make_linked_ref()`
  is required and cannot collide: we are in `case 0` because none of the six
  expansions of `dst_value` is in the map, and `dst_guess` is one of those
  expansions (`refs/heads/<dst>` or `refs/tags/<dst>`), so the key is
  guaranteed absent. Names live in the `struct ref` flex array on the linked
  list, which outlives `dst_map`.
- `try_explicit_object_name()` allocations never enter `src_map`, mirroring
  the old code where they never entered the `src` list. `free_one_ref()` on
  the `out:` path is unchanged.
- Early `return 0` on no-explicit-items is equivalent.

**Behavior change (please document and test)**. The old loop was:

```c
static int match_explicit_refs(struct ref *src, struct ref *dst, ...)
{
	for (i = errs = 0; i < rs->nr; i++)
		errs += match_explicit(src, dst, dst_tail, &rs->items[i]);
```

`dst` is the list head *by value*. New refs go on via `dst_tail`, so a later
refspec could see an earlier refspec's new ref only if the list was
non-empty when the loop started. Against an empty remote, `dst` stayed
`NULL` for the whole loop. Verified with 2.55.0:

```
$ git push --dry-run ../empty main:refs/heads/new main:refs/heads/new
To ../empty
 * [new branch]      main -> new
 * [new branch]      main -> new        # exit 0
$ git push ../empty main:refs/heads/new main:refs/heads/new
remote: error: multiple updates for ref 'refs/heads/new' not allowed
```

With this series both are rejected client-side with
`dst ref refs/heads/new receives from more than one src`, because the map is
updated explicitly. The commit message should say so. The new t5516 test
uses `mk_test testrepo heads/main` (non-empty remote), which already passed
before the series; it is a good regression guard for the `strmap_put()` but
does not exercise the changed case. Suggested addition:

```sh
test_expect_success 'push with two refspecs targeting the same new dst fails (empty remote)' '
	mk_empty testrepo &&
	test_must_fail git push --dry-run testrepo \
		main:refs/heads/new main:refs/heads/new 2>err &&
	test_grep "dst ref refs/heads/new receives from more than one src" err
'
```

`--dry-run` matters: without it the old code was rescued by the server and
`test_must_fail` would pass on both.

**Message**:

- Second paragraph grammar: "With this change, match_explicit_lhs() call
  sites match_explicit() and check_push_refs() have been updated to use the
  new strmap variation introduced in the previous commit, so the separate
  _map form is removed." → "Both callers of match_explicit_lhs() now pass a
  strmap, so fold match_explicit_lhs_map() back into it."
- Add the empty-remote paragraph above.
- `5516.3 +7.7%` (0.13 → 0.14) is noise at this resolution; a parenthetical
  saying so pre-empts the question.

---

## How the `./` acceptance came to be

The short version: `cleanup_path()` is a 2005 filesystem-path cosmetic for
`GIT_DIR=.`; `refname_match()` started routing *refnames* through
`mkpath()` in 2007; the confusion was named and removed from the neighboring
functions in 2017, but that sweep only covered `mksnpath()` callers and
`refname_match()` used `mkpath()`. It has been the last place `cleanup_path()`
could rewrite a refname ever since.

| Date | Commit | Release | What happened | Why it matters here |
|---|---|---|---|---|
| 2005-07-05 | `723c31fea2` Linus, *Add "git_path()" and "head_ref()" helper functions* | 0.99 | `git_path()` is born: printf-style formatting of a **filesystem path** under `$GIT_DIR` into a static buffer. | Establishes the family of path formatters. |
| 2005-07-05 | `f17a1b1bec` Linus, *Fix up path-cleanup in git_path() properly* | 0.99 | Adds the `/* Clean it up */` block: if the result begins with `./`, skip it and any following `/`. Motivation in the message: "`GIT_DIR=.` ends up being what some of the pack senders use ... a `.//HEAD` was cleaned up into `/HEAD`, not `HEAD`". | **Birth of the `./` stripping.** Purely about paths on disk. |
| 2005-07-08 | `26c8a533af` Linus, *Add "mkpath()" helper function* | 0.99 | Creates `path.c`, factors the block into `cleanup_path()`, applies it to both `git_path()` and the new `mkpath()`. Header comment: "I'm tired of doing vsnprintf() etc just to open a file ... `f = open(mkpath("%s/%s.git", base, name), O_RDONLY)` which is what it's designed for." | `mkpath()` is, by its own documentation, for `open()`. |
| 2007-11-11 | `79803322c1` Steffen Prohaska, *add refname_match()* | 1.5.4 | New `refname_match(abbrev, full, rules)`: for each rule in `ref_rev_parse_rules`, `strcmp(full_name, mkpath(*p, abbrev_len, abbrev))`. Moves the rules table out of `sha1_name.c`. | **The bug is born.** Refnames flow through a path formatter; `./refs/heads/x` formats to `refs/heads/x` under the `%.*s` rule. |
| 2007-11-11 | `ae36bdcf51` Steffen Prohaska, *push: use same rules as git-rev-parse to resolve refspecs* | 1.5.4 | `count_refspec_match()` switches from suffix matching to `refname_match()`. Documents that `<src>` matching uses "the same rules used by git-rev-parse to resolve a symbolic ref name". | Push `<src>` inherits the behavior. At the time `dwim_ref()` also used `mkpath()`, so push and rev-parse were at least *consistently* lenient. |
| 2008-10-26 | `94cc355287` Alex Riesen, *Fix mkpath abuse in dwim_ref and dwim_log of sha1_name.c* | 1.6.0.4 | `dwim_ref()`/`dwim_log()` move to `mksnpath()` because `mkpath()`'s static buffer was being clobbered. | First time "mkpath abuse" on refnames is called out. `mksnpath()` still runs `cleanup_path()`, so `./` still stripped. |
| 2014-01-14 | `54457fe509` Michael Haggerty, *refname_match(): always use the rules in ref_rev_parse_rules* | 1.9.0 | Drops the `rules` parameter; table becomes `static`. | Still `mkpath()`. |
| 2017-03-28 | `7f897b6f17` + `6cd4a8982d` Jeff King, *avoid using fixed PATH_MAX buffers for refs* / *avoid using mksnpath for refs* | 2.13.0 | Converts `expand_ref()`, `dwim_log()`, `shorten_unambiguous_ref()` to `strbuf_addf()`. Message: `mksnpath()` "calls cleanup_path(), which removes leading instances of './'. **That's questionable when dealing with refnames, as we could silently canonicalize a syntactically bogus refname into a valid one.**" Sibling commit: "As we move to alternate ref storage, we won't be bound by filesystem limits." | The confusion is named and fixed for the `mksnpath()` callers. `refname_match()` used `mkpath()` and was not in the sweep. **From here on rev-parse rejects `./refs/heads/x` while push `<src>` accepts it.** |
| 2018-08-01 | `60650a48c0` Junio, *remote: make refspec follow the same disambiguation rule as local refs* | 2.19.0 | `refname_match()` returns the rule's precedence instead of 1. | A `./`-prefixed full name matches under rule 1, i.e. with the *highest* precedence, as if exact. |
| 2023-02-15 | `613bef56b8` Jeff King, *shorten_unambiguous_ref(): avoid sscanf()* | 2.40.0 | Introduces `match_parse_rule()`. | The helper 3/5 reuses. |
| 2024-04-05 | `708f7e0590` René Scharfe, *path: remove mksnpath()* | 2.45.0 | `mksnpath()` is gone; `mkpath()` survives for real paths. | `refname_match()` is now the only place `cleanup_path()` can touch a refname (`builtin/pull.c` also builds refnames with `mkpath()`, but its results start with `refs/`, so the cleanup is inert there). |
| 2026-09-30 | `80665ccc31` (this series) | | `refname_match()` uses `match_parse_rule()`; no formatting, no `cleanup_path()`. | Closes the 2017 sweep. |

## Why this is a bug, not a feature

1. **It is not a refname.** No slash-separated component of a refname may
   begin with `.` (`git-check-ref-format(1)` rule 1; enforced by
   `check_refname_component()`, "Component starts with '.'"). The first
   component of `./refs/heads/main` is `.`. `git check-ref-format
   ./refs/heads/main` fails. The local refs being matched against were
   themselves filtered through `check_refname_format()` by
   `get_local_heads()`; the abbreviation must meet the same bar.
2. **It is not a revision expression either.** `git-push(1)` says `<src>`
   "is often the name of the local branch to push, but it can be any
   arbitrary 'SHA-1 expression'". `git rev-parse --verify ./refs/heads/main`
   fails, and has since 2.13 when `expand_ref()` stopped stripping `./`. The
   push refspec parser deliberately accepts anything on the LHS
   (`refspec.c`: "anything goes, for now") *because* `rev-parse` is the
   arbiter of what a `<src>` means; `refname_match()` accepting more than
   `rev-parse` does breaks that contract and the stated design of
   `ae36bdcf51`.
3. **Git already rejects the identical string everywhere else.** The
   fetch-side parser says `fatal: invalid refspec './refs/heads/main:...'`;
   `<dst>` on the push side is rejected the same way. Only push `<src>`
   accepts it, and only because the LHS is left unvalidated for the benefit
   of `rev-parse` syntax.
4. **The acceptance was never designed, documented, or general.** It is a
   side effect of a 2005 `GIT_DIR=.` workaround riding along inside a helper
   whose own header says it exists for `open()`. It only ever worked for
   `./` glued to a *full* refname (never `./main`), so no workflow can be
   relying on it. Jeff King identified this exact hazard in 2017 and removed
   it from the adjacent functions; this is the remaining instance.

## Proposed message for 1/5

```
t5516: demonstrate push with "./"-prefixed source

"git push" accepts a "./"-prefixed refname as the source side of a
refspec:

    $ git push origin ./refs/heads/main:refs/heads/frotz

silently matches the local refs/heads/main and pushes it, as does
".///refs/heads/main".  Nothing else in Git agrees that this string
names a ref:

    $ git check-ref-format ./refs/heads/main; echo $?
    1
    $ git rev-parse --verify ./refs/heads/main; echo $?
    1
    $ git fetch origin ./refs/heads/main:refs/heads/x
    fatal: invalid refspec './refs/heads/main:refs/heads/x'

The acceptance is an accident of implementation.  count_refspec_match()
matches <src> against the local refs with refname_match(), which since
79803322c1 (add refname_match(), 2007-11-11) has expanded each entry of
ref_rev_parse_rules with mkpath() and strcmp()'d the result against the
full refname.  mkpath() is a filesystem path formatter: 26c8a533af (Add
"mkpath()" helper function, 2005-07-08) introduced it for
'open(mkpath("%s/%s.git", base, name))', and it runs its output through
cleanup_path(), which strips a leading "./" and any slashes after it.
That normalization dates to f17a1b1bec (Fix up path-cleanup in
git_path() properly, 2005-07-05) and exists so that GIT_DIR=. does not
yield ".//HEAD".  It has nothing to do with refnames, but when the rule
"%.*s" is expanded with "./refs/heads/main", mkpath() returns
"refs/heads/main", which compares equal to the full name.  Only that
first rule is affected: under the other rules the "./" lands after
"refs/...", where cleanup_path() does not look, which is why "./main"
has never been accepted.

The confusion between refnames and paths here has been noticed before.
ae36bdcf51 (push: use same rules as git-rev-parse to resolve refspecs,
2007-11-11) made push use refname_match() precisely so that <src> would
resolve by "the same rules used by git-rev-parse"; at the time
dwim_ref() went through mkpath() too, so the two were at least
consistent.  94cc355287 (Fix mkpath abuse in dwim_ref and dwim_log of
sha1_name.c, 2008-10-26) moved dwim_ref() to mksnpath() because of
mkpath()'s static buffer.  6cd4a8982d (avoid using mksnpath for refs,
2017-03-28) then removed mksnpath() from expand_ref(), dwim_log() and
shorten_unambiguous_ref() explicitly because it "calls cleanup_path(),
which removes leading instances of './'.  That's questionable when
dealing with refnames, as we could silently canonicalize a
syntactically bogus refname into a valid one."  That sweep covered the
mksnpath() callers; refname_match() used mkpath() and was left behind,
and since then rev-parse has rejected "./refs/heads/main" while push's
<src> matching accepts it.  With 708f7e0590 (path: remove mksnpath(),
2024-04-05) refname_match() became the last place where cleanup_path()
can still rewrite a refname.

This is a bug, not a feature:

 - No slash-separated component of a refname may begin with "."
   (git-check-ref-format(1), check_refname_component()), so
   "./refs/heads/main" is not a refname.  The local refs we match
   against were themselves filtered through check_refname_format() by
   get_local_heads(); the abbreviation must be held to the same rule.

 - The <src> of a push refspec "can be any arbitrary 'SHA-1
   expression'" (git-push(1)), and rev-parse rejects this one.  The
   push refspec parser leaves the LHS unvalidated ("anything goes, for
   now") on the understanding that rev-parse is the arbiter; a matcher
   that accepts more than rev-parse does breaks that contract.

 - The identical string is rejected by the fetch-side parser and as a
   push <dst>.  It is undocumented, and only ever worked for "./" glued
   to a full refname, so nothing can be relying on it.

Add a test_expect_failure documenting the current behavior.  The fix
follows in a subsequent commit.

Signed-off-by: Jon Simons <jon@jonsimons.org>
```

If the maintainer prefers a leaner test-only commit, the two history
paragraphs can move to 3/5's message verbatim; the three-bullet argument
should stay here since this is the commit that asserts "bug".

## Suggested message for 3/5

```
refs: stop expanding rev-parse rules with mkpath() in refname_match()

refname_match() has, since 79803322c1 (add refname_match(),
2007-11-11), matched an abbreviated name against a full refname by
formatting each ref_rev_parse_rules entry with mkpath() and comparing
the result with strcmp().  mkpath() is a filesystem path helper: it
formats into a rotating static buffer with strbuf_vaddf() and then runs
cleanup_path() on the result, which strips a leading "./" and any
slashes that follow it.

Applied to refnames that normalization is wrong.  For the bare "%.*s"
rule the abbreviated name lands at offset 0, so "./refs/heads/foo" (or
".///refs/heads/foo") formats to "refs/heads/foo" and is reported as an
exact match, even though no component of a refname may begin with "."
and neither rev-parse nor the fetch-side refspec parser accepts such a
name.  6cd4a8982d (avoid using mksnpath for refs, 2017-03-28) removed
this exact hazard from expand_ref(), dwim_log() and
shorten_unambiguous_ref(), but refname_match() used mkpath() rather
than mksnpath() and was left behind.

Reuse match_parse_rule(), the helper 613bef56b8
(shorten_unambiguous_ref(): avoid sscanf(), 2023-02-15) introduced for
the reverse direction, moving it up so it is defined before its new
caller.  Each rule check is now a prefix comparison, a suffix strip, a
length check and a memcmp() of the candidate against the abbreviated
name; there is no formatting and no path cleanup.

This changes behavior for every caller of refname_match(): push <src>
matching in count_refspec_match() (the only place a user could have
observed it, since push does not validate <src> as a refname),
--force-with-lease=<ref> matching in apply_cas(), fetch-side matching
in find_ref_by_name_abbrev(), and branch.<name>.merge matching in
branch_merge_matches().  A "./"-prefixed name now matches nothing, so

    git push <remote> ./refs/heads/foo:<dst>

fails with "src refspec ./refs/heads/foo does not match any".  Flip the
test added in the previous commit to test_expect_success.

Avoiding strbuf_vaddf() in this hot path is also a large speedup for
pushes with many refspecs against remotes with many refs, measured with
the p5516 test added in the previous commit:

  Test                           HEAD~1            HEAD
  -----------------------------------------------------------------------
  5516.3: empty:refspecs:1       0.15(0.09+0.11)   0.14(0.07+0.11) -6.7%
  5516.5: empty:refspecs:10      0.38(0.32+0.11)   0.17(0.11+0.11) -55.3%
  5516.7: empty:refspecs:100     2.50(2.43+0.11)   0.49(0.42+0.11) -80.4%
  5516.9: mirror:refspecs:1      0.21(0.15+0.11)   0.16(0.09+0.11) -23.8%
  5516.11: mirror:refspecs:10    0.80(0.73+0.11)   0.26(0.19+0.11) -67.5%
  5516.13: mirror:refspecs:100   6.68(6.59+0.13)   1.18(1.11+0.11) -82.3%

Signed-off-by: Jon Simons <jon@jonsimons.org>
```

## Suggested additions for 5/5

Add after the first paragraph:

```
This also closes a gap in the old code.  match_explicit_refs() received
the remote ref list head by value; refs created by earlier refspecs were
appended through dst_tail, so later refspecs could see them only if the
list was non-empty to begin with.  Against an empty remote,

    git push --dry-run <empty> main:refs/heads/new main:refs/heads/new

reported two "[new branch]" updates and exited 0, and without --dry-run
the duplicate was caught only by receive-pack ("multiple updates for
ref 'refs/heads/new' not allowed").  With the map updated explicitly,
both are now rejected on the client with "dst ref refs/heads/new
receives from more than one src", the same as against a non-empty
remote.
```

and add the empty-remote `--dry-run` test from the 5/5 section above.

## Verification log

- Binary: `./git` built from `a254a852f4`
  (`git version 2.52.0.rc2.3393.ga254a852f4`; version string is
  `git describe`-derived, tags not fetched locally).
- `cd t && ./t5516-fetch-push.sh` → `# passed all 130 test(s)`.
- `cd t && prove -j8 t5510-fetch.sh t5533-push-cas.sh t5505-remote.sh
  t5518-fetch-exit-status.sh t5541-http-push-smart.sh t5523-push-upstream.sh
  t5528-push-default.sh t5536-fetch-conflicts.sh t5548-push-porcelain.sh
  t5560-http-backend-noserver.sh t7406-submodule-update.sh
  t5407-post-rewrite-hook.sh t1430-bad-ref-name.sh t1401-symbolic-ref.sh
  t6300-for-each-ref.sh t5514-fetch-multiple.sh t5512-ls-remote.sh
  t5511-refspec.sh t5583-push-branches.sh t7400-submodule-basic.sh` →
  `Files=20, Tests=1370 ... Result: PASS`.
- `p5516-push-delete-refspec.sh` copied with `ref_count=2000`,
  `GIT_PERF_REPEAT_COUNT=1` → `# passed all 13 test(s)`; copy removed.
- Before/after matrix above: Homebrew `git 2.55.0` vs `./git`, scratch repos
  under `/tmp/review-dotslash/` (a 1-commit `src`, a bare `dst` seeded with
  `refs/heads/main`, a bare `empty`).
- Archaeology: `git log -S` on `cleanup_path`, `mkpath`, `mksnpath`,
  `refname_match`, `ref_rev_parse_rules`; `git blame` of `refname_match()`
  at `origin/main` (loop body last touched by `60650a48c0`, `mkpath()` call
  dating to `79803322c1`); `git describe --contains` for release tags.
