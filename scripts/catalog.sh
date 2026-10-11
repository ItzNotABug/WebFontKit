#!/usr/bin/env bash
# Rebuilds the bundled Google Fonts catalogue: every family's version and the file ID
# of each style, so a first load can skip the CSS2 lookup. Run it before a release.
#
#   scripts/catalog.sh                       fetch from Google and write the bundled file
#   scripts/catalog.sh --rows rows.json OUT  build OUT from saved rows (offline; tests)
#
# Keeps only names, versions and IDs. The layout is documented in GoogleFontsCatalog.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage="usage: $0 [--rows rows.json OUT]"
# Relative --rows paths are the caller's, so resolve them before moving to the repo root.
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }

OUT="$ROOT/Sources/WebFontKit/Resources/GoogleFonts.catalog"
ROWS=""
case "$#:${1:-}" in
    0:) ;;
    3:--rows) ROWS="$(absolute "$2")"; OUT="$(absolute "$3")" ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
cd "$ROOT"

python3 - "$OUT" "$ROWS" <<'EOF'
import base64, binascii, concurrent.futures, datetime, json, os, re, struct, sys, time, urllib.parse

out, rows_path = sys.argv[1], sys.argv[2]
# The library's own user agent, so the catalogue lists the files a CSS2 lookup would return.
version = re.search(r'libraryVersion = "([^"]+)"', open("Sources/WebFontKit/Network/LibraryVersion.swift").read()).group(1)
USER_AGENT = f"WebFontKit/{version}"
URL = re.compile(r"https://fonts\.gstatic\.com/s/([a-z0-9]+)/v(\d+)/([A-Za-z0-9_-]+)\.ttf$")

def slug(family):
    return re.sub(r"[^a-z0-9]", "", family.lower())

def fetch_rows():
    """(family, style, url) for every family Google serves, style like "400" or "700i"."""
    import http.client, threading
    local = threading.local()

    def get(host, path):
        # One kept-alive connection per worker: no TLS handshake per request. Rate limits,
        # server errors and dropped connections are retried with backoff.
        for attempt in range(5):
            if attempt:
                time.sleep(0.5 * 2 ** attempt)
            connection = getattr(local, host, None) or http.client.HTTPSConnection(host, timeout=30)
            setattr(local, host, connection)
            try:
                connection.request("GET", path, headers={"User-Agent": USER_AGENT})
                response = connection.getresponse()
                body = response.read().decode()
                if response.status == 200:
                    return body
                if response.status != 429 and response.status < 500:
                    return ""
            except (OSError, http.client.HTTPException):
                connection.close()
                setattr(local, host, None)
        return ""

    listing = get("fonts.google.com", "/metadata/fonts")
    if not listing:
        sys.exit("Could not fetch Google's font list.")
    metadata = json.loads(listing.removeprefix(")]}'"))
    families = {f["family"]: list(f["fonts"]) for f in metadata["familyMetadataList"]}

    def query(name):
        tuples = sorted({(1 if s.endswith("i") else 0, int(s.rstrip("i"))) for s in families[name]})
        return "family=" + urllib.parse.quote(name).replace("%20", "+") + ":ital,wght@" + ";".join(f"{i},{w}" for i, w in tuples)

    def css(batch):
        # Many families per request; each block names its family, so nothing is attributed wrongly.
        text = get("fonts.googleapis.com", "/css2?" + "&".join(query(name) for name in batch))
        found = []
        for block in text.split("@font-face")[1:]:
            family = re.search(r"font-family:\s*'([^']+)'", block).group(1)
            italic = re.search(r"font-style:\s*italic", block) is not None
            weight = re.search(r"font-weight:\s*(\d+)", block).group(1)
            url = re.search(r"url\((https://[^)]+)\)", block).group(1)
            found.append((family, weight + ("i" if italic else ""), url))
        return found

    names = sorted(families)
    batches = [names[i:i + 20] for i in range(0, len(names), 20)]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        rows = [row for found in pool.map(css, batches) for row in found]
        # A family a batched answer left out (Google drops one it can't serve) is asked for alone.
        missing = sorted(set(names) - {row[0] for row in rows})
        rows += [row for found in pool.map(css, [[name] for name in missing]) for row in found]
    unanswered = sorted(set(names) - {row[0] for row in rows})
    if unanswered:
        sys.exit(f"Google answered nothing for {len(unanswered)} families, so nothing was written: {', '.join(unanswered[:10])}")
    return rows

rows = json.load(open(rows_path)) if rows_path else fetch_rows()

# family -> (version, {(italic, weight): id bytes}); families whose URLs break the pattern are left to CSS2.
families, skipped, sources = {}, set(), {}
for name, style, url in rows:
    match = URL.match(url)
    weight = int(style.rstrip("i"))
    if not match or match.group(1) != slug(name) or weight % 100 or not 100 <= weight <= 1000:
        skipped.add(name)
        continue
    try:
        identifier = base64.urlsafe_b64decode(match.group(3) + "=" * (-len(match.group(3)) % 4))
    except binascii.Error:
        skipped.add(name)
        continue
    # Two files for one style (subsets, say) or two versions in one family: leave it to CSS2.
    if sources.setdefault((name, style.endswith("i"), weight), url) != url:
        skipped.add(name)
    entry = families.setdefault(name, [int(match.group(2)), {}])
    if entry[0] != int(match.group(2)):
        skipped.add(name)
    entry[1][(style.endswith("i"), weight)] = identifier
for name in skipped:
    families.pop(name, None)

def weight_offset(group):
    """Where the weight float sits if every ID differs from the first only there, else None."""
    (w0, b0), rest = group[0], group[1:]
    if not rest:
        return None
    offset = None
    for w, b in rest:
        if len(b) != len(b0):
            return None
        float_diff = bytes(x ^ y for x, y in zip(struct.pack("<f", w0), struct.pack("<f", w)))
        id_diff = bytes(x ^ y for x, y in zip(b0, b))
        hits = [i for i in range(len(b0) - 3)
                if id_diff[i:i + 4] == float_diff and not any(id_diff[:i]) and not any(id_diff[i + 4:])]
        if not hits or (offset is not None and hits[0] != offset):
            return None
        offset = hits[0]
    return offset

names = sorted(families, key=lambda n: n.encode())
records, offsets = bytearray(), []
for name in names:
    version, styles = families[name]
    groups = {}
    for (italic, weight), identifier in styles.items():
        groups.setdefault(italic, []).append((weight, identifier))
    encoded = name.encode()
    offsets.append(len(records))
    records += bytes([len(encoded)]) + encoded + struct.pack("<H", version) + bytes([len(groups)])
    for italic in sorted(groups):
        group = sorted(groups[italic])
        mask = sum(1 << (w // 100) for w, _ in group)
        offset = weight_offset(group)
        if offset is not None:
            w0, b0 = group[0]
            records += bytes([int(italic) | 2]) + struct.pack("<H", mask) + bytes([w0 // 100, offset, len(b0)]) + b0
        else:
            records += bytes([int(italic)]) + struct.pack("<H", mask)
            for _, identifier in group:
                records += bytes([len(identifier)]) + identifier
day = (datetime.datetime.now(datetime.timezone.utc).date() - datetime.date(1970, 1, 1)).days
header = b"WFKC" + bytes([1, 0]) + struct.pack("<HI", len(names), day)
index_size = 4 * len(names)
data = header + b"".join(struct.pack("<I", len(header) + index_size + o) for o in offsets) + records

# Decode every entry back and rebuild its URL exactly as the library will, then compare with Google's.
def decode(name, italic, weight):
    count = struct.unpack_from("<H", data, 6)[0]
    lo, hi, key = 0, count - 1, name.encode()
    while lo <= hi:
        mid = (lo + hi) // 2
        at = struct.unpack_from("<I", data, 12 + 4 * mid)[0]
        candidate = data[at + 1:at + 1 + data[at]]
        if candidate == key:
            break
        lo, hi = (mid + 1, hi) if candidate < key else (lo, mid - 1)
    else:
        return None
    at += 1 + data[at]
    version, groups = struct.unpack_from("<H", data, at)[0], data[at + 2]
    at += 3
    for _ in range(groups):
        flags, mask = data[at], struct.unpack_from("<H", data, at + 1)[0]
        at += 3
        if flags & 2:
            base, offset, length = data[at], data[at + 1], data[at + 2]
            identifier = bytearray(data[at + 3:at + 3 + length])
            at += 3 + length
            if bool(flags & 1) == italic and mask >> (weight // 100) & 1:
                diff = bytes(x ^ y for x, y in zip(struct.pack("<f", base * 100.0), struct.pack("<f", float(weight))))
                for i in range(4):
                    identifier[offset + i] ^= diff[i]
                return version, bytes(identifier)
        else:
            for n in range(16):
                if mask >> n & 1:
                    length = data[at]
                    identifier = data[at + 1:at + 1 + length]
                    at += 1 + length
                    if bool(flags & 1) == italic and n * 100 == weight:
                        return version, identifier
    return None

def rebuilt_url(name, version, identifier):
    encoded = base64.urlsafe_b64encode(identifier).decode().rstrip("=")
    return f"https://fonts.gstatic.com/s/{slug(name)}/v{version}/{encoded}.ttf"

checked = 0
for name in names:
    for (italic, weight) in families[name][1]:
        decoded = decode(name, italic, weight)
        url = rebuilt_url(name, *decoded) if decoded else None
        assert url == sources[(name, italic, weight)], f"round trip failed: {name} {weight}{'i' if italic else ''}"
        checked += 1

# Written beside the target, then renamed: an interrupted run never leaves a half-written file.
with open(out + ".partial", "wb") as file:
    file.write(data)
os.replace(out + ".partial", out)
print(f"{out}: {len(names)} families, {checked} files, {len(data) / 1024:.0f} KB"
      + (f"; {len(skipped)} families left to CSS2 (unusual URLs)" if skipped else ""))
EOF
