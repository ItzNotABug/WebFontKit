# Catalogue format 2

`Sources/WebFontKit/Resources/GoogleFonts.catalog`, written by `scripts/catalog.py` and read by
`GoogleFontsCatalog.swift`. Little-endian; every count is one byte.

## File IDs

A Google file ID is a seed byte, then Google's description of the file XOR the seed's mask row:

```
00 <ID length − 5> 00 <name length> <name> [10 02] [18 <weight>] [3a 0b 08 <tag> 15 <float32>]… 20 00
```

`10 02` marks italic, `18` and a varint a static weight other than 400, and each 13-byte block an
axis (5-byte tag, 4-byte value). The catalogue keeps each family's seed and the fields that differ;
the reader rebuilds the description and XORs it with the mask row.

## Finding a family

A name's hash is the top *hash bits* of 32-bit FNV-1a over its UTF-8 bytes, starting from
`0x811C9DC5` XOR the *hash seed*. Families are stored in hash order, in blocks. An unknown name
matches a stored hash about 0.2% of the time; its URL then 404s and the loader asks CSS2.

## Sections, in file order

- **Header (56 bytes):** `WFKC`, format `2`, hash bits, block size, Rice parameter, build day (u32,
  days since 1970), hash seed (u16), family count (u16), then the offsets (u32) of the ten sections
  below.
- **Layouts:** count, then a byte each: bit 4 for a second group, and each group's flags in bits 2–3
  and 0–1 (1 italic, 2 computed: one stored ID gives every weight).
- **Weight sets:** count, then u16s, bit n for weight n × 100.
- **Versions:** count, then bytes.
- **Axis tags:** count, then 11 bytes each: the tag, flags (bit 0: the value is the weight; bits 4–7:
  other-value count), the usual value (4 bytes) and the index of its first other value.
- **Other values:** 4 bytes each.
- **Codes:** nine u16 offsets, counted from the end of the offsets, then each code's canonical Huffman
  table: counts per length 1–8, then symbols. In order: layout, version, weights, axis weights (a
  computed group's set), base, axes, variable axes (a computed ID's count), tag, value.
- **Row offsets:** 257 u16s into the mask rows; row n ends where row n + 1 starts.
- **Mask rows:** row byte i masks ID byte i + 1.
- **Block index:** per block, its first name hash and its bit offset into the records (u24 each).
- **Records:** MSB-first bits, described below.

## Records

Per block, the gaps between its sorted name hashes (Rice: ones ended by a 0, then the Rice
parameter's bits), then each family's record:

- seed (8 bits), layout, version;
- per group: its weight set (a second group first has a bit: 1 for the first group's set), the base
  weight ÷ 100 if computed, then its IDs: one if computed, else one per weight, ascending.

Per ID: an axis count, then per axis a tag and a value.

- **Tag:** an index into the axis tags; one past the table means 5 raw bytes follow.
- **Value:** 0 for the usual value (the weight for `wght`, zeros for a raw tag); 1–15 for one of the
  tag's other values; 16 means 4 raw bytes follow.

An axis count of 15 marks an ID kept whole: its length after the seed, then runs of a zero count, a
literal count and the literals (8 bits each). It is masked like any other ID.

A computed ID ends with a bit: 1 if the weight float is its `wght` value, else the float's offset in
the ID follows (8 bits). Every other weight of the group differs from the stored ID only there.
