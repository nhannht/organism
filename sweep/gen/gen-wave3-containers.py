#!/usr/bin/env python3
"""Generate the container cross-product for the four object types Wave 2b/2c landed.

    usage: python3 sweep/gen/gen-wave3-containers.py [--write]

Without `--write` it prints what it would create and touches nothing.

## Why a cross product, and why THIS one

`org-element-object-restrictions` is a per-container table: which object types may be lexed
inside a given container. It is the single richest source of silent wrong trees this project has
found. ORG-23 shipped FIVE of them to the public repository -- a plain link or a timestamp
written directly in a link DESCRIPTION built a nested node where org emits plain text -- and it
warned that every object type landing afterwards would become a new wrong tree of the same class
until it was covered.

Four object types have landed since: `inline-src-block`, `inline-babel-call`, `citation` and,
through the citation, `citation-reference`. Each one is permitted by some rows of that table and
refused by others, and nothing in the corpus probed any of them anywhere but a paragraph. So
this generator writes one case per (container, object) pair and lets the oracle answer.

The DECLINE cases are the point. A container that refuses the object must produce plain text --
`| src_py{q} |` is text plus a subscript, not an inline-src-block -- and a parser that ignored
the restriction table would pass every permitted case and fail exactly these.

Element-position cases follow the same idea one layer up: `diary-sexp` and `babel-call` are
elements, so the axis is WHERE they sit rather than what lexes them.
"""

import pathlib
import sys

# (name, template) -- `{}` is where the object goes. Each template's container is the thing
# whose restriction row decides the answer, which is NOT always the outermost construct: a bold
# inside a table cell is lexed under `bold`'s row, not the cell's (see ObjectContainer).
CONTAINERS = [
    ("para", "a {} b\n"),
    ("bold", "*a {} b*\n"),
    ("ital", "/a {} b/\n"),
    ("undr", "_a {} b_\n"),
    ("strk", "+a {} b+\n"),
    ("head", "* a {} b\n"),
    ("itag", "- a {} b :: d\n"),
    ("cell", "| a {} b |\n"),
    ("radio", "<<<a {} b>>>\n"),
    ("ldesc", "[[http://x][a {} b]]\n"),
    ("fnref", "[fn::a {} b]\n"),
    ("verse", "#+begin_verse\na {} b\n#+end_verse\n"),
    ("capt", "#+CAPTION: a {} b\npara\n"),
    ("sub", "x_{{a {} b}}\n"),
    ("sup", "x^{{a {} b}}\n"),
    ("citpre", "[cite:a {} b; @k]\n"),
    ("citsuf", "[cite:@k; a {} b]\n"),
    ("target", "<<a {} b>>\n"),
]

OBJECTS = [
    ("src", "src_py{q}"),
    ("call", "call_f()"),
    ("cite", "[cite:@k]"),
]

# (name, template) -- `{}` is the element's own line. An element's axis is position, not lexing.
ELEMENT_POSITIONS = [
    ("top", "{}\n"),
    ("item", "- x\n  {}\n"),
    ("quote", "#+begin_quote\n{}\n#+end_quote\n"),
    ("fndef", "[fn:1] body\n{}\n"),
    ("drawer", ":D:\n{}\n:END:\n"),
    ("headsec", "* H\n{}\n"),
    ("affil", "#+NAME: n\n{}\n"),
    ("aftpara", "para\n{}\n"),
]

ELEMENTS = [
    ("diary", "%%(diary-float t 4 2)"),
    ("bcall", "#+CALL: f()"),
]


def main() -> int:
    write = "--write" in sys.argv[1:]
    root = pathlib.Path(__file__).resolve().parent.parent / "cases"
    if not root.is_dir():
        print(f"no sweep/cases at {root}", file=sys.stderr)
        return 2

    planned: list[tuple[str, str]] = []
    for object_name, object_text in OBJECTS:
        for container_name, template in CONTAINERS:
            planned.append((f"w3o-{object_name}-{container_name}", template.format(object_text)))
    for element_name, element_text in ELEMENTS:
        for position_name, template in ELEMENT_POSITIONS:
            planned.append((f"w3e-{element_name}-{position_name}",
                            template.format(element_text)))

    created = 0
    for name, text in planned:
        path = root / f"{name}.org"
        if path.exists():
            continue
        created += 1
        if write:
            path.write_text(text, encoding="utf-8")

    verb = "wrote" if write else "would write"
    print(f"== gen-wave3-containers.py: {verb} {created} new cases "
          f"({len(planned)} planned, {len(planned) - created} already present) ==")
    if not write:
        print("re-run with --write, then `bash sweep/regen-expected.sh` for org's answers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
