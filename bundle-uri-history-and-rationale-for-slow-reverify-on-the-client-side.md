# History of `bundle-uri`, and why the client re-indexes

An archaeology of Git’s `bundle-uri` feature: the commits that built
it, the client codepath that downloads a bundle and then spends a
long time running `index-pack`, why that re-verify exists, and
whether a published `.pack` + `.idx` pair could skip it.

The short answer to the last question is **yes, for the large-clone
case that matters**. A complete (non-thin) clone bundle is a pack
with a small text header. Git cannot use a pack without an `.idx`.
Today the client always *rebuilds* that idx by inflating and hashing
every object. The publisher already has a correct idx. Installing
that pair, plus a cheap trailer check, is enough to seed the object
database. The bundle container is what forces `index-pack --stdin`.
As it stands, `bundle-uri` is not useful for speeding up large
clones: the CDN download is sequential with a full-history
`index-pack`, and a normal clone already pipelines those two.

Canonical in-tree sources:

- `Documentation/technical/bundle-uri.adoc`
- `Documentation/gitprotocol-v2.adoc` (`bundle-uri` section)
- `Documentation/gitformat-bundle.adoc`
- `bundle-uri.c` / `bundle-uri.h`
- `bundle.c` (`unbundle()`, `verify_bundle()`)
- `builtin/clone.c`, `builtin/fetch.c`, `transport.c`, `connect.c`
- `t/t5558-clone-bundle-uri.sh`, `t/t5730`–`t/t5732`

Related design notes in this tree (not upstream history):
`history-of-packfile-uri-feature-and-potential-future.md`,
`packfile-uri-with-idx-extension.md`. The idx-extension note is the
same skip-`index-pack` argument, applied to `packfile-uris`.

## What landed

`bundle-uri` lets a client seed its object database from one or more
prebuilt Git *bundles* (header + pack) fetched over HTTP(S) or
`file://`, then catch up with a normal fetch from the origin.

Two discovery paths:

1. The user passes `--bundle-uri=<uri>` to `git clone` (Git 2.38).
2. A protocol-v2 server advertises the `bundle-uri` capability; a
   client with `transfer.bundleURI=true` issues `command=bundle-uri`
   *before* `fetch` and gets a list of `bundle.*` key-value pairs
   (Git 2.40). The in-tree server just dumps its `bundle.*` config
   (`uploadpack.advertiseBundleURIs`).

The URI payload is either a bundle (`git bundle verify` would accept
it) or a plaintext Git-config *bundle list* describing more URIs.
Lists have `bundle.mode=all|any`, optional
`bundle.heuristic=creationToken`, and per-id keys (`uri`,
`creationToken`, `filter`, …). Incremental fetches can persist
`fetch.bundleURI` + `fetch.bundleCreationToken`.

The *protocol* is deliberately loosely coupled. The origin does not
need to know the exact contents of the files on the CDN. After the
client unbundles, it writes the bundle’s refs under `refs/bundles/`
and uses those tips as `have`s in the subsequent fetch. That is the
feature’s whole point relative to `packfile-uris`: the origin can
advertise “here are some snapshots” without computing a pack that
omits exactly those objects.

The *consumption* path is not new. It is `git bundle unbundle`:
parse the header, `verify_bundle()`, then

```text
git index-pack --stdin --fix-thin
```

on the remaining bytes. That last step is the drawback that keeps
the feature from speeding up large clones.

## History of the development

Author dates. Merge commits omitted except topic merges that
introduced a slice of the feature. “Git” is the first release
RelNotes that mention the change, or the first tag that contains it.

### Before the commits: two prior arts, one RFC

The design that shipped (`2da14fad8f`, Git 2.38) cites both.

**Packfile URIs** (Git 2.28, `jt/cdn-offload`) already let a server
point the client at CDN packs as part of a `fetch` response. Gerrit
(JGit) uses this. The bundle-uri design doc calls out the downside
that made them want a different protocol: the origin must know
*exactly* what is in those packs, the packs must stay up for some
time after the response, and the shape is “extremely hard to make
work with fetches.”

**GVFS cache servers** are the organizational model. A cache server
builds hourly / daily / 30-day-rollup “prefetch” packs of commits
and trees. Clients download those, then talk to the origin for refs
and on-demand objects. `bundle-uri` is the in-tree attempt to get
that prefetch pattern without the GVFS protocol.

**Ævar Arnfjörð Bjarmason’s RFC** (August 2021; v2 March 2022)
proposed a protocol-v2 `bundle-uri` command. The v2 cover is
[RFC-patch-v2-01.13](https://lore.kernel.org/git/RFC-patch-v2-01.13-2fc87ce092b-20220311T155841Z-avarab@gmail.com/).
An earlier RFC is cited from the design doc:
[RFC-cover-00.13](https://lore.kernel.org/git/RFC-cover-00.13-0000000000-20210805T150534Z-avarab@gmail.com/).
Ævar’s first transfer format was not the `key=value` list that
landed; the unified format came from merging that protocol skeleton
with Derrick Stolee’s bundle-list design.

Prerequisite, not bundle-uri itself: Git 2.36 extended the bundle
*file* format (v3 capabilities, including a filter) so a bundle can
describe a partial clone. That is why blobless bundle lists are
expressible later.

### Landing (`ds/bundle-uri`, Git 2.38): docs + `--bundle-uri`

RelNotes 2.38: “`git clone` learned the `--bundle-uri` option to
coordinate with hosting sites the use of pre-prepared bundle files.”
Also: “The bundle URI design gets documented.”

| Date | Commit | Author | Subject |
|---|---|---|---|
| 2022-08-09 | `2da14fad8f` | Derrick Stolee | docs: document bundle URI standard |
| 2022-08-09 | `d06ed85dcb` | Derrick Stolee | bundle-uri: add example bundle organization |
| 2022-08-09 | `53a50892be` | Derrick Stolee | bundle-uri: create basic file-copy logic |
| 2022-08-09 | `5556891961` | Derrick Stolee | clone: add `--bundle-uri` option |
| 2022-08-09 | `59c1752ab6` | Derrick Stolee | bundle-uri: add support for `http(s)://` and `file://` |
| 2022-08-09 | `e21e663cd1` | Derrick Stolee | clone: `--bundle-uri` cannot be combined with `--depth` |
| 2022-08-18 | `0d133a3dcf` | Junio C Hamano | Merge branch `ds/bundle-uri-more` |

The design document is explicit that it is *aspirational*. The
implementation plan in that commit is the roadmap that the next
three series actually followed:

1. `clone --bundle-uri` for a single bundle.
2. Parse a bundle list; honor `bundle.mode`.
3. Protocol-v2 `bundle-uri` command; clone discovers URIs.
4. `creationToken` heuristic; persist the URI for later fetches.
5. Discover URIs during `git fetch` as well.
6. “Inspect headers” to avoid downloading a bundle whose tips are
   already present.

Step 6 never landed. Nothing in the plan mentions skipping
`index-pack` or shipping an `.idx`. The stated costs to optimize
were **origin CPU** (avoid `pack-objects` for the bulk of a clone)
and **path to the origin** (pull a snapshot from a closer CDN).
Client-side indexing was treated as the same work a normal clone
already does, not as a new sequential tax.

`5556891961` is the motivation in one paragraph:

> Cloning a remote repository is one of the most expensive
> operations in Git. The server can spend a lot of CPU time
> generating a pack-file for the client's request. The amount of
> data can clog the network for a long time, and the Git protocol
> is not resumable.

The first cut expects a single bundle at the URI and feeds it to
the existing unbundle path. HTTP download is a `git-remote-https`
`get` into a tempfile under `objects/bundles/tmp_uri_XXXXXX`.

### Bundle lists (`ds/bundle-uri-3`, Git 2.39)

RelNotes 2.39: “Define the logical elements of a bundle list, data
structure to store them in-core, format to transfer them, and code
to parse them.”

| Date | Commit | Author | What changed |
|---|---|---|---|
| 2022-10-12 | `0634f717a3` | Derrick Stolee | `bundle_list` / `remote_bundle_info` |
| 2022-10-12 | `bff03c47f7` | Derrick Stolee | Base key-value pair parsing |
| 2022-10-12 | `9424e373fd` | Ævar Arnfjörð Bjarmason | `key=value` line parsing |
| 2022-10-12 | `d796cedbe8` | Ævar Arnfjörð Bjarmason | Unit test for `key=value` parsing |
| 2022-10-12 | `738e5245fa` | Derrick Stolee | Parse a bundle list in config format |
| 2022-10-12 | `20c1e2a68b` | Derrick Stolee | Recursion depth limit (4) |
| 2022-10-12 | `c23f592117` | Derrick Stolee | Fetch a list of bundles |
| 2022-10-12 | `89bd7fedf9` | Derrick Stolee | Flags on `verify_bundle()` (`QUIET`) |
| 2022-10-12 | `70334fc3eb` | Derrick Stolee | Quiet failed unbundlings (try the next bundle) |
| 2022-10-12 | `8628a842bd` | Derrick Stolee | Suppress stderr from `remote-https` |

This is where “download everything, then try to unbundle in an
order that satisfies prerequisites” appears. Failed unbundles are
expected when a newer incremental bundle is applied before its
base. `VERIFY_BUNDLE_QUIET` exists so those failures are not
user-visible noise.

### Protocol v2 command (`ds/bundle-uri-4`, Git 2.40)

| Date | Commit | Author | What changed |
|---|---|---|---|
| 2022-12-22 | `8b8d9a2298` | Ævar Arnfjörð Bjarmason | Server-side `bundle-uri` skeleton; `uploadpack.advertiseBundleURIs` |
| 2022-12-22 | `0cfde740f0` | Ævar Arnfjörð Bjarmason | clone: request the command when available |
| 2022-12-22 | `7cce9074a7` | Ævar Arnfjörð Bjarmason | Client opt-in: `transfer.bundleURI` |
| 2022-12-22 | `70b9c10373` | Ævar Arnfjörð Bjarmason | Test helper for the server |
| 2022-12-22 | `738dc7d4a5` | Derrick Stolee | Serve `bundle.*` keys from config |
| 2022-12-22 | `ebc3947955` | Derrick Stolee | Relative URLs in bundle lists |
| 2022-12-22 | `12b0a14b9e` | Derrick Stolee | Download bundles from an advertised list |
| 2022-12-22 | `876094ac16` | Derrick Stolee | clone: unbundle the advertised bundles |
| 2023-01-02 | `0903d8bbde` | Junio C Hamano | Merge branch `ds/bundle-uri-4` |

`8b8d9a2298` records the format unification: Ævar’s earlier series
used a different transfer format; they switched to the same
`key=value` / `bundle.*` namespace the HTTP bundle-list file
already used, so one parser serves both. The capability is
advertised with no value. Discovery is **opt-in**
(`transfer.bundleURI`, default false) so existing clones do not
suddenly hit a CDN.

The protocol text in `gitprotocol-v2.adoc` is written for graceful
degradation: a bad or missing bundle must not fail the clone. The
origin remains the source of truth. Clients “MAY” disconnect early
and “SHOULD” start the incremental `fetch` using advertised tips
as `have`s even while the bundle is still downloading. The
implementation does not do that overlap: it finishes the bundle
path, then fetches.

### Incremental fetches (`ds/bundle-uri-5`, Git 2.40)

RelNotes 2.40: “The bundle-URI subsystem adds support for
creation-token heuristics to help incremental fetches.”

| Date | Commit | Author | What changed |
|---|---|---|---|
| 2023-01-31 | `c93c3d2fa4` | Derrick Stolee | Parse `bundle.heuristic=creationToken` |
| 2023-01-31 | `512fccf8a5` | Derrick Stolee | Parse `bundle.<id>.creationToken` |
| 2023-01-31 | `7903efb717` | Derrick Stolee | Download in creationToken order |
| 2023-01-31 | `4074d3c7e1` | Derrick Stolee | clone: set `fetch.bundleURI` if the list has a heuristic |
| 2023-01-31 | `7f0cc04f2c` | Derrick Stolee | fetch: fetch from an external bundle URI |
| 2023-01-31 | `c429bed102` | Derrick Stolee | Store `fetch.bundleCreationToken` |
| 2023-02-15 | `4f59836451` | Junio C Hamano | Merge branch `ds/bundle-uri-5` |

This is the GVFS prefetch schedule, in Git terms: newest token
first until a bundle applies, then walk back up applying
incrementals; persist the max token so the next `git fetch` skips
the list if nothing newer exists.

### Correctness, security, and ref-advertisement follow-ups

| Date | Commit | Git | Author | What changed |
|---|---|---|---|---|
| 2023-03-31 | `25bccb4b79` | 2.41 | Derrick Stolee | `fetch --all` must not download the same bundle URI once per remote |
| 2024-06-19 | `3079026fc1` | 2.46 | Xing Xin | Verify OIDs before writing `refs/bundles/*` (tips were lost; the follow-up fetch re-downloaded everything) |
| 2024-06-19 | `63d903ff52` | 2.46 | Xing Xin | `unbundle` honors `fetch.fsckObjects` / `transfer.fsckObjects` via `index-pack --fsck-objects` |
| 2025-04-25 | `c858c6442b` | 2.50 | Scott Chacon | Copy *all* `refs/*` from the bundle, not only `refs/heads/*` (RelNotes: “did not use refs recorded in the bundle other than normal branches as anchoring points”) |
| 2025-05-14 | `35cb1bb0b9` | 2.43.7 | Patrick Steinhardt | CVE-2025-48385: `git-remote-https` `get $uri $file` injection via space/newline in the advertised URI (arbitrary file write / protocol injection) |
| 2025-12-19 | `7796c14a1a` | 2.53 | Sam Bostock | Reject bundle-list entries that have no `uri` |

The Xing Xin and Chacon fixes are about making the *subsequent*
fetch actually see the objects you just paid to download. They do
not touch the `index-pack` cost. The security fix is a reminder
that advertised URIs are adversary-controlled: the client already
treats bundle bytes as untrusted input, which is one reason the
default path runs a full object-level verify.

### What the design promised and the tree still does not do

From `Documentation/technical/bundle-uri.adoc` and the protocol
“future keys” list:

- Inspect bundle headers (or advertised `oid=` / `prerequisite=`)
  and cancel the rest of a download when tips are already present.
- Overlap bundle download with the incremental `fetch`.
- `hash=<val>` / `size=<bytes>` on the advertisement.
- Geographic `bundle.mode=any` selection by `location`.
- Header-only probes.

`hash=` is the interesting one for this note. It was proposed so a
client could skip *opening* a bundle to read its header. Combined
with a published idx it would also be enough to skip *indexing*.
That connection was not made in the original design.

## Today’s client codepath: download, then re-index

End-to-end for `git clone --bundle-uri=<uri>` or a
`transfer.bundleURI` clone that got a non-empty list.

```text
clone
  ls-refs                          # learn remote refs / hash algo
  create empty repo
  fetch_bundle_uri() or fetch_bundle_list()
    download URI(s) to objects/bundles/tmp_uri_*
    if config file: parse list, recurse (depth ≤ 4)
    if bundle:     unbundle_from_file()
  unlink tempfiles
  transport_fetch_refs()           # normal fetch, seeded by refs/bundles/*
  checkout
```

`builtin/fetch.c` is the same `fetch_bundle_uri()` call when
`fetch.bundleURI` is set, *before* talking to remotes.

### 1. Download is a full-file copy, not a pack stream

`copy_uri_to_file()` (`bundle-uri.c`):

- `http:` / `https:` → `download_https_uri_to_file()`: spawn
  `git-remote-https`, issue `get <uri> <tempfile>`, wait for the
  whole body.
- `file://` or a bare path → `copy_file()`.

There is no Range, no overlap with indexing, no progress into
`index-pack`. The tempfile lives under the object database
(`odb_mkstemp(..., "bundles/tmp_uri_XXXXXX")`) and is unlinked
after unbundle, whether it succeeded or not.

For `creationToken` lists, `fetch_bundles_by_token()` downloads
newest-first until one unbundles, then walks back applying older
ones. A fresh clone typically downloads *all* listed bundles
before the oldest (complete) one applies. Each of those is a
full GET plus, once prerequisites exist, a full `index-pack`.

### 2. `unbundle_from_file()` is the only consume path

```text
read_bundle_header(file, &header)     # parse "# v2/v3 git bundle",
                                      # prereqs, refs; fd now at pack
unbundle(r, &header, bundle_fd, NULL, &opts)
  verify_bundle(r, header, flags)
  run: git index-pack --stdin --fix-thin
       [--promisor=from-bundle]       # if bundle has a filter
       [--fsck-objects[=...]]         # if fetch/transfer.fsckObjects
for each header ref under refs/:
  refs_update_ref(refs/bundles/<rest>)
```

`opts.flags` is `VERIFY_BUNDLE_QUIET`, plus `VERIFY_BUNDLE_FSCK`
when `fetch_pack_fsck_objects()` is true (`63d903ff52`). There is
no `-v`, so this `index-pack` is silent. `extra_index_pack_args`
is NULL on the bundle-uri path (the local-bundle transport in
`transport.c:fetch_refs_from_bundle` *does* pass `-v` when
progress is on). That local-bundle path is the same `unbundle()`;
cloning a `.bundle` file has the same indexing cost.

A comment above the `unbundle()` call says “skip the reachability
walk here.” That is not what the code does. `unbundle()` always
calls `verify_bundle()`. The comment is leftover intent; the
expensive work is not that walk anyway.

### 3. `verify_bundle()` is cheap on a complete clone bundle

`bundle.c:verify_bundle()`:

1. For each prerequisite OID, `parse_object()`. Missing prereq →
   fail (the creationToken walker then tries an older bundle).
2. `check_connected()` on the prereq list: the objects exist *and*
   are connected to the repository’s history.

A full-clone bundle has an empty prereq list. Both steps are
near-free. Incremental bundles pay a real but small cost here.
This is **not** the “ton of time.”

### 4. `index-pack --stdin --fix-thin` is the ton of time

`unbundle()` always spawns that command and sets `ip.in = bundle_fd`
(already past the header). `index-pack --stdin` then:

1. Creates `objects/pack/tmp_pack_XXXXXX` and **copies the pack
   bytes from stdin into that file** (`open_pack_file()` when
   `from_stdin`). The bundle tempfile is a complete extra copy of
   the same bytes.
2. Parses every object, inflates it, resolves OFS/REF deltas,
   hashes the inflated content, and checks that the hash matches
   the claimed OID. That is the same work as a normal clone’s
   `index-pack`, minus the download overlap.
3. If `--fix-thin` finds REF_DELTAs whose bases are not in the
   pack, it reads those bases from the ODB, appends them, and the
   pack hash changes. Needed for incremental (thin) bundles.
   A complete clone bundle is thick; `--fix-thin` is then a no-op
   for appending, but the inflate/hash scan still runs.
4. Writes `pack-<hash>.idx` (and, by default, a `.rev`).
5. Renames the tempfile to `pack-<hash>.pack`.

Git will not look up objects in a `.pack` that has no `.idx`.
`add_packed_git()` only accepts idx paths; it then requires a
matching `.pack`. There is no “use this pack as a stream of
objects” path after the download. So *some* idx must appear before
the follow-up fetch or checkout can see the data.

`--fsck-objects` (only when the user asked for fetch/transfer
fsck) walks the same inflated objects with the fsck machinery. The
default path already hashed every object; fsck is extra policy, not
the reason the default is slow.

After success, `fetch_bundle_uri()` unlinks the downloaded bundle.
The durable result is exactly `objects/pack/pack-<hash>.{pack,idx}`
plus `refs/bundles/*`. The publisher produced those same two pack
files when they ran `git bundle create` (which itself runs
`pack-objects` and could have kept the idx).

### 5. Then a normal fetch, hoping the refs work as `have`s

`clone` continues into `transport_fetch_refs()`. Negotiation sees
`refs/bundles/*` (after `c858c6442b`, every `refs/*` from the
bundle, not only heads). If the bundle actually contained the
clone’s tips, the incremental pack is small. If tip writing failed
(`3079026fc1`’s bug) or only heads were copied (the pre-2.50
behavior), the client re-downloads objects it just indexed.

That second failure mode is independent of `index-pack`, but it is
why “we downloaded a bundle” has not always meant “the clone got
faster.”

## Why do we re-index / re-verify?

Not because someone measured large clones and chose this. Because
`bundle-uri` reused `git bundle unbundle`, and that command has
always been “header + `index-pack --stdin --fix-thin`.” Several
constraints make that the conservative default.

**There is no idx in the bundle format.**
`gitformat-bundle(5)`: a bundle is a signature, optional v3
capabilities, prerequisites, references, a blank line, then a
pack. No trailer hash is advertised on the URI either (the
protocol lists `hash=` as future work). The only way the client
can *produce* an idx from those bytes is to index them.

**Git cannot use a pack without an idx.**
Object lookup, the connectivity check, checkout, and the
follow-up fetch’s `have` walk all go through packed-git. A
downloaded `.pack` sitting next to the bundle tempfile is inert.

**Thin incremental bundles need `--fix-thin`.**
The creationToken story is “base bundle + daily incrementals.”
Those incrementals are often thin: deltas against prerequisite
commits that are not in the incremental pack. `index-pack
--fix-thin` injects those bases and writes a self-contained pack.
A published idx of the *thin* pack is not sufficient unless the
client also has the bases and is willing to fix-thin itself (or
the publisher ships thick incrementals).

**The URI is untrusted.**
Bundles come from a CDN or a `--bundle-uri` the user typed. The
protocol’s error-recovery rule is “degrade, don’t fail the clone.”
`index-pack` is the same integrity bar a normal `git fetch` uses:
inflate every object, check the content hash, optionally fsck.
CVE-2025-48385 showed the advertisement itself can be hostile.
Skipping object-level verify is a *trust* change, not just a
performance tweak.

**`--fix-thin` can rewrite the pack.**
If bases are appended, the pack hash changes. You cannot install
a publisher idx of the pre-fix pack and call it the post-fix
pack. Complete (thick) clone bundles do not hit this. The API
still always passes `--fix-thin` because one function serves
both complete and incremental bundles.

**The original success metric did not include client CPU.**
The cover letter and design doc optimize origin `pack-objects`
CPU and last-mile bandwidth. A normal clone already runs
`index-pack` *while* the pack arrives. Reusing that same command
looked free. It is not free when you first write the entire
bundle to disk and only then start indexing: you pay download,
a second full write, and the inflate/hash scan, all in series.
On a large repo that scan is minutes of CPU, comparable to the
download and far more than the subsequent incremental fetch.

So: we re-verify because the consume API is “turn a pack *stream*
into a usable pack+idx,” the file we downloaded is a stream with
a header, and nobody added a path that installs a ready-made idx.

## Could we reuse a simple `.pack` + `.idx` and skip the heavy re-verify?

Yes. That is the right artifact for “speed up a large clone.”
The bundle file is the wrong container for that goal.

### What a published pack+idx already gives you

The operator who ran `git bundle create` (or `git pack-objects`)
has:

- `pack-<hash>.pack` — the same bytes that sit after the bundle
  header
- `pack-<hash>.idx` — OID → offset, plus the pack checksum in
  the idx trailer

Git’s object database is that pair. `add_packed_git()` is happy.
Checkout, `rev-list`, and fetch negotiation (given some tip
refs) work. You do **not** need to inflate every object to make
the pack usable.

A downloaded idx is **not** a cryptographic binding of
“offset N contains the bytes of OID X.” The idx trailer repeats
the pack checksum and has its own checksum; the OID table is not
bound to the bytes at those offsets. That is the same trust
model dumb HTTP already uses when it publishes `pack-*.idx` next
to `pack-*.pack`, and the same model proposed in
`packfile-uri-with-idx-extension.md`. Clients that set
`transfer.fsckObjects` should keep running `index-pack`. Everyone
else can verify:

1. The pack trailer equals the advertised pack hash (or the hash
   in the idx trailer).
2. The idx trailer is consistent with that hash.

That is milliseconds, not a full-history inflate.

### What you would lose if you shipped *only* pack+idx

A bundle’s unique data is the **header**: tip refs and
prerequisite OIDs. `packfile-uris` does not need that because the
server already omitted those objects from the inline pack; the
client is not about to negotiate against them. `bundle-uri` *does*
need tips: the follow-up fetch only sends `have`s for commits it
can name, typically via refs. Objects that exist in a pack but
are not referenced by any ref are invisible to negotiation. That
is exactly the 2.46 / 2.50 bugs, in another form.

So pack+idx alone is not a drop-in replacement for the
*protocol*. You still need a small amount of tip metadata:

- keep a tiny bundle header (or a sidecar refs file), or
- put `oid=` / `prerequisite=` on the bundle list (already
  sketched in `gitprotocol-v2.adoc`), or
- use `ls-refs` from the origin and treat the pack as “probably
  contains those tips” (weaker; you may over-fetch).

You do **not** need to re-index the pack to get those tips.

### What would have to change

Three workable shapes, in increasing ambition:

1. **Sidecar idx next to today’s bundle.** URI still points at a
   bundle. A second URI (or `bundle.<id>.idx`) is the idx of the
   *inner* pack. Client reads the header, `lseek`s to the pack,
   installs pack+idx after trailer checks, writes `refs/bundles/*`
   from the header. Skip `index-pack` when the pack is thick
   (empty prereq list, or a list key says so). Fall back to
   today’s path for thin incrementals and for `transfer.fsckObjects`.

2. **Advertise pack+idx instead of a bundle.** New payload type
   next to “bundle or config list.” The bundle list already has
   per-id keys; `hash=`, `oid=`, `prerequisite=` are reserved.
   Client downloads `pack-<hash>.pack` and `pack-<hash>.idx`
   straight into `objects/pack/`, verifies trailers, creates the
   tip refs from the list. No header parse, no tempfile bundle,
   no second write through stdin. This is “bundle-uri discovery,
   packfile-uri install.”

3. **Use `packfile-uris` with an idx extension for the large
   clone, and keep `bundle-uri` for loosely-coupled incrementals.**
   The origin then *does* have to know the pack contents (the
   coupling the design doc rejected). For a single stale history
   pack plus a small catch-up, that coupling is manageable and
   is what `commit-packfile-uri-design.md` describes. Incrementals
   and geographic “any” lists stay on the bundle-uri side — or
   incrementals are published thick, with their own idx.

(1) and (2) do not require the origin to know pack contents. They
only require the *bundle provider* to publish the idx it already
has. That matches the original loose-coupling goal.

Thin incrementals are the remaining hard case. Options: publish
them thick (bigger CDN objects, trivial client); or keep
`index-pack --fix-thin` for those files only (they are the small
ones); or publish a pre-fixed pack+idx (the provider runs
`--fix-thin` once). None of those need a full-history re-index
on the complete base bundle, which is the clone-time killer.

### Why this was not done

No upstream series proposed it. The consume path was
“call `unbundle()`.” `unbundle()`’s contract is documented in
`bundle.h`: “We’ll invoke `git index-pack --stdin --fix-thin`
for you.” Extending that contract to “or install this idx” was
never in the implementation plan. The protocol’s planned `hash=`
key was for skipping *header* fetches, not for skipping
*object* verification.

`packfile-uris` has the same default (`http-fetch` →
`index-pack`) and the same proposed fix (publish the idx). The
difference is that `packfile-uris` already puts a pack hash on
the wire, so a trailer check has a named expected value.
`bundle-uri` would need `hash=` or the idx trailer to play that
role.

## Why this is not useful for speeding up large clones today

A large clone’s time is dominated by (a) generating or
transferring a pack of the full history and (b) `index-pack` on
that pack.

`bundle-uri` moves (a) from origin `pack-objects` + the Git
protocol onto a CDN GET. That is real: origin CPU drops, and a
well-placed CDN can beat a far-away upload-pack. Then the client
does (b) *after* the GET, on a second copy of the bytes, with no
pipeline.

A normal `git clone` overlaps (a) and (b): `index-pack --stdin`
runs while the pack arrives. When origin and CDN throughput are
similar, the bundle path is **strictly slower** (download +
index, in series, plus a catch-up fetch). When the CDN is much
faster than the origin, you still pay a full-history inflate
that the publisher already paid when building the bundle. On a
laptop CPU that inflate is often the new long pole.

The rest of the feature (lists, tokens, `refs/bundles/`, graceful
fallback) is about incremental fetches and operational coupling.
Those are fine goals. They do not remove the clone-time
`index-pack`. Until the client can install a published
`.pack` + `.idx` — or until download and `index-pack` at least
run at the same time — `bundle-uri` will not make large clones
fast.

## Related reading in this tree

- `Documentation/technical/bundle-uri.adoc` — the aspirational
  design; packfile-uri and GVFS comparisons; implementation plan.
- `Documentation/gitprotocol-v2.adoc`, `bundle-uri` section —
  wire command, degradation rules, future `hash=` / `oid=` keys.
- `history-of-packfile-uri-feature-and-potential-future.md` —
  the other CDN-offload protocol; why the in-tree server is
  blob-only; why bundle-uri was the “stale history snapshot”
  alternative that actually shipped.
- `packfile-uri-with-idx-extension.md` — the skip-`index-pack`
  design for that other protocol. The trust and idx arguments
  apply here with only the tip-metadata difference above.
