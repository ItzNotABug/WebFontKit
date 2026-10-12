#!/usr/bin/env python3
"""The bundled Google Fonts catalogue: build it from Google, read it back, and reckon a fresh
build against the committed one. Run through scripts/catalog.sh and scripts/reckon.sh.

Keeps a hash of each family name, its version and enough to rebuild each file ID; the layout is
documented in GoogleFontsCatalog.swift. The family names live in Tests/Fixtures/catalog/shipped.tsv.
"""
import argparse, base64, binascii, collections, concurrent.futures, datetime, hashlib, heapq, http.client, json, os, random, re, struct, sys, threading, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLED = os.path.join(ROOT, "Sources/WebFontKit/Resources/GoogleFonts.catalog")
LISTING = os.path.join(ROOT, "Tests/Fixtures/catalog/shipped.tsv")
FORMAT, HASH_BITS, BLOCK = 2, 20, 16
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


# A file ID is Google's description of the file, XOR a mask picked by its first byte (the seed):
#   00 <length - 5> 00 <name length> <name> [10 02] [18 <weight>] [3a 0b 08 <axis tag> 15 <float32>]... 20 00
# with 10 02 for italic, 18 and a varint for a static weight other than 400, one 13-byte block per
# variable axis. The catalogue keeps each family's seed and the few fields that differ, plus one mask
# row per seed; the reader rebuilds the description and XORs. An ID that doesn't fit is kept whole.
WGHT = bytes([0xF4, 0xD0, 0x9D, 0xBB, 0x07])     # the axis tag "wght" as Google's varint
WHOLE = 15                                        # axis count that marks an ID kept whole
CODES = ("layout", "version", "weights", "axis weights", "base", "axes", "variable axes", "tag", "value")
HEADER_SIZE = 56


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append(value & 0x7F | 0x80)
        value >>= 7
    return bytes(out + bytes([value]))


def head(name, italic, computed, weight):
    """The description up to the axes; byte 1 (the length) is set once the length is known."""
    text = bytearray([0, 0, 0, len(name)]) + name
    if italic:
        text += b"\x10\x02"
    if not computed and weight != 400:
        text += b"\x18" + varint(weight)
    return text


def describe(name, italic, computed, weight, axes):
    """The description after the seed byte, for these axes (tag, value)."""
    text = head(name, italic, computed, weight)
    for tag, value in axes:
        text += b"\x3a\x0b\x08" + tag + b"\x15" + value
    text += b"\x20\x00"
    text[1] = (len(text) - 4) & 0xFF
    return bytes(text)


def shape(item):
    """Fills in the ID's axis count (None when its length doesn't fit the description) and where each axis block starts."""
    first = 1 + len(head(*item["key"]))
    rest = len(item["id"]) - first - 2
    item["count"] = rest // 13 if rest >= 0 and rest % 13 == 0 else None
    item["starts"] = [first + 13 * axis for axis in range(item["count"] or 0)]


def most(counter):
    # Most common, ties by value, so builds are reproducible.
    return max(sorted(counter), key=lambda value: counter[value])


def learn_masks(items):
    """(seed, position) -> mask byte, from every position whose plain byte is known, then guesses."""
    votes = collections.defaultdict(collections.Counter)
    for item in items:
        count = item["count"]
        if count is None:
            continue
        identifier = item["id"]
        text = describe(*item["key"], [(bytes(5), bytes(4))] * count)
        unknown = {start + offset for start in item["starts"] for offset in (*range(3, 8), *range(9, 13))}
        for position in range(1, len(identifier)):
            if position not in unknown:
                votes[(identifier[0], position)][identifier[position] ^ text[position - 1]] += 1
    mask = {key: most(counter) for key, counter in votes.items()}

    def plain(item, start, length):
        positions = range(start, start + length)
        if all((item["id"][0], position) in mask for position in positions):
            return bytes(item["id"][position] ^ mask[(item["id"][0], position)] for position in positions)

    # Axis tags: known ones teach the others (a partly known tag that fits one known tag only).
    while True:
        tags = collections.Counter(tag for item in items for start in item["starts"] if (tag := plain(item, start + 3, 5)))
        learned = 0
        for item in items:
            seed = item["id"][0]
            for start in item["starts"]:
                positions = range(start + 3, start + 8)
                known = [(index, item["id"][position] ^ mask[(seed, position)])
                         for index, position in enumerate(positions) if (seed, position) in mask]
                fits = [tag for tag in sorted(tags) if all(tag[index] == value for index, value in known)]
                if len(known) < 5 and len(fits) == 1:
                    for index, position in enumerate(positions):
                        learned += (seed, position) not in mask
                        mask.setdefault((seed, position), item["id"][position] ^ fits[0][index])
        if not learned:
            break
    common_tag = most(tags) if tags else WGHT
    values = collections.defaultdict(collections.Counter)
    for item in items:
        for start in item["starts"]:
            tag, value = plain(item, start + 3, 5), plain(item, start + 9, 4)
            if tag and value:
                values[tag][value] += 1
    # What's left: guess, so the first ID to use a position reads as the guess.
    for item in items:
        identifier, seed = item["id"], item["id"][0]
        for start in item["starts"]:
            for index, position in enumerate(range(start + 3, start + 8)):
                mask.setdefault((seed, position), identifier[position] ^ common_tag[index])
            tag = plain(item, start + 3, 5)
            if tag == WGHT:
                guess = struct.pack("<f", float(item["key"][3]))
            else:
                guess = most(values[tag]) if values[tag] else bytes(4)
            for index, position in enumerate(range(start + 9, start + 13)):
                mask.setdefault((seed, position), identifier[position] ^ guess[index])
        for position in range(1, len(identifier)):
            mask.setdefault((seed, position), identifier[position])
    return mask


def huffman(counts, limit=8):
    """Code lengths for the symbols that occur, none longer than limit."""
    counts = dict(counts)
    while True:
        if len(counts) == 1:
            return {next(iter(counts)): 1}
        heap = [(count, order, (symbol,)) for order, (symbol, count) in enumerate(sorted(counts.items()))]
        heapq.heapify(heap)
        depth, next_order = collections.Counter(), len(heap)
        while len(heap) > 1:
            first_count, _, first_symbols = heapq.heappop(heap)
            second_count, _, second_symbols = heapq.heappop(heap)
            for symbol in first_symbols + second_symbols:
                depth[symbol] += 1
            heapq.heappush(heap, (first_count + second_count, next_order, first_symbols + second_symbols))
            next_order += 1
        if max(depth.values()) <= limit:
            return dict(depth)
        # Too deep for the reader: even the counts out a little and try again.
        counts = {symbol: count + max(1, sum(counts.values()) // 64) for symbol, count in counts.items()}


def canonical(lengths):
    """symbol -> (code, length), and the table the file stores: counts per length 1-8, then symbols in code order."""
    order = sorted((length, symbol) for symbol, length in lengths.items())
    codes, code, previous = {}, 0, order[0][0]
    for length, symbol in order:
        code <<= length - previous
        codes[symbol] = (code, length)
        code, previous = code + 1, length
    counts = bytes(sum(1 for each, _ in order if each == length) for length in range(1, 9))
    return codes, counts + bytes(symbol for _, symbol in order)


class Bits:
    """MSB-first bits."""

    def __init__(self):
        self.value, self.count = 0, 0

    def put(self, value, width):
        self.value = self.value << width | value & ((1 << width) - 1)
        self.count += width

    def bytes(self):
        pad = -self.count % 8
        return (self.value << pad).to_bytes((self.count + pad) // 8, "big")


def fnv(name, seed, bits):
    """FNV-1a of the UTF-8 name, from a seeded basis, cut to its top bits."""
    value = 0x811C9DC5 ^ seed
    for byte in name:
        value = (value ^ byte) * 0x01000193 & 0xFFFFFFFF
    return value >> (32 - bits)


def build(families):
    names = sorted(families, key=lambda family: family.encode())
    entries, items = {}, []
    for name in names:
        version, styles = families[name]
        groups = []
        for italic in sorted({style_italic for style_italic, _ in styles}):
            group = sorted((weight, identifier) for (style_italic, weight), identifier in styles.items() if style_italic == italic)
            weights = sum(1 << (weight // 100) for weight, _ in group)
            offset = weight_offset(group)
            if offset is not None:
                groups.append({"flags": int(italic) | 2, "weights": weights, "base": group[0][0], "offset": offset, "ids": [group[0]]})
            else:
                groups.append({"flags": int(italic), "weights": weights, "base": None, "offset": None, "ids": group})
        entries[name] = (version, groups)
        for group in groups:
            for weight, identifier in group["ids"]:
                items.append({"name": name, "id": identifier,
                              "key": (name.encode(), bool(group["flags"] & 1), bool(group["flags"] & 2), group["base"] or weight)})
    if any(not item["id"] or len(item["id"]) > 256 for item in items) or any(len(name.encode()) > 255 for name in names):
        sys.exit("A file ID or family name too long for format 2.")
    for item in items:
        shape(item)
    mask = learn_masks(items)

    # Each ID as fields: its axes (tag, value), or None when it is kept whole.
    for item in items:
        identifier, count = item["id"], item["count"]
        seed = identifier[0]
        plain = bytes([seed]) + bytes(identifier[position] ^ mask[(seed, position)] for position in range(1, len(identifier)))
        axes = None
        if count is not None:
            axes = [(plain[start + 3:start + 8], plain[start + 9:start + 13]) for start in item["starts"]]
            if count >= WHOLE or describe(*item["key"], axes) != plain[1:]:
                axes = None
        item["axes"], item["plain"] = axes, plain

    tag_counts = collections.Counter(tag for item in items for tag, _ in item["axes"] or [])
    tags = sorted((tag for tag, count in tag_counts.items() if count > 1), key=lambda tag: (-tag_counts[tag], tag))
    value_counts = collections.defaultdict(collections.Counter)
    for item in items:
        for tag, value in item["axes"] or []:
            value_counts[tag][value] += 1
    usual = {tag: bytes(4) if tag == WGHT else most(value_counts[tag]) for tag in tags}
    others = {tag: sorted((value for value, count in value_counts[tag].items() if count > 1 and value != usual[tag]),
                          key=lambda value: (-value_counts[tag][value], value))[:15]
              for tag in tags}

    def expected_value(tag, item):
        return struct.pack("<f", float(item["key"][3])) if tag == WGHT else usual.get(tag, bytes(4))

    layouts = sorted({tuple(group["flags"] for group in groups) for _, groups in entries.values()})
    palette = sorted({group["weights"] for _, groups in entries.values() for group in groups})
    versions = sorted({version for version, _ in entries.values()})
    if versions[-1] > 255 or len(palette) > 255 or len(tags) > 255:
        sys.exit("A version above 255, or too many weight sets or axis tags, for format 2.")
    hash_seed = next((seed for seed in range(1 << 16) if len({fnv(name.encode(), seed, HASH_BITS) for name in names}) == len(names)), None)
    if hash_seed is None:
        sys.exit(f"No seed gives {len(names)} names distinct {HASH_BITS}-bit hashes.")
    order = sorted(names, key=lambda name: fnv(name.encode(), hash_seed, HASH_BITS))
    hashes = [fnv(name.encode(), hash_seed, HASH_BITS) for name in order]
    items_of = collections.defaultdict(list)
    for item in items:
        items_of[item["name"]].append(item)
    seed_of = {name: items_of[name][0]["id"][0] for name in names}
    if any(item["id"][0] != seed_of[item["name"]] for item in items):
        sys.exit("A family whose files don't share a seed.")

    def weight_position(item):
        """Where the wght value sits in a rebuilt ID, as the reader finds it."""
        found = None
        for (tag, _), start in zip(item["axes"] or [], item["starts"]):
            if tag in tags and tag == WGHT:
                found = start + 9
        return found

    def record(name):
        """The family's record, in reading order: ("bits", value, width) or (code name, symbol)."""
        version, groups = entries[name]
        out = [("bits", seed_of[name], 8), ("layout", layouts.index(tuple(group["flags"] for group in groups))),
               ("version", versions.index(version))]
        stored = iter(items_of[name])
        for number, group in enumerate(groups):
            computed = bool(group["flags"] & 2)
            same_weights = group["weights"] == groups[0]["weights"]
            if number == 1:
                out.append(("bits", int(same_weights), 1))
            if number == 0 or not same_weights:
                out.append(("axis weights" if computed else "weights", palette.index(group["weights"])))
            if computed:
                out.append(("base", group["base"] // 100))
            for _ in group["ids"]:
                item = next(stored)
                code = "variable axes" if computed else "axes"
                if item["axes"] is None:
                    # Kept whole, as runs of zero bytes and literal bytes against the mask.
                    residual = item["plain"][1:]
                    out += [(code, WHOLE), ("bits", len(residual), 8)]
                    position = 0
                    while position < len(residual):
                        zeros = 0
                        while position < len(residual) and residual[position] == 0 and zeros < 255:
                            zeros, position = zeros + 1, position + 1
                        literals = []
                        while position < len(residual) and residual[position] != 0 and len(literals) < 255:
                            literals.append(residual[position])
                            position += 1
                        out += [("bits", zeros, 8), ("bits", len(literals), 8)] + [("bits", byte, 8) for byte in literals]
                else:
                    out.append((code, len(item["axes"])))
                    for tag, value in item["axes"]:
                        out.append(("tag", tags.index(tag) if tag in tags else len(tags)))
                        if tag not in tags:
                            out += [("bits", byte, 8) for byte in tag]
                        if tag in tags and value == expected_value(tag, item):
                            out.append(("value", 0))
                        elif tag in tags and value in others[tag]:
                            out.append(("value", 1 + others[tag].index(value)))
                        else:
                            out += [("value", 16)] + [("bits", byte, 8) for byte in value]
                if computed:
                    if group["offset"] > 255:
                        sys.exit(f"{name}: a weight offset past byte 255.")
                    derived = weight_position(item)
                    out.append(("bits", int(derived == group["offset"]), 1))
                    if derived != group["offset"]:
                        out.append(("bits", group["offset"], 8))
        return out

    records = {name: record(name) for name in order}
    counts = collections.defaultdict(collections.Counter)
    for entries_of_record in records.values():
        for entry in entries_of_record:
            if entry[0] != "bits":
                counts[entry[0]][entry[1]] += 1
    symbol_limits = {"layout": len(layouts), "version": len(versions), "weights": len(palette), "axis weights": len(palette),
                     "base": 16, "axes": 16, "variable axes": 16, "tag": len(tags) + 1, "value": 17}
    codes, tables = {}, []
    for code in CODES:
        codes[code], table = canonical(huffman(counts[code] or {0: 1}))
        if any(symbol >= symbol_limits[code] for symbol in codes[code]):
            sys.exit(f"A {code} symbol out of range.")
        tables.append(table)

    gaps = [later - earlier for index, (earlier, later) in enumerate(zip(hashes, hashes[1:])) if (index + 1) % BLOCK]
    rice = min(range(1, 20), key=lambda width: sum((gap >> width) + 1 + width for gap in gaps))
    stream, index = Bits(), bytearray()
    for first in range(0, len(order), BLOCK):
        if stream.count >= 1 << 24:
            sys.exit("The record stream outgrew format 2.")
        index += hashes[first].to_bytes(3, "little") + stream.count.to_bytes(3, "little")
        for position in range(first + 1, min(first + BLOCK, len(order))):
            gap = hashes[position] - hashes[position - 1]
            stream.put((1 << (gap >> rice)) - 1, gap >> rice)
            stream.put(0, 1)
            stream.put(gap, rice)
        for name in order[first:first + BLOCK]:
            for entry in records[name]:
                if entry[0] == "bits":
                    stream.put(entry[1], entry[2])
                else:
                    stream.put(*codes[entry[0]][entry[1]])

    row_lengths = collections.Counter()
    for seed, position in mask:
        row_lengths[seed] = max(row_lengths[seed], position)
    row_offsets, rows = bytearray(), bytearray()
    for seed in range(256):
        row_offsets += struct.pack("<H", len(rows))
        rows += bytes(mask.get((seed, position), 0) for position in range(1, row_lengths[seed] + 1))
    row_offsets += struct.pack("<H", len(rows))
    if sum(len(values) for values in others.values()) > 255:
        sys.exit("Too many named axis values for format 2.")
    tag_table, value_table = bytearray([len(tags)]), bytearray()
    for tag in tags:
        tag_table += tag + bytes([int(tag == WGHT) | len(others[tag]) << 4]) + usual[tag] + bytes([len(value_table) // 4])
        value_table += b"".join(others[tag])
    table_offsets, table_bytes = bytearray(), bytearray()
    for table in tables:
        table_offsets += struct.pack("<H", len(table_bytes))
        table_bytes += table
    shapes = bytes((len(shape) - 1) << 4 | shape[0] << 2 | (shape[1] if len(shape) > 1 else 0) for shape in layouts)
    sections = [
        bytes([len(layouts)]) + shapes,
        bytes([len(palette)]) + b"".join(struct.pack("<H", weights) for weights in palette),
        bytes([len(versions)]) + bytes(versions),
        bytes(tag_table), bytes(value_table), bytes(table_offsets + table_bytes),
        bytes(row_offsets), bytes(rows), bytes(index), stream.bytes(),
    ]
    offsets, at = [], HEADER_SIZE
    for section in sections:
        offsets.append(at)
        at += len(section)
    if at > 0xFFFFFFFF or len(rows) > 0xFFFF:
        sys.exit("The catalogue outgrew format 2.")
    day = (datetime.datetime.now(datetime.timezone.utc).date() - datetime.date(1970, 1, 1)).days
    header = b"WFKC" + bytes([FORMAT, HASH_BITS, BLOCK, rice]) + struct.pack("<IHH", day, hash_seed, len(names))
    return header + struct.pack("<10I", *offsets) + b"".join(sections)


class Reader:
    """MSB-first bits; past the end reads zeros, as the Swift reader does."""

    def __init__(self, data, bit):
        self.data, self.bit = data, bit

    def get(self, width):
        # Up to 32 bits, from the 40 starting at this byte.
        start = self.bit >> 3
        window = int.from_bytes(self.data[start:start + 5].ljust(5, b"\0"), "big")
        value = window >> (40 - (self.bit & 7) - width) & ((1 << width) - 1)
        self.bit += width
        return value


class Catalogue:
    """A format-2 file, read as GoogleFontsCatalog.swift reads it."""

    def __init__(self, data):
        if data[:5] != b"WFKC" + bytes([FORMAT]) or len(data) < HEADER_SIZE:
            sys.exit("Not a format-2 catalogue.")
        self.data = data
        self.hash_bits, self.block, self.rice = data[5], data[6], data[7]
        self.hash_seed, self.count = struct.unpack_from("<HH", data, 12)
        (self.layouts, self.palette, self.versions, self.tags, self.values,
         self.codes, self.rows, self.masks, self.index, self.stream) = struct.unpack_from("<10I", data, 16)
        tag_count = data[self.tags]
        self.tag_entries = [data[self.tags + 1 + 11 * tag:self.tags + 12 + 11 * tag] for tag in range(tag_count)]
        self.block_hashes = [int.from_bytes(data[at:at + 3], "little") for at in range(self.index, self.stream, 6)]
        self.block_bits = [int.from_bytes(data[at + 3:at + 6], "little") for at in range(self.index, self.stream, 6)]

    def symbol(self, code, reader):
        """A canonical Huffman symbol, from the code's counts per length and symbols in code order."""
        start = self.codes + 2 * len(CODES) + struct.unpack_from("<H", self.data, self.codes + 2 * CODES.index(code))[0]
        counts, symbols = self.data[start:start + 8], self.data[start + 8:]
        value = first = index = 0
        for length in range(1, 9):
            value |= reader.get(1)
            if value - first < counts[length - 1]:
                return symbols[index + value - first]
            index += counts[length - 1]
            first = (first + counts[length - 1]) << 1
            value <<= 1
        sys.exit("A bad code in the catalogue.")

    def read(self, names):
        """name -> (version, {(italic, weight): file ID}) for the names it holds, in one pass over the records."""
        by_hash = {fnv(name.encode(), self.hash_seed, self.hash_bits): name for name in names}
        found = {}
        for block, (first_hash, bit) in enumerate(zip(self.block_hashes, self.block_bits)):
            reader = Reader(self.data, 8 * self.stream + bit)
            hashes = [first_hash]
            for _ in range(min(self.block, self.count - block * self.block) - 1):
                ones = 0
                while reader.get(1):
                    ones += 1
                hashes.append(hashes[-1] + (ones << self.rice | reader.get(self.rice)))
            for family_hash in hashes:
                name = by_hash.get(family_hash)
                entry = self.family(reader, name.encode() if name else None)
                if name:
                    found[name] = entry
        return found

    def family(self, reader, name):
        seed = reader.get(8)
        shape = self.data[self.layouts + 1 + self.symbol("layout", reader)]
        version = self.data[self.versions + 1 + self.symbol("version", reader)]
        files, first_weights = {}, None
        for number in range((shape >> 4) + 1):
            flags = shape >> 2 & 3 if number == 0 else shape & 3
            italic, computed = bool(flags & 1), bool(flags & 2)
            if number == 1 and reader.get(1):
                weights = first_weights
            else:
                choice = self.symbol("axis weights" if computed else "weights", reader)
                weights = struct.unpack_from("<H", self.data, self.palette + 1 + 2 * choice)[0]
            if number == 0:
                first_weights = weights
            base = self.symbol("base", reader) * 100 if computed else None
            present = [step * 100 for step in range(1, 16) if weights >> step & 1]
            for weight in [base] if computed else present:
                plain, offset = self.file_id(reader, seed, name or b"", italic, computed, weight)
                if computed and not reader.get(1):
                    offset = reader.get(8)
                if name is None:
                    continue
                row = self.masks + struct.unpack_from("<H", self.data, self.rows + 2 * seed)[0] - 1
                identifier = bytes([seed]) + bytes(plain[position] ^ self.data[row + position] for position in range(1, len(plain)))
                if not computed:
                    files[(italic, weight)] = identifier
                    continue
                # Any other weight differs only in the little-endian Float32 of the weight.
                for other in present:
                    other_id = bytearray(identifier)
                    diff = bytes(a ^ b for a, b in zip(struct.pack("<f", float(base)), struct.pack("<f", float(other))))
                    for position in range(4):
                        other_id[offset + position] ^= diff[position]
                    files[(italic, other)] = bytes(other_id)
        return version, files

    def file_id(self, reader, seed, name, italic, computed, weight):
        """(the ID before masking, where its weight float sits) from the record's bits."""
        axes_count = self.symbol("variable axes" if computed else "axes", reader)
        if axes_count == WHOLE:
            length, text = reader.get(8), bytearray()
            while len(text) < length:
                zeros, literals = reader.get(8), reader.get(8)
                if not zeros + literals:
                    sys.exit("A bad record in the catalogue.")
                text += bytes(zeros) + bytes(reader.get(8) for _ in range(literals))
            return bytes([seed]) + bytes(text), None
        axes, offset = [], None
        for _ in range(axes_count):
            tag_index = self.symbol("tag", reader)
            entry = self.tag_entries[tag_index] if tag_index < len(self.tag_entries) else None
            tag = entry[:5] if entry else bytes(reader.get(8) for _ in range(5))
            value_index = self.symbol("value", reader)
            from_weight = entry is not None and entry[5] & 1
            if value_index == 0:
                value = struct.pack("<f", float(weight)) if from_weight else entry[6:10] if entry else bytes(4)
            elif value_index == 16:
                value = bytes(reader.get(8) for _ in range(4))
            else:
                at = self.values + 4 * (entry[10] + value_index - 1)
                value = self.data[at:at + 4]
            if from_weight:
                offset = 1 + len(head(name, italic, computed, weight)) + 13 * len(axes) + 9
            axes.append((tag, value))
        return bytes([seed]) + describe(name, italic, computed, weight, axes), offset


def read(data, names):
    """family -> (version, {(italic, weight): url}) for the names it holds."""
    return {name: (version, {style: url_for(slug(name), version, identifier) for style, identifier in files.items()})
            for name, (version, files) in Catalogue(data).read(names).items()}


def listing(contents):
    """One line per family: name, version, styles, and a digest of its URLs (the Swift tests read it)."""
    lines = []
    for name in sorted(contents, key=lambda family: family.encode()):
        version, styles = contents[name]
        keys = sorted(styles)
        urls = "\n".join(styles[key] for key in keys)
        styles_text = ",".join(f"{weight}{'i' if italic else ''}" for italic, weight in keys)
        lines.append(f"{name}\t{version}\t{styles_text}\t{hashlib.sha256(urls.encode()).hexdigest()[:8]}")
    return "\n".join(lines) + "\n"


def listed_names():
    try:
        with open(LISTING) as file:
            return [line.split("\t")[0] for line in file if line.strip()]
    except FileNotFoundError:
        return []


def verify(data, families, sources):
    """Every entry, read back, must give exactly Google's URL. Returns (file count, what was read)."""
    catalogue = read(data, sorted(families))
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


def write_bundled(data, contents):
    write(BUNDLED, data)
    write(LISTING, listing(contents).encode())


def committed(names=()):
    """(bytes, contents) of the bundled catalogue; empty when it is missing or unreadable.

    The file holds no names: the listing beside the tests names its families, else Google's list does."""
    try:
        with open(BUNDLED, "rb") as file:
            data = file.read()
        return data, read(data, listed_names() or names)
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
    old = {}
    if arguments.rows:
        with open(arguments.rows) as file:
            rows, kept, unanswered = json.load(file), [], []
    else:
        rows, unanswered = fetch_rows()
        old = committed(sorted({row[0] for row in rows} | set(unanswered)))[1]
        kept, unanswered = keep_unanswered(rows, unanswered, old)
    data, count, skipped, contents = catalogue(rows)
    if len(old.keys() - contents.keys()) > max(20, len(old) // 20):
        sys.exit(f"{len(old.keys() - contents.keys())} committed families are missing: Google's font list may be incomplete. Nothing written.")
    out = arguments.out or BUNDLED
    if out == BUNDLED:
        write_bundled(data, contents)
    else:
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
    if not old and old_data:
        # No listing yet: name the committed families from Google's list instead.
        old_data, old = committed(sorted({row[0] for row in rows} | set(unanswered)))
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
        write_bundled(data, new)
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
