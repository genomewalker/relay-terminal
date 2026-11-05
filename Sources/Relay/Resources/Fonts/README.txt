Obel Mono 1.000
===============

A monospaced typeface for terminals, code and agents, from Typographic Systems.
Masking (ss01), Handwritten (ss02, or cv02-cv09 one letter at a time), the dotted zero (cv01) and the alternates cv10-cv14 are opt-in.

variable/  the variable fonts (weight 100-900), roman and italic - install these
static/    every named weight as its own file, for apps without variable fonts

Install
  macOS     double-click the variable TTFs
  Linux     copy the variable TTFs to ~/.local/share/fonts/obel-mono/ and run fc-cache -f
  Windows   right-click the variable TTFs, Install
  Or, on macOS and Linux, install both builds with one line:
    curl -fsSL https://typographic.systems/install.sh | sh

Web
  Host the WOFF2 files and obel-mono.css yourself (they're in the WOFF2 download), then:
  font-family: "Obel Mono", monospace;

License: SIL Open Font License 1.1 (OFL.txt), no Reserved Font Name.
Authors: AUTHORS.txt.  More: https://typographic.systems/obel-mono/
