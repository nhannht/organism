// orgize accuracy adapter (see bench/accuracy/README.md for the fairness protocol):
//   orgize-adapter <file.org>
// parses the file with orgize 0.9 (same pinned crate the speed runner times) and re-encodes
// orgize's own AST into this repo's schema shape (schema/org-node.schema.json).
//
// Pure re-encoder: type/enum renames, the Title-carries-headline-data restructure (orgize
// hangs todo/priority/tags/planning/properties off a Title child; org-element nests them on
// the headline and puts planning/property-drawer inside the section), whitespace moved from
// the head of a following text node onto the previous object's postBlank (org-element's own
// canonical form of the same bytes), and decomposition of already-isolated atomic tokens
// (a repeater cookie "+1w" into {type,value,unit}). orgize 0.9 emits no node positions, so
// whatever its AST does not carry (link path types, item checkboxes/counters, entities,
// latex fragments, ...) is emitted as null/absent and graded honestly.

use orgize::elements::{Clock, Datetime, Element, Table, TableRow, Timestamp};
use orgize::{Event, Org};
use serde_json::{json, Map, Value};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: orgize-adapter <file.org>");
        std::process::exit(1);
    }
    let src = std::fs::read_to_string(&args[1]).expect("read file");
    let org = Org::parse(&src);

    let mut stack: Vec<(String, Map<String, Value>, Vec<Value>)> = Vec::new();
    let mut result: Option<Value> = None;

    for event in org.iter() {
        match event {
            Event::Start(element) => {
                let (kind, data) = open(element);
                stack.push((kind, data, Vec::new()));
            }
            Event::End(_) => {
                let (kind, data, children) = stack.pop().expect("balanced events");
                let node = close(&kind, data, children);
                if let Some((_, _, parent_children)) = stack.last_mut() {
                    if let Some(n) = node {
                        parent_children.push(n);
                    }
                } else {
                    result = node;
                }
            }
        }
    }

    let mut result = result.expect("document");
    // The paragraph-final newline restored by close() assumes every content line was
    // terminated. When the file itself has no final newline, the document's very last
    // text leaf must not carry one - walk the last-child chain and strip it.
    if !src.ends_with('\n') {
        strip_final_newline(&mut result);
    }
    println!("{}", result);
}

fn strip_final_newline(node: &mut Value) {
    let Some(children) = node.get_mut("children").and_then(|c| c.as_array_mut()) else {
        return;
    };
    let Some(last) = children.last_mut() else { return };
    if last.get("type").and_then(|t| t.as_str()) == Some("text") {
        let v = last["value"].as_str().unwrap_or("").to_string();
        if let Some(stripped) = v.strip_suffix('\n') {
            if stripped.is_empty() {
                children.pop();
            } else {
                last["value"] = Value::String(stripped.to_string());
            }
        }
    } else {
        strip_final_newline(last);
    }
}

fn s(v: &str) -> Value {
    Value::String(v.to_string())
}

// org-element's comment / fixed-width value: each raw line minus indentation, the marker
// character, and one following space; no trailing newline on the last line for comments.
fn strip_line_prefix(raw: &str, marker: char) -> String {
    let mut out: Vec<String> = Vec::new();
    for line in raw.trim_end_matches('\n').split('\n') {
        let t = line.trim_start();
        let t = t.strip_prefix(marker).unwrap_or(t);
        let t = t.strip_prefix(' ').unwrap_or(t);
        out.push(t.to_string());
    }
    out.join("\n")
}

fn opt(v: &Option<std::borrow::Cow<'_, str>>) -> Value {
    match v {
        Some(c) => s(c),
        None => Value::Null,
    }
}

// Open an element: record its kind tag and every scalar field available at start time.
fn open(element: &Element) -> (String, Map<String, Value>) {
    let mut d = Map::new();
    let kind;
    match element {
        Element::Document { .. } => kind = "document",
        Element::Section => kind = "section",
        Element::Headline { level } => {
            kind = "headline";
            d.insert("level".into(), json!(level));
        }
        Element::Title(t) => {
            kind = "title";
            d.insert("level".into(), json!(t.level));
            d.insert(
                "priority".into(),
                t.priority.map(|c| s(&c.to_string())).unwrap_or(Value::Null),
            );
            d.insert("todo".into(), opt(&t.keyword));
            d.insert(
                "tags".into(),
                Value::Array(t.tags.iter().map(|t| s(t)).collect()),
            );
            d.insert("preBlank".into(), json!(t.post_blank));
            if let Some(p) = &t.planning {
                d.insert(
                    "planning".into(),
                    json!({
                        "type": "planning",
                        "scheduled": p.scheduled.as_ref().map(timestamp).unwrap_or(Value::Null),
                        "deadline": p.deadline.as_ref().map(timestamp).unwrap_or(Value::Null),
                        "closed": p.closed.as_ref().map(timestamp).unwrap_or(Value::Null),
                        "postBlank": 0,
                    }),
                );
            }
            if !t.properties.pairs.is_empty() {
                let props: Vec<Value> = t
                    .properties
                    .pairs
                    .iter()
                    .map(|(k, v)| {
                        json!({
                            "type": "node-property",
                            "key": k,
                            "value": if v.is_empty() { Value::Null } else { s(v) },
                            "postBlank": 0,
                        })
                    })
                    .collect();
                d.insert(
                    "propertyDrawer".into(),
                    json!({
                        "type": "property-drawer",
                        "children": props,
                        "postBlank": 0,
                    }),
                );
            }
        }
        Element::Paragraph { post_blank } => {
            kind = "paragraph";
            d.insert("postBlank".into(), json!(post_blank));
        }
        Element::Text { value } => {
            kind = "text";
            d.insert("value".into(), s(value));
        }
        Element::Bold => kind = "bold",
        Element::Italic => kind = "italic",
        Element::Underline => kind = "underline",
        Element::Strike => kind = "strikethrough",
        Element::Verbatim { value } => {
            kind = "verbatim";
            d.insert("value".into(), s(value));
        }
        Element::Code { value } => {
            kind = "code";
            d.insert("value".into(), s(value));
        }
        Element::Link(l) => {
            kind = "link";
            // orgize 0.9 only matches bracket links, so every Link is org's "regular"
            // format; it stores no :type equivalent, so pathType has no honest value.
            d.insert("path".into(), s(&l.path));
            d.insert(
                "description".into(),
                match &l.desc {
                    Some(t) => json!([{ "type": "text", "value": t }]),
                    None => Value::Null,
                },
            );
        }
        Element::List(l) => {
            kind = "list";
            d.insert(
                "kind".into(),
                s(if l.ordered { "ordered" } else { "unordered" }),
            );
            d.insert("postBlank".into(), json!(l.post_blank));
        }
        Element::ListItem(i) => {
            kind = "item";
            d.insert("bullet".into(), s(&i.bullet));
        }
        Element::Keyword(k) => {
            kind = "keyword";
            d.insert("key".into(), s(&k.key.to_uppercase()));
            d.insert("value".into(), s(&k.value));
            d.insert("postBlank".into(), json!(k.post_blank));
        }
        Element::BabelCall(b) => {
            kind = "babel-call";
            d.insert("value".into(), s(&b.value));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::SourceBlock(b) => {
            kind = "src-block";
            d.insert(
                "language".into(),
                if b.language.is_empty() { Value::Null } else { s(&b.language) },
            );
            // orgize stores switches + header arguments as ONE string; splitting them is
            // org grammar, so the whole string goes to params (marker-listed).
            d.insert("switches".into(), Value::Null);
            let args = b.arguments.trim_start();
            d.insert(
                "params".into(),
                if args.is_empty() { Value::Null } else { s(args) },
            );
            d.insert("value".into(), s(&b.contents));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::ExampleBlock(b) => {
            kind = "example-block";
            d.insert(
                "switches".into(),
                match &b.data {
                    Some(v) if !v.trim().is_empty() => s(v.trim_start()),
                    _ => Value::Null,
                },
            );
            d.insert("value".into(), s(&b.contents));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::ExportBlock(b) => {
            kind = "export-block";
            d.insert("backend".into(), s(&b.data.to_uppercase()));
            d.insert("value".into(), s(&b.contents));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::CommentBlock(b) => {
            kind = "comment-block";
            d.insert("value".into(), s(&b.contents));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::QuoteBlock(b) => {
            kind = "quote-block";
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::CenterBlock(b) => {
            kind = "center-block";
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::VerseBlock(b) => {
            kind = "verse-block";
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::SpecialBlock(b) => {
            kind = "special-block";
            d.insert("blockType".into(), s(&b.name));
            d.insert("parameters".into(), opt(&b.parameters));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::DynBlock(b) => {
            kind = "dynamic-block";
            d.insert("blockName".into(), s(&b.block_name));
            d.insert("arguments".into(), opt(&b.arguments));
            d.insert("postBlank".into(), json!(b.post_blank));
        }
        Element::Drawer(dr) => {
            kind = "drawer";
            d.insert("name".into(), s(&dr.name));
            d.insert("postBlank".into(), json!(dr.post_blank));
        }
        Element::FnDef(f) => {
            kind = "footnote-definition";
            d.insert("label".into(), s(&f.label));
            d.insert("postBlank".into(), json!(f.post_blank));
        }
        Element::FnRef(f) => {
            kind = "footnote-reference";
            let inline = f.definition.is_some();
            d.insert(
                "label".into(),
                if f.label.is_empty() { Value::Null } else { s(&f.label) },
            );
            d.insert("inline".into(), json!(inline));
            if let Some(def) = &f.definition {
                d.insert(
                    "children".into(),
                    if def.is_empty() {
                        json!([])
                    } else {
                        json!([{ "type": "text", "value": def }])
                    },
                );
            }
        }
        Element::InlineSrc(i) => {
            kind = "inline-src-block";
            d.insert("language".into(), s(&i.lang));
            d.insert("parameters".into(), opt(&i.options));
            d.insert("value".into(), s(&i.body));
        }
        Element::InlineCall(c) => {
            kind = "inline-babel-call";
            let mut v = format!("call_{}", c.name);
            if let Some(h) = &c.inside_header {
                v.push_str(&format!("[{}]", h));
            }
            v.push_str(&format!("({})", c.arguments));
            if let Some(h) = &c.end_header {
                v.push_str(&format!("[{}]", h));
            }
            d.insert("value".into(), s(&v));
        }
        Element::Macros(m) => {
            kind = "macro";
            let v = match &m.arguments {
                Some(a) => format!("{{{{{{{}({})}}}}}}", m.name, a),
                None => format!("{{{{{{{}}}}}}}", m.name),
            };
            d.insert("value".into(), s(&v));
        }
        Element::Snippet(sn) => {
            kind = "export-snippet";
            d.insert("backEnd".into(), s(&sn.name));
            d.insert("value".into(), s(&sn.value));
        }
        Element::Target(t) => {
            kind = "target";
            d.insert("value".into(), s(&t.target));
        }
        Element::RadioTarget => kind = "radio-target",
        Element::Cookie(c) => {
            kind = "statistics-cookie";
            d.insert("value".into(), s(&c.value));
        }
        Element::Timestamp(t) => {
            kind = "timestamp";
            d.insert("node".into(), timestamp(t));
        }
        Element::Clock(c) => {
            kind = "clock";
            match c {
                Clock::Closed {
                    start,
                    end,
                    repeater,
                    delay,
                    duration,
                    post_blank,
                } => {
                    d.insert(
                        "value".into(),
                        ts_value("inactive-range", Some(start), Some(end), repeater, delay, None),
                    );
                    d.insert("duration".into(), s(duration));
                    d.insert("postBlank".into(), json!(post_blank));
                }
                Clock::Running {
                    start,
                    repeater,
                    delay,
                    post_blank,
                } => {
                    d.insert(
                        "value".into(),
                        ts_value("inactive", Some(start), None, repeater, delay, None),
                    );
                    d.insert("duration".into(), Value::Null);
                    d.insert("postBlank".into(), json!(post_blank));
                }
            }
        }
        Element::Comment(c) => {
            kind = "comment";
            // orgize keeps the raw lines; org-element's value strips the comment marker
            // and one following space per line, and the trailing newline (rule-3
            // normalization of the same captured bytes).
            d.insert("value".into(), s(&strip_line_prefix(&c.value, '#')));
            d.insert("postBlank".into(), json!(c.post_blank));
        }
        Element::FixedWidth(f) => {
            kind = "fixed-width";
            d.insert("value".into(), s(&strip_line_prefix(&f.value, ':')));
            // org-element counts the element's own final newline into fixed-width's
            // postBlank (measured convention; see the uniorg adapter).
            d.insert("postBlank".into(), json!(f.post_blank + 1));
        }
        Element::Rule(r) => {
            kind = "horizontal-rule";
            d.insert("postBlank".into(), json!(r.post_blank));
        }
        Element::Table(t) => {
            kind = "table";
            match t {
                Table::Org { tblfm, post_blank, .. } => {
                    d.insert(
                        "tblfm".into(),
                        match tblfm {
                            Some(f) => json!([f]),
                            None => Value::Null,
                        },
                    );
                    d.insert("postBlank".into(), json!(post_blank));
                }
                Table::TableEl { value, post_blank } => {
                    d.insert("value".into(), s(value));
                    d.insert("tblfm".into(), Value::Null);
                    d.insert("postBlank".into(), json!(post_blank));
                }
            }
        }
        Element::TableRow(r) => {
            kind = "table-row";
            let k = match r {
                TableRow::Header | TableRow::Body => "standard",
                TableRow::HeaderRule | TableRow::BodyRule => "rule",
            };
            d.insert("kind".into(), s(k));
        }
        Element::TableCell(_) => kind = "table-cell",
    }
    (kind.to_string(), d)
}

fn datetime(dt: &Datetime) -> Value {
    json!({
        "year": dt.year,
        "month": dt.month,
        "day": dt.day,
        "dayname": if dt.dayname.is_empty() { Value::Null } else { s(&dt.dayname) },
        "hour": dt.hour,
        "minute": dt.minute,
    })
}

// Decompose an already-isolated repeater/delay cookie ("+1w", ".+2d", "--3h").
fn cookie(raw: &Option<std::borrow::Cow<'_, str>>) -> Value {
    let Some(raw) = raw else { return Value::Null };
    let ty = if raw.starts_with("++") {
        "++"
    } else if raw.starts_with(".+") {
        ".+"
    } else if raw.starts_with("--") {
        "--"
    } else if raw.starts_with('+') {
        "+"
    } else if raw.starts_with('-') {
        "-"
    } else {
        return Value::Null;
    };
    let rest = &raw[ty.len()..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    let unit = &rest[digits.len()..];
    match digits.parse::<i64>() {
        Ok(value) => json!({ "type": ty, "value": value, "unit": unit }),
        Err(_) => Value::Null,
    }
}

fn ts_value(
    kind: &str,
    start: Option<&Datetime>,
    end: Option<&Datetime>,
    repeater: &Option<std::borrow::Cow<'_, str>>,
    delay: &Option<std::borrow::Cow<'_, str>>,
    diary: Option<&str>,
) -> Value {
    let mut m = Map::new();
    m.insert("type".into(), s("timestamp"));
    m.insert("kind".into(), s(kind));
    // orgize collapses the two range source forms, so rangeType has no honest value.
    m.insert("rangeType".into(), Value::Null);
    m.insert("start".into(), start.map(datetime).unwrap_or(Value::Null));
    m.insert("end".into(), end.map(datetime).unwrap_or(Value::Null));
    m.insert("repeater".into(), cookie(repeater));
    m.insert("delay".into(), cookie(delay));
    if let Some(dv) = diary {
        m.insert("diarySexp".into(), s(dv));
    }
    m.insert("postBlank".into(), json!(0));
    Value::Object(m)
}

fn timestamp(t: &Timestamp) -> Value {
    match t {
        Timestamp::Active { start, repeater, delay } => {
            ts_value("active", Some(start), None, repeater, delay, None)
        }
        Timestamp::Inactive { start, repeater, delay } => {
            ts_value("inactive", Some(start), None, repeater, delay, None)
        }
        Timestamp::ActiveRange { start, end, repeater, delay } => {
            ts_value("active-range", Some(start), Some(end), repeater, delay, None)
        }
        Timestamp::InactiveRange { start, end, repeater, delay } => {
            ts_value("inactive-range", Some(start), Some(end), repeater, delay, None)
        }
        // orgize strips the sexp's outer parens; org-element's diarySexp keeps them -
        // structural delimiters restored by concatenation, same class as macro braces
        Timestamp::Diary { value } => {
            ts_value("diary", None, None, &None, &None, Some(&format!("({})", value)))
        }
    }
}

// Move the spaces orgize keeps at the head of a following text node onto the previous
// object's postBlank - org-element's canonical form of the same bytes.
fn move_object_spacing(children: &mut Vec<Value>) {
    let mut i = 0;
    while i < children.len() {
        let is_object = children[i]
            .get("type")
            .and_then(|t| t.as_str())
            .map(|t| t != "text")
            .unwrap_or(false);
        if is_object && i + 1 < children.len() {
            let stripped = {
                let next = &children[i + 1];
                if next.get("type").and_then(|t| t.as_str()) == Some("text") {
                    let v = next.get("value").and_then(|v| v.as_str()).unwrap_or("");
                    let ws = v.len() - v.trim_start_matches([' ', '\t']).len();
                    if ws > 0 {
                        Some((ws, v[ws..].to_string()))
                    } else {
                        None
                    }
                } else {
                    None
                }
            };
            if let Some((ws, rest)) = stripped {
                if let Some(pb) = children[i].get_mut("postBlank") {
                    *pb = json!(pb.as_i64().unwrap_or(0) + ws as i64);
                }
                if rest.is_empty() {
                    children.remove(i + 1);
                } else {
                    children[i + 1]["value"] = s(&rest);
                }
            }
        }
        i += 1;
    }
}

const OBJECT_CONTAINERS: &[&str] = &[
    "paragraph", "title", "verse-block", "bold", "italic", "underline", "strikethrough",
    "table-cell", "radio-target",
];

// orgize's line-based parser never includes a paragraph's final newline in its Text
// values; org-element always does when the line was terminated. Restore the canonical
// form (the terminator's existence is part of orgize's own line structure); the one
// unknowable case, a file with no final newline, is fixed up in main().
fn ensure_trailing_newline(children: &mut Vec<Value>) {
    match children.last_mut() {
        Some(last) if last.get("type").and_then(|t| t.as_str()) == Some("text") => {
            let v = last["value"].as_str().unwrap_or("").to_string();
            if !v.ends_with('\n') {
                last["value"] = Value::String(v + "\n");
            }
        }
        Some(_) => children.push(json!({ "type": "text", "value": "\n" })),
        None => {}
    }
}

fn close(kind: &str, mut d: Map<String, Value>, mut children: Vec<Value>) -> Option<Value> {
    if OBJECT_CONTAINERS.contains(&kind) {
        move_object_spacing(&mut children);
    }
    if kind == "paragraph" {
        ensure_trailing_newline(&mut children);
    }
    if kind == "verse-block" {
        // orgize wraps verse contents in paragraph(s); org-element holds the objects
        // directly. Hoist them (blank lines between orgize's paragraphs are lost by
        // orgize itself and fail honestly).
        let mut flat: Vec<Value> = Vec::new();
        for c in children.drain(..) {
            if c.get("type").and_then(|t| t.as_str()) == Some("paragraph") {
                if let Some(arr) = c.get("children").and_then(|x| x.as_array()) {
                    flat.extend(arr.iter().cloned());
                }
            } else {
                flat.push(c);
            }
        }
        children = flat;
    }
    match kind {
        "document" => {
            let restructured = restructure_top(children);
            Some(json!({ "type": "document", "children": restructured, "postBlank": 0 }))
        }
        "section" => Some(json!({
            "type": "section",
            "children": children,
            "postBlank": 0,
            "__section": true,
        })),
        "headline" => Some(build_headline(d, children)),
        "title" => {
            // carried up into the enclosing headline frame
            d.insert("__title".into(), json!(true));
            d.insert("titleChildren".into(), Value::Array(children));
            Some(Value::Object(d))
        }
        "timestamp" => d.remove("node"),
        "text" => {
            let v = d.remove("value").unwrap_or(Value::Null);
            Some(json!({ "type": "text", "value": v }))
        }
        "bold" | "italic" | "underline" | "strikethrough" | "radio-target" => {
            Some(json!({ "type": kind, "children": children, "postBlank": 0 }))
        }
        "verbatim" | "code" | "statistics-cookie" | "target" | "macro" | "export-snippet"
        | "inline-src-block" | "inline-babel-call" | "footnote-reference" | "link" => {
            d.insert("type".into(), s(kind));
            d.insert("postBlank".into(), json!(0));
            if kind == "link" {
                d.insert("linkType".into(), s("regular"));
                d.insert("pathType".into(), Value::Null);
            }
            Some(Value::Object(d))
        }
        "table-cell" => Some(json!({ "type": "table-cell", "children": children, "postBlank": 0 })),
        "table-row" => {
            d.insert("type".into(), s(kind));
            d.insert("children".into(), Value::Array(children));
            d.insert("postBlank".into(), json!(0));
            Some(Value::Object(d))
        }
        "item" => Some(json!({
            "type": "item",
            "bullet": d.remove("bullet").unwrap_or(Value::Null),
            "checkbox": Value::Null,
            "counter": Value::Null,
            "tag": Value::Null,
            "preBlank": 0,
            "children": children,
            "postBlank": 0,
        })),
        _ => {
            d.insert("type".into(), s(kind));
            if kind == "footnote-definition" {
                d.insert("preBlank".into(), json!(0));
                // orgize keeps the "[fn:LABEL] " separator's space at the head of the
                // first paragraph's text; org-element starts contents after it
                if let Some(txt) = children
                    .first_mut()
                    .filter(|f| f.get("type").and_then(|t| t.as_str()) == Some("paragraph"))
                    .and_then(|f| f.get_mut("children"))
                    .and_then(|c| c.as_array_mut())
                    .and_then(|c| c.first_mut())
                    .filter(|t| t.get("type").and_then(|t| t.as_str()) == Some("text"))
                {
                    let v = txt["value"].as_str().unwrap_or("").to_string();
                    if let Some(stripped) = v.strip_prefix(' ') {
                        txt["value"] = Value::String(stripped.to_string());
                    }
                }
            }
            if !children.is_empty() || matches!(kind, "list" | "quote-block" | "center-block"
                | "special-block" | "dynamic-block" | "drawer" | "footnote-definition"
                | "verse-block" | "table" | "property-drawer")
            {
                // table.el tables keep their value and take no children key
                if !(kind == "table" && d.contains_key("value")) {
                    d.insert("children".into(), Value::Array(children));
                }
            }
            Some(Value::Object(d))
        }
    }
}

fn build_headline(d: Map<String, Value>, children: Vec<Value>) -> Value {
    let mut title: Option<Map<String, Value>> = None;
    let mut rest: Vec<Value> = Vec::new();
    for c in children {
        if c.get("__title").is_some() {
            if let Value::Object(m) = c {
                title = Some(m);
            }
        } else {
            rest.push(c);
        }
    }
    let mut t = title.unwrap_or_default();
    let level = d.get("level").cloned().unwrap_or(json!(1));

    // Re-nest planning and the property drawer where org-element keeps them: first
    // elements of the headline's section (synthesizing the section when orgize omitted it).
    let planning = t.remove("planning");
    let property_drawer = t.remove("propertyDrawer");
    if planning.is_some() || property_drawer.is_some() {
        let mut prefix: Vec<Value> = Vec::new();
        if let Some(p) = planning {
            prefix.push(p);
        }
        if let Some(pd) = property_drawer {
            prefix.push(pd);
        }
        if let Some(first) = rest.first_mut() {
            if first.get("__section").is_some() {
                let existing = first["children"].as_array().cloned().unwrap_or_default();
                prefix.extend(existing);
                first["children"] = Value::Array(prefix);
            } else {
                rest.insert(
                    0,
                    json!({ "type": "section", "children": prefix, "postBlank": 0, "__section": true }),
                );
            }
        } else {
            rest.push(
                json!({ "type": "section", "children": prefix, "postBlank": 0, "__section": true }),
            );
        }
    }
    for c in rest.iter_mut() {
        if let Some(obj) = c.as_object_mut() {
            obj.remove("__section");
        }
    }

    let pre_blank = t.remove("preBlank").unwrap_or(json!(0));
    let (pre_blank, post_blank) = if rest.is_empty() {
        // no content: the blanks after the headline line are its postBlank (measured)
        (json!(0), pre_blank)
    } else {
        (pre_blank, json!(0))
    };

    json!({
        "type": "headline",
        "level": level,
        "trueLevel": level,
        "todo": t.remove("todo").unwrap_or(Value::Null),
        "priority": t.remove("priority").unwrap_or(Value::Null),
        "commented": false,
        "tags": t.remove("tags").unwrap_or(json!([])),
        "title": t.remove("titleChildren").unwrap_or(json!([])),
        "preBlank": pre_blank,
        "children": rest,
        "postBlank": post_blank,
    })
}

fn restructure_top(children: Vec<Value>) -> Vec<Value> {
    children
        .into_iter()
        .map(|mut c| {
            if let Some(obj) = c.as_object_mut() {
                obj.remove("__section");
            }
            c
        })
        .collect()
}
