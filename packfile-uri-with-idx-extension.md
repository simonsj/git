# Packfile-URI with server-supplied `.idx`

This document outlines a small extension to Git’s experimental
`packfile-uris` feature: the server can also advertise a URI for the
matching `.idx`, and a client that opts in can install that pair
without running `index-pack` on the downloaded pack.

It is meant to land on its own, and to unblock the commit-based CDN
packs in `commit-packfile-uri-design.md`. Background on why an idx is
required at all (and what you give up by not generating one) is in
`thin-pack-and-packfile-uri.md`.

See also: `Documentation/technical/packfile-uri.adoc` (lists “different
file formats referenced by URIs” under protocol-changing future work)
and `Documentation/gitprotocol-v2.adoc` (`packfile-uris` section).

## Summary

Today each `packfile-uris` line is `<pack-hash> <uri>`. The client
downloads that pack through `git http-fetch --packfile=` and always
pipes it through `index-pack`, which walks every object and writes a
fresh `.idx`.

That scan is the expensive part of making the pack usable. Git will
not look up objects in a `.pack` that has no `.idx`
(`add_packed_git()` only accepts idx paths). The operator who built
the URI pack already has a correct idx; hosting it next to the pack
and handing the client that file is enough for OID lookup, including
`--fix-thin` on the inline pack.

The change is:

1. The client opts in, so old clients keep seeing today’s line format
   and keep running `index-pack`.
2. The server, when an idx is available, emits a second URI for that
   pack’s idx.
3. The new client downloads pack + idx, checks that both trailers name
   the advertised pack hash, installs them as
   `objects/pack/pack-<hash>.{pack,idx}` plus a `.keep`, and skips
   `index-pack` for that URI pack.

No change to how the inline `packfile` section is generated. Blob
exclusions (`uploadpack.blobPackfileUri`) and the future commit-base
path (`uploadpack.commitPackfileUri`) both benefit.

## Motivation

`index-pack` is not “write a table of offsets.” It inflates every
object, resolves internal deltas, and checks that the content hashes
to the claimed OID. For the current blob-URI MVP that cost is small
(one blob per URI). For a commit-closure pack it is the whole history.

That is the pack we most want on a CDN, and the one the thin-pack
design needs installed *before* `--fix-thin` can resolve bases in
`C`. Spending clone CPU to rebuild an idx the publisher already has
defeats much of the point of shipping a prebuilt pack.

A downloaded idx is enough for:

- `odb_read_object()` / `index-pack --fix-thin` on the inline pack
- the post-fetch connectivity check
- later checkout, merge, and ordinary reads

It is **not** a substitute for a full integrity scan. The idx trailer
repeats the pack checksum and has its own checksum, but the
OID-to-offset table is not cryptographically bound to the bytes at
those offsets. Trust is the same model dumb HTTP already uses when it
publishes `pack-*.idx` next to `pack-*.pack`. Clients that set
`transfer.fsckObjects` should keep running `index-pack` (see below).

The idx is small (tens of bytes per object). Serving it from the CDN
is the natural place; serving it from upload-pack would also be cheap
but is not required for the MVP.

## Non-goals

- Teaching URI packs to carry `.rev` / `.mtimes` / MIDX. Those can be
  built locally later if wanted.
- Changing dumb HTTP. It already downloads published idx files for
  *discovery*, then still regenerates the idx with `index-pack` when
  installing the pack (`finish_http_pack_request()`). This work does
  not have to fix that; it may share a helper with it later.
- Implementing commit-based `uploadpack.commitPackfileUri`. This
  extension is a prerequisite, not that feature.
- Making `verify-pack` / `index-pack --verify` run automatically
  after a URI download. Fetch/clone do not run those today; they
  remain on-demand.

## Design choices

### Capability: opt-in token on the existing request line

The client already sends:

```text
packfile-uris <comma-separated-list-of-protocols>
```

with `http` and/or `https`. Add a well-known extra token `idx` that is
**not** a URI scheme:

```text
packfile-uris http,https,idx
```

The server already receives that list (pack-objects’ `--uri-protocol`,
and upload-pack for a future commit-URI path). It only emits idx
information when `idx` is present.

Why this instead of a new advertised feature:

- No new capability name, no extra fetch argument, no section-order
  change.
- Old clients never send `idx`, so they never see a new line shape.
- `Documentation/technical/packfile-uri.adoc` already said a different
  file format needs a protocol change; this is that change, kept to
  one token plus one extra line.

A dedicated `packfile-uris-idx` feature would also work. Prefer the
token unless review wants a first-class capability (for example so
`server_supports_feature()` can advertise that the server *can* send
idx URIs). Advertising is optional: a server that has no idx
configured simply never emits the extra line.

### Wire format: second line, same pack hash

Keep the existing line as-is:

```text
packfile-uri = PKT-LINE(hash SP uri LF)
```

When the client sent `idx` **and** the server has an idx URI for that
pack, emit a second line:

```text
idx-uri = PKT-LINE("idx" SP hash SP uri LF)
```

Example:

```text
packfile-uris
<pack-hash> https://cdn.example/base.pack
idx <pack-hash> https://cdn.example/base.idx
<other-hash> https://cdn.example/blob.pack
packfile
...
```

Rules:

- `hash` is the same pack checksum already advertised (what
  `index-pack` prints after `pack\t` / `keep\t`). It is **not** the
  idx file’s own checksum.
- The `idx` line is optional per pack. A response may mix packs that
  have an idx URI with packs that do not.
- `idx` lines MAY appear immediately after their pack line, or
  grouped after all pack lines. The client matches on `hash`.
- URIs stay `*%x20-ff` as today (one URI per line, so spaces in a URI
  are still unambiguous).
- Old clients never requested `idx`, so they never receive `idx …`
  and their `expected '<hash> <uri>'` parser is unchanged.

Rejected alternatives:

| Approach | Why not for the MVP |
|---|---|
| `<hash> <pack-uri> <idx-uri>` on one line | The URI field is allowed to contain spaces; a second field is ambiguous. |
| Naming convention only (`<pack-uri>` → `.idx`) | No way to host the idx elsewhere; silent 404; old clients cannot be distinguished from “try the suffix.” Fine as a *server* default when synthesizing a URI (below), not as the only protocol. |
| New `packfile-idx-uris` section | Extra section in a fixed v2 response grammar; more client and test churn for the same data. |

### Server config

Extend the existing blob config with an optional fourth field:

```text
uploadpack.blobPackfileUri = <object-hash> <pack-hash> <pack-uri> [<idx-uri>]
```

If `<idx-uri>` is omitted, the server may synthesize one when the
client asked for `idx`:

- if `<pack-uri>` ends in `.pack`, replace that suffix with `.idx`;
- otherwise append `.idx`.

If the operator does not want an idx published, they can leave the
fourth field empty **and** disable synthesis (config or a leading
convention such as `-`). MVP: synthesize only when the pack URI ends
in `.pack`; otherwise omit the `idx` line.

The same optional fourth field applies later to
`uploadpack.commitPackfileUri`:

```text
uploadpack.commitPackfileUri = <commit-oid> <pack-hash> <pack-uri> [<idx-uri>]
```

Operator workflow is unchanged except they must publish the idx that
`pack-objects` already wrote next to the pack:

```bash
git rev-list --objects <commit> | git pack-objects --stdout > base.pack
# keep the pack-<hash>.idx that pack-objects wrote; publish both
```

### Client install path

When a URI pack has a matching `idx` line:

1. Download the pack (existing `http-fetch --packfile=` / `new_direct_http_pack_request()` temp file).
2. Download the idx (`http_get_file()`, same helper dumb HTTP uses in
   `fetch_pack_index()`).
3. Check the pack trailer equals the advertised `<pack-hash>`.
4. Parse the idx (`parse_pack_index()` / `verify_pack_index()`): idx
   self-checksum valid, idx trailer’s copy of the pack checksum equals
   the advertised hash.
5. Install as `objects/pack/pack-<hash>.pack` and
   `objects/pack/pack-<hash>.idx`.
6. Write a `.keep` (same “keep until refs move” rule as today).
7. Emit `keep\t<hash>\n` on stdout so `do_fetch_pack_v2()`’s existing
   reader and `pack_lockfiles` handling stay the same.
8. Do **not** run `index-pack` for that URI pack.
9. Refresh the packed-git list so later `--fix-thin` and connectivity
   can see the new objects.

When there is no `idx` line, keep today’s `--index-pack-arg=` path.

`http-fetch --packfile=` currently *requires* `--index-pack-args`.
That coupling goes away for the idx path: `--packfile=` plus
`--idx=<uri>` (or `--packfile-idx=`) is sufficient.

### Integrity and `transfer.fsckObjects`

Default (fsck off): trust the publisher/CDN the way the idx trailer
allows. No automatic `verify-pack`.

When `transfer.fsckObjects` / `fetch.fsckObjects` is true: **do not
skip `index-pack`**. Pass the downloaded pack through
`index-pack --fsck-objects` as today, even if an idx URI was sent.
Reasons:

- fsck needs a real object walk (malformed objects, `.gitmodules`,
  `fsck.<msg-id>`).
- `parse_gitmodules_oids()` today reads OIDs from `index-pack`
  stdout. The `.gitmodules`-as-URI-blob tests in
  `t/t5702-protocol-v2.sh` depend on that. Skipping `index-pack`
  would drop those OIDs on the floor.

So the fast path is the default-off-fsck path. That matches current
fetch/clone behavior: fsck is opt-in, and `verify-pack` is not in the
transfer path at all.

### Order relative to the inline pack

The current client indexes the **inline** pack first, then downloads
URI packs. That is correct for today’s blob URIs (the inline pack is
not thin against those blobs).

The commit-based design *does* make the inline pack thin against the
URI pack (`--not C`). For that, the URI pack **and its idx** must be
installed before `index-pack --fix-thin` on the inline pack. See
`thin-pack-and-packfile-uri.md`.

This idx extension should therefore:

1. Parse `packfile-uris` (including `idx` lines) **before** consuming
   the `packfile` section (already true).
2. Download and install URI packs that have an idx **before** running
   `get_pack()` on the inline stream, **or** buffer the inline pack
   to a tempfile and index it after the URI installs.

Prefer (2)’s first half if the transport allows it: the v2 response
is `packfile-uris` then `packfile` on one stream, so the client
cannot fully download URI packs from the CDN *and* simultaneously
read the inline pack without either buffering or overlapping I/O
carefully. Practical MVP:

- Read and parse the `packfile-uris` section (cheap).
- Stream the inline pack to a tempfile (or into `index-pack` only if
  no URI pack is a thin-pack base).
- Download/install URI pack+idx.
- Run `index-pack --fix-thin` on the tempfile.

For the existing blob-URI path, either order remains correct. Do not
reorder in a way that breaks current tests; gate “URI first” on “we
received at least one URI pack that we will treat as a thin-pack
base,” or always buffer when any URI+idx pair is present (simpler,
fine for MVP).

### Fallback and errors

| Situation | Behavior |
|---|---|
| Client did not send `idx` | Today’s format and `index-pack` path. |
| Client sent `idx`, server has no idx | Pack line only; client `index-pack`s as today. |
| `idx` line hash does not match any pack line | Die (protocol error). |
| Pack trailer ≠ advertised hash | Die (already the case). |
| Idx fails `verify_pack_index` or its pack-checksum ≠ advertised hash | Die; do not fall back to a possibly-wrong local index build unless we decide to. Prefer fail-closed: the server promised an idx. |
| Idx HTTP 404 | Die if an `idx` line was sent. Do not guess another URL. |
| `transfer.fsckObjects` | Ignore the skip-index fast path; `index-pack --fsck-objects`. |

## Sequence of changes

Implement in this order so each step is reviewable and testable.

### 1. Document the protocol

- `Documentation/gitprotocol-v2.adoc`
  - Client argument: `packfile-uris` list may include `idx`.
  - `packfile-uris` section: optional `idx <hash> <uri>` lines;
    hash is the pack checksum; client must pair them before the
    connectivity check.
- `Documentation/technical/packfile-uri.adoc`
  - Client downloads pack **and** idx when an `idx` line is present,
    installs both, and may skip generating an idx.
  - Note the weaker integrity model and the fsck fallback.
  - Move “different file formats referenced by URIs” from future
    work to something this extension starts (idx only).
- `Documentation/config/uploadpack.adoc` (or wherever
  `uploadpack.blobPackfileUri` is described): optional idx URI;
  `.pack` → `.idx` synthesis rule.
- `Documentation/config/fetch.adoc`: `fetch.uriprotocols` does
  **not** need to mention `idx`; that token is sent automatically
  when the client implements this, independent of URI schemes.

### 2. Teach the client to request `idx`

- `fetch-pack.c` (`send_fetch_request`): when building
  `packfile-uris http,https`, also append `,idx` (only if at least
  one real protocol is present, same as today).
- No user-facing config for the first cut. A later
  `fetch.packfileUriIdx` (bool, default true) can disable the token
  if we want a kill switch.

### 3. Parse `idx` lines

- `receive_packfile_uris()` in `fetch-pack.c`: accept either
  `<hash> <uri>` or `idx <hash> <uri>`. Store a small struct
  `{ pack_hash, pack_uri, idx_uri }` instead of a flat
  `string_list` of raw lines.
- Reject `idx` lines whose hash has no pack line, duplicate idx
  for the same hash, or `idx` lines when we did not send the token
  (should not happen).
- Keep `PACKET_READ_REDACT_URI_PATH` working for both URIs
  (trace redaction tests in `t/t5702-protocol-v2.sh`).

### 4. Server: emit `idx` lines for blob URIs

- `builtin/pack-objects.c`
  - Parse optional fourth field of `uploadpack.blobPackfileUri`
    into `struct configured_exclusion`.
  - `--uri-protocol` list may contain `idx`. Treat `idx` as a flag,
    not as a URI scheme to match against `http:` / `https:`.
  - `write_excluded_by_configs()`: after each `<pack-hash> <uri>`
    line, if the client sent `idx` and an idx URI is known (explicit
    or synthesized), write `idx <pack-hash> <idx-uri>\n`.
- `upload-pack.c`: no structural change for the blob path; it still
  relays pack-objects’ stdout before the `PACK` header into the
  `packfile-uris` section. Confirm `idx …` lines pass through
  unchanged (they will).
- Future commit-URI path (out of scope here): upload-pack writes
  both lines itself before spawning pack-objects.

### 5. Client: download idx and skip `index-pack`

- `http-fetch.c` / `http.c`
  - New option, e.g. `--idx=<uri>`, valid only with `--packfile=`.
  - Download idx; verify pack trailer + `verify_pack_index()` +
    matching pack checksum.
  - Install pack+idx+`.keep`; print `keep\t<hash>\n`.
  - When `--idx=` is set, `--index-pack-args` is optional. When
    `--index-pack-args` is also set (fsck), download both files but
    still run `index-pack` on the pack (idx file is then unused, or
    used only as a sanity check).
- `fetch-pack.c` (`do_fetch_pack_v2` loop over URIs)
  - If `idx_uri` is set and fsck is off: spawn
    `http-fetch --packfile=<hash> --idx=<idx-uri> <pack-uri>`.
  - Else: existing `--index-pack-arg=` path.
- Shared helper (optional but useful): “verify and install a
  pack+idx pair given advertised hash.” Keep it next to the dumb-HTTP
  idx code in `http.c` so the trailer checks live in one place.

### 6. Ordering vs the inline pack

- After step 5 works with the current “inline first, URI second”
  order (enough for blob URIs and all existing tests), add buffering:
  - If any URI entry has an idx (or, later, is a commit-base pack),
    write the inline pack to a tempfile, install URI pack+idx,
    then `index-pack --stdin --fix-thin` from the tempfile.
- Until commit-based URIs exist, this is latent correctness, not
  user-visible. Still do it in this series if the tempfile change is
  small; otherwise a follow-up commit with a comment pointing at
  `thin-pack-and-packfile-uri.md` is acceptable.

### 7. Tests (`t/t5702-protocol-v2.sh` and/or a sibling)

Extend `configure_exclusion` (or add `configure_exclusion_with_idx`)
so the idx produced by `pack-objects` is published next to the pack
and advertised.

New cases:

1. **Clone with idx URI** — client sends `idx`; server emits `idx`
   line; child repo has the URI pack and a matching idx; clone
   succeeds. Optionally `GIT_TRACE2` / test-tool to assert
   `index-pack` was **not** invoked for that pack hash.
2. **Fetch with idx URI** — same as today’s fetch test, plus idx.
3. **No idx on server** — client sends `idx`; only pack line;
   client falls back to `index-pack`; still succeeds.
4. **Old client** — do not send `idx`; response must not contain
   `idx ` lines (trace-packet assertion).
5. **Idx / pack hash mismatch** — die with a clear error.
6. **Wrong idx trailer** — publish a different pack’s idx; die.
7. **`transfer.fsckObjects=1` with idx URI** — still succeeds, and
   still catches the existing “bad object” / `.gitmodules` cases
   (fsck path must not skip `index-pack`).
8. **Trace redaction** — `idx` URI path redacted like the pack URI.
9. **Synthesis** — config has only three fields; pack URL ends in
   `.pack`; server emits `…idx` URL and the file is there.

Existing blob-URI tests must keep passing unchanged.

### 8. RelNotes and capability comment

- Short RelNotes entry under pack-protocol / fetch: clients may
  request `idx`; servers may send `idx <hash> <uri>`; clients may
  install a published idx instead of building one.
- Mention experimental, same as `packfile-uris` itself.

## Correctness sketch

For a clone of tips `T` with a URI pack (blob or commit-closure):

| Need | How it is met |
|---|---|
| Bytes of the URI pack | HTTP GET of `<pack-uri>`, trailer = advertised hash |
| OID → offset map | HTTP GET of `<idx-uri>`, `verify_pack_index`, idx trailer pack-checksum = advertised hash |
| Thin-pack bases in the URI pack | Map above, after the pair is installed and packed-git is refreshed |
| Connectivity of `T` | Unchanged; runs after all packs are present |
| Object-content trust | Default: publisher/CDN. With fsck: `index-pack --fsck-objects` still walks the pack |

Old clients: no `idx` token → no `idx` lines → `index-pack` as today.
New clients against old servers: `idx` token ignored → pack lines
only → `index-pack` as today.

## Suggested commit split

1. Protocol docs + parse/emit of `idx` lines (server still never
   emits them; client already sends the token). Tests: token in the
   request; parser accepts `idx` lines from a fixture.
2. Server config fourth field + synthesis + emission.
3. `http-fetch --idx=` install path + fetch-pack wiring + fsck
   fallback.
4. Tests from §7.
5. Optional: inline-pack buffering / URI-first ordering.
