#!/usr/bin/env bash
# Rebuilds the bundled Google Fonts catalogue: every family's version and the file ID
# of each style, so a first load can skip the CSS2 lookup. Run it before a release.
#
#   scripts/catalog.sh                       fetch from Google and write the bundled file
#   scripts/catalog.sh --rows rows.json OUT  build OUT from saved rows (offline; tests)
#
# Writes only what a lookup needs: names, versions and IDs. Every entry is decoded back
# and compared with Google's URL before the file is written.
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$ROOT"

OUT="Sources/WebFontKit/Resources/GoogleFonts.catalog"
ROWS=""
if [ "${1:-}" = "--rows" ]; then
    ROWS="${2:?usage: $0 --rows rows.json OUT}"
    OUT="${3:?usage: $0 --rows rows.json OUT}"
fi

python3 - "$OUT" "$ROWS" <<'EOF'
import base64, concurrent.futures, datetime, json, re, struct, sys, urllib.parse

out, rows_path = sys.argv[1], sys.argv[2]
URL = re.compile(r"https://fonts\.gstatic\.com/s/([a-z0-9]+)/v(\d+)/([A-Za-z0-9_-]+)\.ttf$")

def slug(family):
    return re.sub(r"[^a-z0-9]", "", family.lower())

def fetch_rows():
    """(family, style, url) for every family Google serves, style like "400" or "700i"."""
    import http.client, threading
    local = threading.local()

    def get(host, path):
        # One kept-alive connection per worker: no TLS handshake per request.
        for attempt in range(3):
            connection = getattr(local, host, None) or http.client.HTTPSConnection(host, timeout=30)
            setattr(local, host, connection)
            try:
                connection.request("GET", path, headers={"User-Agent": "WebFontKit-catalog"})
                response = connection.getresponse()
                body = response.read().decode()
                if response.status == 200:
                    return body
            except (OSError, http.client.HTTPException):
                connection.close()
                setattr(local, host, None)
        return ""

    metadata = json.loads(get("fonts.google.com", "/metadata/fonts").removeprefix(")]}'"))
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
    return rows

rows = json.load(open(rows_path)) if rows_path else fetch_rows()

# family -> (version, {(italic, weight): id bytes}); families whose URLs break the pattern are left to CSS2.
families, skipped = {}, set()
for name, style, url in rows:
    match = URL.match(url)
    weight = int(style.rstrip("i"))
    if not match or match.group(1) != slug(name) or weight % 100 or not 100 <= weight <= 1000:
        skipped.add(name)
        continue
    identifier = base64.urlsafe_b64decode(match.group(3) + "=" * (-len(match.group(3)) % 4))
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

# Layout (little-endian):
#   header  "WFKC" | format u8 = 1 | reserved u8 | family count u16 | catalogue day u32 (days since 1970)
#   index   family count x u32: record offsets, records sorted by the family's UTF-8 bytes
#   record  name length u8 | name | version u16 | group count u8 | groups
#   group   flags u8 (1 italic, 2 computed) | weights u16 (bit n: weight n x 100)
#           computed: base weight / 100 u8 | float offset u8 | ID length u8 | ID
#           listed:   per weight, ascending: ID length u8 | ID
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
day = (datetime.date.today() - datetime.date(1970, 1, 1)).days
header = b"WFKC" + bytes([1, 0]) + struct.pack("<HI", len(names), day)
index_size = 4 * len(names)
data = header + b"".join(struct.pack("<I", len(header) + index_size + o) for o in offsets) + records

# Decode every entry back, exactly as the library will, and compare with Google's URL.
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

checked = 0
for name in names:
    version, styles = families[name]
    for (italic, weight), identifier in styles.items():
        assert decode(name, italic, weight) == (version, identifier), f"round trip failed: {name} {weight}{'i' if italic else ''}"
        checked += 1

open(out, "wb").write(data)
print(f"{out}: {len(names)} families, {checked} files, {len(data) / 1024:.0f} KB"
      + (f"; {len(skipped)} families left to CSS2 (unusual URLs)" if skipped else ""))
EOF
