# Bundle-URI: opt-in sidecar `.idx` for thick bundles

A small extension to today’s `bundle-uri` consume path: the provider
publishes the `.idx` that already belongs to the bundle’s inner pack,
and a new client that opts in can install that pair instead of running
`index-pack` during `unbundle`.

Limited on purpose to **thick** bundles (no prerequisites, so
`--fix-thin` would be a no-op). Incremental / thin bundles keep
today’s path.

Background on why `unbundle` always re-indexes — and why a published
idx is enough for a complete clone bundle — is in
`bundle-uri-history-and-rationale-for-slow-reverify-on-the-client-side.md`
(“Why do we re-index / re-verify?”). The same skip-`index-pack` trust
model is in `packfile-uri-with-idx-extension.md`. Parallel download
shape is in `packfile-uri-download.md`.

## Goal

On a large thick clone bundle, today’s client:

1. GETs the whole bundle (header + pack) into a tempfile.
2. Parses the header, then feeds the pack bytes to
   `git index-pack --stdin --fix-thin`.
3. That command *copies the pack again* and inflates/hashes every
   object to *build* an idx the publisher already has.

The end state is `objects/pack/pack-<hash>.{pack,idx}` plus
`refs/bundles/*`. We already have the pack bytes after step 1. The
missing file is the idx. Downloading that one extra file, checking
the two trailers, and installing the pair is the speedup.

New clients opt in. Old clients never see a format they cannot
parse: they ignore unknown bundle-list keys (`gitprotocol-v2.adoc`)
and keep calling `unbundle()`.

## Non-goals

- Thin or incremental bundles (`--fix-thin` can rewrite the pack
  hash; a publisher idx of the pre-fix pack is then the wrong file).
- Changing the bundle *file* format. The idx is a sidecar, not a
  new header field.
- Replacing bundles with bare pack+idx (that drops tip refs). The
  header still supplies `refs/bundles/*`.
- Automatic `verify-pack` after install. Same as fetch today.
- A `$GIT_DIR/hooks/` download hook. Clone has no useful local
  hooks; see “Download helper” below.

## Advertisement

`bundle.version` stays `1`. Unknown keys are ignored, so this is
backward compatible.

```text
bundle.<id>.uri = https://cdn.example/base.bundle
bundle.<id>.idx = https://cdn.example/base.idx
```

`bundle.<id>.idx` is the HTTP(S) or `file://` URI of the `.idx`
that `pack-objects` / `index-pack` wrote for **the inner pack**
(the bytes after the bundle’s blank line). It is not an index of
the bundle file.

Rules:

- The key is optional per id. A list may mix thick+idx entries
  with ordinary bundles.
- Relative URIs resolve like `bundle.<id>.uri`.
- Advertise `idx` only for thick bundles. If the client still finds
  prerequisites in the header, it ignores the idx and unbundles.
- Old clients never look at the key.

Optional sugar (not required for the MVP):

```text
bundle.<id>.packHash = <hex>     # inner pack trailer; else take it from the idx
bundle.<id>.size     = <bytes>   # bundle length, for preallocate / helper
```

`hash=` on the list was already reserved for the *bundle file*.
Do not overload it as the pack checksum.

### Lone `--bundle-uri` (no list)

If the URI is a bundle, not a config list, and the client has the
feature on:

- if the URI ends in `.bundle`, try the same URL with that suffix
  replaced by `.idx`;
- otherwise try `<uri>.idx`.

HTTP 404 → today’s `unbundle` (bundle-uri already degrades). Do
not guess a third URL. A list with an explicit `bundle.<id>.idx`
is the reliable operator path; synthesis is for the one-file
`--bundle-uri` case.

## Client opt-in

```text
transfer.bundleURIIdx
```

Bool, default **true** in a Git that implements this. The
implementation is the opt-in: old Git never reads `.idx`. The
knob is a kill switch (and a test lever), not a second discovery
flag. It is independent of `transfer.bundleURI` (whether to ask
the v2 command at all).

`git clone --bundle-uri=` uses the same knob. No new clone flag
in the MVP.

## When the fast path is allowed

All of:

1. An idx URI is known (list key or synthesis).
2. `transfer.bundleURIIdx` is true.
3. `transfer.fsckObjects` / `fetch.fsckObjects` is false.
4. After `read_bundle_header()`, the prerequisite list is **empty**.
5. Trailer checks succeed (below).

Anything else → existing `unbundle()` →
`index-pack --stdin --fix-thin` (plus `--fsck-objects` when
requested). Filtered v3 bundles are still eligible if they are
thick: write the `.promisor` marker as today, but do not
re-index.

Empty prereqs is the thick-bundle definition for this feature.
Do not trust a list key alone; the header is authoritative.

## Install path

After the bundle bytes are on disk (and the idx has been
downloaded, in parallel if the helper is in use):

1. `read_bundle_header()` — fd now at the pack. If any
   prerequisite → `unbundle()` and stop.
2. `verify_pack_index()` on the downloaded idx. Idx
   self-checksum valid.
3. Pack trailer (last `hashsz` bytes of the bundle file) equals
   the pack checksum stored in the idx trailer, and equals
   `bundle.<id>.packHash` if that key was sent.
4. Copy or splice the pack portion to
   `objects/pack/pack-<hash>.pack`. One write, not the
   stdin-into-`tmp_pack` second copy `index-pack --stdin` does.
5. Install `pack-<hash>.idx`. Write a `.keep` until
   `refs/bundles/*` are updated.
6. `refs_update_ref()` from the header, same as today
   (`c858c6442b`: every `refs/*` in the header).
7. Refresh packed-git. Unlink the bundle tempfile.

Do **not** run `index-pack`. Do **not** pass `--fix-thin`.

`verify_bundle()`’s prereq walk is a no-op on a thick bundle;
skipping it with the empty-prereq check is equivalent.

## Integrity

Default (fsck off): publisher/CDN trust, same as dumb HTTP’s
published `pack-*.idx`. The idx table is not cryptographically
bound to the bytes at those offsets. The trailer match is a
consistency check, not an object-content proof.

`transfer.fsckObjects` / `fetch.fsckObjects`: **do not take the
fast path.** `unbundle()` already grows `--fsck-objects`
(`63d903ff52`). That walk needs inflated objects.

CVE-2025-48385 is about URI injection into `git-remote-https`,
not about idx trust. Keep treating advertised URIs as hostile
(space/newline checks). An idx URI gets the same validation as
`bundle.<id>.uri`.

## Download helper

Today `copy_uri_to_file()` is one sequential `git-remote-https`
`get`. That is the other half of “bundle-uri does not speed up
large clones”: no `Range`, no overlap with anything.

Do **not** add a githook. Clone’s `$GIT_DIR/hooks` is a template.
Use a **configured helper**, same family as `core.sshCommand` /
`uploadpack.packObjectsHook`, protected-scope only (user /
system / `includeIf` — not a value the remote’s config can set
during clone).

```text
fetch.bundleUriHelper = /usr/local/libexec/git-bundle-uri-helper
```

Byte-fetcher only. Git still parses the header, checks trailers,
installs pack+idx, writes refs. The helper’s job is: the dest
path exists and is complete.

One process, stdin records (reuse the packfile-uri helper
shape so one binary can serve both):

```text
uri=https://cdn.example/base.bundle
path=/path/to/objects/bundles/tmp_uri_XXXXXX
size=4294967296
kind=bundle

uri=https://cdn.example/base.idx
path=/path/to/objects/pack/tmp_idx_XXXXXX
kind=idx
```

Stdout: `progress` / `ok` lines; non-zero exit aborts that
bundle (then the usual degrade-to-origin-fetch).

The helper may shard the **bundle** with parallel `Range` GETs
after a one-byte `206` probe. Do not shard the idx. Public or
pre-signed CDN URLs only for the MVP; authenticated `http.*`
stays on `git-remote-https`.

Unset helper → built-in `get` (today), still two GETs (bundle
then idx) when the fast path is on. A later built-in ranged
downloader can fill that gap; the helper is the escape hatch
that makes “massive” parallelism available without putting
aria2 inside Git.

If the helper is unset and `size` is unknown, sequential GETs
are fine: the idx is tiny; the win is skipping `index-pack`,
not the second RTT.

## Fallback

| Situation | Behavior |
|---|---|
| Old client | Ignores `bundle.<id>.idx`; `unbundle()` as today |
| New client, no idx key / synthesis 404 | `unbundle()` |
| `transfer.bundleURIIdx=false` | `unbundle()` |
| Header has prerequisites | `unbundle()` (idx unused) |
| `transfer.fsckObjects` | `unbundle()` + `--fsck-objects` |
| Idx / pack trailer mismatch | Fail that bundle; do not install a half-pair; try the next list entry or fall back to fetch |
| Idx HTTP 404 after an explicit list key | Fail that bundle (the list promised an idx). Synthesis 404 is the other row |
| Helper missing / non-zero | Same as a failed `get`: that bundle is skipped |

## Operator workflow

When cutting a thick clone bundle, keep the idx `pack-objects`
already wrote:

```bash
git bundle create base.bundle --all          # thick: no --since / prereqs
# objects/pack/pack-<hash>.{pack,idx} exist from that run
# publish base.bundle and pack-<hash>.idx (as base.idx) on the CDN
```

List:

```text
[bundle]
	version = 1
	mode = all

[bundle "full"]
	uri = https://cdn.example/base.bundle
	idx = https://cdn.example/base.idx
```

Do not advertise `idx` on creationToken incrementals unless
those files are themselves thick (no `-` prerequisite lines).

## Sequence of changes

1. **Docs** — `bundle-uri.adoc`: `bundle.<id>.idx`, thick-only
   rule, synthesis for `--bundle-uri`, trust/fsck note.
   `gitprotocol-v2.adoc`: mention the new key under future →
   implemented keys. `config/transfer.adoc`:
   `transfer.bundleURIIdx`.
2. **Parse** — accept `bundle.<id>.idx` (and optional
   `packHash` / `size`) in the existing list parser.
3. **`unbundle` split** — extract “header + install pack+idx +
   write refs” from “header + `index-pack --stdin --fix-thin`.”
   Fast path is a new flag or a sibling of `unbundle()`.
4. **Wire it in `bundle-uri.c`** — after download, if the gate
   in “When the fast path is allowed” holds, take (3); else
   today’s call. Tests in `t/t5558` / `t/t5730`: thick+idx
   clone (no `index-pack` for that hash), old-client ignore,
   thin fallback, fsck fallback, trailer mismatch, synthesis
   404.
5. **`fetch.bundleUriHelper`** — optional, after (4) works with
   sequential GETs. Shared record format with
   `fetch.packfileUriHelper` if that lands.

(1)–(4) are the feature. (5) is how the remaining GET becomes
fast on a multi-gigabyte bundle. Neither changes the origin
protocol beyond one ignored-by-old-clients list key.
