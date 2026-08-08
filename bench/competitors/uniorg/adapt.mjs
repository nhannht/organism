// uniorg accuracy adapter (see bench/accuracy/README.md for the fairness protocol):
//   node adapt.mjs <file.org>
// parses the file with uniorg-parse (same installed package the speed runner times) and
// re-encodes uniorg's AST into this repo's schema shape (schema/org-node.schema.json).
//
// The adapter is a pure re-encoder. It maps only what uniorg's own AST carries:
//   - type/enum renames (org-data -> document, plain-list -> list, rowType -> kind, ...)
//   - the section/headline nesting inversion (uniorg wraps a whole subtree in `section` with
//     the headline as its first child; org-element nests a `section` INSIDE the headline)
//   - whitespace bookkeeping: org-element's postBlank/preBlank are re-derived from uniorg's
//     own node positions (trackPosition: true) by counting whitespace in inter-node gaps,
//     and by moving the leading spaces uniorg keeps in a following text node onto the
//     preceding object, which is org-element's own canonical form of the same bytes.
// It never re-parses org syntax from the source or from raw-value string fields, and it
// never copies non-whitespace source bytes into the tree. Information uniorg's AST does not
// carry (timestamp daynames/repeaters/delays, example-block switches, ...) is emitted as
// null/absent and graded honestly against the reference tree.

import { readFileSync } from 'node:fs';
import { parse } from 'uniorg-parse/lib/parser.js';

const file = process.argv[2];
if (!file) {
  console.error('usage: node adapt.mjs <file.org>');
  process.exit(1);
}
const src = readFileSync(file, 'utf8');
const root = parse(src, { trackPosition: true });

const pStart = (n) => n.position.start.offset;
const pEnd = (n) => n.position.end.offset;

// Where trailing-blank counting starts after a node: uniorg's end positions are
// inconsistent about the node's own final line (headlines stop before the tags, several
// value elements stop before their final newline), so skip to the next line start whenever
// the extent stopped mid-line.
function nextLineStart(end) {
  if (end > 0 && src[end - 1] === '\n') return end;
  const nl = src.indexOf('\n', end);
  return nl === -1 ? src.length : nl + 1;
}

// Count completely blank lines ([ \t]* + newline) in [i, bound). Non-blank lines in the
// region (bytes uniorg dropped from its tree, e.g. affiliated lines on elements that
// cannot carry them) are skipped, not counted.
function blankLinesFrom(i, bound) {
  let n = 0;
  while (i < bound) {
    let j = i;
    while (j < bound && (src[j] === ' ' || src[j] === '\t')) j++;
    if (j < bound && src[j] === '\n') {
      n++;
      i = j + 1;
    } else {
      const nl = src.indexOf('\n', j);
      if (nl === -1 || nl >= bound) break;
      i = nl + 1;
    }
  }
  return n;
}

const countNL = (a, b) => {
  let n = 0;
  for (let i = a; i < b; i++) if (src[i] === '\n') n++;
  return n;
};

// Blank lines between an element and the next sibling's start (or the container bound).
const blanksAfter = (n, gapEnd) => blankLinesFrom(nextLineStart(pEnd(n)), gapEnd);

// Blank lines between a node's first line and its first content child (headline/item
// preBlank). 0 when the content starts on the node's own first line.
function preBlankOf(node, firstChild) {
  if (!firstChild) return 0;
  const lineEnd = src.indexOf('\n', pStart(node));
  if (lineEnd === -1 || pStart(firstChild) <= lineEnd) return 0;
  return blankLinesFrom(lineEnd + 1, pStart(firstChild));
}

// ---- objects ----------------------------------------------------------------------------

// Map an object-context child list. uniorg keeps the spaces after an inline object at the
// head of the FOLLOWING text node; org-element's canonical form is postBlank on the object.
// Same data, moved. Whitespace that uniorg consumed into a positional gap between objects
// (statistics-cookie does this) is counted from the gap instead.
function mapObjects(nodes, endBound) {
  const out = [];
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    if (n.type === 'text') {
      if (n.value !== '') out.push({ type: 'text', value: n.value });
      continue;
    }
    const mapped = mapObject(n);
    if (mapped === null) continue;
    let pb;
    if (typeof n.postBlank === 'number') {
      pb = n.postBlank;
    } else {
      const next = nodes[i + 1];
      const gapEnd = next ? pStart(next) : endBound;
      let ws = 0;
      for (let k = pEnd(n); k < gapEnd; k++) {
        if (src[k] === ' ' || src[k] === '\t') ws++;
        else break;
      }
      pb = ws;
      if (next && next.type === 'text') {
        const m = next.value.match(/^[ \t]+/);
        if (m && ws === 0) {
          pb += m[0].length;
          next.value = next.value.slice(m[0].length);
        }
      }
    }
    if (mapped.type !== 'text') mapped.postBlank = pb;
    out.push(mapped);
  }
  return out;
}

function mapDate(d) {
  if (!d) return null;
  return { year: d.year, month: d.month, day: d.day, dayname: null, hour: d.hour, minute: d.minute };
}

function mapTimestamp(n) {
  const t = {
    type: 'timestamp',
    kind: n.timestampType,
    rangeType: null,
    start: mapDate(n.start),
    end: mapDate(n.end),
    repeater: null,
    delay: null,
  };
  // uniorg does not expose the diary sexp, the range source form, daynames, repeaters or
  // delays as structured data (only inside rawValue, which this adapter treats as opaque).
  return t;
}

function mapObject(n) {
  switch (n.type) {
    case 'bold':
    case 'italic':
    case 'underline':
      return { type: n.type, children: mapObjects(n.children, n.contentsEnd ?? pEnd(n)) };
    case 'strike-through':
      return { type: 'strikethrough', children: mapObjects(n.children, n.contentsEnd ?? pEnd(n)) };
    case 'code':
    case 'verbatim':
      return { type: n.type, value: n.value };
    case 'entity':
      return { type: 'entity', name: n.name, useBrackets: n.useBrackets };
    case 'latex-fragment':
      return { type: 'latex-fragment', value: n.value };
    case 'export-snippet':
      return { type: 'export-snippet', backEnd: n.backEnd, value: n.value };
    case 'line-break':
      return { type: 'line-break' };
    case 'statistics-cookie':
      return { type: 'statistics-cookie', value: n.value };
    case 'subscript':
    case 'superscript':
      return {
        type: n.type,
        useBrackets: (n.contentsBegin ?? pStart(n) + 1) - pStart(n) === 2,
        children: mapObjects(n.children, n.contentsEnd ?? pEnd(n)),
      };
    case 'timestamp':
      return mapTimestamp(n);
    case 'footnote-reference': {
      const o = { type: 'footnote-reference', label: n.label, inline: n.footnoteType === 'inline' };
      if (o.inline) o.children = mapObjects(n.children, n.contentsEnd ?? pEnd(n));
      return o;
    }
    case 'link': {
      const fmt = { bracket: 'regular', plain: 'plain', angle: 'angle' }[n.format] ?? n.format;
      return {
        type: 'link',
        linkType: fmt,
        pathType: n.linkType,
        path: n.rawLink,
        description: n.children && n.children.length ? mapObjects(n.children, n.contentsEnd ?? pEnd(n)) : null,
      };
    }
    case 'citation': {
      // citation sub-nodes carry no positions in uniorg; map them position-free
      let prefix = null;
      let suffix = null;
      const refs = [];
      for (const c of n.children ?? []) {
        if (c.type === 'citation-common-prefix') prefix = orNull(mapAffObjects(c.children));
        else if (c.type === 'citation-common-suffix') suffix = orNull(mapAffObjects(c.children));
        else if (c.type === 'citation-reference') refs.push(mapCitationRef(c));
      }
      return { type: 'citation', style: n.style ?? null, prefix, suffix, children: refs };
    }
    case 'table-cell':
      return { type: 'table-cell', children: mapObjects(n.children, n.contentsEnd ?? pEnd(n)) };
    default:
      // An object kind with no schema slot; emit nothing and let the diff record the loss.
      return null;
  }
}

const orNull = (arr) => (arr && arr.length ? arr : null);

function mapCitationRef(c) {
  let prefix = null;
  let suffix = null;
  for (const k of c.children ?? []) {
    if (k.type === 'citation-prefix') prefix = orNull(mapAffObjects(k.children));
    else if (k.type === 'citation-suffix') suffix = orNull(mapAffObjects(k.children));
  }
  return { type: 'citation-reference', key: c.key, prefix, suffix, postBlank: 0 };
}

// ---- affiliated keywords ----------------------------------------------------------------

const isNode = (x) => x && typeof x === 'object' && !Array.isArray(x) && typeof x.type === 'string';

// A parsed secondary string from uniorg's affiliated storage: an ObjectType[] with no
// reliable positions, so postBlank falls back to the moved-prefix rule only.
function mapAffObjects(objs) {
  const out = [];
  for (let i = 0; i < objs.length; i++) {
    const n = objs[i];
    if (n.type === 'text') {
      if (n.value !== '') out.push({ type: 'text', value: n.value });
      continue;
    }
    const mapped = mapAffObject(n);
    if (mapped === null) continue;
    let pb = 0;
    const next = objs[i + 1];
    if (next && next.type === 'text') {
      const m = next.value.match(/^[ \t]+/);
      if (m) {
        pb = m[0].length;
        next.value = next.value.slice(m[0].length);
      }
    }
    if (mapped.type !== 'text') mapped.postBlank = pb;
    out.push(mapped);
  }
  return out;
}

function mapAffObject(n) {
  switch (n.type) {
    case 'bold':
    case 'italic':
    case 'underline':
      return { type: n.type, children: mapAffObjects(n.children) };
    case 'strike-through':
      return { type: 'strikethrough', children: mapAffObjects(n.children) };
    case 'code':
    case 'verbatim':
      return { type: n.type, value: n.value };
    case 'entity':
      return { type: 'entity', name: n.name, useBrackets: n.useBrackets };
    case 'latex-fragment':
      return { type: 'latex-fragment', value: n.value };
    default:
      return isNode(n) ? mapObject(n) : null;
  }
}

function mapAffiliated(aff) {
  if (!aff) return undefined;
  const entries = [];
  for (const [key, raw] of Object.entries(aff)) {
    if (key === 'CAPTION') {
      const values = normalizeCaptionValues(raw);
      entries.push({
        key,
        value: values.map((v) => {
          if (isDualTuple(v)) {
            const short = v[1];
            return {
              long: mapAffObjects(v[0]),
              short: short === '' || short == null
                ? null
                : (Array.isArray(short) ? mapAffObjects(short) : [{ type: 'text', value: short }]),
            };
          }
          return { long: mapAffObjects(v), short: null };
        }),
      });
    } else if (key === 'RESULTS') {
      if (Array.isArray(raw) && raw.length === 2 && typeof raw[0] === 'string' && typeof raw[1] === 'string') {
        entries.push({ key, value: { value: raw[0], hash: raw[1] } });
      } else if (typeof raw === 'string') {
        entries.push({ key, value: { value: raw, hash: null } });
      } else {
        entries.push({ key, value: raw });
      }
    } else if (key === 'HEADER' || key.startsWith('ATTR_')) {
      entries.push({ key, value: Array.isArray(raw) ? raw : [raw] });
    } else {
      entries.push({ key, value: Array.isArray(raw) && raw.length === 1 ? raw[0] : raw });
    }
  }
  return entries.length ? entries : undefined;
}

const isDualTuple = (v) =>
  Array.isArray(v) && v.length === 2 && Array.isArray(v[0]) && !isNode(v[1]);

function normalizeCaptionValues(raw) {
  if (!Array.isArray(raw)) return [raw];
  if (raw.length && isNode(raw[0])) return [raw]; // single plain parsed value
  if (isDualTuple(raw) && raw[0].every?.((x) => isNode(x) || typeof x === 'string')) {
    // single dual value [[objects], "short"]
    if (typeof raw[1] === 'string') return [raw];
  }
  return raw; // already a list of values
}

// ---- elements ---------------------------------------------------------------------------

function withAff(schema, n) {
  const aff = mapAffiliated(n.affiliated);
  if (aff) schema.affiliated = aff;
  return schema;
}

// The start of an item's internal trailing gap: after its last child, or after its own
// first (bullet) line when it has no children.
function itemGapStart(item) {
  const kids = item.children ?? [];
  const last = kids[kids.length - 1];
  if (last && last.position) return nextLineStart(pEnd(last));
  const lineEnd = src.indexOf('\n', pStart(item));
  return lineEnd === -1 ? pEnd(item) : lineEnd + 1;
}

function mapList(n, gapEnd) {
  const items = n.children ?? [];
  const mappedItems = [];
  let hoist = 0;
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const last = i === items.length - 1;
    const internal = countNL(itemGapStart(item), last ? pEnd(item) : pStart(items[i + 1]));
    if (last) hoist = internal;
    mappedItems.push(mapItem(item, last ? 0 : internal));
  }
  return withAff(
    {
      type: 'list',
      kind: n.listType,
      children: mappedItems,
      postBlank: hoist + blanksAfter(n, gapEnd),
    },
    n,
  );
}

function mapItem(item, postBlank) {
  const kids = item.children ?? [];
  let tag = null;
  let rest = kids;
  if (kids.length && kids[0].type === 'list-item-tag') {
    // list-item-tag carries no positions in uniorg; map it position-free
    tag = mapAffObjects(kids[0].children);
    rest = kids.slice(1);
  }
  const firstContent = rest[0] ?? null;
  const counter = item.counter == null ? null : (Number.isNaN(parseInt(item.counter, 10)) ? null : parseInt(item.counter, 10));
  const children = rest.length ? mapElems(rest, nextLineStart(pEnd(rest[rest.length - 1]))) : [];
  // uniorg starts an item's first paragraph ON the bullet line even when the content is on
  // later lines, swallowing the bullet line's terminator (and any blank lines) into the
  // paragraph text. Move that whitespace back where org-element keeps it (both measured):
  // when real content follows, every swallowed newline is the item's preBlank; when the
  // paragraph held nothing else, org-element emits no node and the newlines are the item's
  // own postBlank.
  let swallowed = 0;
  while (children.length && children[0].type === 'paragraph') {
    const ch = children[0].children;
    if (!(ch.length && ch[0].type === 'text' && ch[0].value.startsWith('\n'))) break;
    const m = ch[0].value.match(/^\n+/);
    ch[0].value = ch[0].value.slice(m[0].length);
    swallowed += m[0].length;
    if (ch[0].value === '') ch.shift();
    if (ch.length) break;
    swallowed += children[0].postBlank ?? 0; // the blank gap that followed the ghost node
    children.shift();
  }
  let extraPre = 0;
  if (children.length) extraPre = swallowed;
  else postBlank += swallowed;
  return {
    type: 'item',
    bullet: item.bullet,
    checkbox: item.checkbox ?? null,
    counter,
    tag,
    preBlank: preBlankOf(item, firstContent) + extraPre,
    children,
    postBlank,
  };
}

function mapElems(nodes, endBound) {
  const out = [];
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    const gapEnd = i + 1 < nodes.length ? pStart(nodes[i + 1]) : endBound;
    const mapped = mapElement(n, gapEnd);
    if (mapped !== null) out.push(mapped);
  }
  return out;
}

function mapElement(n, gapEnd) {
  const pb = () => blanksAfter(n, gapEnd);
  switch (n.type) {
    case 'section':
      return makeHeadline(n, gapEnd);
    case 'paragraph':
      return withAff(
        { type: 'paragraph', children: mapObjects(n.children, n.contentsEnd), postBlank: pb() },
        n,
      );
    case 'plain-list':
      return mapList(n, gapEnd);
    case 'keyword':
      return withAff({ type: 'keyword', key: n.key, value: n.value, postBlank: pb() }, n);
    case 'src-block':
      return withAff(
        {
          type: 'src-block',
          language: n.language ?? null,
          switches: n.switches ?? null,
          params: n.parameters ?? null,
          value: n.value,
          postBlank: pb(),
        },
        n,
      );
    case 'example-block':
      // uniorg drops example-block switches entirely; null is the honest emission.
      return withAff({ type: 'example-block', switches: null, value: n.value, postBlank: pb() }, n);
    case 'export-block':
      return withAff(
        { type: 'export-block', backend: n.backend ? n.backend.toUpperCase() : null, value: n.value, postBlank: pb() },
        n,
      );
    case 'comment-block':
      return withAff({ type: 'comment-block', value: n.value, postBlank: pb() }, n);
    case 'quote-block':
    case 'center-block':
      return withAff(
        { type: n.type, children: mapElems(n.children, n.contentsEnd), postBlank: pb() },
        n,
      );
    case 'special-block':
      return withAff(
        {
          type: 'special-block',
          blockType: n.blockType,
          parameters: null, // uniorg drops special-block parameters
          children: mapElems(n.children, n.contentsEnd),
          postBlank: pb(),
        },
        n,
      );
    case 'verse-block':
      return withAff(
        { type: 'verse-block', children: mapObjects(n.children, n.contentsEnd), postBlank: pb() },
        n,
      );
    case 'comment':
      return withAff({ type: 'comment', value: n.value, postBlank: pb() }, n);
    case 'fixed-width':
      // org-element's fixed-width postBlank counts the element's own final newline too
      // (measured against the oracle; comment/diary-sexp/latex-environment do not).
      return withAff(
        {
          type: 'fixed-width',
          value: n.value,
          postBlank: (src[pEnd(n)] === '\n' ? 1 : 0) + pb(),
        },
        n,
      );
    case 'horizontal-rule':
      return withAff({ type: 'horizontal-rule', postBlank: pb() }, n);
    case 'latex-environment':
      return withAff({ type: 'latex-environment', value: n.value, postBlank: pb() }, n);
    case 'diary-sexp':
      return withAff({ type: 'diary-sexp', value: n.value, postBlank: pb() }, n);
    case 'table': {
      if (n.tableType === 'table.el') {
        return withAff(
          { type: 'table', value: n.value, tblfm: n.tblfm ? [n.tblfm] : null, postBlank: pb() },
          n,
        );
      }
      return withAff(
        {
          type: 'table',
          tblfm: n.tblfm ? [n.tblfm] : null,
          children: mapElems(n.children, n.contentsEnd),
          postBlank: pb(),
        },
        n,
      );
    }
    case 'table-row':
      return {
        type: 'table-row',
        kind: n.rowType,
        children: (n.children ?? []).map((c) => {
          const cell = mapObject(c);
          cell.postBlank = 0;
          return cell;
        }),
        postBlank: pb(),
      };
    case 'planning':
      return {
        type: 'planning',
        scheduled: n.scheduled ? mapTimestamp(n.scheduled) : null,
        deadline: n.deadline ? mapTimestamp(n.deadline) : null,
        closed: n.closed ? mapTimestamp(n.closed) : null,
        postBlank: pb(),
      };
    case 'property-drawer':
      return {
        type: 'property-drawer',
        children: mapElems(n.children, n.contentsEnd),
        postBlank: pb(),
      };
    case 'node-property':
      return { type: 'node-property', key: n.key, value: n.value === '' ? null : n.value, postBlank: pb() };
    case 'drawer':
      return withAff(
        { type: 'drawer', name: n.name, children: mapElems(n.children, n.contentsEnd), postBlank: pb() },
        n,
      );
    case 'footnote-definition': {
      const kids = n.children ?? [];
      // fn-def preBlank counts newlines from the label's line end, not blank lines: content
      // on the very next line is preBlank 1 (measured; headline/item count blank lines).
      const first = kids[0] ?? null;
      let preBlank = 0;
      if (first) {
        const lineEnd = src.indexOf('\n', pStart(n));
        if (lineEnd !== -1 && pStart(first) > lineEnd) {
          preBlank = 1 + blankLinesFrom(lineEnd + 1, pStart(first));
        }
      }
      return withAff(
        {
          type: 'footnote-definition',
          label: n.label,
          preBlank,
          children: mapElems(kids, n.contentsEnd),
          postBlank: pb(),
        },
        n,
      );
    }
    case 'clock':
      return {
        type: 'clock',
        value: n.value ? mapTimestamp(n.value) : null,
        duration: n.duration ?? null,
        postBlank: pb(),
      };
    default:
      return null;
  }
}

// ---- section/headline restructure -------------------------------------------------------

// uniorg: section = [headline?, ...body elements, ...subtree sections].
// org-element: headline = { title objects, children: [section?(body), sub-headlines] }.
function makeHeadline(sec, gapEnd) {
  const kids = sec.children ?? [];
  if (!kids.length || kids[0].type !== 'headline') {
    // A section with no leading headline is the zeroth section itself.
    return { type: 'section', children: mapElems(kids, gapEnd), postBlank: 0 };
  }
  const hl = kids[0];
  const rest = kids.slice(1);
  const firstSub = rest.findIndex((k) => k.type === 'section');
  const body = firstSub === -1 ? rest : rest.slice(0, firstSub);
  const subs = firstSub === -1 ? [] : rest.slice(firstSub);

  const children = [];
  if (body.length) {
    const bodyEnd = subs.length ? pStart(subs[0]) : gapEnd;
    children.push({ type: 'section', children: mapElems(body, bodyEnd), postBlank: 0 });
  }
  for (let i = 0; i < subs.length; i++) {
    const subGapEnd = i + 1 < subs.length ? pStart(subs[i + 1]) : gapEnd;
    children.push(makeHeadline(subs[i], subGapEnd));
  }

  const firstContent = body[0] ?? subs[0] ?? null;
  const postBlank = children.length ? 0 : blanksAfter(hl, gapEnd);
  return {
    type: 'headline',
    level: hl.level,
    trueLevel: hl.level,
    todo: hl.todoKeyword,
    priority: hl.priority,
    commented: hl.commented,
    tags: hl.tags,
    title: mapObjects(hl.children, hl.contentsEnd ?? pEnd(hl)),
    preBlank: preBlankOf(hl, firstContent),
    children,
    postBlank,
  };
}

function mapDocument(root) {
  const kids = root.children ?? [];
  const firstSec = kids.findIndex((k) => k.type === 'section');
  const pre = firstSec === -1 ? kids : kids.slice(0, firstSec);
  const secs = firstSec === -1 ? [] : kids.slice(firstSec);
  const children = [];
  if (pre.length) {
    const bound = secs.length ? pStart(secs[0]) : pEnd(root);
    children.push({ type: 'section', children: mapElems(pre, bound), postBlank: 0 });
  }
  for (let i = 0; i < secs.length; i++) {
    const gapEnd = i + 1 < secs.length ? pStart(secs[i + 1]) : pEnd(root);
    children.push(makeHeadline(secs[i], gapEnd));
  }
  return { type: 'document', children, postBlank: 0 };
}

process.stdout.write(JSON.stringify(mapDocument(root)) + '\n');
