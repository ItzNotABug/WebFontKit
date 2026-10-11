#!/usr/bin/env python3
"""The bundled Google Fonts catalogue: build it from Google, read it back, and reckon a fresh
build against the committed one. Run through scripts/catalog.sh and scripts/reckon.sh.

Keeps only names, versions and file IDs; the layout is documented in GoogleFontsCatalog.swift.
"""
import argparse, base64, binascii, concurrent.futures, datetime, http.client, json, os, random, re, struct, sys, threading, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLED = os.path.join(ROOT, "Sources/WebFontKit/Resources/GoogleFonts.catalog")
URL = re.compile(r"https://fonts\.gstatic\.com/s/([a-z0-9]+)/v(\d+)/([A-Za-z0-9_-]+)\.ttf$")
# The library's own user agent, so the catalogue lists the files a CSS2 lookup would return.
VERSION = re.search(r'libraryVersion = "([^"]+)"', open(os.path.join(ROOT, "Sources/WebFontKit/Network/LibraryVersion.swift")).read()).group(1)
USER_AGENT = f"WebFontKit/{VERSION}"
_local = threading.local()


def slug(family):
    return re.sub(r"[^a-z0-9]", "", family.lower())


def url_for(name, version, identifier):
    encoded = base64.urlsafe_b64encode(identifier).decode().rstrip("=")
    return f"https://fonts.gstatic.com/s/{slug(name)}/v{version}/{encoded}.ttf"


def get(host, path, method="GET"):
    """(status, body). One kept-alive connection per thread and host, so no TLS handshake per
    request; rate limits, server errors and dropped connections are retried with backoff."""
    status, body = 0, ""
    for attempt in range(5):
        if attempt:
            time.sleep(0.5 * 2 ** attempt)
        connection = getattr(_local, host, None) or http.client.HTTPSConnection(host, timeout=30)
        setattr(_local, host, connection)
        try:
            connection.request(method, path, headers={"User-Agent": USER_AGENT})
            response = connection.getresponse()
            status, body = response.status, response.read().decode(errors="replace")
            if status != 429 and status < 500:
                return status, body
        except (OSError, http.client.HTTPException):
            connection.close()
            setattr(_local, host, None)
    return status, body


def fetch_rows():
    """(rows, unanswered): (family, style, url) for every family Google serves, style like "400"
    or "700i", and the families it answered nothing for."""
    status, listing = get("fonts.google.com", "/metadata/fonts")
    if status != 200:
        sys.exit("Could not fetch Google's font list.")
    families = {f["family"]: list(f["fonts"]) for f in json.loads(listing.removeprefix(")]}'"))["familyMetadataList"]}

    def query(name):
        tuples = sorted({(1 if s.endswith("i") else 0, int(s.rstrip("i"))) for s in families[name]})
        return "family=" + urllib.parse.quote(name).replace("%20", "+") + ":ital,wght@" + ";".join(f"{i},{w}" for i, w in tuples)

    def css(batch):
        # Many families per request; each block names its family, so nothing is attributed wrongly.
        # A block that doesn't parse (a weight range, say) gets an empty URL, so its family is left to CSS2.
        status, text = get("fonts.googleapis.com", "/css2?" + "&".join(query(name) for name in batch))
        found = []
        for block in text.split("@font-face")[1:] if status == 200 else []:
            family = re.search(r"font-family:\s*'([^']+)'", block)
            weight = re.search(r"font-weight:\s*(\d+)\s*;", block)
            url = re.search(r"url\((https://[^)]+)\)", block)
            if family:
                italic = re.search(r"font-style:\s*italic", block) is not None
                style = (weight.group(1) if weight else "0") + ("i" if italic else "")
                found.append((family.group(1), style, url.group(1) if url and weight else ""))
        return found

    names = sorted(families)
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        rows = [row for found in pool.map(css, [names[i:i + 20] for i in range(0, len(names), 20)]) for row in found]
        # A family a batched answer left out (Google drops one it can't serve) is asked for alone.
        missing = sorted(set(names) - {row[0] for row in rows})
        rows += [row for found in pool.map(css, [[name] for name in missing]) for row in found]
    return rows, sorted(set(names) - {row[0] for row in rows})


def parse(rows):
    """(families, skipped, sources): family -> [version, {(italic, weight): id bytes}], the families
    left to CSS2 (unusual URLs), and each style's URL as Google gave it."""
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
        # The library re-encodes the bytes, so only an ID that round-trips exactly can be stored.
        if base64.urlsafe_b64encode(identifier).decode().rstrip("=") != match.group(3):
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
    return families, skipped, sources


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


def build(families):
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
    return header + b"".join(struct.pack("<I", len(header) + 4 * len(names) + o) for o in offsets) + records


def read(data):
    """family -> (version, {(italic, weight): url}), read as GoogleFontsCatalog.swift reads it."""
    if data[:5] != b"WFKC\x01":
        sys.exit("Not a format-1 catalogue.")
    catalogue, previous = {}, None
    for i in range(struct.unpack_from("<H", data, 6)[0]):
        at = struct.unpack_from("<I", data, 12 + 4 * i)[0]
        key = data[at + 1:at + 1 + data[at]]
        # The library binary-searches the index, so it must be in byte order.
        if previous is not None and not previous < key:
            sys.exit(f"The index is out of order at {key.decode()}.")
        previous, name = key, key.decode()
        at += 1 + data[at]
        version, groups = struct.unpack_from("<H", data, at)[0], data[at + 2]
        at += 3
        styles = {}
        for _ in range(groups):
            flags, mask = data[at], struct.unpack_from("<H", data, at + 1)[0]
            at += 3
            italic, weights = bool(flags & 1), [n * 100 for n in range(1, 16) if mask >> n & 1]
            if flags & 2:
                base, offset, length = data[at], data[at + 1], data[at + 2]
                identifier = data[at + 3:at + 3 + length]
                at += 3 + length
                for weight in weights:
                    computed = bytearray(identifier)
                    diff = bytes(x ^ y for x, y in zip(struct.pack("<f", base * 100.0), struct.pack("<f", float(weight))))
                    for k in range(4):
                        computed[offset + k] ^= diff[k]
                    styles[(italic, weight)] = url_for(name, version, bytes(computed))
            else:
                for weight in weights:
                    styles[(italic, weight)] = url_for(name, version, data[at + 1:at + 1 + data[at]])
                    at += 1 + data[at]
        catalogue[name] = (version, styles)
    return catalogue


def verify(data, families, sources):
    """Every entry, read back, must give exactly Google's URL. Returns the file count."""
    catalogue = read(data)
    count = 0
    for name, (_, styles) in catalogue.items():
        for (italic, weight), url in styles.items():
            if url != sources.get((name, italic, weight)):
                sys.exit(f"Round trip failed for {name} {weight}{'i' if italic else ''}: the writer and reader disagree.")
            count += 1
    if catalogue.keys() != families.keys() or count != sum(len(f[1]) for f in families.values()):
        sys.exit("Round trip failed: the catalogue doesn't hold every family and style it was built from.")
    return count


def write(path, data):
    # Beside the target, then renamed: an interrupted run never leaves a half-written file.
    with open(path + ".partial", "wb") as file:
        file.write(data)
    os.replace(path + ".partial", path)


def catalogue(rows):
    """(data, families, file count, skipped) for these rows, verified."""
    families, skipped, sources = parse(rows)
    data = build(families)
    return data, families, verify(data, families, sources), skipped


def command_build(arguments):
    rows, unanswered = (json.load(open(arguments.rows)), []) if arguments.rows else fetch_rows()
    data, families, count, skipped = catalogue(rows)
    out = arguments.out or BUNDLED
    write(out, data)
    print(f"{out}: {len(families)} families, {count} files, {len(data) / 1024:.0f} KB")
    for label, names in (("unusual URLs", skipped), ("no answer", unanswered)):
        if names:
            print(f"Left to CSS2, {label}: {', '.join(sorted(names))}", file=sys.stderr)


def command_reckon(arguments):
    """Fails when the committed catalogue stops working or Google's answers change shape;
    otherwise rewrites it when its content changed, with a summary of what did."""
    with open(BUNDLED, "rb") as file:
        committed = file.read()
    old = read(committed)
    problems, lines = [], []

    # The design relies on Google serving old versions; check a sample of the committed files.
    sample = random.sample(sorted(url for _, styles in old.values() for url in styles.values()), 50)
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        statuses = list(pool.map(lambda url: get("fonts.gstatic.com", urllib.parse.urlsplit(url).path, "HEAD")[0], sample))
    dead = [url for url, status in zip(sample, statuses) if status != 200]
    if dead:
        problems.append(f"{len(dead)} of {len(sample)} committed file URLs no longer answer 200, e.g. {dead[0]}")

    rows, unanswered = fetch_rows()
    data, _, count, skipped = catalogue(rows)
    new = read(data)
    if len(skipped) + len(unanswered) > 10:
        problems.append(f"{len(skipped) + len(unanswered)} families left to CSS2 (usually none): Google's answers may have changed shape")

    added, removed = sorted(new.keys() - old.keys()), sorted(old.keys() - new.keys())
    common = sorted(old.keys() & new.keys())
    bumped = [n for n in common if old[n][0] != new[n][0]]
    restyled = [n for n in common if old[n][1].keys() != new[n][1].keys()]
    # File IDs have been stable across versions; one changing within a version breaks that assumption.
    unstable = [n for n in common if old[n][0] == new[n][0]
                and any(old[n][1][s] != new[n][1][s] for s in old[n][1].keys() & new[n][1].keys())]
    if unstable:
        problems.append(f"file IDs changed without a version bump: {', '.join(unstable[:10])}")

    lines.append(f"Catalogue: {len(new)} families, {count} files, {len(data) / 1024:.0f} KB; {len(sample) - len(dead)} of {len(sample)} committed URLs alive.")
    for label, names in (("Added", added), ("Removed", removed), ("New versions", bumped), ("Styles changed", restyled),
                         ("Left to CSS2", sorted(skipped | set(unanswered)))):
        if names:
            lines.append(f"- **{label} ({len(names)}):** {', '.join(names[:30])}{' …' if len(names) > 30 else ''}")
    lines += [f"- **Problem:** {problem}" for problem in problems]

    # The header's build day changes every run; only a content change is worth a refresh.
    changed = committed[:8] + committed[12:] != data[:8] + data[12:]
    if changed and not problems:
        write(BUNDLED, data)
    lines.append("Refreshed the catalogue." if changed and not problems else "No refresh." if not changed else "Not refreshed: fix the problems first.")
    summary = "\n".join(lines) + "\n"
    print(summary, end="")
    for path in (arguments.summary, os.environ.get("GITHUB_STEP_SUMMARY")):
        if path:
            with open(path, "a") as file:
                file.write(summary)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write(f"changed={'true' if changed and not problems else 'false'}\n")
    if problems:
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(prog="catalog.py")
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="write the catalogue (offline from saved rows with --rows)")
    build_parser.add_argument("--rows", help="rows.json from an earlier run, instead of fetching from Google")
    build_parser.add_argument("out", nargs="?", help="where to write (default: the bundled file)")
    reckon_parser = commands.add_parser("reckon", help="compare a fresh build with the committed catalogue")
    reckon_parser.add_argument("--summary", help="also append the Markdown summary to this file")
    arguments = parser.parse_args()
    if arguments.command == "build" and bool(arguments.rows) != bool(arguments.out):
        build_parser.error("--rows and OUT go together")
    {"build": command_build, "reckon": command_reckon}[arguments.command](arguments)


if __name__ == "__main__":
    main()
