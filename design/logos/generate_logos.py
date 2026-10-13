#!/usr/bin/env python3
"""Generate Nidhi logo SVGs — 4 concepts x 12 Indian scripts -> design/logos/<concept>/.

Colors are the app's Zen palette (Nidhi/Theme.swift). Text uses system Indic
fonts; before shipping as an app icon, convert text to outlines (e.g. open in a
browser and print to PDF, or use a font tool) so rendering is font-independent.
Re-run:  python3 design/logos/generate_logos.py
"""
import os

ACCENT, DEEP, SAGE, SAGE_DEEP, INK = "#6E9BD8", "#4F7FC4", "#7FC4A3", "#5BA585", "#151A22"
FONT = "'Kohinoor Devanagari','Noto Sans',-apple-system,sans-serif"

# (slug, language label, word, first-akshara, BCP-47 lang)
SCRIPTS = [
    ("devanagari", "Hindi · Marathi · Sanskrit · Nepali", "निधि", "नि", "hi"),
    ("bengali",    "Bengali · Assamese",                  "নিধি", "নি", "bn"),
    ("gujarati",   "Gujarati",                            "નિધિ", "નિ", "gu"),
    ("gurmukhi",   "Punjabi (Gurmukhi)",                  "ਨਿਧੀ", "ਨਿ", "pa"),
    ("odia",       "Odia",                                "ନିଧି", "ନି", "or"),
    ("tamil",      "Tamil",                               "நிதி", "நி", "ta"),
    ("telugu",     "Telugu",                              "నిధి", "ని", "te"),
    ("kannada",    "Kannada",                             "ನಿಧಿ", "ನಿ", "kn"),
    ("malayalam",  "Malayalam",                           "നിധി", "നി", "ml"),
    ("urdu",       "Urdu",                                "نِدھی", "ن", "ur"),
    ("meitei",     "Manipuri (Meetei Mayek)",             "ꯅꯤꯙꯤ", "ꯅꯤ", "mni"),
    ("latin",      "English",                             "Nidhi", "N", "en"),
]

DEFS = f"""<defs>
  <linearGradient id="zen" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{ACCENT}"/><stop offset="1" stop-color="{DEEP}"/>
  </linearGradient>
  <linearGradient id="calm" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{ACCENT}"/><stop offset="1" stop-color="{SAGE_DEEP}"/>
  </linearGradient>
</defs>"""


def coin(word, akshara, lang):
    """A. Coin — the akshara struck on a coin, wordmark beside it."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 420 140" lang="{lang}">{DEFS}
  <circle cx="70" cy="70" r="54" fill="none" stroke="url(#zen)" stroke-width="7"/>
  <circle cx="70" cy="70" r="41" fill="none" stroke="url(#zen)" stroke-width="1.5" opacity="0.45"/>
  <circle cx="70" cy="16" r="5" fill="{SAGE}"/>
  <text x="70" y="74" font-family="{FONT}" font-size="42" font-weight="600" fill="{DEEP}"
        text-anchor="middle" dominant-baseline="middle">{akshara}</text>
  <text x="150" y="74" font-family="{FONT}" font-size="56" font-weight="600" fill="{INK}"
        dominant-baseline="middle">{word}</text>
</svg>"""


def kalasha(word, lang):
    """B. Kalasha — the treasure pot; mark is script-independent, wordmark below."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 260 220" lang="{lang}">{DEFS}
  <path d="M 90 62 Q 84 54 92 50 L 168 50 Q 176 54 170 62 Q 196 78 196 112
           Q 196 152 130 152 Q 64 152 64 112 Q 64 78 90 62 Z" fill="url(#zen)"/>
  <circle cx="112" cy="34" r="8" fill="{SAGE}"/>
  <circle cx="130" cy="26" r="8" fill="{SAGE_DEEP}"/>
  <circle cx="148" cy="34" r="8" fill="{SAGE}"/>
  <path d="M 88 96 Q 130 116 172 96" stroke="#FFFFFF" stroke-width="5"
        fill="none" opacity="0.55" stroke-linecap="round"/>
  <text x="130" y="196" font-family="{FONT}" font-size="40" font-weight="600" fill="{INK}"
        text-anchor="middle">{word}</text>
</svg>"""


def wordmark(word, lang):
    """C. Wordmark + sprout — pure type, one sage leaf rising off the word."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 420 150" lang="{lang}">{DEFS}
  <text x="40" y="98" font-family="{FONT}" font-size="64" font-weight="600"
        fill="url(#zen)">{word}</text>
  <path d="M 348 52 Q 348 30 368 26 Q 372 46 354 54 Z" fill="{SAGE}"/>
  <path d="M 350 58 Q 352 44 350 34" stroke="{SAGE_DEEP}" stroke-width="3"
        fill="none" stroke-linecap="round"/>
  <rect x="40" y="118" width="200" height="4" rx="2" fill="url(#calm)" opacity="0.6"/>
</svg>"""


def tile(akshara, lang):
    """D. Tile — app-icon treatment, akshara reversed out of the calm gradient."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 160" lang="{lang}">{DEFS}
  <rect x="8" y="8" width="144" height="144" rx="34" fill="url(#calm)"/>
  <text x="80" y="86" font-family="{FONT}" font-size="64" font-weight="600" fill="#FFFFFF"
        text-anchor="middle" dominant-baseline="middle">{akshara}</text>
  <circle cx="80" cy="132" r="4" fill="#FFFFFF" opacity="0.7"/>
</svg>"""


here = os.path.dirname(os.path.abspath(__file__))
count = 0
for slug, label, word, akshara, lang in SCRIPTS:
    for concept, svg in [("coin", coin(word, akshara, lang)),
                         ("kalasha", kalasha(word, lang)),
                         ("wordmark", wordmark(word, lang)),
                         ("tile", tile(akshara, lang))]:
        d = os.path.join(here, concept)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"nidhi-{slug}.svg"), "w") as f:
            f.write(svg + "\n")
        count += 1
print(f"wrote {count} SVGs across 4 concepts x {len(SCRIPTS)} scripts")
