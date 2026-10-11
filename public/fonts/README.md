# Black Team bundled fonts

These assets are served with the app. The interface does not contact a font CDN,
Google Fonts, or any other external font service. CSS family aliases are defined
in `src/atmosphere.css` so desktop and Companion (including iPhone and Android) share the same
typography.

| File | Role | Origin | Bytes |
| --- | --- | --- | ---: |
| `adwaita-sans-variable.woff2` | Body, forms and cards; weights 100–900 | Installed Adwaita Sans variable font, converted to WOFF2 | 350704 |
| `jetbrains-mono-regular.woff2` | Command headings, status labels and code | Installed Hermes terminal font bundle; unmodified JetBrains Mono 2.305 | 92380 |
| `jetbrains-mono-bold.woff2` | Bold technical text | Installed Hermes terminal font bundle; unmodified JetBrains Mono 2.305 | 94628 |

Adwaita Sans is derived from Inter. The installed source was
`/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf`; its complete package license is
included as `Adwaita-OFL.txt`. WOFF2 conversion used the local `woff2_compress`
tool, preserving the full font's language coverage and variable weights.

The JetBrains files were copied from the installed Hermes
`hermes_cli/web_dist/fonts-terminal/` bundle. Their font name and embedded
copyright/license records identify JetBrains Mono and the SIL Open Font License,
Version 1.1. The matching license is included as `JetBrainsMono-OFL.txt`. These
are the plain fonts, without the much larger Nerd Font icon set.

All three fonts are distributed under the SIL Open Font License 1.1. Copyright
notices and license terms are preserved in the accompanying files and font
metadata. The fonts are bundled with Black Team and are not sold separately.
