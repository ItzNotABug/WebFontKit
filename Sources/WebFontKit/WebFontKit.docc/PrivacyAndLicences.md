# Privacy and licences

What the default source sends, and what the font licences ask.

## Privacy

Every download from the default source sends the user's IP address, the requested URL and HTTP headers to Google. Google says the Fonts API sets no cookies and is not used for profiling or advertising, but a German court has held that loading Google Fonts without consent breached GDPR (LG München I, 20 January 2022, 3 O 17493/20). Say so in your privacy policy, or serve the files from your own server with ``HostedFontSource`` or a custom source. WebFontKit collects no data itself.

## Licences

Google Fonts are open-licensed (SIL OFL, Apache 2.0, a few UFL), so apps may use them. The OFL and Apache licences require the copyright notice and licence to travel with redistributed font files, for example a self-hoster's. They do not require on-screen credit. The files the default source downloads carry no licence text.
