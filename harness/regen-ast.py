#!/usr/bin/env python3
"""Regenerate Sources/OrgSwift/OrgAST.generated.swift from schema/org-node.schema.json.

    usage: python3 harness/regen-ast.py [--check]

`--check` regenerates into memory and diffs against the committed file, exiting 1 on a
difference. That is the form CI wants: it proves the committed Swift is what the schema
currently produces, so the two cannot drift apart silently.

## Why generated

`schema/org-node.schema.json` is the published cross-language contract. Hand-writing 55 Swift
types beside it would create a second copy of that contract kept in sync by hand, which is the
exact shape this repository keeps finding bugs in. Generating means the schema stays the single
source of truth and the Swift types are a build product.

Same precedent as `harness/regen-entities.sh`, which generates `Sources/OrgSwift/
EntityNames.swift` from the live Emacs entity table: output is committed AND regenerable, so a
reader never has to run anything, and a drift check is one command.

## What the schema guarantees, and what this relies on

- Every node def is `additionalProperties: false`. The schema is CLOSED, so a struct with
  exactly the declared fields is faithful; nothing can arrive that the type cannot hold.
- Node defs are identified by a `properties.type.const`. There are 54 of them, plus `table`,
  whose def is a two-branch `oneOf` (org-flavour vs table.el-flavour) under one `type` const.
- `required` is explicit everywhere, so optionality is read rather than guessed.

Three traps, all of them found by measuring rather than reading:

1. `rep` has a property literally NAMED `type` which is a real enum (`+`, `++`, `.+`, `-`, `--`),
   not a discriminator. Any pass that treats `properties.type` as "the node tag" silently drops
   it. Only defs whose `type` carries a `const` are node defs.
2. `text` is the ONLY node with no `postBlank` key at all -- org-element tracks post-blank on
   proper element/object nodes and a bare plain-text span is not one.
3. Three `children` arrays are HOMOGENEOUS, not `nodeArray`: `list.children` is `[item]`,
   `property-drawer.children` is `[node-property]`, `table-row.children` is `[table-cell]`.
   Typing those as `[OrgNode]` would compile and would throw away real information.

## Absent vs null

These are different in the schema and the round-trip depends on the difference:

    ABSENT   an optional key (`affiliated`, `footnote-reference.children`,
             `timestamp.diarySexp`). Decodes to nil; re-emitted by OMITTING the key.
    NULL     a required-but-nullable key (`headline.todo`, `item.checkbox`, ...).
             Decodes to nil; re-emitted as an explicit JSON null.

Collapsing them would round-trip `{"todo": null}` as `{}`, which fails the identity gate on the
first headline it meets. Both map to Swift `nil`, so the distinction lives in the emitter, driven
by the `required` list.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "schema" / "org-node.schema.json"
OUT = ROOT / "Sources" / "OrgSwift" / "OrgAST.generated.swift"

SWIFT_KEYWORDS = {"subscript", "operator", "protocol", "extension", "default", "class",
                  "struct", "enum", "case", "func", "let", "var", "in", "is", "as", "where",
                  "switch", "return", "init", "self", "super", "static", "import", "repeat"}


def camel(name: str) -> str:
    """`citation-reference` -> `citationReference`. Mechanical; no semantic renaming."""
    head, *rest = name.split("-")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def pascal(name: str) -> str:
    c = camel(name)
    return c[:1].upper() + c[1:]


def case_name(name: str) -> str:
    c = camel(name)
    return f"`{c}`" if c in SWIFT_KEYWORDS else c


def enum_case(value: str) -> str:
    """Raw enum values are not all identifiers: `+`, `++`, `.+`, `-`, `--`, `active-range`.

    Punctuation gets a spelled-out mechanical name rather than an invented semantic one. A
    generator that named `.+` `restart` would be encoding org knowledge that belongs in
    SCHEMA.md, and would be wrong the moment the same enum is reused elsewhere -- which it is:
    `rep.type` serves both repeaters and delays, where the same glyph means different things.
    """
    spelled = {"+": "plus", "++": "plusPlus", ".+": "dotPlus", "-": "minus", "--": "minusMinus"}
    if value in spelled:
        return spelled[value]
    return camel(value)


class Generator:
    def __init__(self, schema: dict):
        self.defs = schema["$defs"]
        self.nodes = {}          # org type name -> def
        for name, d in self.defs.items():
            const = d.get("properties", {}).get("type", {}).get("const")
            if const is not None:
                self.nodes[const] = d
        # `table` is the one node whose def is a two-branch oneOf rather than flat properties.
        self.table = self.defs["table"]
        self.lines: list[str] = []
        self.enums: dict[str, list[str]] = {}   # swift enum name -> raw values

    # ---- type mapping -------------------------------------------------------------------

    def enum_type_name(self, owner: str, field: str) -> str:
        special = {("timestamp", "kind"): "OrgTimestampKind",
                   ("timestamp", "rangeType"): "OrgRangeType",
                   ("rep", "type"): "OrgRepType",
                   ("rep", "unit"): "OrgRepUnit",
                   ("item", "checkbox"): "OrgCheckbox",
                   ("link", "linkType"): "OrgLinkType",
                   ("list", "kind"): "OrgListKind",
                   ("table-row", "kind"): "OrgTableRowKind"}
        return special[(owner, field)]

    def swift_type(self, prop: dict, owner: str, field: str) -> tuple[str, str]:
        """Return (swift type without optionality, decode-kind tag)."""
        if "$ref" in prop:
            ref = prop["$ref"].rsplit("/", 1)[-1]
            if ref == "postBlank":
                return "Int", "int"
            if ref == "nodeArray":
                return "[OrgNode]", "nodeArray"
            if ref == "nodeArrayOrNull":
                return "[OrgNode]", "nodeArrayOrNull"
            if ref == "affiliated":
                return "OrgAffiliated", "affiliated"
            if ref == "tblfm":
                return "[String]", "stringArrayOrNull"
            if ref == "date":
                return "OrgDate", "date"
            if ref == "rep":
                return "OrgRep", "rep"
            return f"Org{pascal(ref)}", f"node:{ref}"

        if "enum" in prop:
            values = [v for v in prop["enum"] if v is not None]
            name = self.enum_type_name(owner, field)
            self.enums.setdefault(name, values)
            return name, f"enum:{name}"

        if "oneOf" in prop:
            branches = [b for b in prop["oneOf"] if b.get("type") != "null"]
            if len(branches) == 1:
                return self.swift_type(branches[0], owner, field)
            raise SystemExit(f"unhandled oneOf at {owner}.{field}")

        t = prop.get("type")
        if isinstance(t, list):
            base = [x for x in t if x != "null"]
            if base == ["string"]:
                return "String", "string"
            if base == ["integer"]:
                return "Int", "int"
            raise SystemExit(f"unhandled nullable primitive {t} at {owner}.{field}")
        if t == "string":
            return "String", "string"
        if t == "integer":
            return "Int", "int"
        if t == "boolean":
            return "Bool", "bool"
        if t == "array":
            items = prop.get("items", {})
            if items.get("type") == "string":
                return "[String]", "stringArray"
            if "$ref" in items:
                ref = items["$ref"].rsplit("/", 1)[-1]
                return f"[Org{pascal(ref)}]", f"nodeList:{ref}"
        raise SystemExit(f"unhandled property shape at {owner}.{field}: {prop}")

    def is_nullable(self, prop: dict) -> bool:
        """Whether the schema permits an explicit JSON null here.

        MUST resolve `$ref`, because nullability is frequently declared one level down rather
        than inline. `link.description` is `{"$ref": "#/$defs/nodeArrayOrNull"}` and the null
        branch lives inside that def; an inline-only check calls it non-nullable, generates the
        REQUIRED decoder, and every link without a description throws
        "expected an array of nodes, got null". Measured: that was 115 of 1,432 trees, across
        link, item.tag, citation.prefix/suffix and citation-reference.suffix.
        """
        if "$ref" in prop:
            ref = prop["$ref"].rsplit("/", 1)[-1]
            target = self.defs.get(ref)
            return bool(target) and self.is_nullable(target)
        if "oneOf" in prop:
            return any(b.get("type") == "null" for b in prop["oneOf"])
        if "enum" in prop:
            return None in prop["enum"]
        t = prop.get("type")
        return isinstance(t, list) and "null" in t

    # ---- emitters -----------------------------------------------------------------------

    def w(self, line: str = "") -> None:
        self.lines.append(line)

    def fields(self, definition: dict, owner: str) -> list[dict]:
        required = set(definition.get("required", []))
        out = []
        for field, prop in definition.get("properties", {}).items():
            if field == "type" and prop.get("const") is not None:
                continue
            swift, kind = self.swift_type(prop, owner, field)
            optional = (field not in required) or self.is_nullable(prop)
            out.append({"json": field, "swift": camel(field), "type": swift, "kind": kind,
                        "optional": optional, "absent": field not in required})
        return out

    def emit_struct(self, swift_name: str, org_name: str, fields: list[dict],
                    doc: str, type_const: str | None) -> None:
        self.w(f"/// {doc}")
        self.w(f"public struct {swift_name}: Equatable, Sendable {{")
        for f in fields:
            self.w(f"    public let {f['swift']}: {f['type']}{'?' if f['optional'] else ''}")
        self.w()
        # memberwise init, explicit so it is public
        args = ", ".join(
            f"{f['swift']}: {f['type']}{'?' if f['optional'] else ''}"
            + (" = nil" if f["absent"] else "")
            for f in fields)
        self.w(f"    public init({args}) {{")
        for f in fields:
            self.w(f"        self.{f['swift']} = {f['swift']}")
        self.w("    }")
        self.w()
        self.w(f"    public init(_ json: OrgJSON) throws {{")
        self.w(f'        let o = try ASTDecode.object(json, "{org_name}")')
        if type_const is not None:
            self.w(f'        try ASTDecode.expectType(o, "{type_const}")')
        for f in fields:
            self.w(f"        self.{f['swift']} = " + self.decode_expr(f, org_name))
        self.w("    }")
        self.w()
        self.w("    public func toJSON() -> OrgJSON {")
        self.w("        var o: [String: OrgJSON] = [:]")
        if type_const is not None:
            self.w(f'        o["type"] = .string("{type_const}")')
        for f in fields:
            self.emit_encode(f)
        self.w("        return .object(o)")
        self.w("    }")
        self.w("}")
        self.w()

    def decode_expr(self, f: dict, owner: str) -> str:
        key, kind = f["json"], f["kind"]
        opt = "Opt" if f["optional"] else ""
        base = {
            "string": "string", "int": "int", "bool": "bool",
            "stringArray": "stringArray", "stringArrayOrNull": "stringArray",
            "nodeArray": "nodeArray", "nodeArrayOrNull": "nodeArray",
            "affiliated": "affiliated", "date": "date", "rep": "rep",
        }.get(kind)
        if base:
            return f'try ASTDecode.{base}{opt}(o, "{key}", in: "{owner}")'
        if kind.startswith("enum:"):
            return f'try ASTDecode.enumValue{opt}({kind[5:]}.self, o, "{key}", in: "{owner}")'
        if kind.startswith("node:"):
            t = f"Org{pascal(kind[5:])}"
            return f'try ASTDecode.nested{opt}({t}.self, o, "{key}", in: "{owner}")'
        if kind.startswith("nodeList:"):
            t = f"Org{pascal(kind[9:])}"
            return f'try ASTDecode.nestedList{opt}({t}.self, o, "{key}", in: "{owner}")'
        raise SystemExit(f"no decoder for kind {kind}")

    def emit_encode(self, f: dict) -> None:
        key, kind, name = f["json"], f["kind"], f["swift"]
        conv = {
            "string": "  .string(v)", "int": "  .int(v)", "bool": "  .bool(v)",
            "stringArray": "  .array(v.map { .string($0) })",
            "stringArrayOrNull": "  .array(v.map { .string($0) })",
            "nodeArray": "  .array(v.map { $0.toJSON() })",
            "nodeArrayOrNull": "  .array(v.map { $0.toJSON() })",
            "affiliated": "  v.toJSON()", "date": "  v.toJSON()", "rep": "  v.toJSON()",
        }.get(kind)
        if conv is None:
            if kind.startswith("enum:"):
                conv = "  .string(v.rawValue)"
            elif kind.startswith("node:"):
                conv = "  v.toJSON()"
            elif kind.startswith("nodeList:"):
                conv = "  .array(v.map { $0.toJSON() })"
            else:
                raise SystemExit(f"no encoder for kind {kind}")
        expr = conv.strip()
        if not f["optional"]:
            self.w(f'        o["{key}"] = {{ let v = self.{name}; return {expr} }}()')
        elif f["absent"]:
            # ABSENT-optional: omit the key entirely when nil.
            self.w(f'        if let v = self.{name} {{ o["{key}"] = {expr} }}')
        else:
            # NULLABLE-required: the key must be present, carrying an explicit null.
            self.w(f'        o["{key}"] = self.{name}.map {{ v in {expr} }} ?? .null')

    def emit_post_blank(self, names: list[str]) -> None:
        """`postBlank` off any node, without first knowing which type it is.

        Generated for the same reason as `childNodes`: a 55-case switch that has to stay exact.

        Returns nil for `text` alone, the one node with no such key. Not a quirk to paper over
        with 0 -- SCHEMA.md is explicit that a plain-text span carries no post-blank of its own
        and that any inter-object space beside it belongs to the OBJECT. Returning 0 would assert
        "no spaces follow", a different and often false claim.
        """
        self.w("""extension OrgNode {
    /// This node's `postBlank`, or nil for `text` -- the one node type with no such field.
    ///
    /// The UNIT depends on position, which is org's convention rather than this package's: on an
    /// OBJECT it counts SPACES following on the same line, on an ELEMENT it counts blank LINES.
    /// SCHEMA.md section 1 has the measurement, and it is the reason `*bold* text` can be
    /// reconstructed at all -- that space lives here and in no text node.
    public var postBlank: Int? {
        switch self {""")
        for n in names:
            if n == "table":
                has = True
            else:
                has = any(f["json"] == "postBlank" for f in self.fields(self.nodes[n], n))
            self.w(f"        case .{case_name(n)}(let x): return x.postBlank" if has
                   else f"        case .{case_name(n)}: return nil")
        self.w("        }")
        self.w("    }")
        self.w("}")
        self.w()

    def assert_coverage(self, emitted: list[str]) -> None:
        """Every `type` const the schema declares must reach the OrgNode enum.

        Generation is only safe while the emitted set equals the declared set. A type the
        generator skips does not fail to build -- it produces a struct nothing references and a
        decoder that rejects real documents at runtime, which is strictly worse than a compile
        error. Measured: this fired on the first run, catching `table`.

        Reads the discriminators straight out of the schema rather than out of `self.nodes`, so
        it is an independent count and not a restatement of the thing it is checking.
        """
        declared = set()
        for name, d in self.defs.items():
            const = d.get("properties", {}).get("type", {}).get("const")
            if const is not None:
                declared.add(const)
            for branch in d.get("oneOf", []) or []:
                const = branch.get("properties", {}).get("type", {}).get("const")
                if const is not None:
                    declared.add(const)
        missing = declared - set(emitted)
        extra = set(emitted) - declared
        if missing or extra:
            raise SystemExit(
                f"regen-ast: OrgNode coverage mismatch.\n"
                f"  declared in schema but not emitted: {sorted(missing)}\n"
                f"  emitted but not in schema:          {sorted(extra)}")

    # ---- top level ----------------------------------------------------------------------

    def generate(self) -> str:
        self.emit_header()
        self.emit_decode_helpers()

        # Node structs first, which populates self.enums as a side effect.
        body_start = len(self.lines)
        self.emit_helper_types()
        self.emit_nodes()
        self.emit_orgnode()
        body = self.lines[body_start:]
        del self.lines[body_start:]

        self.emit_enums()
        self.lines.extend(body)
        return "\n".join(self.lines) + "\n"

    def emit_header(self) -> None:
        self.w("// GENERATED by harness/regen-ast.py -- do not edit by hand.")
        self.w("// Source: schema/org-node.schema.json, the published cross-language contract.")
        self.w("// Regenerate:  python3 harness/regen-ast.py")
        self.w("// Drift check: python3 harness/regen-ast.py --check")
        self.w("//")
        self.w("// A typed view of the same tree `parseOrg` returns as `OrgJSON`. Additive: the")
        self.w("// untyped API is unchanged and every corpus gate still grades it. See the")
        self.w("// generator's own docstring for the absent-vs-null rule the round-trip depends on.")
        self.w()

    def emit_decode_helpers(self) -> None:
        self.w("""// MARK: - Decoding support

/// Field readers shared by every generated `init(_ json:)`.
///
/// Each throws `OrgError.malformedTree` naming the owning node type and the field, because a
/// decode failure here is a tree this package cannot faithfully represent -- exactly what that
/// case already means for the renderer. Reused rather than adding a parallel error type.
///
/// The `Opt` variants return nil for BOTH an absent key and an explicit JSON null. That looks
/// lossy and is not: which of the two a field may be is fixed by the schema's `required` list,
/// so the emitter always knows which to write back. See the generator docstring.
enum ASTDecode {
    static func fail(_ message: String) -> OrgError { .malformedTree(message) }

    static func object(_ json: OrgJSON, _ owner: String) throws -> [String: OrgJSON] {
        guard let o = json.objectValue else {
            throw fail("\\(owner): expected an object, got \\(json)")
        }
        return o
    }

    static func expectType(_ o: [String: OrgJSON], _ expected: String) throws {
        guard let actual = o["type"]?.stringValue else {
            throw fail("expected a node with type \\"\\(expected)\\", found no type key")
        }
        guard actual == expected else {
            throw fail("expected type \\"\\(expected)\\", got \\"\\(actual)\\"")
        }
    }

    static func require(_ o: [String: OrgJSON], _ key: String,
                        _ owner: String) throws -> OrgJSON {
        guard let v = o[key] else {
            throw fail("\\(owner): missing required field \\"\\(key)\\"")
        }
        return v
    }

    static func wrong(_ owner: String, _ key: String, _ want: String,
                      _ got: OrgJSON) -> OrgError {
        fail("\\(owner).\\(key): expected \\(want), got \\(got)")
    }
}""")
        self.w()
        # The per-kind readers, written once each in both required and optional form.
        readers = [
            ("string", "String", "stringValue", "a string"),
            ("int", "Int", "intValue", "an integer"),
            ("bool", "Bool", "boolValue", "a boolean"),
        ]
        self.w("extension ASTDecode {")
        for name, swift, accessor, want in readers:
            self.w(f"""    static func {name}(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> {swift} {{
        let v = try require(o, k, owner)
        guard let x = v.{accessor} else {{ throw wrong(owner, k, "{want}", v) }}
        return x
    }}

    static func {name}Opt(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> {swift}? {{
        guard let v = o[k], !v.isNull else {{ return nil }}
        guard let x = v.{accessor} else {{ throw wrong(owner, k, "{want}", v) }}
        return x
    }}
""")
        self.w("""    static func stringArray(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> [String] {
        let v = try require(o, k, owner)
        guard let a = v.arrayValue else { throw wrong(owner, k, "an array", v) }
        return try a.map {
            guard let s = $0.stringValue else { throw wrong(owner, k, "an array of strings", v) }
            return s
        }
    }

    static func stringArrayOpt(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> [String]? {
        guard let v = o[k], !v.isNull else { return nil }
        guard let a = v.arrayValue else { throw wrong(owner, k, "an array", v) }
        return try a.map {
            guard let s = $0.stringValue else { throw wrong(owner, k, "an array of strings", v) }
            return s
        }
    }

    static func nodeArray(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> [OrgNode] {
        let v = try require(o, k, owner)
        guard let a = v.arrayValue else { throw wrong(owner, k, "an array of nodes", v) }
        return try a.map { try OrgNode($0) }
    }

    static func nodeArrayOpt(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> [OrgNode]? {
        guard let v = o[k], !v.isNull else { return nil }
        guard let a = v.arrayValue else { throw wrong(owner, k, "an array of nodes", v) }
        return try a.map { try OrgNode($0) }
    }

    static func nested<T>(_ t: T.Type, _ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> T where T: ASTNode {
        try T(try require(o, k, owner))
    }

    static func nestedOpt<T>(_ t: T.Type, _ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> T? where T: ASTNode {
        guard let v = o[k], !v.isNull else { return nil }
        return try T(v)
    }

    static func nestedList<T>(_ t: T.Type, _ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> [T] where T: ASTNode {
        let v = try require(o, k, owner)
        guard let a = v.arrayValue else { throw wrong(owner, k, "an array", v) }
        return try a.map { try T($0) }
    }

    static func nestedListOpt<T>(_ t: T.Type, _ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> [T]? where T: ASTNode {
        guard let v = o[k], !v.isNull else { return nil }
        guard let a = v.arrayValue else { throw wrong(owner, k, "an array", v) }
        return try a.map { try T($0) }
    }

    static func enumValue<T>(_ t: T.Type, _ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> T where T: RawRepresentable, T.RawValue == String {
        let v = try require(o, k, owner)
        guard let s = v.stringValue, let x = T(rawValue: s) else {
            throw wrong(owner, k, "one of \\(T.self)", v)
        }
        return x
    }

    static func enumValueOpt<T>(_ t: T.Type, _ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> T? where T: RawRepresentable, T.RawValue == String {
        guard let v = o[k], !v.isNull else { return nil }
        guard let s = v.stringValue, let x = T(rawValue: s) else {
            throw wrong(owner, k, "one of \\(T.self)", v)
        }
        return x
    }

    static func date(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> OrgDate {
        try OrgDate(try require(o, k, owner))
    }

    static func dateOpt(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> OrgDate? {
        guard let v = o[k], !v.isNull else { return nil }
        return try OrgDate(v)
    }

    static func rep(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> OrgRep {
        try OrgRep(try require(o, k, owner))
    }

    static func repOpt(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> OrgRep? {
        guard let v = o[k], !v.isNull else { return nil }
        return try OrgRep(v)
    }

    static func affiliated(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> OrgAffiliated {
        try OrgAffiliated(try require(o, k, owner))
    }

    static func affiliatedOpt(_ o: [String: OrgJSON], _ k: String,
                    in owner: String) throws -> OrgAffiliated? {
        guard let v = o[k], !v.isNull else { return nil }
        return try OrgAffiliated(v)
    }
}

/// Anything the generated decoders can build from an `OrgJSON` and turn back into one.
public protocol ASTNode: Equatable, Sendable {
    init(_ json: OrgJSON) throws
    func toJSON() -> OrgJSON
}
""")
        self.w()

    def emit_enums(self) -> None:
        self.w("// MARK: - Fixed-value enums")
        self.w("//")
        self.w("// Magic strings in the JSON tree, real types here. Raw values are the schema's own")
        self.w("// spelling; case names are mechanical, so `.+` is `dotPlus` rather than a semantic")
        self.w("// name the generator would have to invent (and `rep` serves both repeaters and")
        self.w("// delays, where the same glyph does not mean the same thing).")
        self.w()
        for name in sorted(self.enums):
            values = self.enums[name]
            self.w(f"public enum {name}: String, Equatable, Sendable, CaseIterable {{")
            for v in values:
                cn = enum_case(v)
                self.w(f'    case {cn} = "{v}"')
            self.w("}")
            self.w()

    def emit_helper_types(self) -> None:
        self.w("// MARK: - Shared value types")
        self.w()
        date = self.defs["date"]
        self.emit_struct("OrgDate", "date", self.fields(date, "date"),
                         "A timestamp component. SCHEMA.md, timestamp.", None)
        rep = self.defs["rep"]
        self.emit_struct("OrgRep", "rep", self.fields(rep, "rep"),
                         "A repeater or delay. NOTE its `type` field is a real enum, not a node "
                         "discriminator.", None)
        self.w("""/// Affiliated keywords, in SOURCE ORDER.
///
/// An ORDERED array rather than a dictionary, because the order is schema data: org-element
/// retains affiliated keys in plist order and SCHEMA.md section 5 pins it. A dictionary would
/// round-trip the wrong byte order on any node with two of them.
///
/// The value shape depends on the key, which is why `Value` is an enum rather than a string.
public struct OrgAffiliated: Equatable, Sendable {
    public struct Caption: Equatable, Sendable {
        public let long: [OrgNode]
        public let short: [OrgNode]?
        public init(long: [OrgNode], short: [OrgNode]?) { self.long = long; self.short = short }
    }

    public struct Results: Equatable, Sendable {
        public let value: String
        public let hash: String?
        public init(value: String, hash: String?) { self.value = value; self.hash = hash }
    }

    public enum Value: Equatable, Sendable {
        case text(String)             // NAME, PLOT
        case strings([String])        // HEADER, ATTR_*
        case captions([Caption])      // CAPTION
        case results(Results)         // RESULTS
    }

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: Value
        public init(key: String, value: Value) { self.key = key; self.value = value }
    }

    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    public init(_ json: OrgJSON) throws {
        guard let array = json.arrayValue else {
            throw ASTDecode.fail("affiliated: expected an array, got \\(json)")
        }
        self.entries = try array.map { item in
            let o = try ASTDecode.object(item, "affiliated entry")
            let key = try ASTDecode.string(o, "key", in: "affiliated entry")
            let raw = try ASTDecode.require(o, "value", "affiliated entry")
            return Entry(key: key, value: try OrgAffiliated.decodeValue(key, raw))
        }
    }

    private static func decodeValue(_ key: String, _ raw: OrgJSON) throws -> Value {
        if let s = raw.stringValue { return .text(s) }
        if let o = raw.objectValue {
            return .results(Results(
                value: try ASTDecode.string(o, "value", in: "affiliated RESULTS"),
                hash: try ASTDecode.stringOpt(o, "hash", in: "affiliated RESULTS")))
        }
        guard let a = raw.arrayValue else {
            throw ASTDecode.fail("affiliated \\(key): unrecognized value shape \\(raw)")
        }
        if a.allSatisfy({ $0.stringValue != nil }) {
            return .strings(a.compactMap(\\.stringValue))
        }
        return .captions(try a.map { entry in
            let c = try ASTDecode.object(entry, "affiliated CAPTION")
            return Caption(long: try ASTDecode.nodeArray(c, "long", in: "affiliated CAPTION"),
                           short: try ASTDecode.nodeArrayOpt(c, "short", in: "affiliated CAPTION"))
        })
    }

    public func toJSON() -> OrgJSON {
        .array(entries.map { entry in
            let value: OrgJSON
            switch entry.value {
            case .text(let s): value = .string(s)
            case .strings(let xs): value = .array(xs.map { .string($0) })
            case .results(let r):
                value = .object(["value": .string(r.value),
                                 "hash": r.hash.map { OrgJSON.string($0) } ?? .null])
            case .captions(let cs):
                value = .array(cs.map { c in
                    .object(["long": .array(c.long.map { $0.toJSON() }),
                             "short": c.short.map { OrgJSON.array($0.map { $0.toJSON() }) }
                                      ?? .null])
                })
            }
            return .object(["key": .string(entry.key), "value": value])
        })
    }
}
""")
        self.w()

    def emit_nodes(self) -> None:
        self.w("// MARK: - Node types")
        self.w()
        for org_name in sorted(self.nodes):
            if org_name == "table":
                continue
            d = self.nodes[org_name]
            swift = "OrgDocument" if org_name == "document" else f"Org{pascal(org_name)}"
            doc = f"`{org_name}`. SCHEMA.md section 4."
            if org_name == "text":
                doc += (" The only node with NO postBlank: org-element tracks post-blank on "
                        "proper element/object nodes, and a bare plain-text span is not one.")
            self.emit_struct(swift, org_name, self.fields(d, org_name), doc, org_name)
        self.emit_table()

    def emit_table(self) -> None:
        org_branch, el_branch = self.table["oneOf"]
        self.w("""/// `table`. The one node whose schema def is a two-branch `oneOf`, both under the same
/// `type: "table"`: an org-flavour table carries ROWS, a `table.el`-flavour one carries its raw
/// text as a single string, and neither ever carries both.
///
/// Modelling that as a `Flavour` enum is where typing pays here. In the untyped tree a consumer
/// has to know by folklore which key to look for, and reading `children` on a table.el table
/// silently yields nothing.
public struct OrgTable: Equatable, Sendable {
    public enum Flavour: Equatable, Sendable {
        case org(rows: [OrgTableRow])
        case tableEl(value: String)
    }

    public let flavour: Flavour
    public let tblfm: [String]?
    public let postBlank: Int
    public let affiliated: OrgAffiliated?

    public init(flavour: Flavour, tblfm: [String]?, postBlank: Int,
                affiliated: OrgAffiliated? = nil) {
        self.flavour = flavour
        self.tblfm = tblfm
        self.postBlank = postBlank
        self.affiliated = affiliated
    }

    public init(_ json: OrgJSON) throws {
        let o = try ASTDecode.object(json, "table")
        try ASTDecode.expectType(o, "table")
        self.tblfm = try ASTDecode.stringArrayOpt(o, "tblfm", in: "table")
        self.postBlank = try ASTDecode.int(o, "postBlank", in: "table")
        self.affiliated = try ASTDecode.affiliatedOpt(o, "affiliated", in: "table")
        // Dispatch on which branch is PRESENT. Neither, or both, is a malformed tree rather
        // than a defaultable case -- silently preferring one would invent a table.
        switch (o["children"], o["value"]) {
        case (.some, .some):
            throw ASTDecode.fail("table: carries both children and value; the schema's oneOf "
                                 + "permits exactly one")
        case (.some, .none):
            self.flavour = .org(rows: try ASTDecode.nestedList(
                OrgTableRow.self, o, "children", in: "table"))
        case (.none, .some):
            self.flavour = .tableEl(value: try ASTDecode.string(o, "value", in: "table"))
        case (.none, .none):
            throw ASTDecode.fail("table: has neither children nor value")
        }
    }

    public func toJSON() -> OrgJSON {
        var o: [String: OrgJSON] = ["type": .string("table")]
        o["tblfm"] = tblfm.map { OrgJSON.array($0.map { .string($0) }) } ?? .null
        o["postBlank"] = .int(postBlank)
        if let a = affiliated { o["affiliated"] = a.toJSON() }
        switch flavour {
        case .org(let rows): o["children"] = .array(rows.map { $0.toJSON() })
        case .tableEl(let value): o["value"] = .string(value)
        }
        return .object(o)
    }
}
""")
        self.w()

    def emit_orgnode(self) -> None:
        # `table` is emitted by `emit_table` rather than the uniform loop, because its def is a
        # oneOf and carries no flat `properties`. That also keeps it out of `self.nodes`, and the
        # first cut of this method iterated `self.nodes` alone -- so `OrgTable` was generated,
        # compiled, and unreachable, and any document containing a table decoded as "unknown
        # org-element type". `assertCoverage` below is the standing guard against that shape:
        # the special case is fine, forgetting to rejoin it is not.
        names = sorted(list(self.nodes) + ["table"])
        self.assert_coverage(names)
        self.w("// MARK: - OrgNode")
        self.w()
        self.w("""/// Any node in the tree, tagged by its org-element type.
///
/// Exhaustive: a `switch` over this covers every type the oracle maps, and the compiler says so.
/// That is the property the untyped tree cannot offer -- a new node type added upstream is a
/// silently skipped branch there and a build error here.
public indirect enum OrgNode: Equatable, Sendable {""")
        for n in names:
            swift = "OrgDocument" if n == "document" else f"Org{pascal(n)}"
            self.w(f"    case {case_name(n)}({swift})")
        self.w("}")
        self.w()
        self.w("extension OrgNode: ASTNode {")
        self.w("    /// The org-element type string this node carries in the JSON tree.")
        self.w("    public var typeName: String {")
        self.w("        switch self {")
        for n in names:
            self.w(f'        case .{case_name(n)}: return "{n}"')
        self.w("        }")
        self.w("    }")
        self.w()
        self.w("    public init(_ json: OrgJSON) throws {")
        self.w('        let o = try ASTDecode.object(json, "node")')
        self.w('        guard let tag = o["type"]?.stringValue else {')
        self.w('            throw ASTDecode.fail("node: missing a type key: \\(json)")')
        self.w("        }")
        self.w("        switch tag {")
        for n in names:
            swift = "OrgDocument" if n == "document" else f"Org{pascal(n)}"
            self.w(f'        case "{n}": self = .{case_name(n)}(try {swift}(json))')
        self.w("        default:")
        self.w('            throw ASTDecode.fail("node: unknown org-element type \\"\\(tag)\\". '
               'The typed layer is generated from schema/org-node.schema.json; regenerate it '
               'if the schema gained a type.")')
        self.w("        }")
        self.w("    }")
        self.w()
        self.w("    public func toJSON() -> OrgJSON {")
        self.w("        switch self {")
        for n in names:
            self.w(f"        case .{case_name(n)}(let x): return x.toJSON()")
        self.w("        }")
        self.w("    }")
        self.w("}")
        self.w()
        self.emit_child_nodes(names)

    def emit_child_nodes(self, names: list[str]) -> None:
        """Every nested `OrgNode` a node holds, in field order.

        Generated rather than hand-written because it is a 55-case switch that must stay exact:
        a node whose children this forgot would be silently invisible to every traversal built on
        it, and no test of the traversal itself would notice. The generator already knows which
        fields hold nodes, so it is the only place that cannot fall out of step.

        Includes SECONDARY STRINGS, not just `children`. A headline's `title` and a link's
        `description` are node arrays that happen to sit in a differently-named field; a walk
        that skipped them would miss most of the objects in a real document.
        """
        self.w("""extension OrgNode {
    /// Every nested node this one holds, in field order, one level down.
    ///
    /// Secondary strings count: a headline's `title` and a link's `description` are node arrays
    /// too, and a traversal that visited only `children` would miss most of the objects in a
    /// real file. See `walk()` in OrgAST+Support.swift for the recursive form.
    public var childNodes: [OrgNode] {
        switch self {""")
        for n in names:
            parts: list[str] = []
            if n == "table":
                self.w("        case .table(let x):")
                self.w("            if case .org(let rows) = x.flavour "
                       "{ return rows.map { OrgNode.tableRow($0) } }")
                self.w("            return []")
                continue
            for f in self.fields(self.nodes[n], n):
                kind, name = f["kind"], f["swift"]
                if kind in ("nodeArray", "nodeArrayOrNull"):
                    parts.append(f"(x.{name}{' ?? []' if f['optional'] else ''})")
                elif kind.startswith("nodeList:"):
                    inner = case_name(kind[9:])
                    opt = " ?? []" if f["optional"] else ""
                    parts.append(f"(x.{name}{opt}).map {{ OrgNode.{inner}($0) }}")
            if not parts:
                self.w(f"        case .{case_name(n)}: return []")
            else:
                self.w(f"        case .{case_name(n)}(let x): return "
                       + " + ".join(parts))
        self.w("        }")
        self.w("    }")
        self.w("}")
        self.w()
        self.emit_post_blank(names)
        # Conform every generated struct to ASTNode.
        self.w("// Every generated node type satisfies the decode/encode contract.")
        for n in names:
            swift = "OrgDocument" if n == "document" else f"Org{pascal(n)}"
            self.w(f"extension {swift}: ASTNode {{}}")
        self.w("extension OrgDate: ASTNode {}")
        self.w("extension OrgRep: ASTNode {}")


def main() -> int:
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    generated = Generator(schema).generate()

    if "--check" in sys.argv[1:]:
        if not OUT.exists():
            print(f"regen-ast --check: {OUT} does not exist", file=sys.stderr)
            return 1
        current = OUT.read_text(encoding="utf-8")
        if current != generated:
            print("regen-ast --check: FAIL, the committed file is not what the schema produces.",
                  file=sys.stderr)
            print("Run: python3 harness/regen-ast.py", file=sys.stderr)
            return 1
        print("regen-ast --check: OK, committed output matches the schema")
        return 0

    OUT.write_text(generated, encoding="utf-8")
    cases = generated.count("\n    case ", generated.index("public indirect enum OrgNode"),
                            generated.index("extension OrgNode: ASTNode"))
    print(f"regen-ast: wrote {OUT.relative_to(ROOT)} "
          f"({cases} node types in OrgNode, {len(generated.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
