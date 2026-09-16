# Bundle file vs bundle-config payloads

A bundle URI is just a URL (or `file://` path) whose bytes the client
downloads with a GET. After a `200 OK`, Git does **not** trust
`Content-Type`. It sniffs the body:

1. Try to parse it as a Git **bundle file** (`git bundle verify`
   would accept it).
2. If that fails, parse it as a plaintext Git **config** file
   describing more URIs (a *bundle list*).
3. If that also fails, warn and continue the clone/fetch as if no
   bundle URI had been offered.

Those two payload types are the whole story at the URI. They are
easy to confuse with the protocol-v2 `command=bundle-uri` response,
which is a third, related thing: the origin never streams a `.bundle`
over the Git protocol. It only returns `bundle.*` key/value pairs
that *point at* URIs. Each of those URIs then GET-returns either a
bundle file or another config list.

Canonical sources: `Documentation/technical/bundle-uri.adoc`,
`Documentation/gitprotocol-v2.adoc` (`bundle-uri` / "URI CONTENTS"),
`Documentation/gitformat-bundle.adoc`, `bundle-uri.c`
(`fetch_bundle_uri_internal()`, `is_bundle()` then
`bundle_uri_parse_config_format()`).

---

## The two HTTP/file payloads

### 1. Direct bundle file

A bundle is a small text header followed by a pack. v2 starts with
the magic line `# v2 git bundle`; v3 starts with `# v3 git bundle`
and may list capabilities (`@object-format=…`, `@filter=…`).

```text
# v2 git bundle
- <prereq-oid> <optional comment>
<tip-oid> refs/heads/main
<tip-oid> refs/tags/v1.0

PACK....
```

- Lines starting with `-` are **prerequisites**: objects the reader
  must already have. A *thick* clone bundle has none.
- Other `oid SP refname` lines are the tips stored in the pack.
- A blank line ends the header. Everything after that is a normal
  packfile (the same bytes `git index-pack` would accept).

The client writes those tips under `refs/bundles/*` and later sends
them as `have` lines in the origin `fetch`, so the origin only has
to pack the delta since that snapshot.

This is the payload you get from `git bundle create repo.bundle --all`
dropped on a CDN.

### 2. Bundle config (bundle list)

Plaintext Git-config. Same keys the origin would advertise on the
v2 command. Typical shape:

```text
[bundle]
	version = 1
	mode = all
	heuristic = creationToken

[bundle "full"]
	uri = https://cdn.example.com/base.bundle
	creationToken = 1700000000

[bundle "daily"]
	uri = daily.bundle
	creationToken = 1700086400
```

Required by the design doc:

- `bundle.version` — only `1` is understood; anything else and the
  client ignores the list.
- `bundle.mode` — `all` (need every matching URI) or `any` (one of
  them is enough; used for geo mirrors).

The in-tree parser defaults `version=1` and `mode=all` if omitted.
Unknown keys are ignored, so a list can grow without breaking old
clients.

`bundle.<id>.uri` is required per entry. Relative URIs resolve
against the list URL (path-relative, or `/…` against the host).
Optional keys the client actually uses today: `filter`,
`creationToken`, `location`. `bundle.heuristic=creationToken` tells
the client this list is meant for incremental fetches and that it
may store `fetch.bundleURI` for later `git fetch`.

A list entry's URI is itself either a bundle **or** another list
("list of lists"). Recursion is capped at depth 4
(`max_bundle_uri_depth` in `bundle-uri.c`). When
`heuristic=creationToken` is set, those URIs are expected to be
bundles, not nested lists.

---

## How the client decides

`fetch_bundle_uri_internal()` downloads the URI to a tempfile, then:

```c
if (!is_bundle(file, /*quiet*/1))
        /* treat as config; recurse on the listed URIs */
else
        /* keep the file; later unbundle() it */
```

`is_bundle()` opens the file and tries `read_bundle_header()`. That
succeeds only if the magic is `# v2 git bundle` or `# v3 git bundle`.
A config file starts with `[bundle]` or a comment, so the header
parse fails and the config path runs.

There is no `Content-Type` check and no filename heuristic in this
sniff. A URI named `foo.bundle` that contains a config list is a
config list. A URI named `bundles.cfg` that starts with
`# v2 git bundle` is a bundle.

---

## Two ways the client learns a URI

| Path | What talks first | What that conversation returns |
|---|---|---|
| `git clone --bundle-uri=<uri>` | Nothing on the origin (the v2 `bundle-uri` command is **skipped**) | The GET of `<uri>` is a bundle **or** a config list |
| `transfer.bundleURI=true` and the origin advertises `bundle-uri` | Protocol v2 `command=bundle-uri` | Always `key=value` packet lines. Then the client GETs each advertised URI, and **those** bodies are bundle or config |

The in-tree server (`bundle_uri_command()`) just dumps every
`bundle.*` key from the repo config as packet lines. Enable with
`uploadpack.advertiseBundleURIs=true` and set e.g.
`bundle.full.uri=https://cdn.example.com/base.bundle`.

`--bundle-uri` wins if both are present: the client does not issue
`command=bundle-uri`.

---

## Example conversations

Pkt-lines are shown decoded (`command=bundle-uri`) rather than as
`0014command=bundle-uri\n`. `0000` is flush, `0001` is delim. Over
HTTPS the capability advertisement is the smart `info/refs`
response; the command is a later `POST …/git-upload-pack`. The CDN
GETs are ordinary HTTP, not Git protocol.

OIDs are shortened.

### A. `--bundle-uri` → direct bundle

The user already knows a snapshot URL. No v2 bundle command.

```text
$ git clone --bundle-uri=https://cdn.example.com/linux.bundle \
        https://git.example.com/linux.git
```

```http
GET /linux.bundle HTTP/1.1
Host: cdn.example.com

HTTP/1.1 200 OK

# v2 git bundle
c0ffee… refs/heads/master
d00d00… refs/tags/v6.8

PACK\0…          ← the objects
```

Client: `unbundle()` → `index-pack --stdin --fix-thin`, write
`refs/bundles/heads/master` and `refs/bundles/tags/v6.8`. Then a
normal v2 `ls-refs` + `fetch` against `git.example.com`, sending
those tips as `have`s so the origin only packs whatever landed
after the snapshot.

### B. `--bundle-uri` → config list → two bundles

Same clone flag, but the URI is an index of bundles. Incremental
history: a thick base plus a thin daily.

```text
$ git clone --bundle-uri=https://cdn.example.com/bundles.cfg \
        https://git.example.com/linux.git
```

```http
GET /bundles.cfg HTTP/1.1
Host: cdn.example.com

HTTP/1.1 200 OK
Content-Type: text/plain

[bundle]
	version = 1
	mode = all
	heuristic = creationToken

[bundle "base"]
	uri = https://cdn.example.com/base.bundle
	creationToken = 1700000000

[bundle "daily"]
	uri = daily.bundle
	creationToken = 1700086400
```

`daily.bundle` is relative, so it becomes
`https://cdn.example.com/daily.bundle`.

`heuristic=creationToken` and `mode=all`: download newest-first,
unbundle oldest-first (so the daily's `- <prereq>` is already in
the ODB). Then GET the files:

```http
GET /base.bundle HTTP/1.1
Host: cdn.example.com

HTTP/1.1 200 OK

# v2 git bundle
aaaaaa… refs/heads/master

PACK\0…          ← thick: no "-" lines
```

```http
GET /daily.bundle HTTP/1.1
Host: cdn.example.com

HTTP/1.1 200 OK

# v2 git bundle
- aaaaaa…        ← need the tip of base.bundle
bbbbbb… refs/heads/master

PACK\0…          ← only objects since base
```

After both unbundle, `refs/bundles/heads/master` is `bbbbbb`. The
client may store `fetch.bundleURI=https://cdn.example.com/bundles.cfg`
and `fetch.bundleCreationToken=1700086400` so the next
`git fetch` only downloads list entries with a larger token.

### C. Origin advertises a list; URI is a direct bundle

This is the "I don't know a CDN URL, the host tells me" path.
`transfer.bundleURI` must be true or the client never asks.

Server config (what `git-upload-pack` will dump):

```text
[uploadpack]
	advertiseBundleURIs = true
[bundle "full"]
	uri = https://cdn.example.com/base.bundle
```

Capability advertisement (HTTPS shown):

```http
GET /linux.git/info/refs?service=git-upload-pack HTTP/1.1
Host: git.example.com
Git-Protocol: version=2

HTTP/1.1 200 OK
Content-Type: application/x-git-upload-pack-advertisement

000eversion 2
0012ls-refs
0010fetch
0014bundle-uri          ← capability, no value
0000
```

Then the client issues the command (no arguments today):

```text
C: command=bundle-uri
C: agent=git/2.51.0
C: object-format=sha1
C: 0001
C: 0000

S: bundle.full.uri=https://cdn.example.com/base.bundle
S: 0000
```

That response is **already** a bundle list, just in pkt-line
`key=value` form instead of INI. The client does not download a
config file from the origin. Implied defaults fill in
`bundle.version=1` and `bundle.mode=all`.

Then the CDN GET is flow A: a raw bundle file. Unbundle, then
`ls-refs` / `fetch` on the same origin connection (or a new POST),
with the bundle tips as `have`s.

If the operator also set `bundle.version`, `bundle.mode`,
`bundle.heuristic`, those appear as extra packet lines:

```text
S: bundle.version=1
S: bundle.mode=all
S: bundle.heuristic=creationToken
S: bundle.full.uri=https://cdn.example.com/base.bundle
S: bundle.full.creationToken=1700000000
S: 0000
```

Same information as the INI in example B; different framing
because this hop is Git protocol, not a static file.

### D. Origin advertises `mode=any`; each URI is another config list

Geo split. The origin returns a tiny, rarely changing list. Each
region's URI is a config file that names the actual bundles.

```text
C: command=bundle-uri
C: 0001
C: 0000

S: bundle.version=1
S: bundle.mode=any
S: bundle.eastus.uri=https://eastus.example.com/linux/bundles.cfg
S: bundle.eastus.location=East US
S: bundle.europe.uri=https://europe.example.com/linux/bundles.cfg
S: bundle.europe.location=Europe
S: 0000
```

Client picks one (implementation today: first that downloads).
Suppose it takes East US:

```http
GET /linux/bundles.cfg HTTP/1.1
Host: eastus.example.com

HTTP/1.1 200 OK

[bundle]
	version = 1
	mode = all
	heuristic = creationToken

[bundle "base"]
	uri = base.bundle
	creationToken = 1700000000
```

Relative `base.bundle` → `https://eastus.example.com/linux/base.bundle`,
which is a direct bundle (flow A). If that GET fails, `mode=any` on
the *parent* list lets the client try `europe`.

This is two config hops (v2 packets, then an HTTP INI) before any
pack bytes move. Both hops are "bundle config responses." Only the
last GET is a bundle file.

---

## Side-by-side

| | Direct bundle | Bundle config |
|---|---|---|
| Magic / first bytes | `# v2 git bundle` or `# v3 git bundle` | `[bundle]` (or a `#` comment, then that) |
| What it contains | Header + pack (objects + tip refs) | Pointers: URIs, mode, optional heuristic |
| Who serves it | CDN / static file / `file://` | Same, **or** origin via `command=bundle-uri` as `key=value` pkt-lines |
| Client action | `unbundle()` → `index-pack --stdin --fix-thin`; write `refs/bundles/*` | Parse list; GET the listed URIs (recurse) |
| v2 `command=bundle-uri` | Never this | Always this (pkt-line form of the same keys) |
| `--bundle-uri=` | Yes, if that URL is a bundle | Yes, if that URL is a list |

---

## After the payload: catch-up fetch

Neither payload replaces talking to the origin. After unbundling:

```text
C: command=fetch
C: 0001
C: want <current origin master>
C: have <oid from refs/bundles/heads/master>
C: done
C: 0000

S: NAK
S: PACK…          ← hopefully small
```

If a bundle or list is missing, corrupt, or has unsatisfied
prerequisites, the client **degrades**: ignore it and fetch
everything from the origin. The origin is the source of truth; the
CDN is a hint.

---

## Operator cheat sheet

Serve a single thick snapshot:

```bash
git bundle create /var/www/base.bundle --all
# nginx: GET /base.bundle → that file
git -C repo.git config uploadpack.advertiseBundleURIs true
git -C repo.git config bundle.full.uri https://cdn.example.com/base.bundle
```

Serve a list (so you can add dailies later without changing the
origin advertisement):

```bash
# origin still advertises one URI — the list
git -C repo.git config bundle.full.uri https://cdn.example.com/bundles.cfg

# CDN: GET /bundles.cfg → the INI; GET /base.bundle → the bundle
```

Or skip the origin advertisement and tell clones yourself:

```bash
git clone --bundle-uri=https://cdn.example.com/base.bundle \
        https://git.example.com/linux.git
# or
git clone --bundle-uri=https://cdn.example.com/bundles.cfg \
        https://git.example.com/linux.git
```

A proposed extra list key (`bundle.<id>.idx`) for skipping
`index-pack` on thick bundles is described in
`bundle-uri-extended-to-include-idx.md`. It does not change this
sniff: the URI is still either a bundle or a config list; the idx
is a sidecar named *from* the list.
