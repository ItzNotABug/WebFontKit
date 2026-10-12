# Fixture sources

Downloaded once with curl on 2026-10-07 and kept byte for byte, except the three `Corrupt/` files made locally. Each font URL comes from a fresh CSS2 response of that day, requested with `User-Agent: WebFontKit/1.0.0` unless noted. Sizes are decoded bytes. Glyph counts and PostScript names were read with `CTFontManagerCreateFontDescriptorsFromURL` on macOS 26.4.

All fonts are under the SIL Open Font License 1.1. Each folder carries the licence text from the google/fonts repository (`https://raw.githubusercontent.com/google/fonts/main/ofl/<family>/OFL.txt`), because the served font files carry no licence text.

## Fonts/

| File | Source URL | Bytes | SHA-256 | PostScript name | Glyphs | Licence |
|---|---|---|---|---|---|---|
| `Lato-Regular.ttf` | `https://fonts.gstatic.com/s/lato/v25/S6uyw4BMUTPHvxk.ttf` | 72,312 | `f43f1c7780d69792278f04b136c934a0298fc66f2e974bac13dd2e53adc52bde` | `Lato-Regular` | 272 | `OFL-Lato.txt` |
| `Lato-Bold.ttf` | `https://fonts.gstatic.com/s/lato/v25/S6u9w4BMUTPHh6UVew8.ttf` | 70,576 | `02e8f4be57ddc47cb7882c41b60216b6085b1ceaf717514be2b88fa15396238d` | `Lato-Bold` | 272 | `OFL-Lato.txt` |
| `Lato-Italic.ttf` | `https://fonts.gstatic.com/s/lato/v25/S6u8w4BMUTPHjxswWw.ttf` | 72,936 | `ae2f4abf0bf802b3710c474f05d1a34f086ef57001f5751d03e428e113f5a684` | `Lato-Italic` | 272 | `OFL-Lato.txt` |
| `Lato-BoldItalic.ttf` | `https://fonts.gstatic.com/s/lato/v25/S6u_w4BMUTPHjxsI5wqPHA.ttf` | 74,836 | `0c55b8d34d395c056230c7c5741244de73d0d3cf5fe01b5a0f54cb025fb942fd` | `Lato-BoldItalic` | 272 | `OFL-Lato.txt` |
| `Lobster-Regular.ttf` (v32) | `https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9_oU.ttf` | 392,208 | `dfdc22543e8a5188aa6d774aa2e9a1f3c9cb363dc814ba1e919ac9e379daec03` | `Lobster-Regular` | 1142 | `OFL-Lobster.txt` |
| `NotoSansKannada-Regular.ttf` | `https://fonts.gstatic.com/s/notosanskannada/v32/8vIs7xs32H97qzQKnzfeXycxXZyUmySvZWItmf1fe6TVmgop9ndpS-BqHEyGrDvNzSI.ttf` | 143,576 | `4b8dd08fc05afa13cc8daa8ac2187f35711be026286db8608e87c86f715e273d` | `NotoSansKannada-Regular` | 758 | `OFL-NotoSansKannada.txt` |
| `BebasNeue-Regular.ttf` | `https://fonts.gstatic.com/s/bebasneue/v16/JTUSjIg69CK48gW7PXooxW4.ttf` | 56,136 | `939fea723dad24504f40faadc34eeffadfbbee558754f70c3c736e13786b0ab6` | `BebasNeue-Regular` | 497 | `OFL-BebasNeue.txt` |

The four Lato files are the faces one CSS2 request for `Lato:ital,wght@0,400;0,700;1,400;1,700` returned. CoreText reports family `Lato` for all four, with the matching bold and italic traits.

Lato check, 2026-10-07: on the iOS 26.5 (23F77) and iOS 18.0 (22A3351) simulators, `CTFontCreateWithName` for `Lato-Regular`, `Lato-Bold`, `Lato-Italic` and `Lato-BoldItalic` resolved to Helvetica in every case, so none is active before registration.

## Fonts/Versions/

| File | Source URL | Bytes | SHA-256 | PostScript name | Glyphs | Licence |
|---|---|---|---|---|---|---|
| `Lobster-Regular-v20.ttf` | `https://fonts.gstatic.com/s/lobster/v20/neILzCirqoswsqX9_oU.ttf` | 406,076 | `d6568e697fd50cedc0be04d8aae4127fe95add607e7bff954ca88604be80c205` | `Lobster-Regular` | 1174 | `OFL-Lobster.txt` |

The v32 path with the version segment changed; CSS2 serves only the current version. Old versions are still served (checked by hand before each release).

## Woff/

| File | Source URL | Bytes | SHA-256 | PostScript name | Glyphs | Licence |
|---|---|---|---|---|---|---|
| `Lobster-Regular.woff` | `https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9_oY.woff` | 138,008 | `d0962a8c6c53e92b323855f052c17d41ceb42f7388f1c4686f25c65dc07546c4` | `Lobster-Regular` | 1142 | `OFL-Lobster.txt` |
| `Lobster-Regular-latin.woff2` | `https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9zoKmM4MwWJU.woff2` | 17,068 | `91f29167fda1cb9227c5197c473b9f4b7604d2356f096908c31deb8b1cd10159` | `Lobster-Regular` | 333 | `OFL-Lobster.txt` |

- The WOFF URL came from a CSS2 request for `Lobster` with `User-Agent: Mozilla/5.0 (Windows NT 6.1; rv:30.0) Gecko/20100101 Firefox/30.0`: one `format('woff')` face with no `unicode-range`.
- The WOFF2 URL is the `/* latin */` slice from a CSS2 request for `Lobster` with a Mobile Safari user agent (`Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1`).

## Corrupt/

| File | How it was made | Bytes | SHA-256 |
|---|---|---|---|
| `Empty.ttf` | Zero bytes, made locally. | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `Truncated.ttf` | The first 4,096 bytes of `Fonts/Lobster-Regular.ttf`, made locally with `head -c`: the whole table directory (17 tables, 284 bytes) survives, and 10 tables, `glyf` among them, are cut mid-body, as in an interrupted download. | 4,096 | `c05719eb71b4fb8551d94f2241a3e3831ff816e433f598396777e78fc5efcb7d` |
| `NotFound.ttf` | Downloaded: the HTML page `https://fonts.googleapis.com/css2?family=lobster` returns (status 400, `text/html; charset=utf-8`, "400: Font family not found"), saved as `.ttf`. | 6,478 | `283dee1142dc6f5b704942c3842e9ba43e558a6979f335744601061c0795f70d` |
| `Truncated.woff2` | The first 8,534 bytes (half) of `Woff/Lobster-Regular-latin.woff2`, made locally with `head -c`. | 8,534 | `d62aa017e5617b597476ab0ab2ad5dab8ba246fe53dd4e31d581d2aab159e83f` |

CoreText check, 2026-10-07: `CTFontManagerCreateFontDescriptorsFromURL` returned no descriptor for each of the four files on macOS 26.4, on the iOS 26.5 simulator (23F77) and on the iOS 18.0 simulator (22A3351). In the same runs the uncut `Woff/Lobster-Regular-latin.woff2` returned one descriptor.

`Truncated.ttf` was first cut at half the file (196,104 bytes). It was cut to 4,096 bytes on 2026-10-09 and checked again: still no descriptor on macOS 26.4, on the iOS 26.5 simulator (23F77) and on the iOS 18.0 simulator (22A3351), and on macOS registration still fails with 103, as the half-length cut did.

## css2/

Responses captured from the live endpoint with curl; each file name carries its capture date. Each came from `https://fonts.googleapis.com/css2?family=<query>`:

| File | Query | Status |
|---|---|---|
| `lobster-2026-10-07.css` | `Lobster` | 200 |
| `inter-four-styles-2026-10-07.css` | `Inter:ital,wght@0,400;0,700;1,400;1,700` | 200 |
| `not-found-2026-10-07.html` | `Lobstr` | 400 |
| `invalid-selector-2026-10-07.html` | `Inter:wght@400;400` | 400 |
| `noto-sans-jp-2026-10-07.css` | `Noto+Sans+JP` | 200 |
| `inter-450-2026-10-07.css` | `Inter:wght@450` | 200 |
| `material-symbols-outlined-2026-10-07.css` | `Material+Symbols+Outlined` | 200 |
| `nabla-2026-10-07.css` | `Nabla` | 200 |

- The partial answer for `Lobster:wght@400;700` was byte for byte the `Lobster` answer (the regular face alone), so tests use `lobster-2026-10-07.css` for it.

## catalog/

`rows.json` holds Google's real CSS2 answers (family, style, file URL): ten families captured 2026-10-08 (listed and computed weights, upright and italic), plus fifteen taken on 2026-10-12 from the format-1 catalogue, whose URLs the builder had checked against Google's answers. The fifteen are families whose shipped records take a rarer path: several axes, one-off axis tags, IDs kept whole (Bitcount Ink, Roboto Flex), static fonts with an axis, a non-default `wght` value, italic weights unlike the upright, and the highest version. Built into a 25-family catalogue, most of them decode the common way, as the mask rows learn their differences; the shipped-catalogue tests cover the rarer paths. One more row, "Zz Cbsq" with no URL, is a made-up name left to CSS2 whose hash meets ABeeZee's at seed 0, so the fixtures are built with a nonzero hash seed. `sample.catalog` is built from these rows by `scripts/catalog.sh --rows`, and `without-lobster.catalog` from them less Lobster's (as `scripts/verify.sh` checks).

`shipped.tsv` is written with the shipped catalogue by `scripts/catalog.sh` and `scripts/reckon.sh`: every family, its version and styles, and the first 8 hex digits of the SHA-256 of its URLs in that order, newline-separated. The build checks each URL against Google's answer; the Swift tests check the shipped catalogue against this listing.

## Perf/

Added for the performance tests and the Example app's cold-launch benchmark on 2026-10-07: 20 OFL regular faces with 20 distinct PostScript names, none of them a family iOS ships. On the iOS 26.5 simulator none of the 20 names was active before registration (20 of 20 checked). Each URL came from a CSS2 request for the family with `User-Agent: WebFontKit/1.0.0`.

| File | Source URL | Bytes | SHA-256 | PostScript name | Glyphs | Licence |
|---|---|---|---|---|---|---|
| `AbrilFatface-Regular.ttf` | `https://fonts.gstatic.com/s/abrilfatface/v25/zOL64pLDlL1D99S8g8PtiKchm-A.ttf` | 56,308 | `c426e1328c73a1d1c1c36809ead3353b487ae71d3b387ac8daca2d4b6d9124c0` | `AbrilFatface-Regular` | 402 | `OFL-AbrilFatface.txt` |
| `Bangers-Regular.ttf` | `https://fonts.gstatic.com/s/bangers/v25/FeVQS0BTqb0h60ACL5k.ttf` | 91,216 | `a5ad3f06658ecd92705c3499cf000ff5b0c0c6f49641f7b3a6531dcee4bdb4c0` | `Bangers-Regular` | 592 | `OFL-Bangers.txt` |
| `Caveat-Regular.ttf` | `https://fonts.gstatic.com/s/caveat/v23/WnznHAc5bAfYB2QRah7pcpNvOx-pjfJ9SII.ttf` | 251,024 | `012f33f9814bf9614973983335c3a375fe267c094e7c09a02a276cd1dcd4180a` | `Caveat-Regular` | 993 | `OFL-Caveat.txt` |
| `Comfortaa-Regular.ttf` | `https://fonts.gstatic.com/s/comfortaa/v47/1Pt_g8LJRfWJmhDAuUsSQamb1W0lwk4S4WjMPrQ.ttf` | 110,000 | `c5633dc8323c788158d456e461bacc78d251f713e33228527765a1f3fa84ec03` | `Comfortaa-Regular` | 871 | `OFL-Comfortaa.txt` |
| `DancingScript-Regular.ttf` | `https://fonts.gstatic.com/s/dancingscript/v29/If2cXTr6YS-zF4S-kcSWSVi_sxjsohD9F50Ruu7BMSoHTQ.ttf` | 76,340 | `cbf45d12702db573b174863d83fc137f29ac270240f289aa41942b36032d5201` | `DancingScript-Regular` | 596 | `OFL-DancingScript.txt` |
| `Fredoka-Regular.ttf` | `https://fonts.gstatic.com/s/fredoka/v17/X7nP4b87HvSqjb_WIi2yDCRwoQ_k7367_B-i2yQag0-mac3O8SLMFg.ttf` | 48,856 | `7fe52d17e4c5c80ec74c9b26cb635d593e72cfc30cc189dab7a0babece57e153` | `Fredoka-Regular` | 327 | `OFL-Fredoka.txt` |
| `JosefinSans-Regular.ttf` | `https://fonts.gstatic.com/s/josefinsans/v34/Qw3PZQNVED7rKGKxtqIqX5E-AVSJrOCfjY46_DjQXME.ttf` | 57,844 | `51db65928e13442537cf58237592cb49aad1ac5e24345e11283d7ed5723e6793` | `JosefinSans-Regular` | 610 | `OFL-JosefinSans.txt` |
| `Kalam-Regular.ttf` | `https://fonts.gstatic.com/s/kalam/v18/YA9dr0Wd4kDdMuhW.ttf` | 426,488 | `f20e9de66ca054e1d1376b3c811d2240b1b5ef831474bda9fbbaf28d67e67902` | `Kalam-Regular` | 1027 | `OFL-Kalam.txt` |
| `LobsterTwo-Regular.ttf` | `https://fonts.gstatic.com/s/lobstertwo/v22/BngMUXZGTXPUvIoyV6yN59fK.ttf` | 228,208 | `4d775b0dcbede4e7363db94430ac600b05c57b75238df184fd9bad1cda36c4cb` | `LobsterTwo` | 349 | `OFL-LobsterTwo.txt` |
| `Lora-Regular.ttf` | `https://fonts.gstatic.com/s/lora/v37/0QI6MX1D_JOuGQbT0gvTJPa787weuyJG.ttf` | 132,188 | `1d37d1e34c77be80f0119754ad78df9aad30d5b1c78132a4cbdac0fe567f5d4f` | `Lora-Regular` | 888 | `OFL-Lora.txt` |
| `Merriweather-Regular.ttf` | `https://fonts.gstatic.com/s/merriweather/v33/u-4D0qyriQwlOrhSvowK_l5UcA6zuSYEqOzpPe3HOZJ5eX1WtLaQwmYiScCmDxhtNOKl8yDr3icqEw.ttf` | 585,976 | `e029d3b71e5bae3877c73f4f2b15af28db16593d49b0aed2a328d37ff7075846` | `Merriweather-Regular` | 1603 | `OFL-Merriweather.txt` |
| `Montserrat-Regular.ttf` | `https://fonts.gstatic.com/s/montserrat/v31/JTUHjIg1_i6t8kCHKm4532VJOt5-QNFgpCtr6Ew-.ttf` | 180,068 | `84f3d3275dfb159dd311c61828fd754a82ec31c377120518e2cd3e7d34394e96` | `Montserrat-Regular` | 1527 | `OFL-Montserrat.txt` |
| `Nunito-Regular.ttf` | `https://fonts.gstatic.com/s/nunito/v32/XRXI3I6Li01BKofiOc5wtlZ2di8HDLshRTM.ttf` | 125,528 | `9ecbdba35fa74f10a1a916c31649b802a12deb9e66c7b1fe4650afcfd4d16971` | `Nunito-Regular` | 1050 | `OFL-Nunito.txt` |
| `Oswald-Regular.ttf` | `https://fonts.gstatic.com/s/oswald/v57/TK3_WkUHHAIjg75cFRf3bXL8LICs1_FvgUE.ttf` | 86,068 | `bd6ff5a83bcdc92d7aac6dbb16e4dd2b0b0320bec6402bb81f5dd9735b500e46` | `Oswald-Regular` | 867 | `OFL-Oswald.txt` |
| `Pacifico-Regular.ttf` | `https://fonts.gstatic.com/s/pacifico/v23/FwZY7-Qmy14u9lezJ96A.ttf` | 251,232 | `0adbdce4f5422e632945cc29001dc19f0bbda1336626ca7ea9c921d49bcc0bf4` | `Pacifico-Regular` | 1191 | `OFL-Pacifico.txt` |
| `PlayfairDisplay-Regular.ttf` | `https://fonts.gstatic.com/s/playfairdisplay/v40/nuFvD-vYSZviVYUb_rj3ij__anPXJzDwcbmjWBN2PKdFvUDQ.ttf` | 123,240 | `1609a54fa3ad1abc8d0037132f73700333241ea0b65672079998e352f151dea7` | `PlayfairDisplay-Regular` | 756 | `OFL-PlayfairDisplay.txt` |
| `Poppins-Regular.ttf` | `https://fonts.gstatic.com/s/poppins/v24/pxiEyp8kv8JHgFVrFJA.ttf` | 154,628 | `cdedb1729acac414ed01744a11da7badb86adf13108e7bd3fa161b9323f7fe54` | `Poppins-Regular` | 1029 | `OFL-Poppins.txt` |
| `Quicksand-Regular.ttf` | `https://fonts.gstatic.com/s/quicksand/v37/6xK-dSZaM9iE8KbpRA_LJ3z8mH9BOJvgkP8o18E.ttf` | 73,224 | `0977c1d9781e03adfc1b120b3b60b6c4db776b5261e801ec881549cd17894351` | `Quicksand-Regular` | 754 | `OFL-Quicksand.txt` |
| `Raleway-Regular.ttf` | `https://fonts.gstatic.com/s/raleway/v37/1Ptxg8zYS_SKggPN4iEgvnHyvveLxVvaooCP.ttf` | 138,808 | `943300b002516feaf028c27aceaa2f473f2e1c0229ed913652a406d43277d9ba` | `Raleway-Regular` | 1018 | `OFL-Raleway.txt` |
| `Righteous-Regular.ttf` | `https://fonts.gstatic.com/s/righteous/v18/1cXxaUPXBpj2rGoU7C9mjw.ttf` | 40,364 | `82e2ac84900128219615a1e3a986a1821409e727e2bdb67714b2dcfe4447b946` | `Righteous-Regular` | 372 | `OFL-Righteous.txt` |
