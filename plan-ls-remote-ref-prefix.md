# Plan: `git ls-remote --ref-prefix=<prefix>`

## Goal

Add a repeatable `--ref-prefix=<prefix>` option to `git ls-remote`. A ref is
shown when its full name starts with any given prefix. When protocol v2 is
negotiated, the same prefixes are sent as `ref-prefix` lines in the `ls-refs`
request so the server omits non-matching refs from its advertisement. On
v0/v1, the full advertisement is fetched and filtered locally, so output is
identical across protocol versions.

The option name matches the protocol argument in `gitprotocol-v2(5)` and the
`GIT_TRACE_PACKET` output (`ls-remote> ref-prefix ...`).

Motivating case: `git ls-remote --symref <url> HEAD` (used by
`scalar.c:remote_default_branch()` and similar tools) forces a full ref
advertisement, because `<patterns>` are tail-matched globs and cannot be
turned into a `ref-prefix` (see `631f0f8c4b`, "ls-remote: do not send ref
prefixes for patterns"). `--ref-prefix=HEAD` makes the intent explicit, so
the client can safely send `ref-prefix HEAD`.

## Decisions

- **Name**: `--ref-prefix`, same as the wire argument.
- **Empty value is an error**: `--ref-prefix=` dies with a usage-style
  message. The server would treat an empty `ref-prefix` as "match
  everything", which would make the option a silent no-op.
- **No hard v2 requirement**: the option is a filter first and a protocol
  optimization second. On v0/v1 the full advertisement is fetched and the
  same filter is applied locally, with no warning. v0-only servers are
  nearly obsolete, and failing after the advertisement has already arrived
  would save nothing.
- **Unborn `HEAD` behavior is unchanged**: an empty remote repository
  prints nothing, as it does today for every form of `ls-remote`. See
  "Unborn HEAD" below and the test that pins the behavior.

## Semantics

| Input | Server (v2 only) | Client filter | Match rule |
|---|---|---|---|
| `--branches` / `--tags` | `ref-prefix refs/heads/` / `refs/tags/` | `check_ref_type()` | namespace, OR between the two |
| `--ref-prefix=<p>` (new) | `ref-prefix <p>` per value | new `prefix_match()` | `starts_with(name, p)`, OR across values |
| `<patterns>` | nothing | `tail_match()` | tail glob, OR across patterns |

- Between kinds, filters AND: a ref must pass `check_ref_type()`,
  `prefix_match()`, and `tail_match()`. This matches how `<patterns>` already
  compose with `--branches`/`--tags`.
- Client-side `prefix_match()` must use exactly the server's rule in
  `ls-refs.c:ref_match()` (`starts_with` on the namespace-stripped name) so
  v0 and v2 produce the same set.
- Server-side, all prefixes from all sources are sent as a union. That is a
  superset of the client's AND result, which is what protocol v2 permits ("a
  server MAY show refs not matching the prefix").
- Peeled entries (`refs/tags/v1^{}`) and `HEAD` are ordinary `struct ref`
  names on the client and pass through `prefix_match()` as-is.
- Validation: reject an empty value, and reject values containing LF (the
  pkt-line is `ref-prefix %s\n`; `--server-option` documents the same
  NUL/LF rule). No `check_refname_format()` call: `refs/heads/ma` is a valid
  prefix but not a valid refname.
- Protocol fallback is silent, like `--branches`/`--tags`.

### Unborn HEAD

Against an empty repository, `ls-remote --symref --ref-prefix=HEAD` prints
nothing and exits 0 (2 with `--exit-code`). This is existing behavior, not
something this topic changes:

- On v2, `ls-refs.c:send_possibly_unborn_head()` applies the same
  `ref_match()` check, so with `ref-prefix HEAD` the server does send
  `unborn HEAD symref-target:refs/heads/<name>`. The client's
  `connect.c:process_ref_v2()` stores that target in
  `transport_ls_refs_options.unborn_head_target` and adds no `struct ref`;
  `ls-remote` never reads `unborn_head_target`, so nothing is printed.
- On v0, an empty repository advertises only the `capabilities^{}` line.

Printing `ref: <target>\tHEAD` for an unborn `HEAD` would be a separate
enhancement; it is outside this topic. A test documents the current output.

## Changepoints

### `builtin/ls-remote.c`

1. `ls_remote_usage[]`: add `[--ref-prefix=<prefix>]` to the usage string.
   `t/t0450-txt-doc-vs-help.sh` checks `-h` output against the documentation
   SYNOPSIS, so this and the `.adoc` synopsis must change together.
2. `options[]`: `OPT_STRING_LIST(0, "ref-prefix", &ref_prefixes,
   N_("prefix"), N_("limit to refs whose name starts with <prefix>"))`. Not
   hidden; bash completion picks it up through `__gitcomp_builtin ls-remote`
   with no completion-script change.
3. After `parse_options()`: validate each value (non-empty, no LF), `die()`
   otherwise.
4. Next to the existing `if (flags & REF_TAGS)
   strvec_push(&transport_options.ref_prefixes, ...)` block: push each
   `--ref-prefix` value into `transport_options.ref_prefixes`. This is the
   entire protocol change; `connect.c:get_remote_refs()` already emits one
   `ref-prefix` line per entry, and `transport.c:handshake()` only calls it
   when v2 was negotiated.
5. Add `static int prefix_match(const struct string_list *prefixes, const
   char *name)` beside `tail_match()`: return 1 when the list is empty,
   otherwise `starts_with()` against each entry.
6. In the result loop, insert `if (!prefix_match(&ref_prefixes, ref->name))
   continue;` between `check_ref_type()` and `tail_match()`.
7. Release the list at exit.

### `Documentation/git-ls-remote.adoc`

- SYNOPSIS: add `[--ref-prefix=<prefix>]` (must mirror the `-h` string for
  t0450).
- OPTIONS: new entry after `--symref`/before `--sort`, or near
  `--branches`/`--tags`. Draft:

  > `--ref-prefix=<prefix>`: Only show references whose full name starts
  > with `<prefix>`. May be given more than once; a reference is shown when
  > it matches any of the given prefixes. The value must not be empty.
  > Unlike `<patterns>`, which are globs matched against the tail of a
  > reference name, a prefix is matched literally against the start of the
  > full name: `refs/heads/ma` matches `refs/heads/main` and
  > `refs/heads/maint`; `HEAD` matches the remote's `HEAD` but not
  > `refs/remotes/origin/HEAD`. When the remote speaks protocol version 2,
  > the prefixes are also sent to the server so it can omit non-matching
  > references from its advertisement; with older protocols the full
  > advertisement is fetched and filtered locally. A reference must satisfy
  > `--branches`/`--tags`, every `--ref-prefix` group, and `<patterns>` when
  > more than one kind of restriction is given.

### No changes needed

- `transport.c`, `transport.h`, `connect.c`, `ls-refs.c`:
  `transport_ls_refs_options.ref_prefixes` already carries prefixes end to
  end for `git://`, `ssh://`, `file://`, and smart HTTP (via `remote-curl`
  `stateless-connect` → `get_refs_via_connect`).
- `transport-helper.c`: helpers without `stateless-connect` use the `list`
  command and ignore `ref_prefixes`; the client-side filter keeps output
  correct there.
- `contrib/completion/git-completion.bash`: automatic.
- `ls-refs.c` `TOO_MANY_PREFIXES` (65536): a pathological number of
  `--ref-prefix` values makes the server ignore the hint entirely; the
  client filter still yields correct output. No client-side cap needed.

## Tests

### `t/t5512-ls-remote.sh` (protocol-independent behavior)

Setup already provides `refs/heads/main`, lightweight tags `mark`,
`mark1.1`, `mark1.2`, `mark1.10`, and (after the `--symref` test runs `git
fetch origin`) `refs/remotes/origin/HEAD` and `refs/remotes/origin/main`.
New tests, placed after the existing `ls-remote prefixes work with all
protocol versions` test:

1. **Literal prefix match**: `git ls-remote --ref-prefix=refs/tags/mark1.
   self` equals `generate_references refs/tags/mark1.1 refs/tags/mark1.10
   refs/tags/mark1.2`. Shows that a prefix is not a tail glob and does not
   need a trailing `/`.
2. **Multiple values union**: `--ref-prefix=refs/heads/
   --ref-prefix=refs/tags/mark1.1` yields heads plus `mark1.1` and
   `mark1.10`.
3. **`HEAD` only**: `git ls-remote --symref --ref-prefix=HEAD .` yields
   exactly `ref: refs/heads/main\tHEAD` and `$oid\tHEAD`. Contrast with the
   existing `ls-remote with filtered symref (refname)` test, where the
   pattern `HEAD` also returns `refs/remotes/origin/HEAD`. This is the
   motivating case.
4. **AND with `<patterns>`**: `--ref-prefix=refs/tags/ . mark1.1` yields
   only `refs/tags/mark1.1` (pattern `*/mark1.1` excludes `mark1.10`).
5. **AND with `--branches`/`--tags`**: `--branches --ref-prefix=refs/tags/
   self` prints nothing and exits 0; with `--exit-code` exits 2. `--tags
   --ref-prefix=refs/tags/mark1.` yields the three `mark1.*` tags.
6. **`--exit-code`**: `--exit-code --ref-prefix=refs/nsn/` exits 2.
7. **Same output on every protocol**: run cases 1 and 3 under `-c
   protocol.version=0` and `=2` and `test_cmp` (mirrors the existing
   `patterns work with all protocol versions` test).
8. **Validation**: `test_must_fail git ls-remote --ref-prefix= .` and
   `test_must_fail git ls-remote --ref-prefix="$(printf 'a\nb')" .`.
9. **Sorting still applies**: `--sort=-refname
   --ref-prefix=refs/tags/mark1.` yields `mark1.2, mark1.10, mark1.1`
   (confirms filtering happens before `ref_array_sort()`).
10. **Unborn HEAD prints nothing**: `git init --bare unborn.git`, then
    `git ls-remote --symref --ref-prefix=HEAD unborn.git >actual` with
    `test_must_be_empty actual`, under both `-c protocol.version=0` and
    `=2`, and `test_expect_code 2` when `--exit-code` is added. Pins the
    "unchanged" claim above.

### `t/t5702-protocol-v2.sh` (wire behavior)

Use `GIT_TRACE_PACKET` as the existing clone/fetch tests do. Note the
existing test named `ref advertisement is filtered with ls-remote using
protocol v2` only checks output, not the wire; the new tests check both.

1. **git:// sends prefixes**: `ls-remote --ref-prefix=refs/heads/
   "$GIT_DAEMON_URL/parent"`; assert `test_grep "ls-remote> ref-prefix
   refs/heads/" log`, `test_grep "ls-remote< version 2" log`, and that the
   server response omitted tags: `test_grep ! "ls-remote< .*refs/tags/one"
   log`.
2. **file:// `HEAD` only**: `ls-remote --symref --ref-prefix=HEAD
   "file://$(pwd)/file_parent"`; assert `ref-prefix HEAD` was sent and `!
   "ls-remote< .*refs/tags/"` in the response. Avoid asserting on
   `refs/heads/` absence, since the `HEAD` line itself carries
   `symref-target:refs/heads/main`.
3. **Multiple values each produce a line**: assert both `ref-prefix
   refs/heads/` and `ref-prefix refs/tags/one` appear.
4. **Combined with `--tags`**: assert both `ref-prefix refs/tags/` and the
   user prefix appear (union is sent).
5. **HTTP v2**: in the httpd section near `ls-remote with v2 http sends only
   one POST`, run `--ref-prefix=refs/heads/` against
   `$HTTPD_URL/smart/http_parent`, assert the `ref-prefix` line and that
   only one POST was made.
6. **HTTP v0 fallback**: same command with `-c protocol.version=0`; assert
   no `ref-prefix` line in the trace and that stdout equals the v2 run's
   stdout.
7. **Unborn HEAD on the wire**: against the existing `file_empty_parent`
   (or a fresh empty repo), `ls-remote --symref --ref-prefix=HEAD`; assert
   `ls-remote> ref-prefix HEAD`, `ls-remote< unborn HEAD symref-target:`
   in the trace, and empty stdout. Documents that the server still answers
   and that the client's output is unchanged.

### Optional: `t/t5801-remote-helpers.sh`

`git ls-remote --ref-prefix=refs/heads/ testgit::...` filters locally
through a `list`-only helper. Cheap insurance that the client filter is not
bypassed on non-connect transports.

### Optional, only if the scalar patch is included: `t/t9211-scalar-clone.sh`

Run `scalar clone` with `GIT_TRACE_PACKET` and assert `ls-remote> ref-prefix
HEAD` and that the `ls-remote<` response does not include the test repo's
other branch names.

## Patch structure: a small topic, not one commit

Recommended: a 2-patch topic, plus one optional follow-on. Each step is
independently testable and bisectable, and the split mirrors how the 2018
fix separated correctness (`631f0f8c4b`) from optimization (`6a139cdd74`).

1. **`ls-remote: add --ref-prefix to limit output by literal prefix`**
   Option parsing, validation, `prefix_match()`, documentation, usage
   string, and all `t5512` tests. Purely client-side; identical behavior on
   every protocol version. The commit message should explain why
   `<patterns>` cannot be used for this (tail-glob semantics, citing
   `631f0f8c4b`) and define the AND/OR composition rules.

2. **`ls-remote: send --ref-prefix values as protocol v2 ref-prefixes`**
   The `strvec_push` into `transport_options.ref_prefixes` and the `t5702`
   wire tests. The message should state this is an optimization only, that
   the client still filters, and that v0/v1 output is unchanged (point at
   the equivalence test from patch 1).

3. **Optional: `scalar: ask only for HEAD when discovering the default
   branch`**
   Change `scalar.c:remote_default_branch()` from `ls-remote --symref <url>
   HEAD` to `ls-remote --symref --ref-prefix=HEAD <url> HEAD`. Keeping the
   pattern preserves the exact set of lines the parser looks for; the prefix
   stops the full advertisement on v2 servers. Scalar invokes the same `git`
   binary, so there is no version-skew concern. This patch demonstrates the
   real-world win and is the natural place to quantify it in the cover
   letter (ref count before/after on a large repo).

A single squashed commit is defensible because the total diff is roughly 40
lines of C, but the split costs little and gives reviewers one concept per
patch.
