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
with open(os.path.join(ROOT, "Sources/WebFontKit/Network/LibraryVersion.swift")) as source:
    VERSION = re.search(r'libraryVersion = "([^"]+)"', source.read()).group(1)
USER_AGENT = f"WebFontKit/{VERSION}"
_local = threading.local()
REFRESH_AFTER_DAYS = 90


def slug(family):
    # As GoogleFontsCatalog.swift spells Google's folder.
    return family.lower().replace(" ", "")


def url_for(folder, version, identifier):
    encoded = base64.urlsafe_b64encode(identifier).decode().rstrip("=")
    return f"https://fonts.gstatic.com/s/{folder}/v{version}/{encoded}.ttf"


def get(host, path, method="GET"):
    """(status, body) over a kept-alive connection per thread; 429s, 5xx and drops retry with backoff."""
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
    """(rows, unanswered): (family, style like "700i", url) for every family, and those with no answer."""
    status, listing = get("fonts.google.com", "/metadata/fonts")
    if status != 200:
        sys.exit("Could not fetch Google's font list.")
    families = {f["family"]: list(f["fonts"]) for f in json.loads(listing.removeprefix(")]}'"))["familyMetadataList"]}

    def query(name):
        tuples = sorted({(1 if s.endswith("i") else 0, int(s.rstrip("i"))) for s in families[name]})
        return "family=" + urllib.parse.quote(name).replace("%20", "+") + ":ital,wght@" + ";".join(f"{i},{w}" for i, w in tuples)

    def css(batch):
        # Each block names its family, so batches are safe; one that doesn't parse leaves its family to CSS2.
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
    """(family -> [version, {(italic, weight): ID}], families left to CSS2, each style's URL from Google)."""
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
        folder = slug(name)
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
                    styles[(italic, weight)] = url_for(folder, version, bytes(computed))
            else:
                for weight in weights:
                    styles[(italic, weight)] = url_for(folder, version, data[at + 1:at + 1 + data[at]])
                    at += 1 + data[at]
        catalogue[name] = (version, styles)
    return catalogue


def verify(data, families, sources):
    """Every entry, read back, must give exactly Google's URL. Returns (file count, what was read)."""
    catalogue = read(data)
    count = 0
    for name, (_, styles) in catalogue.items():
        for (italic, weight), url in styles.items():
            if url != sources.get((name, italic, weight)):
                sys.exit(f"Round trip failed for {name} {weight}{'i' if italic else ''}: the writer and reader disagree.")
            count += 1
    if catalogue.keys() != families.keys() or count != sum(len(f[1]) for f in families.values()):
        sys.exit("Round trip failed: the catalogue doesn't hold every family and style it was built from.")
    return count, catalogue


def write(path, data):
    # Beside the target, then renamed: an interrupted run never leaves a half-written file.
    with open(path + ".partial", "wb") as file:
        file.write(data)
    os.replace(path + ".partial", path)


def committed():
    """(bytes, contents) of the bundled catalogue; empty when it is missing or unreadable."""
    try:
        with open(BUNDLED, "rb") as file:
            data = file.read()
        return data, read(data)
    except FileNotFoundError:
        return b"", {}
    except (SystemExit, struct.error, IndexError, UnicodeDecodeError):
        print("The committed catalogue is unreadable; building a new one from scratch.", file=sys.stderr)
        return b"", {}


def keep_unanswered(rows, unanswered, old):
    """Families listed but unanswered keep their committed entries. Returns (kept, still unanswered)."""
    kept = [name for name in unanswered if name in old]
    rows += [(name, f"{weight}{'i' if italic else ''}", url) for name in kept for (italic, weight), url in old[name][1].items()]
    return kept, [name for name in unanswered if name not in old]


def catalogue(rows):
    """(data, file count, skipped, contents) for these rows, verified."""
    families, skipped, sources = parse(rows)
    data = build(families)
    count, contents = verify(data, families, sources)
    return data, count, skipped, contents


def command_build(arguments):
    old = {} if arguments.rows else committed()[1]
    if arguments.rows:
        with open(arguments.rows) as file:
            rows, kept, unanswered = json.load(file), [], []
    else:
        rows, unanswered = fetch_rows()
        kept, unanswered = keep_unanswered(rows, unanswered, old)
    data, count, skipped, contents = catalogue(rows)
    if len(old.keys() - contents.keys()) > max(20, len(old) // 20):
        sys.exit(f"{len(old.keys() - contents.keys())} committed families are missing: Google's font list may be incomplete. Nothing written.")
    out = arguments.out or BUNDLED
    write(out, data)
    print(f"{out}: {len(contents)} families, {count} files, {len(data) / 1024:.0f} KB")
    if kept:
        print(f"No answer, kept as committed: {', '.join(kept)}", file=sys.stderr)
    for label, names in (("unusual URLs", skipped), ("no answer", unanswered)):
        if names:
            print(f"Left to CSS2, {label}: {', '.join(sorted(names))}", file=sys.stderr)


def command_reckon(arguments):
    """Fails on dead committed URLs or a changed answer shape; otherwise refreshes changed or old files."""
    old_data, old = committed()
    pairs = [(name, url) for name, (_, styles) in old.items() for url in styles.values()]
    sample = random.sample(pairs, min(50, len(pairs)))
    # The catalogue relies on Google serving old versions; sampled while the fresh build is fetched.
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        statuses = pool.map(lambda pair: get("fonts.gstatic.com", urllib.parse.urlsplit(pair[1]).path, "HEAD")[0], sample)
        rows, unanswered = fetch_rows()
        statuses = list(statuses)
    kept, unanswered = keep_unanswered(rows, unanswered, old)
    data, count, skipped, new = catalogue(rows)

    problems, lines = [], []
    # A retired family's files are expected to go; it is reported as removed instead.
    checked = [(url, status) for (name, url), status in zip(sample, statuses) if name in new]
    dead = [url for url, status in checked if status != 200]
    if dead:
        problems.append(f"{len(dead)} of {len(checked)} committed file URLs no longer answer 200, e.g. {dead[0]}")
    # Kept families ride out an outage, so only the rest count here.
    if len(skipped) + len(unanswered) > 10:
        problems.append(f"{len(skipped) + len(unanswered)} families unanswered or unusual (usually none): Google's answers may have changed shape")

    added, removed = sorted(new.keys() - old.keys()), sorted(old.keys() - new.keys())
    # Google retires a family now and then; losing many at once means a truncated font list.
    if len(removed) > max(20, len(old) // 20):
        problems.append(f"{len(removed)} families would be removed: Google's font list may be incomplete")
    common = sorted(old.keys() & new.keys())
    bumped = [n for n in common if old[n][0] != new[n][0]]
    restyled = [n for n in common if old[n][1].keys() != new[n][1].keys()]
    # File IDs have been stable across versions; one changing within a version breaks that assumption.
    unstable = [n for n in common if old[n][0] == new[n][0]
                and any(old[n][1][s] != new[n][1][s] for s in old[n][1].keys() & new[n][1].keys())]
    if unstable:
        problems.append(f"file IDs changed without a version bump: {', '.join(unstable[:10])}")

    lines.append(f"Catalogue: {len(new)} families, {count} files, {len(data) / 1024:.0f} KB; {len(checked) - len(dead)} of {len(checked)} committed URLs alive.")
    for label, names in (("Added", added), ("Removed", removed), ("New versions", bumped), ("Styles changed", restyled),
                         ("No answer, kept as committed", kept), ("Left to CSS2", sorted(skipped | set(unanswered)))):
        if names:
            lines.append(f"- **{label} ({len(names)}):** {', '.join(names[:30])}{' …' if len(names) > 30 else ''}")
    lines += [f"- **Problem:** {problem}" for problem in problems]

    # The library trusts a catalogue for a year from its build day, so rebuild an unchanged one early.
    age = (datetime.datetime.now(datetime.timezone.utc).date() - datetime.date(1970, 1, 1)).days - struct.unpack_from("<I", old_data, 8)[0] if old_data else 0
    changed = old != new or age > REFRESH_AFTER_DAYS
    refresh = changed and not problems
    if refresh:
        write(BUNDLED, data)
        lines.append("Refreshed the catalogue." if old != new else f"Refreshed the catalogue's build day: it was {age} days old.")
    else:
        lines.append("Not refreshed: fix the problems first." if problems else "No refresh.")
    summary = "\n".join(lines) + "\n"
    print(summary, end="")
    for path in (arguments.summary, os.environ.get("GITHUB_STEP_SUMMARY")):
        if path:
            with open(path, "a") as file:
                file.write(summary)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write(f"changed={'true' if refresh else 'false'}\n")
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
