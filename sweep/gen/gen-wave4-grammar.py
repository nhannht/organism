#!/usr/bin/env python3
"""Generate the four Phase-4 accuracy grids: timestamps, affiliated keywords, citations, table.el.

    usage: python3 sweep/gen/gen-wave4-grammar.py [--write]

Without `--write` it prints what it would create and touches nothing. After writing, the
answers come from the oracle as always:

    bash sweep/regen-expected.sh $(python3 sweep/gen/gen-wave4-grammar.py | awk '{print $2}')

## Why these four, and why grids

The sweep is the instrument that has broken "zero wrong trees" three times, and each time the
break came from a GRID nobody had hand-written, not from a cleverer single case. These four
families are where the benchmark competitors visibly simplify the grammar (go-org and uniorg
both flatten the timestamp grammar; none of them models affiliated attachment or table.el
boundaries fully), which makes them exactly the areas where this parser's fidelity claim needs
staged negatives, not prose.

Family by family, the axis that matters:

    ts-*    the timestamp grammar is a CROSS PRODUCT (kind x shape x repeater x warning) and
            every hand-written corpus samples it. The one org actually implements has corners
            like "repeater and warning in either order" and "time range collapses to one time
            when both ends are equal" that a sampled corpus never stages.
    aff-*   affiliated keywords interact with WHAT FOLLOWS: an element that accepts them, a
            blank line (attachment broken), a headline (cannot attach), end of buffer. The
            parsed-vs-dropped decision also depends on the KEY (CAPTION parses objects, ATTR_
            keeps strings) and on stacking/repetition.
    cit-*   the citation grammar's prefix/suffix/style/variant split is all delimiter
            positions: which `;` and `/` land where decides four different node shapes.
    tel-*   a table is org-flavoured or table.el-flavoured by its FIRST line, and everything
            after that is boundary questions: mixed rule styles, blank interruption,
            adjacency, TBLFM on the wrong flavour.
"""

import pathlib
import sys

CASES: list[tuple[str, str]] = []


def case(name: str, text: str) -> None:
    CASES.append((name, text))


# -- ts-*: the timestamp grammar grid ------------------------------------------------------

# kind x shape, bare
case("ts-act-date", "<2024-03-05 Tue>\n")
case("ts-act-datetime", "<2024-03-05 Tue 10:30>\n")
case("ts-act-timerange", "<2024-03-05 Tue 10:30-12:00>\n")
case("ts-act-daterange", "<2024-03-05 Tue>--<2024-03-07 Thu>\n")
case("ts-act-dtrange", "<2024-03-05 Tue 10:30>--<2024-03-07 Thu 12:00>\n")
case("ts-ina-date", "[2024-03-05 Tue]\n")
case("ts-ina-datetime", "[2024-03-05 Tue 10:30]\n")
case("ts-ina-timerange", "[2024-03-05 Tue 10:30-12:00]\n")
case("ts-ina-daterange", "[2024-03-05 Tue]--[2024-03-07 Thu]\n")
# a time "range" whose ends are equal, and one crossing midnight
case("ts-timerange-equal", "<2024-03-05 Tue 10:30-10:30>\n")
case("ts-timerange-late", "<2024-03-05 Tue 23:00-1:00>\n")
# repeaters, all three kinds, both timestamp kinds
case("ts-rep-plus", "<2024-03-05 Tue +1w>\n")
case("ts-rep-plusplus", "<2024-03-05 Tue ++2d>\n")
case("ts-rep-dotplus", "<2024-03-05 Tue .+3m>\n")
case("ts-ina-rep", "[2024-03-05 Tue +1y>]\n")
# warnings, both kinds
case("ts-warn", "<2024-03-05 Tue -2d>\n")
case("ts-warn-first", "<2024-03-05 Tue --3h>\n")
# repeater and warning together, both orders
case("ts-rep-warn", "<2024-03-05 Tue +1w -2d>\n")
case("ts-warn-rep", "<2024-03-05 Tue -2d +1w>\n")
case("ts-time-rep-warn", "<2024-03-05 Tue 10:30 +1w -2d>\n")
# no dayname, wrong dayname, unicode dayname: the dayname is free text
case("ts-nodayname", "<2024-03-05>\n")
case("ts-dayname-full", "<2024-03-05 Tuesday 10:30>\n")
case("ts-dayname-uni", "<2024-03-05 Thü>\n")
# shapes that must NOT be timestamps
case("ts-bad-month", "<2024-13-05 Tue>\n")
case("ts-bad-shape", "<2024-3-5>\n")
case("ts-unclosed", "<2024-03-05 Tue\n")
case("ts-empty", "<>\n")
# diary sexp timestamp
case("ts-diary", "<%%(diary-float t 4 2)>\n")
case("ts-diary-mid", "a <%%(org-anniversary 2000 3 5)> b\n")
# positions: mid-paragraph, headline title, planning, clock
case("ts-mid-para", "before <2024-03-05 Tue> after\n")
case("ts-in-title", "* meet <2024-03-05 Tue 10:30>\n")
case("ts-planning-all", "* h\nSCHEDULED: <2024-03-05 Tue> DEADLINE: <2024-03-09 Sat -1d> CLOSED: [2024-03-04 Mon 09:00]\n")
case("ts-clock-range", "CLOCK: [2024-03-05 Tue 09:00]--[2024-03-05 Tue 11:30] =>  2:30\n")
# seconds and single-digit hour
case("ts-seconds", "<2024-03-05 Tue 10:30:45>\n")
case("ts-hour-one-digit", "<2024-03-05 Tue 9:05>\n")
# the envelope is LAX and the closer class is [ ] > ] regardless of the opener: the KIND comes
# from the opener alone, and a `]` in the free text CLOSES an active timestamp
case("ts-mixed-close-act", "<2024-03-05 Tue] x\n")
case("ts-mixed-close-ina", "[2024-03-05 Tue> x\n")
case("ts-bracket-in-text", "<2024-03-05 a]b>\n")
# a date range's second half may use EITHER bracket, and a repeater in the second half is
# scraped from the whole raw value
case("ts-range-mixed", "<2024-03-05>--[2024-03-07]\n")
case("ts-range-second-rep", "<2024-03-05>--<2024-03-07 +1w>\n")
# repeater deadline form, and modifiers glued to the dayname
case("ts-rep-deadline", "<2024-03-05 Tue +1w/2d>\n")
case("ts-warn-glued", "<2024-03-05 Tue-2d>\n")
# dayname is a SCRAPE, not a token: ASCII letters immediately after the date's spaces
case("ts-day-digit-split", "<2024-03-05 T2e>\n")
case("ts-day-punct", "<2024-03-05 !x>\n")
case("ts-nospace-text", "<2024-03-05x>\n")
case("ts-double-space", "<2024-03-05  Tue>\n")
# diary tolerates junk between the sexp and the closer; nesting is greedy, not balanced
case("ts-diary-junk", "<%%(a) b>\n")
case("ts-diary-nested", "<%%(a(b)c)>\n")
case("ts-diary-time", "<%%(diary-float t 4 2) 10:30>\n")
# the separator after the date is a literal SPACE: a tab is no timestamp at all
case("ts-tab-sep", "<2024-03-05\tTue>\n")
# NOT a case, recorded here instead: `<99-1-1 +1d>` passes org-element's lexer gate (the
# second `org-element--timestamp-regexp` alternative accepts 1+ digits when a repeater
# follows) and then CRASHES org-element-parse-buffer outright - `org-parse-time-string`
# signals "Not an Org time string". The reference produces NO tree for any buffer containing
# that form, so no expected answer can exist and no sweep case can be stored. Measured
# 2026-08-08 on Emacs 30.2 / org 9.7.11. organism reads it as plain text.

# -- aff-*: affiliated keywords against what follows ---------------------------------------

# each key, attaching to a paragraph
case("aff-caption-para", "#+CAPTION: a *b* c\npara\n")
case("aff-caption-short", "#+CAPTION[s *t*]: long *u*\npara\n")
case("aff-name-para", "#+NAME: n1\npara\n")
case("aff-plot-para", "#+PLOT: set terminal png\npara\n")
case("aff-results-para", "#+RESULTS: label\npara\n")
case("aff-results-hash", "#+RESULTS[abc123]: label\npara\n")
case("aff-header-para", "#+HEADER: :var x=1\npara\n")
case("aff-attr-para", "#+ATTR_HTML: :width 100\npara\n")
case("aff-attr-odd-backend", "#+ATTR_X9-Y: :a b\npara\n")
# the same keys attaching to a table (the classic caption target)
case("aff-caption-table", "#+CAPTION: t\n| a |\n")
case("aff-name-table", "#+NAME: tbl\n| a |\n")
# stacking and repetition
case("aff-two-captions", "#+CAPTION: one\n#+CAPTION: two\npara\n")
case("aff-caption-name", "#+CAPTION: c\n#+NAME: n\npara\n")
case("aff-two-headers", "#+HEADER: :var a=1\n#+HEADER: :var b=2\n#+BEGIN_SRC sh\nx\n#+END_SRC\n")
case("aff-two-attr", "#+ATTR_HTML: :a 1\n#+ATTR_HTML: :b 2\npara\n")
case("aff-dual-two", "#+CAPTION[s1]: l1\n#+CAPTION[s2]: l2\npara\n")
# attachment BREAKERS
case("aff-blank-breaks", "#+CAPTION: c\n\npara\n")
case("aff-before-headline", "#+CAPTION: c\n* h\n")
case("aff-at-eof", "#+CAPTION: c\n")
case("aff-before-comment", "#+CAPTION: c\n# comment\npara\n")
case("aff-before-keyword", "#+CAPTION: c\n#+TODO: A B\npara\n")
case("aff-before-fixed", "#+CAPTION: c\n: fixed\n")
# case and empty values
case("aff-lowercase", "#+caption: c\npara\n")
case("aff-empty-value", "#+CAPTION:\npara\n")
case("aff-attr-empty", "#+ATTR_HTML:\npara\n")
# non-affiliated lookalikes
case("aff-attr-no-backend", "#+ATTR_: :a 1\npara\n")
case("aff-caption-inside-item", "- #+CAPTION: c\n  para\n")

# -- cit-*: citation delimiter positions ---------------------------------------------------

case("cit-min", "[cite:@k]\n")
case("cit-style", "[cite/apa:@k]\n")
case("cit-style-variant", "[cite/apa/full:@k]\n")
case("cit-style-punct", "[cite/a_b-c:@k]\n")
case("cit-style-empty", "[cite/:@k]\n")
case("cit-global-prefix", "[cite:see ;@k]\n")
case("cit-global-suffix", "[cite:@k; p. 7]\n")
case("cit-both-globals", "[cite:see ;@k; p. 7]\n")
case("cit-ref-prefix", "[cite:pre @k]\n")
case("cit-ref-suffix", "[cite:@k post]\n")
case("cit-ref-both", "[cite:pre @k post]\n")
case("cit-multi", "[cite:@a;@b;@c]\n")
case("cit-multi-mixed", "[cite:see ;pre @a post;@b tail; end]\n")
case("cit-semi-only", "[cite:;@k]\n")
case("cit-trailing-semi", "[cite:@k;]\n")
case("cit-no-key", "[cite:nokey]\n")
case("cit-at-alone", "[cite:@]\n")
case("cit-key-punct", "[cite:@k.:?!]\n")
case("cit-key-slash", "[cite:@a/b]\n")
case("cit-prefix-bold", "[cite:*b* ;@k]\n")
case("cit-suffix-code", "[cite:@k; see ~f()~]\n")
case("cit-in-item", "- [cite:@k]\n")
case("cit-space-before-colon", "[cite :@k]\n")
case("cit-double-at", "[cite:@@k]\n")
case("cit-uni-key", "[cite:@café]\n")

# -- tel-*: the org / table.el flavour boundary --------------------------------------------

case("tel-min", "+-+\n|a|\n+-+\n")
case("tel-no-close", "+-+\n|a|\n")
case("tel-rule-only", "+-+\n")
case("tel-plus-alone", "+\n")
case("tel-plus-text", "+x\n")
case("tel-double-rule", "+-+\n+-+\n")
case("tel-indented", "  +-+\n  |a|\n  +-+\n")
case("tel-in-item", "- +-+\n  |a|\n  +-+\n")
case("tel-blank-splits", "+-+\n|a|\n\n|b|\n")
case("tel-org-first", "| o |\n+-+\n| p |\n")
case("tel-after-org", "| o |\n\n+-+\n|a|\n+-+\n")
case("tel-adjacent-org", "| o |\n+-+\n")
case("tel-tblfm", "+-+\n|a|\n+-+\n#+TBLFM: $1=2\n")
case("tel-org-tblfm-control", "| a |\n#+TBLFM: $1=2\n")
case("tel-caption", "#+CAPTION: c\n+-+\n|a|\n+-+\n")
case("tel-rule-junk", "+-+ x\n|a|\n")
case("tel-wide", "+---+---+\n| a | b |\n+---+---+\n")
case("tel-mixed-tail", "+-+\n|a|\nplain\n")


def main() -> None:
    write = "--write" in sys.argv
    cases_dir = pathlib.Path(__file__).resolve().parent.parent / "cases"
    names = [n for n, _ in CASES]
    assert len(names) == len(set(names)), "duplicate case name"
    for name, text in CASES:
        path = cases_dir / f"{name}.org"
        if write:
            path.write_text(text, encoding="utf-8")
        print(f"{'wrote' if write else 'would write'} {name}")
    print(f"== {len(CASES)} cases ==", file=sys.stderr)


if __name__ == "__main__":
    main()
