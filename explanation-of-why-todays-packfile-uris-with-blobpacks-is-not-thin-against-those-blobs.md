# Why today’s blob packfile-URIs are not thin against those blobs

This is a sidebar for the sentence in `packfile-uri-with-idx-extension.md`:

> The current client indexes the inline pack first, then downloads
> URI packs. That is correct for today’s blob URIs (the inline pack is
> not thin against those blobs).

The claim is easy to misread. It is **not** saying “blobs cannot participate
in thin packs” or “a thin blob pack is a contradiction.” Blobs are the
most common thin-pack bases in ordinary fetch. The claim is narrower:

1. The *URI pack* is a self-contained pack of one (or a few) complete
   blob(s). It is not itself a thin pack.
2. The *inline pack* omits those blobs, but it does **not** store any
   remaining object as a `REF_DELTA` whose base is one of those blobs.
   So the inline pack is not thin *against* them.

Those are two different “the blob is missing” stories. Mixing them up
is the conceptual gap. One is a hole in the **object graph**. The other
is a hole in **delta encoding**. Only the second makes a pack thin.

## Two packs, two jobs

On a `packfile-uris` fetch the server sends:

| Pack | What today’s blob MVP puts in it |
|---|---|
| **URI pack** | A prebuilt pack, usually one configured blob. Built with `pack-objects` of that OID. Hosted at a URL. |
| **Inline pack** | Everything else the client needs for the fetch: commits, trees, other blobs. Streamed in the `packfile` section. |

The client today does:

1. Stream the inline pack into `index-pack` (and `--fix-thin` if the
   client asked for `thin-pack`).
2. Download each URI pack and `index-pack` it.
3. Connectivity check: every wanted tip must be fully reachable in the
   local object database.

Step 1 succeeding *without* the URI blobs already present is the fact
that needs explaining.

## What “thin” actually means

A pack is thin when some object in it is stored as a delta whose **base
is not in that same pack**. The pack format names that base by OID
(`OBJ_REF_DELTA`). Inflating the delta requires the base’s bytes.

`pack-objects --thin` creates those external bases from objects marked
`UNINTERESTING` (the `--not` / have side). Those objects are
**preferred bases**: they may be used as delta bases, and they are not
written into the pack. The receiver is assumed to have them already.
`index-pack --fix-thin` looks each missing base up with
`odb_read_object()` and copies it in so the pack becomes self-contained.

If the base is not in the pack **and** not yet in the ODB, `--fix-thin`
fails. That is why a pack that is thin against a URI pack cannot be
indexed until that URI pack is installed (and has an idx). See
`thin-pack-and-packfile-uri.md`.

Thinness is a property of **how objects are encoded in a pack**, not of
**which objects the graph still names**.

## Taxonomy: three object kinds, two kinds of “points at”

Git’s object store has four payload types that matter here (tag is
ignored). They do not all “contain” each other the same way.

```text
commit  →  tree OID, parent commit OIDs, metadata
tree    →  (mode, name, OID)*     each OID is a tree or a blob
blob    →  raw bytes              no outbound object pointers
```

A tree that lists `100644 hello.txt <blob-oid>` is a complete tree
object. The blob’s *content* is not embedded in the tree. Only the
20- or 32-byte name is. You can hash the tree, store the tree, and
`index-pack` the tree without ever opening the blob.

That is an **object-graph** edge: “this tree claims this blob exists.”
The connectivity check walks those edges. It is *not* a pack delta.

A pack delta is different. Any object (commit, tree, or blob) may be
stored as “apply this binary diff to object X.” X is usually the same
type — `pack-objects` sorts candidates by type and only searches for
deltas within a type (`type_size_sort` in `builtin/pack-objects.c`).
Cross-type deltas are legal in the file format and almost never
produced. A tree-delta-against-a-blob would compare a textual
`mode name oid` list to file bytes; it is a bad idea, not a useful
encoding.

So, by taxonomy:

| Question | Answer |
|---|---|
| Can a tree *name* a blob that is not in the same pack? | Yes. That is normal. The tree object is still complete. |
| Can a commit *name* a tree that is not in the same pack? | Yes, same story. |
| Does omitting a named blob make the pack *thin*? | No. Nothing in the pack needs that blob’s bytes to inflate. |
| Can a blob be a `REF_DELTA` base for another blob? | Yes. That is the usual thin-pack case (old file → new file). |
| Would a tree or commit be a `REF_DELTA` against a URI blob? | Not with this pack-objects. Wrong type, wrong bytes. |

The interesting leftover is the blob-vs-blob row. A “thin inline pack
against those URI blobs” is a coherent idea. Today’s server just does
not do it. That is an implementation choice, not a law of the object
model.

## Why the inline pack is not thin against the URI blobs

### What the server does with a configured blob

`uploadpack.blobPackfileUri = <blob-oid> <pack-hash> <uri>` is read by
pack-objects. When the object list is assembled,
`want_object_in_pack()` sees that OID, records it in
`excluded_by_config`, and returns 0: **do not put this object in the
pack**. After the pack is written, `write_excluded_by_configs()` emits
`<pack-hash> <uri>` for the `packfile-uris` section.

That is **omission**, not **exclusion-as-have**.

`--not` / `UNINTERESTING` is the other knob. It means “the receiver
already has this closure; you may delta against it; do not send it.”
Preferred-base machinery (`add_preferred_base`, `entry->preferred_base`,
`bitmap_has_oid_in_uninteresting`) only feeds *those* objects into
delta search as bases that will not be written.

The configured blob is never marked `UNINTERESTING`. It is not added
as a preferred base. Delta search never considers it as a source.
Another blob that would compress well against it is written in full
(or as a delta against some *other* object that *is* in the packing
list).

So the inline pack may *lack* the blob and still contain no
`REF_DELTA` whose base is that blob. `index-pack --fix-thin` has
nothing to look up in the URI pack. Indexing the inline pack first is
safe.

### Why omission is enough for the blob MVP

The feature’s job is “this blob’s bytes live at a URL; do not spend
origin bandwidth on them.” The tree that names the blob still goes in
the inline pack, as a full tree object. After step 1 the client has:

- every commit and tree needed for the tips
- every blob that was *not* configured for a URI
- a valid idx for the inline pack

It does **not** yet have the configured blob. `git cat-file` on that
OID would fail. Checkout of a path that uses it would fail. The
**connectivity** check would fail. That is why the protocol says:
download and index the URI packs *before the connectivity check* — not
“before you may run `index-pack` on the inline pack.”

```text
inline pack indexed     →  objects in that pack are lookupable
URI packs indexed       →  omitted blobs become lookupable
connectivity check      →  tree → blob edges must resolve
```

Today those three steps are allowed in that order. A thin-against-URI
design would need URI packs *before* the first step.

## Why not (why the inline pack does not delta against those blobs)

### Not because blobs are the wrong type

A thin pack whose external bases are blobs is the everyday fetch
shape. You have `hello.txt` at commit A; you fetch commit B; the new
`hello.txt` is often a delta against the old blob, which is not in the
new pack. Taxonomy *encourages* that. File content is what delta
compression is for.

If today’s blob-URI path *did* mark each configured blob
`UNINTERESTING` / preferred-base, pack-objects could emit exactly
that: inline blob B′ as `REF_DELTA` against URI blob B. Then the
inline pack *would* be thin against those blobs, and indexing it first
would break. The client order in
`packfile-uri-with-idx-extension.md` would become wrong.

The server does not do that. The MVP is a sideload, not a synthetic
have.

### Not because a “thin blob pack” is meaningless

Two phrases get collapsed:

**“The URI pack is a blob pack.”**  
It is a normal pack that happens to contain a blob (often only one).
`git pack-objects` of a single OID writes an undeltified blob plus a
header and trailer. Self-contained. Not thin. There is nothing for
`--fix-thin` to do.

**“A thin pack of blobs.”**  
A pack that contains only blobs, some of them `REF_DELTA` against
bases not in the pack, is a perfectly ordinary thin pack. Fetch of
“just the new versions of a few files” can look like that.

**“A thin URI blob pack.”**  
This one is the awkward idea. The URI pack is fetched from a CDN as
an independent file. If *it* were thin, its missing bases would have
to already be at the client — typically the inline pack, or some
older local object. That inverts the dependency (URI pack needs the
inline pack), and it makes a CDN object that is not self-contained.
The protocol *allows* URI packs to use `thin-pack` if the client
advertised it (`packfile-uri.adoc`), but the blob MVP never produces
that: the operator publishes a complete one-blob pack.

So: “thin blob packfile” is not a category error. “Thin **URI** blob
packfile against the inline pack” is a bad *layering* choice. “Inline
pack thin against the URI blobs” is a good compression choice that
today’s code simply does not take.

### Why the MVP stopped at omission

Omission is the smallest change that proves the protocol:

- pack-objects already had a “do I want this object in the pack?”
  hook; returning 0 and printing a URI is enough.
- The client can keep the existing fetch order (inline first).
- No preferred-base / `--not` / bitmap interaction.
- No requirement that the URI pack be installed before `--fix-thin`.
- Tests can use a one-blob pack and a one-blob tree.

Making the inline pack thin against those blobs would buy better
compression when two versions of the same file straddle the cut (URI
has v1, inline has v2). It would also force the URI-first / tempfile
ordering that the commit-based design needs anyway. The blob MVP did
not need that win; the blobs it sideloads are usually large binaries
that nothing else deltas well against in the first place.

## Contrast: commit-based URIs *are* thin against the URI pack

`commit-packfile-uri-design.md` injects commit `C` as a real `--not`.
Everything reachable from `C` becomes `UNINTERESTING` and a preferred
base. The inline pack is `T ^ C`: new commits, new trees, new blobs,
encoded with `--thin` against objects that live only in the URI pack.

That *does* use the taxonomy the way fetch already does:

- new blob against old blob (same path, similar bytes)
- new tree against old tree (same directory, few entries changed)
- new commit against old commit (sometimes)

Those bases are not “the commit object `C`.” They are the trees and
blobs in `C`’s closure. The URI pack has to be a full closure pack
exactly so those bases exist as objects, not as a single commit
header.

Here “thin against the URI pack” is the whole point, and “index the
inline pack first” is incorrect. Blob-URI omission is the other
extreme: no `--not`, no preferred bases, no cross-pack deltas.

## Why the current client order is correct *for blobs*

Putting the pieces together:

```text
                    blob URI (today)              commit URI (proposed)
                    ----------------              ---------------------
How objects leave   want_object_in_pack() = 0     --not C
the inline pack     (omit this OID)               (UNINTERESTING closure)

Used as delta base? no                            yes (--thin)

What the inline     complete objects;             complete objects plus
pack still has      trees still name the          REF_DELTA to objects
                    omitted blob by OID           only in the URI pack

index-pack on       succeeds; nothing to          needs URI pack+idx
inline pack first   resolve from the URI pack     already in the ODB

connectivity        needs the URI blob            needs the URI closure
                    (graph edge)                  (graph edges + any
                                                  bases already copied
                                                  in by --fix-thin)
```

The blob column is “not thin against those blobs” in the only sense
that matters for client order: **`--fix-thin` will not ask for them.**
The graph still asks for them later. That is why download-URI-before-
connectivity is required and download-URI-before-inline-`index-pack`
is not.

## Short answers

| Question | Answer |
|---|---|
| Is the URI blob pack thin? | No. It is a self-contained pack of complete blob object(s). |
| Is the inline pack thin against those blobs? | No. They are omitted, not preferred bases, so nothing is a `REF_DELTA` against them. |
| Does omitting a blob from a pack make that pack thin? | No. A tree that *names* the blob is still a full object. Thin means “delta base missing,” not “graph neighbor missing.” |
| Is a thin pack whose bases are blobs a contradiction? | No. That is normal fetch. Taxonomy favors blob-vs-blob and tree-vs-tree deltas, not tree-vs-blob. |
| Could today’s feature make the inline pack thin against URI blobs? | Yes, by treating those OIDs like haves. The MVP did not, so the client may index the inline pack first. |
| Would a thin URI blob pack (delta against the inline pack) make sense? | As a CDN object, poorly: it would not be self-contained and would reverse the dependency. |
| Why must URI packs still arrive before connectivity? | Trees in the inline pack name the omitted blobs. Reachability is a later check than `index-pack`. |
