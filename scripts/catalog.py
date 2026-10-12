#!/usr/bin/env python3
"""The bundled Google Fonts catalogue: build it from Google, read it back, and reckon a fresh
build against the committed one. Run through scripts/catalog.sh and scripts/reckon.sh.

Keeps a hash of each family name, its version and enough to rebuild each file ID; the layout is
documented in scripts/catalog-format.md. The family names live in Tests/Fixtures/catalog/shipped.tsv.
"""
import argparse, base64, binascii, collections, concurrent.futures, dataclasses, hashlib, heapq, http.client, json, os
import random, re, struct, sys, threading, time, urllib.parse
from typing import NamedTuple

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
    # Google's folder for a family (see catalog-format.md).
    return family.lower().replace(" ", "")


def url_for(folder, version, identifier):
    encoded = base64.urlsafe_b64encode(identifier).decode().rstrip("=")
    return f"https://fonts.gstatic.com/s/{folder}/v{version}/{encoded}.ttf"


def get(host, path, method="GET"):
    """(status, body), retrying 429s, 5xx and dropped connections with backoff."""
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
    metadata = json.loads(listing.removeprefix(")]}'"))["familyMetadataList"]
    families = {family["family"]: list(family["fonts"]) for family in metadata}

    def query(name):
        tuples = sorted({(1 if style.endswith("i") else 0, int(style.rstrip("i"))) for style in families[name]})
        axes = ";".join(f"{italic},{weight}" for italic, weight in tuples)
        return "family=" + urllib.parse.quote(name).replace("%20", "+") + ":ital,wght@" + axes

    def css(batch):
        # Each block names its family, so batching is safe; an unparsable one leaves it to CSS2.
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
        batches = [names[start:start + 20] for start in range(0, len(names), 20)]
        rows = [row for found in pool.map(css, batches) for row in found]
        # Google drops a family it can't serve from a batch: ask for it alone.
        missing = sorted(set(names) - {row[0] for row in rows})
        rows += [row for found in pool.map(css, [[name] for name in missing]) for row in found]
    return rows, sorted(set(names) - {row[0] for row in rows})


def parse(rows):
    """(family -> [version, {(italic, weight): ID}], families left to CSS2, each style's URL from Google)."""
    families, skipped, sources = {}, set(), {}
    for name, style, url in rows:
        match = URL.match(url)
        weight = int(style.rstrip("i"))
        if weight > 900:
            continue    # FontStyle stops at 900: the library never asks for it
        if not match or match.group(1) != slug(name) or weight % 100 or weight < 100:
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
        # Format 2's limits: IDs up to 256 bytes, names up to 255, versions up to 255, one seed per family.
        seeds = {first[0] for first in entry[1].values()} | {identifier[0]}
        if len(identifier) > 256 or len(name.encode()) > 255 or entry[0] > 255 or len(seeds) > 1:
            skipped.add(name)
        entry[1][(style.endswith("i"), weight)] = identifier
    for name in skipped:
        families.pop(name, None)
    return families, skipped, sources


def xor(first, second):
    return bytes(left ^ right for left, right in zip(first, second))


def weight_offset(group):
    """Where the weight float sits if every ID differs from the first only there, else None."""
    (base_weight, base_id), rest = group[0], group[1:]
    if not rest:
        return None
    offset = None
    for weight, identifier in rest:
        if len(identifier) != len(base_id):
            return None
        float_diff = xor(struct.pack("<f", base_weight), struct.pack("<f", weight))
        id_diff = xor(base_id, identifier)
        hits = [at for at in range(len(base_id) - 3)
                if id_diff[at:at + 4] == float_diff and not any(id_diff[:at]) and not any(id_diff[at + 4:])]
        if not hits or (offset is not None and hits[0] != offset):
            return None
        offset = hits[0]
    return offset


WGHT = bytes([0xF4, 0xD0, 0x9D, 0xBB, 0x07])     # the axis tag "wght" as Google's varint
WHOLE = 15                                        # axis count that marks an ID kept whole
CODES = ("layout", "version", "weights", "axis weights", "base", "axes", "variable axes", "tag", "value")
HEADER_SIZE = 16 + 4 * 10                         # fixed fields, then ten section offsets


class Style(NamedTuple):
    name: bytes        # the family name, UTF-8
    italic: bool
    computed: bool     # a computed group's ID, whose weight is the group's base
    weight: int


@dataclasses.dataclass
class FileID:
    style: Style
    id: bytes
    starts: list | None          # where each axis block starts; None when the length doesn't fit
    axes: list | None = None     # (tag, value) per axis; None when the ID is kept whole
    plain: bytes = b""           # the ID unmasked


@dataclasses.dataclass
class Group:
    flags: int         # 1 italic, 2 computed
    weights: int       # bit n set for weight n * 100
    offset: int | None # a computed group's weight float offset
    ids: list


def today():
    return int(time.time()) // 86_400


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append(value & 0x7F | 0x80)
        value >>= 7
    return bytes(out + bytes([value]))


def head(style):
    """The description up to the axes; byte 1 (the length) is set once the length is known."""
    text = bytearray([0, 0, 0, len(style.name)]) + style.name
    if style.italic:
        text += b"\x10\x02"
    if not style.computed and style.weight != 400:
        text += b"\x18" + varint(style.weight)
    return text


def describe(style, axes):
    """The description after the seed byte, for these axes (tag, value)."""
    text = head(style)
    for tag, value in axes:
        text += b"\x3a\x0b\x08" + tag + b"\x15" + value
    text += b"\x20\x00"
    text[1] = (len(text) - 4) & 0xFF
    return bytes(text)


def axis_starts(style, identifier):
    """Where each axis block starts in the ID, or None when the length doesn't fit."""
    first = 1 + len(head(style))
    rest = len(identifier) - first - 2
    if rest < 0 or rest % 13:
        return None
    return [first + 13 * axis for axis in range(rest // 13)]


def most(counter):
    # Most common, ties by value, so builds are reproducible.
    return max(sorted(counter), key=lambda value: counter[value])


def unmasked(file, mask, start, length):
    """The ID's bytes at start, unmasked, or None while the mask doesn't cover them all."""
    positions = range(start, start + length)
    if all((file.id[0], position) in mask for position in positions):
        return bytes(file.id[position] ^ mask[(file.id[0], position)] for position in positions)
    return None


def learn_masks(ids):
    """(seed, position) -> mask byte: from known bytes, then axis tags and values, then zeros."""
    votes = collections.defaultdict(collections.Counter)
    for file in ids:
        if file.starts is None:
            continue
        text = describe(file.style, [(bytes(5), bytes(4))] * len(file.starts))
        unknown = {start + offset for start in file.starts for offset in (*range(3, 8), *range(9, 13))}
        for position in range(1, len(file.id)):
            if position not in unknown:
                votes[(file.id[0], position)][file.id[position] ^ text[position - 1]] += 1
    mask = {key: most(counter) for key, counter in votes.items()}

    # A partly known tag that fits only one fully read tag is that tag; otherwise the most common.
    read_tags = (unmasked(file, mask, start + 3, 5) for file in ids for start in file.starts or [])
    tag_counts = collections.Counter(tag for tag in read_tags if tag)
    tags, common_tag = sorted(tag_counts), most(tag_counts) if tag_counts else WGHT
    for file in ids:
        seed = file.id[0]
        for start in file.starts or []:
            positions = range(start + 3, start + 8)
            known = [(index, file.id[position] ^ mask[(seed, position)])
                     for index, position in enumerate(positions) if (seed, position) in mask]
            fits = [tag for tag in tags if all(tag[index] == value for index, value in known)]
            if len(known) < 5 and len(fits) == 1:
                for index, position in enumerate(positions):
                    mask.setdefault((seed, position), file.id[position] ^ fits[0][index])
    values = collections.defaultdict(collections.Counter)
    for file in ids:
        for start in file.starts or []:
            if (tag := unmasked(file, mask, start + 3, 5)) and (value := unmasked(file, mask, start + 9, 4)):
                values[tag][value] += 1
    for file in ids:
        for start in file.starts or []:
            for index, position in enumerate(range(start + 3, start + 8)):
                mask.setdefault((file.id[0], position), file.id[position] ^ common_tag[index])
            tag = unmasked(file, mask, start + 3, 5)
            if tag == WGHT:
                guess = struct.pack("<f", float(file.style.weight))
            else:
                guess = most(values[tag]) if values[tag] else bytes(4)
            for index, position in enumerate(range(start + 9, start + 13)):
                mask.setdefault((file.id[0], position), file.id[position] ^ guess[index])
    # Whatever is left reads as zero in the first ID to use it.
    for file in ids:
        for position in range(1, len(file.id)):
            mask.setdefault((file.id[0], position), file.id[position])
    return mask


def huffman(counts, limit=8):
    """Code lengths for the symbols that occur, none longer than limit (the reader's window)."""
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
        # Too deep: even the counts out a little and try again.
        step = max(1, sum(counts.values()) // 64)
        counts = {symbol: count + step for symbol, count in counts.items()}


def canonical(lengths):
    """symbol -> (code, length), and the stored table: counts per length 1-8, then symbols."""
    order = sorted((length, symbol) for symbol, length in lengths.items())
    codes, code, previous = {}, 0, order[0][0]
    for length, symbol in order:
        code <<= length - previous
        codes[symbol] = (code, length)
        code, previous = code + 1, length
    counts = bytes(sum(1 for code_length, _ in order if code_length == length) for length in range(1, 9))
    return codes, counts + bytes(symbol for _, symbol in order)


class BitWriter:
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


def raw(data):
    return [("bits", byte, 8) for byte in data]


def zero_runs(data):
    """The bytes as (zeros, literals) runs of at most 255 each, the form a whole ID is kept in."""
    runs, position = [], 0
    while position < len(data):
        zeros = 0
        while position < len(data) and data[position] == 0 and zeros < 255:
            zeros, position = zeros + 1, position + 1
        literals = bytearray()
        while position < len(data) and data[position] != 0 and len(literals) < 255:
            literals.append(data[position])
            position += 1
        runs.append((zeros, bytes(literals)))
    return runs


def group_styles(families):
    """name -> (version, [Group]): upright and italic groups, computed when one ID gives every weight."""
    entries = {}
    for name, (version, styles) in families.items():
        groups = []
        for italic in sorted({style_italic for style_italic, _ in styles}):
            group = sorted((weight, identifier) for (style_italic, weight), identifier in styles.items()
                           if style_italic == italic)
            weights = sum(1 << (weight // 100) for weight, _ in group)
            offset = weight_offset(group)
            stored = [group[0]] if offset is not None else group
            ids = []
            for weight, identifier in stored:
                style = Style(name.encode(), bool(italic), offset is not None, weight)
                ids.append(FileID(style, identifier, axis_starts(style, identifier)))
            groups.append(Group(int(italic) | (2 if offset is not None else 0), weights, offset, ids))
        entries[name] = (version, groups)
    return entries


def split_fields(ids, mask):
    """Unmasks each ID and reads its axes, or leaves it whole when the description doesn't match."""
    for file in ids:
        seed = file.id[0]
        file.plain = bytes([seed]) + bytes(file.id[position] ^ mask[(seed, position)]
                                           for position in range(1, len(file.id)))
        if file.starts is not None and len(file.starts) < WHOLE:
            axes = [(file.plain[start + 3:start + 8], file.plain[start + 9:start + 13]) for start in file.starts]
            if describe(file.style, axes) == file.plain[1:]:
                file.axes = axes


def expected_value(tag, style, usual):
    """An axis's default value: the weight for a listed wght, else the usual value or zeros."""
    return struct.pack("<f", float(style.weight)) if tag == WGHT and tag in usual else usual.get(tag, bytes(4))


@dataclasses.dataclass
class Tables:
    """What records are coded against: axis tags and values, layouts, weight sets and versions."""
    tags: list                # axis tags seen more than once, most common first
    usual: dict               # tag -> the value an axis gets unless it says otherwise (not used for wght)
    others: dict              # tag -> up to 15 other values seen more than once
    layouts: list             # each family's group flags, as a tuple
    weight_sets: list
    versions: list


def tables_for(entries, ids):
    tag_counts = collections.Counter(tag for file in ids for tag, _ in file.axes or [])
    tags = sorted((tag for tag, count in tag_counts.items() if count > 1), key=lambda tag: (-tag_counts[tag], tag))
    value_counts = collections.defaultdict(collections.Counter)
    for file in ids:
        for tag, value in file.axes or []:
            value_counts[tag][value] += 1
    usual = {tag: bytes(4) if tag == WGHT else most(value_counts[tag]) for tag in tags}
    other_counts = collections.defaultdict(collections.Counter)
    for file in ids:
        for tag, value in file.axes or []:
            if tag in usual and value != expected_value(tag, file.style, usual):
                other_counts[tag][value] += 1
    others = {tag: sorted((value for value, count in other_counts[tag].items() if count > 1),
                          key=lambda value: (-other_counts[tag][value], value))[:15] for tag in tags}
    tables = Tables(tags, usual, others,
                    layouts=sorted({tuple(group.flags for group in groups) for _, groups in entries.values()}),
                    weight_sets=sorted({group.weights for _, groups in entries.values() for group in groups}),
                    versions=sorted({version for version, _ in entries.values()}))
    if (len(tags) > 254 or len(tables.weight_sets) > 255 or len(tables.versions) > 255
            or sum(map(len, others.values())) > 255):
        sys.exit("Too many axis tags, weight sets, versions or named axis values for format 2.")
    return tables


def hash_order(names, avoid):
    """(hash seed, names in hash order, name -> hash), with no hash shared or met by a name in avoid."""
    for seed in range(1 << 16):
        hashes = {name: fnv(name.encode(), seed, HASH_BITS) for name in names}
        stored = set(hashes.values())
        if len(stored) == len(names) and not stored & {fnv(name.encode(), seed, HASH_BITS) for name in avoid}:
            return seed, sorted(names, key=hashes.get), hashes
    sys.exit(f"No seed keeps {len(names)} names' {HASH_BITS}-bit hashes apart.")


def weight_position(file, tables):
    """Where the wght value sits in a rebuilt ID, as the reader finds it."""
    found = None
    for (tag, _), start in zip(file.axes or [], file.starts or []):
        if tag == WGHT and tag in tables.usual:
            found = start + 9
    return found


def record(version, groups, tables):
    """A family's record, in reading order: ("bits", value, width) or (code name, symbol)."""
    layout = tables.layouts.index(tuple(group.flags for group in groups))
    out = [("bits", groups[0].ids[0].id[0], 8), ("layout", layout), ("version", tables.versions.index(version))]
    for number, group in enumerate(groups):
        computed = bool(group.flags & 2)
        same_weights = group.weights == groups[0].weights
        if number == 1:
            out.append(("bits", int(same_weights), 1))
        if number == 0 or not same_weights:
            out.append(("axis weights" if computed else "weights", tables.weight_sets.index(group.weights)))
        if computed:
            out.append(("base", group.ids[0].style.weight // 100))
        for file in group.ids:
            code = "variable axes" if computed else "axes"
            if file.axes is None:
                residual = file.plain[1:]
                out += [(code, WHOLE), ("bits", len(residual), 8)]
                for zeros, literals in zero_runs(residual):
                    out += [("bits", zeros, 8), ("bits", len(literals), 8)] + raw(literals)
            else:
                out.append((code, len(file.axes)))
                for tag, value in file.axes:
                    listed = tag in tables.usual
                    out.append(("tag", tables.tags.index(tag) if listed else len(tables.tags)))
                    if not listed:
                        out += raw(tag)
                    if value == expected_value(tag, file.style, tables.usual):
                        out.append(("value", 0))
                    elif listed and value in tables.others[tag]:
                        out.append(("value", 1 + tables.others[tag].index(value)))
                    else:
                        out += [("value", 16)] + raw(value)
            if computed:
                derived = weight_position(file, tables)
                out.append(("bits", int(derived == group.offset), 1))
                if derived != group.offset:
                    out.append(("bits", group.offset, 8))
    return out


def build(families, avoid):
    """The format-2 file; names in avoid (left to CSS2) never share a stored hash."""
    names = sorted(families, key=lambda family: family.encode())
    if not names:
        sys.exit("No families to build.")
    entries = group_styles(families)
    ids = [file for name in names for group in entries[name][1] for file in group.ids]
    mask = learn_masks(ids)
    split_fields(ids, mask)
    tables = tables_for(entries, ids)
    hash_seed, order, hashes = hash_order(names, avoid)

    records = {name: record(*entries[name], tables) for name in order}
    counts = collections.defaultdict(collections.Counter)
    for fields in records.values():
        for field in fields:
            if field[0] != "bits":
                counts[field[0]][field[1]] += 1
    codes, code_tables = {}, []
    for code in CODES:
        codes[code], table = canonical(huffman(counts[code] or {0: 1}))
        code_tables.append(table)

    hash_list = [hashes[name] for name in order]
    # Per block: Rice-coded hash gaps (the first hash is in the index), then the records.
    gaps = [hash_list[position] - hash_list[position - 1] for position in range(1, len(hash_list)) if position % BLOCK]
    rice = min(range(1, 20), key=lambda width: sum((gap >> width) + 1 + width for gap in gaps))
    stream, index = BitWriter(), bytearray()
    for first in range(0, len(order), BLOCK):
        if stream.count >= 1 << 24:
            sys.exit("The records outgrew format 2.")
        index += hash_list[first].to_bytes(3, "little") + stream.count.to_bytes(3, "little")
        for position in range(first + 1, min(first + BLOCK, len(order))):
            gap = hash_list[position] - hash_list[position - 1]
            stream.put((1 << (gap >> rice)) - 1, gap >> rice)
            stream.put(0, 1)
            stream.put(gap, rice)
        for name in order[first:first + BLOCK]:
            for field in records[name]:
                if field[0] == "bits":
                    stream.put(field[1], field[2])
                else:
                    stream.put(*codes[field[0]][field[1]])

    row_lengths = collections.Counter()
    for seed, position in mask:
        row_lengths[seed] = max(row_lengths[seed], position)
    rows = [bytes(mask.get((seed, position), 0) for position in range(1, row_lengths[seed] + 1)) for seed in range(256)]
    if sum(map(len, rows)) > 0xFFFF:
        sys.exit("The mask rows outgrew format 2.")
    row_offsets, mask_rows = bytearray(), bytearray()
    for row in rows:
        row_offsets += struct.pack("<H", len(mask_rows))
        mask_rows += row
    row_offsets += struct.pack("<H", len(mask_rows))
    tag_table, value_table = bytearray([len(tables.tags)]), bytearray()
    for tag in tables.tags:
        flags = int(tag == WGHT) | len(tables.others[tag]) << 4
        tag_table += tag + bytes([flags]) + tables.usual[tag] + bytes([len(value_table) // 4])
        value_table += b"".join(tables.others[tag])
    table_offsets, table_bytes = bytearray(), bytearray()
    for table in code_tables:
        table_offsets += struct.pack("<H", len(table_bytes))
        table_bytes += table
    # Bit 4: a second group; bits 2-3 and 0-1: each group's flags.
    shapes = bytes((len(flags) - 1) << 4 | flags[0] << 2 | (flags[1] if len(flags) > 1 else 0)
                   for flags in tables.layouts)
    sections = [
        bytes([len(tables.layouts)]) + shapes,
        bytes([len(tables.weight_sets)]) + b"".join(struct.pack("<H", weights) for weights in tables.weight_sets),
        bytes([len(tables.versions)]) + bytes(tables.versions),
        bytes(tag_table), bytes(value_table), bytes(table_offsets + table_bytes),
        bytes(row_offsets), bytes(mask_rows), bytes(index), stream.bytes(),
    ]
    offsets, at = [], HEADER_SIZE
    for section in sections:
        offsets.append(at)
        at += len(section)
    header = b"WFKC" + bytes([FORMAT, HASH_BITS, BLOCK, rice]) + struct.pack("<IHH", today(), hash_seed, len(names))
    return header + struct.pack("<10I", *offsets) + b"".join(sections)


class BitReader:
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
    """A format-2 file, read as strictly as the Swift reader; anything else is ValueError."""

    def __init__(self, data):
        if len(data) < HEADER_SIZE or data[:5] != b"WFKC" + bytes([FORMAT]):
            raise ValueError("Not a format-2 catalogue.")
        self.data = data
        self.hash_bits, self.block, self.rice = data[5], data[6], data[7]
        self.hash_seed, self.count = struct.unpack_from("<HH", data, 12)
        offsets = struct.unpack_from("<10I", data, 16)
        if not (1 <= self.hash_bits <= 24 and self.block and self.rice < 24 and HEADER_SIZE <= offsets[0]
                and list(offsets) == sorted(offsets) and offsets[-1] <= len(data) and offsets[5] + 18 <= offsets[6]):
            raise ValueError("A damaged catalogue header.")
        (self.layouts, self.weight_sets, self.versions, self.tags, self.values,
         self.codes, self.row_offsets, self.mask_rows, self.index, self.records) = offsets
        table_offsets = struct.unpack_from(f"<{len(CODES)}H", data, self.codes)
        self.tables = [self.codes + 2 * len(CODES) + offset for offset in table_offsets]
        self.tag_entries = [data[self.tags + 1 + 11 * tag:self.tags + 12 + 11 * tag] for tag in range(data[self.tags])]
        self.block_starts = [(int.from_bytes(data[at:at + 3], "little"), int.from_bytes(data[at + 3:at + 6], "little"))
                             for at in range(self.index, self.records - 5, 6)]

    def byte(self, at):
        if not 0 <= at < len(self.data):
            raise ValueError("A read past the catalogue.")
        return self.data[at]

    def symbol(self, code, reader):
        """A canonical Huffman symbol, from the code's counts per length and symbols in code order."""
        table = self.tables[CODES.index(code)]
        value = first = index = 0
        for length in range(1, 9):
            value |= reader.get(1)
            count = self.byte(table + length - 1)
            if value - first < count:
                return self.byte(table + 8 + index + value - first)
            index += count
            first = (first + count) << 1
            value <<= 1
        raise ValueError("A bad code in the catalogue.")

    def read(self, names):
        """name -> (version, {(italic, weight): file ID}) for the names it holds."""
        by_hash = {fnv(name.encode(), self.hash_seed, self.hash_bits): name for name in names}
        found = {}
        for block, (first_hash, bit) in enumerate(self.block_starts):
            reader = BitReader(self.data, 8 * self.records + bit)
            hashes = [first_hash]
            for _ in range(min(self.block, self.count - block * self.block) - 1):
                ones = 0
                while reader.get(1):
                    ones += 1
                    if ones << self.rice >= 1 << self.hash_bits:
                        raise ValueError("A bad name hash in the catalogue.")
                hashes.append(hashes[-1] + (ones << self.rice | reader.get(self.rice)))
            for family_hash in hashes:
                name = by_hash.get(family_hash)
                entry = self.family(reader, name.encode() if name else None)
                if name:
                    found[name] = entry
        return found

    def family(self, reader, name):
        seed = reader.get(8)
        layout, version = self.symbol("layout", reader), self.symbol("version", reader)
        if layout >= self.byte(self.layouts) or version >= self.byte(self.versions):
            raise ValueError("A bad record in the catalogue.")
        shape, version = self.byte(self.layouts + 1 + layout), self.byte(self.versions + 1 + version)
        files, weights = {}, 0
        for number in range((shape >> 4 & 1) + 1):
            flags = shape >> 2 & 3 if number == 0 else shape & 3
            italic, computed = bool(flags & 1), bool(flags & 2)
            if number == 0 or not reader.get(1):
                choice = self.symbol("axis weights" if computed else "weights", reader)
                if choice >= self.byte(self.weight_sets):
                    raise ValueError("A bad record in the catalogue.")
                at = self.weight_sets + 1 + 2 * choice
                weights = self.byte(at) | self.byte(at + 1) << 8
            base = self.symbol("base", reader) * 100 if computed else None
            present = [step * 100 for step in range(1, 16) if weights >> step & 1]
            for weight in [base] if computed else present:
                style = Style(name or b"", italic, computed, weight)
                plain, offset = self.file_id(reader, seed, style)
                if computed and not reader.get(1):
                    offset = reader.get(8)
                if name is None:
                    continue
                row = self.row_offsets + 2 * seed
                if row + 4 > self.mask_rows:
                    raise ValueError("A damaged mask row offset.")
                start, end = struct.unpack_from("<HH", self.data, row)
                if len(plain) - 1 > end - start or self.mask_rows + end > self.index:
                    raise ValueError("A mask row shorter than its ID.")
                identifier = bytes([seed]) + bytes(plain[position] ^ self.data[self.mask_rows + start + position - 1]
                                                   for position in range(1, len(plain)))
                if not computed:
                    files[(italic, weight)] = identifier
                    continue
                if offset is None or offset + 4 > len(identifier):
                    raise ValueError("A computed group with no weight offset.")
                # Other weights differ only in the weight float.
                for other in present:
                    diff = xor(struct.pack("<f", float(base)), struct.pack("<f", float(other)))
                    other_id = bytearray(identifier)
                    for position in range(4):
                        other_id[offset + position] ^= diff[position]
                    files[(italic, other)] = bytes(other_id)
        return version, files

    def file_id(self, reader, seed, style):
        """(the ID before masking, where its weight float sits) from the record's bits."""
        axes_count = self.symbol("variable axes" if style.computed else "axes", reader)
        if axes_count == WHOLE:
            length, text = reader.get(8), bytearray()
            while len(text) < length:
                zeros, literals = reader.get(8), reader.get(8)
                if not zeros + literals:
                    raise ValueError("A bad record in the catalogue.")
                text += bytes(zeros) + bytes(reader.get(8) for _ in range(literals))
            if len(text) != length:
                raise ValueError("A bad record in the catalogue.")
            return bytes([seed]) + bytes(text), None
        axes, offset = [], None
        for _ in range(axes_count):
            tag_index = self.symbol("tag", reader)
            if tag_index > len(self.tag_entries):
                raise ValueError("A bad record in the catalogue.")
            entry = self.tag_entries[tag_index] if tag_index < len(self.tag_entries) else None
            tag = entry[:5] if entry else bytes(reader.get(8) for _ in range(5))
            value_index = self.symbol("value", reader)
            from_weight = entry is not None and entry[5] & 1
            if value_index == 0 and from_weight:
                value = struct.pack("<f", float(style.weight))
            elif value_index == 0:
                value = entry[6:10] if entry else bytes(4)
            elif value_index == 16:
                value = bytes(reader.get(8) for _ in range(4))
            elif entry is not None and value_index - 1 < entry[5] >> 4:
                at = self.values + 4 * (entry[10] + value_index - 1)
                value = self.data[at:at + 4]
            else:
                raise ValueError("A bad record in the catalogue.")
            if from_weight:
                offset = 1 + len(head(style)) + 13 * len(axes) + 9
            axes.append((tag, value))
        return bytes([seed]) + describe(style, axes), offset


def read(data, names):
    """family -> (version, {(italic, weight): url}) for the names it holds. ValueError for a damaged file."""
    return {name: (version, {style: url_for(slug(name), version, identifier) for style, identifier in files.items()})
            for name, (version, files) in Catalogue(data).read(names).items()}


def shares_hash(data, name):
    """Whether name's hash meets a stored family's. A ValueError comes only past a match (some style can't be
    rebuilt for name), and Swift may still answer the others."""
    try:
        return bool(read(data, [name]))
    except ValueError:
        return True


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


def verify(data, families, sources, avoid):
    """Every entry, read back, must give exactly Google's URL, and names left to CSS2 must miss.
    Returns (file count, what was read)."""
    try:
        contents, strays = read(data, sorted(families)), read(data, sorted(avoid))
    except ValueError as error:
        sys.exit(f"Round trip failed: {error}")
    count = 0
    for name, (_, styles) in contents.items():
        for (italic, weight), url in styles.items():
            if url != sources.get((name, italic, weight)):
                style = f"{weight}{'i' if italic else ''}"
                sys.exit(f"Round trip failed for {name} {style}: the writer and reader disagree.")
            count += 1
    if contents.keys() != families.keys() or count != sum(len(styles) for _, styles in families.values()):
        sys.exit("Round trip failed: the catalogue doesn't hold every family and style it was built from.")
    if strays:
        sys.exit(f"Round trip failed: {', '.join(sorted(strays))} would read a stored family's files.")
    return count, contents


def write(path, data):
    # Beside the target, then renamed: an interrupted run never leaves a half-written file.
    with open(path + ".partial", "wb") as file:
        file.write(data)
    os.replace(path + ".partial", path)


def write_bundled(data, contents):
    write(BUNDLED, data)
    write(LISTING, listing(contents).encode())


def committed():
    """(bytes, contents) of the bundled catalogue, named by its listing, which must match; else empty."""
    try:
        with open(BUNDLED, "rb") as file:
            data = file.read()
        with open(LISTING, encoding="utf-8") as file:
            text = file.read()
        contents = read(data, [line.split("\t")[0] for line in text.splitlines() if line])
        if listing(contents) != text or len(contents) != Catalogue(data).count:
            raise ValueError("the listing doesn't match the catalogue")
        return data, contents
    except FileNotFoundError:
        return b"", {}
    except (ValueError, IndexError, struct.error, UnicodeDecodeError) as error:
        print(f"The committed catalogue is unreadable: {error}.", file=sys.stderr)
        return b"", {}


def keep_unanswered(rows, unanswered, old):
    """Unanswered families keep their committed entries. Returns (kept, still unanswered)."""
    kept = [name for name in unanswered if name in old]
    rows += [(name, f"{weight}{'i' if italic else ''}", url)
             for name in kept for (italic, weight), url in old[name][1].items()]
    return kept, [name for name in unanswered if name not in old]


def build_verified(rows, unanswered):
    """(data, file count, skipped, left to CSS2, contents) for these rows, verified."""
    families, skipped, sources = parse(rows)
    # Every name Google listed that isn't stored, including one whose styles are all skipped.
    left_to_css2 = ({row[0] for row in rows} | set(unanswered)) - families.keys()
    data = build(families, avoid=left_to_css2)
    count, contents = verify(data, families, sources, left_to_css2)
    return data, count, skipped, left_to_css2, contents


def command_build(arguments):
    old = {}
    if arguments.rows:
        with open(arguments.rows) as file:
            rows = json.load(file)
        kept, unanswered = [], []
    else:
        rows, unanswered = fetch_rows()
        old = committed()[1]
        kept, unanswered = keep_unanswered(rows, unanswered, old)
    data, count, skipped, left_to_css2, contents = build_verified(rows, unanswered)
    missing = len(old.keys() - contents.keys())
    if missing > max(20, len(old) // 20):
        sys.exit(f"{missing} committed families are missing: Google's font list may be incomplete. Nothing written.")
    # From saved rows, only the file asked for; otherwise the bundled catalogue and its listing.
    if arguments.out:
        write(arguments.out, data)
    else:
        write_bundled(data, contents)
    print(f"{arguments.out or BUNDLED}: {len(contents)} families, {count} files, {len(data) / 1024:.0f} KB")
    if kept:
        print(f"No answer, kept as committed: {', '.join(kept)}", file=sys.stderr)
    for label, names in (("unusual URLs", left_to_css2 - set(unanswered)), ("no answer", unanswered)):
        if names:
            print(f"Left to CSS2, {label}: {', '.join(sorted(names))}", file=sys.stderr)


def command_reckon(arguments):
    """Fails on dead committed URLs or a changed answer shape; otherwise refreshes changed or old files."""
    old_data, old = committed()
    pairs = [(name, url) for name, (_, styles) in old.items() for url in styles.values()]
    sample = random.sample(pairs, min(50, len(pairs)))
    # The catalogue relies on Google serving old versions: sample them while fetching.
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        statuses = pool.map(lambda pair: get("fonts.gstatic.com", urllib.parse.urlsplit(pair[1]).path, "HEAD")[0],
                            sample)
        rows, unanswered = fetch_rows()
        statuses = list(statuses)
    kept, unanswered = keep_unanswered(rows, unanswered, old)
    data, count, skipped, left_to_css2, new = build_verified(rows, unanswered)

    problems, lines = [], []
    # A retired family's files are expected to go; it is reported as removed instead.
    checked = [(url, status) for (name, url), status in zip(sample, statuses) if name in new]
    dead = [url for url, status in checked if status != 200]
    if dead:
        problems.append(f"{len(dead)} of {len(checked)} committed file URLs no longer answer 200, e.g. {dead[0]}")
    # Kept families ride out an outage, so only the rest count here.
    if len(skipped) + len(unanswered) > 10:
        problems.append(f"{len(skipped) + len(unanswered)} families unanswered or unusual (usually none): "
                        "Google's answers may have changed shape")

    added, removed = sorted(new.keys() - old.keys()), sorted(old.keys() - new.keys())
    # Google retires a family now and then; losing many at once means a truncated font list.
    if len(removed) > max(20, len(old) // 20):
        problems.append(f"{len(removed)} families would be removed: Google's font list may be incomplete")
    common = sorted(old.keys() & new.keys())
    bumped = [name for name in common if old[name][0] != new[name][0]]
    restyled = [name for name in common if old[name][1].keys() != new[name][1].keys()]
    # An ID changing within one version breaks the catalogue's assumption.
    unstable = [name for name in common if old[name][0] == new[name][0]
                and any(old[name][1][style] != new[name][1][style]
                        for style in old[name][1].keys() & new[name][1].keys())]
    if unstable:
        problems.append(f"file IDs changed without a version bump: {', '.join(unstable[:10])}")

    alive = len(checked) - len(dead)
    lines.append(f"Catalogue: {len(new)} families, {count} files, {len(data) / 1024:.0f} KB; "
                 f"{alive} of {len(checked)} committed URLs alive.")
    for label, names in (("Added", added), ("Removed", removed), ("New versions", bumped), ("Styles changed", restyled),
                         ("No answer, kept as committed", kept), ("Left to CSS2", sorted(left_to_css2))):
        if names:
            lines.append(f"- **{label} ({len(names)}):** {', '.join(names[:30])}{' …' if len(names) > 30 else ''}")
    lines += [f"- **Problem:** {problem}" for problem in problems]

    # The library trusts a catalogue for a year, so rebuild an unchanged one early.
    age = today() - struct.unpack_from("<I", old_data, 8)[0] if old_data else 0
    # A family newly left to CSS2 may share a committed hash; the fresh build's seed avoids it.
    strays = [name for name in sorted(left_to_css2 - old.keys()) if old_data and shares_hash(old_data, name)]
    changed = old != new or strays or age > REFRESH_AFTER_DAYS
    refresh = changed and not problems
    if refresh:
        write_bundled(data, new)
        if old != new:
            lines.append("Refreshed the catalogue.")
        elif strays:
            lines.append(f"Refreshed the hash seed: {', '.join(strays)} would read a stored family's files.")
        else:
            lines.append(f"Refreshed the catalogue's build day: it was {age} days old.")
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
