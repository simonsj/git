# History of `packfile-uris`, and why it started as `blobPackfileUri`

An archaeology of Git’s experimental `packfile-uris` feature: the
commits that built it, why the in-tree server only ever learned
`uploadpack.blobPackfileUri`, and what a deliberate next step would
look like.

Canonical in-tree sources:

- `Documentation/technical/packfile-uri.adoc`
- `Documentation/gitprotocol-v2.adoc` (`packfile-uris` section)
- `builtin/pack-objects.c` (`configured_exclusions`, `--uri-protocol`)
- `upload-pack.c` (advertise + relay)
- `fetch-pack.c` / `http-fetch.c` (client download + `index-pack`)
- `t/t5702-protocol-v2.sh`

Related design notes in this tree (not upstream history):
`commit-packfile-uri-design.md`, `thin-pack-and-packfile-uri.md`,
`packfile-uri-with-idx-extension.md`, `packfile-uri-download.md`.

## What landed

Protocol v2 lets a server omit objects from the inline `packfile`
section and instead send a `packfile-uris` section of

```text
<pack-hash> <uri>
```

lines. The client downloads those packs (today: sequential
`git http-fetch --packfile=` + `index-pack`), then runs the usual
connectivity check.

The *protocol* is generic. The *in-tree server* is not. The only
non-trivial implementation is still:

```text
uploadpack.blobPackfileUri = <object-hash> <pack-hash> <uri>
```

When pack-objects is assembling the send list and the client offered
a matching URI scheme (`fetch.uriprotocols`, default empty), a
configured blob is dropped from the inline pack and its URI is
emitted. That is an exact-OID lookup in `configured_exclusions`.
There is no commit-closure config, no `--not C`, and no advertised
way to say “this pack is the reachable set of commit C.”

That split — generic wire, blob-only server — is the original
intention, not an unfinished accident. The rest of this note is the
evidence.

## Commit table

Author dates. Merge commits omitted except the topic merge that
introduced the feature. “Git” is the first release RelNotes that
mention the change, or the first tag that contains it.

### Landing (`jt/cdn-offload`, Git 2.28)

| Date | Commit | Author | Subject |
|---|---|---|---|
| 2020-06-10 | `9cb3cab560` | Jonathan Tan | `http`: use `--stdin` when indexing dumb HTTP pack |
| 2020-06-10 | `eb05349247` | Jonathan Tan | `http`: refactor `finish_http_pack_request()` |
| 2020-06-10 | `8e6adb69e1` | Jonathan Tan | `http-fetch`: refactor into function |
| 2020-06-10 | `8d5d2a34df` | Jonathan Tan | `http-fetch`: support fetching packfiles by URL |
| 2020-06-10 | `fd194dd56a` | Jonathan Tan | Documentation: order protocol v2 sections |
| 2020-06-10 | `cd8402e0fd` | Jonathan Tan | Documentation: add Packfile URIs design doc |
| 2020-06-10 | `acaaca7d70` | Jonathan Tan | `upload-pack`: refactor reading of pack-objects out |
| 2020-06-10 | `9da69a6539` | Jonathan Tan | `fetch-pack`: support more than one pack lockfile |
| 2020-06-10 | `dd4b732df7` | Jonathan Tan | `upload-pack`: send part of packfile response as uri |
| 2020-06-16 | `cae2ee1055` | Ramsay Jones | `upload-pack`: fix a sparse '0 as NULL pointer' warning |
| 2020-06-25 | `34e849b05a` | Junio C Hamano | Merge branch `jt/cdn-offload` |

RelNotes 2.28: “The fetch/clone protocol has been updated to allow
the server to instruct the clients to grab pre-packaged packfile(s)
in addition to the packed object data coming over the wire.”

### Follow-ups (correctness, docs, hygiene)

| Date | Commit | Git | Author | What changed |
|---|---|---|---|---|
| 2020-08-17 | `0bd96bea2f` | 2.29 | Jonathan Tan | `transfer.fsckObjects` + URI packs: `--fsck-objects` not `--strict` (incomplete links are expected; connectivity is later) |
| 2021-01-20 | `bfc2a36ff2` | 2.30.1 | Jonathan Tan | **Doc: clients must not assume URI packs contain a single blob** |
| 2021-02-22 | `b664e9ffa1` | 2.31 | Jonathan Tan | Unify `index-pack` args for inline pack and URI packs |
| 2021-03-04 | `2aec3bc4b6` | 2.31 | Jonathan Tan | Fetch bug: do not reuse `--pack_header` on URI packs |
| 2021-05-13 | `3127ff90ea` | 2.33 | Teng Long | Doc: `blobPackfileUri` is `<object-hash> <pack-hash> <uri>` |
| 2021-11-10 | `88e9b1e3fc` | 2.35 | Ivan Frade | Redact packfile URI paths in traces (URIs can be bearer tokens) |
| 2021-11-19 | `2a4aed42ec` | 2.35 | Jeff King | Ignore `SIGPIPE` when `index-pack` dies under fsck + URI packs |
| 2024-02-28 | `179776f9e6` | 2.45 | Jeff King | Accept only one `packfile-uris` request line |
| 2024-02-28 | `9a7b22959a` | 2.45 | Jeff King | Advertise capabilities from the same config path used to honor them |
| 2024-02-28 | `a922bfa3b5` | 2.45 | Jeff King | Reject `packfile-uris` unless it was advertised (`blobPackfileUri` set) |
| 2026-07-26 | `5e855d9b42` | post-2.55 | Ted Nyman | Concurrent appends to partial packs corrupt URI/dumb-HTTP downloads |
| 2026-07-26 | `c4244bdfe6` | post-2.55 | Ted Nyman | Accept `pack` as well as `keep` from `http-fetch` / `index-pack` |

### Mailing-list history that never became a commit

These are part of the feature’s history even though they are not in
`git log`.

| Date | What | Outcome |
|---|---|---|
| 2018-12-03 | Jonathan Tan, `[WIP RFC 0/5] Design for offloading part of packfile response to CDN` | First public design. Cover letter: implementation “only allows replacing single blobs with URIs,” protocol left open for other servers. |
| 2019-03 | `[PATCH v2 0/8] CDN offloading of fetch response` | Adds pack-hash on the wire; still blob config. |
| 2020-06 | `[PATCH 0/8] CDN offloading update` | The series that merged as `jt/cdn-offload`. |
| 2021-05 → 2021-10 | Teng Long, `uploadpack.commitpackfileuri` then `uploadpack.excludeobject` (v1–v6+) | Attempt to exclude commits (later: recursive closure via oidmap). Reviewed, revised, **never merged**. |
| 2022-08-09 | `2da14fad8f` docs: document bundle URI standard | Shipped “CDN snapshot of history” path. Different protocol (`bundle-uri` command *before* `fetch`), not an extension of `blobPackfileUri`. Git 2.38 (`--bundle-uri`) / 2.40 (v2 command). |

## Discussion: why only `blobPackfileUri`?

The short answer: the authors wanted a **small, testable server
MVP** that offloaded **large immutable leaves**, and a **protocol
that would not have to change** if a later server grew a commit
closure. They did **not** want the first cut to be “here is a stale
history pack; top it up.” That second idea was already in reviewers’
heads, was listed as future work, was attempted the wrong way in
2021, and then shipped as **bundle-uri** instead.

### 1. The protocol was generic on day one; the server was an MVP

The 2018 cover letter is unambiguous:

> Currently, the implementation only allows replacing single blobs
> with URIs, but the protocol improvement is designed in such a way
> as to allow independent improvement of Git server
> implementations.

The design doc that landed in `cd8402e0fd` (and is still
`packfile-uri.adoc`) says the same thing twice:

- A server can advertise `packfile-uris`, accept the client
  argument, and **never emit a URI**. Compatibility is cheap.
- A non-trivial implementation is included “at least so that we can
  test the client.” That implementation is
  `uploadpack.blobPackfileUri`.
- Future work, **no protocol change required**: “more sophisticated
  means of excluding objects (e.g. by specifying a commit to
  represent that commit and all objects that it references).”

So `blobPackfileUri` is named for what the *in-tree server* does,
not for what a URI pack is allowed to contain. `bfc2a36ff2`
(2021-01-20) later made that explicit: clients must accept URI
packs with multiple objects of all types. The 2020 landing text had
said the opposite (expect single-blob packs). The clarification is
the authors tightening the original contract, not changing it.

Ævar later called `blobpackfileuri` “unfortunately named” *if* the
in-tree server were about to become type-agnostic. It never did. The
name still describes the only shipped policy.

### 2. Blobs were the intended first CDN object

The original server paragraph:

> Whenever the list of objects to be sent is assembled, a blob with
> the given sha1 can be replaced by the given URI. This allows, for
> example, servers to delegate serving of large blobs to CDNs.

That is a Google-scale large-object problem (Jonathan Tan
`<jonathantanmy@google.com>`), sitting next to but distinct from
partial clone / promisor remotes (also his work). Christian Couder
asked whether many promisor remotes already covered large objects.
Tan’s reply (2019-02-19):

> It's true that there is a slight overlap with respect to large
> objects, but this protocol can also handle large sets of objects
> being offloaded to CDN, not only single ones. (The included
> implementation only handles single objects, as a minimum viable
> product, but it is conceivable that the server implementation is
> later expanded to allow offloading of sets of objects.)

Two jobs, one protocol:

| Job | Why a blob MVP is enough |
|---|---|
| Offload a few huge blobs | Exact OID → URI. No history involved. |
| Offload a set of objects later | Same wire line; different server policy. |

Promisor remotes require another Git server and (on dumb HTTP)
per-object fetches. `packfile-uris` is “GET a pack from a CDN.”
Blobs are the smallest object for which that distinction matters.

### 3. Blobs are leaves; a commit closure is a different primitive

The in-tree exclusion is `want_object_in_pack()` consulting
`configured_exclusions` and returning 0. That is cheap and correct
**only** for objects you are willing to treat as “this OID, and
nothing it implies.”

A blob is a leaf. Dropping it from the send list does not change
which commits or trees go in the inline pack. The inline pack is
not marked `UNINTERESTING` at those blobs, so pack-objects will not
use them as thin-pack bases. The client can therefore:

1. Stream and `index-pack` the inline pack first.
2. Download URI packs second.
3. Connectivity-check once both are present.

That order is what the current client does. It is wrong for a
commit-closure pack used as a `--not C` / preferred-base set (see
`thin-pack-and-packfile-uri.md`). The blob MVP never needed that
ordering, so the implementation never grew it.

A commit closure needs the opposite machinery:

- Decide whether `C` is an ancestor of the wants (and not already
  had).
- Exclude **by reachability**, not by enumerating every OID into a
  map.
- Inject `C` as a real `--not` so the dynamic pack can be thin
  against objects in the URI pack.
- Install the URI pack **and an idx** before `--fix-thin` on the
  inline pack.

Doing “commit exclusion” by walking `C` into `configured_exclusions`
is the thing `commit-packfile-uri-design.md` argues against:
memory-heavy, easy to get wrong with bitmaps, and it still does not
give you thin-pack bases. That is why a config named
`commitPackfileUri` is not a second line in the same oidmap.

### 4. They actively steered reviewers away from “stale history + top-up”

Junio’s first reading of the 2018 RFC (2018-12-05) was the commit-
closure story:

> would this feature involve “you asked history up to these
> commits, but with this pack-uri, you'll be getting history up to
> these (somewhat stale) commits”?

Tan (2018-12-06):

> It could be, but not necessarily. In my current WIP
> implementation, for example, pack URIs don't give you any commits
> at all (and thus, no history) — only blobs. Quite a few people
> first think of the “stale clone then top-up” case, though — I
> wonder if it would be a good idea to give the blob example in
> this paragraph in order to put people in the right frame of mind.

That is a deliberate framing choice. The protocol *can* carry a
history pack. The first implementation *must not look like one*, or
reviewers will demand ancestor gating, stale-tip semantics, and
client “have” after download before the feature can even be tested.

Stefan Beller (2018-12-04) already saw the clone-sized base pack:

> I assumed we'd want to use this pack feature over broadly (e.g.
> eventually by offloading most of the objects into a base pack
> that is just always included as the likelihood for any object in
> there is very high on initial clone)

He also noted that the blob design “makes total sense to only
output the URIs that we actually need.” Need-based blob URIs and
always-include-the-base-pack are different server policies on the
same wire.

Ævar (2019-02) wanted a third thing: a server that **does not know
the OIDs** in the CDN pack (“some machine entirely disconnected
from the server … continually generating an up-to-date-enough
packfile”). Tan said that works only when the client can later say
what it got (ordinary `have` lines). It does not work for “omit
these blobs” or “this pack is a shallow slice.” The server-ignorant
snapshot is exactly what **bundle-uri** later implemented: download
*before* `fetch`, then negotiate. `packfile-uris` is the other
order: negotiate, then the server names packs that cover objects it
is about to omit.

### 5. The 2021 commit-exclusion series showed the trap, then died

Teng Long (Alibaba), 2021-05 through at least v6 (2021-10), tried
to do the design doc’s “future work” as “the same oidmap, more
types”:

1. v1: `uploadpack.commitpackfileuri` excluding **only the commit
   object**, “not including … all objects that it references.”
2. Review (Ævar): the code already does not care about type; add
   `uploadpack.excludeObject` and treat `blobpackfileuri` as a
   synonym.
3. Later: a `<recursively>` flag, then recursive exclusion of a
   commit’s trees and blobs into the same map.

That series never merged. The review thread is mostly naming,
config compatibility, and test structure — but the design itself
is the oidmap-shaped trap. Excluding a lone commit OID is useless
for CDN offload (the commit is tiny). Recursively stuffing the
closure into `configured_exclusions` is the approach the 2020
authors deferred, and it still does not mark `C` uninteresting for
thin packs. After enough revisions without a merge, the energy
moved elsewhere.

Teng Long *did* land `3127ff90ea` (the `blobPackfileUri` format
doc fix). The type-generalization did not.

### 6. Bundle-uri took the “history on a CDN” slot

By 2022 the “stale snapshot then top-up” product had its own
protocol:

- `bundle-uri` v2 command, issued **before** `fetch`.
- Bundles (pack + refs), not anonymous packs named mid-fetch.
- Client-side `have`s from what the bundle contained.
- No need for upload-pack to omit objects from a live pack-objects
  walk.

That is a better fit for “clone most of the repo from a CDN.” It
leaves `packfile-uris` as what it was built to be: mid-fetch
omission of objects the server *knows* it is not sending, with the
in-tree knowledge limited to configured blob OIDs.

The two features look similar (HTTP GET of a pack-like file from a
CDN) and solve different scheduling problems:

| | `packfile-uris` | `bundle-uri` |
|---|---|---|
| When | After negotiation, inside `fetch` | Before `fetch` |
| Server must know contents? | Yes (it is omitting those objects) | No (client will `have` what it got) |
| In-tree policy | Blob OID map | Advertised bundle list / `--bundle-uri` |
| Thin pack against the download | Not in the blob MVP | No; the subsequent fetch is a normal negotiate |
| Resume / ranges | Listed as future work | Ordinary HTTP of a file |

A commit-closure `packfile-uris` would sit between them: server
*does* know the contents (`C`), and the inline pack *is* a thin
delta from `C`. That is why it is still worth doing, and why it
was not the 2020 MVP.

### 7. Experimental on both sides, on purpose

`fetch.uriprotocols` defaults to empty. Servers only advertise
`packfile-uris` if `uploadpack.blobPackfileUri` is set. Jeff King’s
2024 series made that advertisement/acceptance pairing strict
(`a922bfa3b5`). The feature has stayed experimental, lightly used,
and therefore cheap to leave blob-only. There was never production
pressure in git.git to grow `commitPackfileUri`.

## Future-looking: how to extend it without repeating 2021

The original design doc’s future list is still the right outline.
The last six years add constraints on *how*.

### A. Commit-closure URI packs (`uploadpack.commitPackfileUri`)

This is the item the 2018 doc named, and the one this tree’s
`commit-packfile-uri-design.md` specifies.

Do:

- Config: `<commit-oid> <pack-hash> <uri>` meaning “this pack is
  the **full reachable closure** of `C`.”
- In **upload-pack**, before pack-objects: if `C` is a useful
  ancestor of the wants and the client does not already have it,
  emit the URI and add `C` to the `--not` list.
- Keep `--thin`. Preferred bases then fall out of the existing
  rev-walk.
- Leave blob exclusion in pack-objects. Do not reuse
  `configured_exclusions` for `C`.

Do not:

- Walk `C` into an oidset and filter every candidate (Teng Long
  v3–v6; the 2021 “recursively” flag).
- Exclude only the commit object (Teng Long v1). That offloads
  nothing that matters.
- Blindly always send the URI. Unrelated refs and already-
  negotiated fetches waste a CDN GET.

No protocol change. Clients already must accept multi-object packs
(`bfc2a36ff2`). What they lack is **order** and **an idx** (B, C).

### B. Server-supplied `.idx` (skip client `index-pack` on the URI pack)

`packfile-uri.adoc` lists “different file formats referenced by
URIs” as a **protocol-changing** item. An idx is that item, and it
is a prerequisite for A at clone scale.

`index-pack` on a commit-closure pack *is* the history. The
publisher already has a correct idx. Dumb HTTP already downloads
`pack-*.idx`. The current URI client always rebuilds one.

`packfile-uri-with-idx-extension.md` is the concrete extension:
client sends `idx` on the existing `packfile-uris` protocol list;
server may emit `idx <pack-hash> <uri>`; client installs the pair
and skips `index-pack` unless `transfer.fsckObjects` is on.

Without this, A still works, but you spend clone CPU re-hashing
the CDN pack you just downloaded. With it, `--fix-thin` only needs
OID lookup, which requires *an* idx, not a locally generated one.

### C. URI pack before the inline pack (thin-pack order)

Today: index inline pack, then download URIs, then connectivity.
Correct for blob omission. Incorrect if the inline pack may name
delta bases that exist only in the URI pack.

`thin-pack-and-packfile-uri.md`: parse `packfile-uris`, buffer the
inline stream, install URI pack+idx, then `index-pack --fix-thin`.
Gate the reorder on “this URI pack is a thin-pack base” so existing
blob tests stay green.

The protocol text already says “download and index all given URIs
… before performing the connectivity check.” The stronger “URI
first” rule is the thin-pack reading of that sentence.

### D. Byte ranges, resume, parallelism

Original future work that **needs a protocol change** if Git is to
*advertise* size/range metadata; **does not** need one for the
client to send HTTP `Range` to the CDN.

Today each URI is one sequential GET (`http-fetch --packfile=`).
Fine for one blob. Wrong for a multi-gigabyte closure pack.
`packfile-uri-download.md`:

- Probe with a one-byte `Range` (`206` + `Content-Range` total).
- Optional wire line `size <pack-hash> <n>` (token-gated, like
  `idx`).
- Parallel slices into a `.partial`; resume is the same loop.
- Optional `fetch.packfileUriHelper` as a **configured downloader**
  (not a githook; clone has no useful `$GIT_DIR/hooks`). Git keeps
  trailer checks, `.keep`, idx vs `index-pack`, and `--fix-thin`
  order.

The 2026 `tn/packfile-uri-concurrency` series (`5e855d9b42`,
`c4244bdfe6`) is the first in-tree work that treats URI downloads
as concurrent: fix `O_APPEND` corruption on the shared partial
pack, and accept `index-pack`’s `pack\t` when a `.keep` already
exists. That is infrastructure for D, not D itself.

### E. Things the 2018 doc listed that are still open

| Item | Protocol change? | Notes |
|---|---|---|
| Clone resume | No (if you keep a `.partial` / recorded URIs) | Same mechanism as D. Original text wanted a `clone-resume` command; a leftover partial + the same URI list is enough for an MVP. Fetch resume is harder (user may use the repo mid-fetch). |
| Extra HTTP headers (authn) | Yes | Ivan Frade’s redaction (`88e9b1e3fc`) already treats URI paths as secrets. Prefer pre-signed CDN URLs over teaching the Git server to mint headers. |
| Raw objects (or other file formats) at a URI | Yes | The idx extension is the useful special case. Loose objects would throw away delta compression. |
| Interaction with `--filter` / shallow / deepen | Policy | Synthetic `--not C` vs partial clone is easy to get wrong. Start A on non-shallow full clones. |

### F. What not to build

- **Another oidmap of every object in `C`.** That is 2021.
- **A githook for the download.** Wrong scope for clone.
- **Replacing `http-fetch` via `PATH`.** The CLI (`--packfile`
  coupled to `--index-pack-args`, `keep\t` on stdout) is a hostile
  API for a downloader.
- **Making bundle-uri and packfile-uris the same feature.** Bundle-
  uri is “seed, then negotiate.” Commit-URI packs are “negotiate,
  omit `reachable(C)`, thin-pack the rest.” Operators may use both
  (bundle for the first clone, commit-URI for later fetches that
  share a snapshot `C`), but the code paths should stay distinct.

### Suggested sequence

The dependencies are real; the 2020 authors were right to land
blobs first.

1. **Idx extension** (B). Unblocks A at realistic pack sizes; also
   helps today’s blob URIs a little.
2. **Buffer inline pack / URI-first when the URI is a thin base**
   (C). Latent until A exists; small and testable with fixtures.
3. **`uploadpack.commitPackfileUri`** (A). upload-pack owns the
   URI line and the synthetic `--not`. pack-objects unchanged.
4. **Size + parallel ranges** (D), then optional helper. Needed
   once A’s packs are large enough that one GET is the bottleneck.
5. **Resume** falls out of D’s `.partial`. A dedicated
   `clone-resume` command is optional productization.

That is the same unfolding the 2018 RFC described — protocol first,
blob MVP to test the client, commit-as-closure later — with the
intervening lessons applied: do not fake a closure with an oidmap,
do not skip the idx, and do not fight bundle-uri for the
server-ignorant snapshot job.
