// go-org accuracy adapter (see bench/accuracy/README.md for the fairness protocol):
//
//	go build -o go-org-adapter.bin ./adapter && ./go-org-adapter.bin <file.org>
//
// parses the file with go-org (same pinned module the speed runner times) and re-encodes
// go-org's own AST into this repo's schema shape (schema/org-node.schema.json).
//
// Pure re-encoder. go-org's AST is renderer-oriented and drops most of org-element's
// bookkeeping: no blank-line counts anywhere, no node positions, timestamps normalized
// through time.Time (source dayname gone, only the active <...> form parsed), soft line
// breaks as LineBreak nodes. The adapter merges Text+LineBreak runs back into org-element's
// newline-bearing text values, restores structural delimiters go-org strips (statistics
// cookie brackets, latex fragment pairs), and emits postBlank 0 everywhere - the structure
// tier of the grader is where go-org can score.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"strings"

	"github.com/niklasfasching/go-org/org"
)

type M = map[string]any

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: go-org-adapter <file.org>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	src := string(data)
	conf := org.New()
	conf.Log = log.New(io.Discard, "", 0)
	doc := conf.Parse(strings.NewReader(src), os.Args[1])
	if doc.Error != nil {
		fmt.Fprintln(os.Stderr, doc.Error)
		os.Exit(1)
	}

	document := M{"type": "document", "children": mapTop(doc.Nodes), "postBlank": 0}
	if !strings.HasSuffix(src, "\n") {
		stripFinalNewline(document)
	}
	out, err := json.Marshal(document)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

// ---- structure ---------------------------------------------------------------------------

func mapTop(nodes []org.Node) []any {
	var pre []org.Node
	var headlines []org.Node
	for i, n := range nodes {
		if _, ok := n.(org.Headline); ok {
			headlines = nodes[i:]
			break
		}
		pre = append(pre, n)
	}
	if headlines == nil {
		pre = nodes
	}
	children := []any{}
	if len(pre) > 0 {
		if sec := section(mapElements(pre)); sec != nil {
			children = append(children, sec)
		}
	}
	for _, h := range headlines {
		if hl, ok := h.(org.Headline); ok {
			children = append(children, mapHeadline(hl))
		}
	}
	return children
}

func section(elems []any) M {
	if len(elems) == 0 {
		return nil
	}
	return M{"type": "section", "children": elems, "postBlank": 0}
}

func mapHeadline(h org.Headline) M {
	var body []org.Node
	var subs []org.Headline
	for _, c := range h.Children {
		if sub, ok := c.(org.Headline); ok {
			subs = append(subs, sub)
		} else {
			body = append(body, c)
		}
	}
	elems := []any{}
	if h.Properties != nil && len(h.Properties.Properties) > 0 {
		elems = append(elems, propertyDrawer(h.Properties))
	}
	elems = append(elems, mapElements(body)...)
	children := []any{}
	if sec := section(elems); sec != nil {
		children = append(children, sec)
	}
	for _, sub := range subs {
		children = append(children, mapHeadline(sub))
	}
	tags := []any{}
	for _, t := range h.Tags {
		tags = append(tags, t)
	}
	return M{
		"type": "headline", "level": h.Lvl, "trueLevel": h.Lvl,
		"todo": nullIfEmpty(h.Status), "priority": nullIfEmpty(h.Priority),
		"commented": false, "tags": tags, "title": mapObjects(h.Title, false),
		"preBlank": 0, "children": children, "postBlank": 0,
	}
}

func propertyDrawer(pd *org.PropertyDrawer) M {
	props := []any{}
	for _, kv := range pd.Properties {
		val := any(nil)
		if len(kv) > 1 && kv[1] != "" {
			val = kv[1]
		}
		props = append(props, M{"type": "node-property", "key": kv[0], "value": val, "postBlank": 0})
	}
	return M{"type": "property-drawer", "children": props, "postBlank": 0}
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// ---- elements ----------------------------------------------------------------------------

func mapElements(nodes []org.Node) []any {
	out := []any{}
	for _, n := range nodes {
		if m := mapElement(n); m != nil {
			out = append(out, m)
		}
	}
	return out
}

func mapElement(n org.Node) any {
	switch v := n.(type) {
	case org.Paragraph:
		kids := mapObjects(v.Children, true)
		return M{"type": "paragraph", "children": kids, "postBlank": 0}
	case org.Block:
		return mapBlock(v)
	case org.Example:
		lines := make([]string, 0, len(v.Children))
		for _, c := range v.Children {
			if t, ok := c.(org.Text); ok {
				lines = append(lines, t.Content)
			}
		}
		// org-element's fixed-width postBlank counts the element's own final newline
		// (measured convention; blank-line info beyond that is absent from go-org's AST)
		return M{"type": "fixed-width", "value": strings.Join(lines, "\n"), "postBlank": 1}
	case org.List:
		items := []any{}
		for _, it := range v.Items {
			items = append(items, mapItem(it))
		}
		return M{"type": "list", "kind": v.Kind, "children": items, "postBlank": 0}
	case org.Keyword:
		return M{"type": "keyword", "key": strings.ToUpper(v.Key), "value": v.Value, "postBlank": 0}
	case org.NodeWithName:
		inner := mapElement(v.Node)
		return addAffiliated(inner, M{"key": "NAME", "value": v.Name})
	case org.NodeWithMeta:
		inner := mapElement(v.Node)
		for i := len(v.Meta.Caption) - 1; i >= 0; i-- {
			_ = i
		}
		if len(v.Meta.Caption) > 0 {
			vals := []any{}
			for _, capt := range v.Meta.Caption {
				vals = append(vals, M{"long": mapObjects(capt, false), "short": nil})
			}
			inner = addAffiliated(inner, M{"key": "CAPTION", "value": vals})
		}
		if len(v.Meta.HTMLAttributes) > 0 {
			vals := []any{}
			for _, attrs := range v.Meta.HTMLAttributes {
				vals = append(vals, strings.Join(attrs, " "))
			}
			inner = addAffiliated(inner, M{"key": "ATTR_HTML", "value": vals})
		}
		return inner
	case org.Drawer:
		return M{"type": "drawer", "name": v.Name, "children": mapElements(v.Children), "postBlank": 0}
	case org.PropertyDrawer:
		return propertyDrawer(&v)
	case org.FootnoteDefinition:
		return M{
			"type": "footnote-definition", "label": v.Name, "preBlank": 0,
			"children": mapElements(v.Children), "postBlank": 0,
		}
	case org.Table:
		return mapTable(v)
	case org.HorizontalRule:
		return M{"type": "horizontal-rule", "postBlank": 0}
	case org.Comment:
		return M{"type": "comment", "value": strings.TrimPrefix(strings.TrimSpace(v.Content), " "), "postBlank": 0}
	case org.LatexBlock:
		lines := []string{}
		for _, c := range v.Content {
			if t, ok := c.(org.Text); ok {
				lines = append(lines, t.Content)
			}
		}
		return M{"type": "latex-environment", "value": strings.Join(lines, "\n") + "\n", "postBlank": 0}
	case org.Headline:
		return mapHeadline(v)
	default:
		return nil // construct with no schema mapping; the diff records the loss
	}
}

func addAffiliated(inner any, entry M) any {
	m, ok := inner.(M)
	if !ok {
		return inner
	}
	existing, _ := m["affiliated"].([]any)
	m["affiliated"] = append([]any{entry}, existing...)
	return m
}

func mapBlock(b org.Block) any {
	params := b.Parameters
	switch b.Name {
	case "SRC":
		// go-org fuses "language -switches" into Parameters[0] and header args into
		// ":key value" pairs beyond it. The language is by definition the first token;
		// the fused switch tail has no honest slot (marker-listed) and is dropped.
		lang := any(nil)
		if len(params) > 0 {
			if fields := strings.Fields(params[0]); len(fields) > 0 {
				lang = fields[0]
			}
		}
		headerArgs := []string{}
		for i := 1; i+1 < len(params); i += 2 {
			headerArgs = append(headerArgs, params[i]+" "+params[i+1])
		}
		return M{
			"type": "src-block", "language": lang, "switches": nil,
			"params": nullIfEmpty(strings.Join(headerArgs, " ")),
			"value":  rawBlockValue(b.Children), "postBlank": 0,
		}
	case "EXAMPLE":
		return M{
			"type": "example-block", "switches": nullIfEmpty(strings.Join(params, " ")),
			"value": rawBlockValue(b.Children), "postBlank": 0,
		}
	case "EXPORT":
		backend := any(nil)
		if len(params) > 0 {
			backend = strings.ToUpper(params[0])
		}
		return M{"type": "export-block", "backend": backend, "value": rawBlockValue(b.Children), "postBlank": 0}
	case "COMMENT":
		// go-org parses comment-block contents as elements; rejoin their text lines
		lines := []string{}
		for _, c := range b.Children {
			if p, ok := c.(org.Paragraph); ok {
				lines = append(lines, contentText(p.Children))
			}
		}
		val := strings.Join(lines, "\n")
		if val != "" {
			val += "\n"
		}
		return M{"type": "comment-block", "value": val, "postBlank": 0}
	case "QUOTE", "CENTER":
		return M{
			"type": strings.ToLower(b.Name) + "-block",
			"children": mapElements(b.Children), "postBlank": 0,
		}
	case "VERSE":
		// go-org wraps verse contents in paragraphs; org-element holds objects directly
		flat := []any{}
		for _, c := range b.Children {
			if p, ok := c.(org.Paragraph); ok {
				flat = append(flat, mapObjects(p.Children, true)...)
			} else if m := mapElement(c); m != nil {
				flat = append(flat, m)
			}
		}
		return M{"type": "verse-block", "children": flat, "postBlank": 0}
	default:
		return M{
			"type": "special-block", "blockType": strings.ToLower(b.Name),
			"parameters": nullIfEmpty(strings.Join(params, " ")),
			"children":   mapElements(b.Children), "postBlank": 0,
		}
	}
}

func rawBlockValue(children []org.Node) string {
	lines := []string{}
	for _, c := range children {
		if t, ok := c.(org.Text); ok {
			lines = append(lines, t.Content)
		}
	}
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}

func mapItem(n org.Node) any {
	switch v := n.(type) {
	case org.ListItem:
		return M{
			"type": "item", "bullet": v.Bullet + " ", "checkbox": checkbox(v.Status),
			"counter": nil, "tag": nil, "preBlank": 0,
			"children": mapElements(v.Children), "postBlank": 0,
		}
	case org.DescriptiveListItem:
		return M{
			"type": "item", "bullet": v.Bullet + " ", "checkbox": checkbox(v.Status),
			"counter": nil, "tag": mapObjects(v.Term, false), "preBlank": 0,
			"children": mapElements(v.Details), "postBlank": 0,
		}
	default:
		return nil
	}
}

func checkbox(status string) any {
	switch status {
	case "X", "x":
		return "on"
	case " ":
		return "off"
	case "-":
		return "trans"
	default:
		return nil
	}
}

func mapTable(t org.Table) any {
	rows := []any{}
	for _, r := range t.Rows {
		if r.IsSpecial || len(r.Columns) == 0 {
			rows = append(rows, M{"type": "table-row", "kind": "rule", "children": []any{}, "postBlank": 0})
			continue
		}
		cells := []any{}
		for _, c := range r.Columns {
			cells = append(cells, M{"type": "table-cell", "children": mapObjects(c.Children, false), "postBlank": 0})
		}
		rows = append(rows, M{"type": "table-row", "kind": "standard", "children": cells, "postBlank": 0})
	}
	return M{"type": "table", "tblfm": nil, "children": rows, "postBlank": 0}
}

// ---- objects -----------------------------------------------------------------------------

// mapObjects merges go-org's Text + LineBreak runs back into newline-bearing text values,
// moves the spaces go-org keeps at the head of a following text onto the previous object's
// postBlank, and (in paragraph context) restores the final line terminator.
func mapObjects(nodes []org.Node, paragraphContext bool) []any {
	out := []any{}
	var textRun strings.Builder
	flush := func() {
		if textRun.Len() > 0 {
			out = append(out, M{"type": "text", "value": textRun.String()})
			textRun.Reset()
		}
	}
	for _, n := range nodes {
		switch v := n.(type) {
		case org.Text:
			textRun.WriteString(v.Content)
		case org.LineBreak:
			textRun.WriteString(strings.Repeat("\n", v.Count))
		default:
			flush()
			if m := mapObject(n); m != nil {
				out = append(out, m)
			} else if raw := rawFallback(n); raw != "" {
				textRun.WriteString(raw)
			}
		}
	}
	flush()
	out = moveObjectSpacing(out)
	if paragraphContext {
		out = ensureTrailingNewline(out)
	}
	return out
}

func rawFallback(org.Node) string { return "" }

func moveObjectSpacing(children []any) []any {
	for i := 0; i < len(children); i++ {
		m, ok := children[i].(M)
		if !ok || m["type"] == "text" || i+1 >= len(children) {
			continue
		}
		next, ok := children[i+1].(M)
		if !ok || next["type"] != "text" {
			continue
		}
		v, _ := next["value"].(string)
		trimmed := strings.TrimLeft(v, " \t")
		if ws := len(v) - len(trimmed); ws > 0 {
			if pb, ok := m["postBlank"].(int); ok {
				m["postBlank"] = pb + ws
			}
			if trimmed == "" {
				children = append(children[:i+1], children[i+2:]...)
			} else {
				next["value"] = trimmed
			}
		}
	}
	return children
}

func ensureTrailingNewline(children []any) []any {
	if len(children) == 0 {
		return children
	}
	if last, ok := children[len(children)-1].(M); ok {
		if last["type"] == "text" {
			v, _ := last["value"].(string)
			if !strings.HasSuffix(v, "\n") {
				last["value"] = v + "\n"
			}
		} else {
			children = append(children, M{"type": "text", "value": "\n"})
		}
	}
	return children
}

var emphasisKinds = map[string]string{
	"*": "bold", "/": "italic", "_": "underline", "+": "strikethrough",
}

func mapObject(n org.Node) any {
	switch v := n.(type) {
	case org.Emphasis:
		if kind, ok := emphasisKinds[v.Kind]; ok {
			return M{"type": kind, "children": mapObjects(v.Content, false), "postBlank": 0}
		}
		switch v.Kind {
		case "=":
			return M{"type": "verbatim", "value": contentText(v.Content), "postBlank": 0}
		case "~":
			return M{"type": "code", "value": contentText(v.Content), "postBlank": 0}
		case "_{}":
			// go-org only matches the braced form
			return M{"type": "subscript", "useBrackets": true, "children": mapObjects(v.Content, false), "postBlank": 0}
		case "^{}":
			return M{"type": "superscript", "useBrackets": true, "children": mapObjects(v.Content, false), "postBlank": 0}
		}
		return nil
	case org.RegularLink:
		linkType := "regular"
		if v.AutoLink {
			linkType = "plain"
		}
		var desc any
		if len(v.Description) > 0 {
			desc = mapObjects(v.Description, false)
		}
		return M{
			"type": "link", "linkType": linkType, "pathType": nullIfEmpty(v.Protocol),
			"path": v.URL, "description": desc, "postBlank": 0,
		}
	case org.FootnoteLink:
		inline := v.Definition != nil && v.Definition.Inline
		m := M{"type": "footnote-reference", "label": nullIfEmpty(v.Name), "inline": inline, "postBlank": 0}
		if inline {
			kids := []any{}
			for _, c := range v.Definition.Children {
				if p, ok := c.(org.Paragraph); ok {
					kids = append(kids, mapObjects(p.Children, false)...)
				}
			}
			m["children"] = kids
		}
		return m
	case org.Timestamp:
		// go-org parses only the active <...> form and normalizes through time.Time:
		// the source dayname is gone (recomputing it would fabricate source bytes)
		start := M{
			"year": v.Time.Year(), "month": int(v.Time.Month()), "day": v.Time.Day(),
			"dayname": nil, "hour": nil, "minute": nil,
		}
		if !v.IsDate {
			start["hour"] = v.Time.Hour()
			start["minute"] = v.Time.Minute()
		}
		return M{
			"type": "timestamp", "kind": "active", "rangeType": nil,
			"start": start, "end": nil, "repeater": cookie(strings.TrimSpace(v.Interval)),
			"delay": nil, "postBlank": 0,
		}
	case org.StatisticToken:
		return M{"type": "statistics-cookie", "value": "[" + v.Content + "]", "postBlank": 0}
	case org.Macro:
		val := "{{{" + v.Name
		if len(v.Parameters) > 0 {
			val += "(" + strings.Join(v.Parameters, ",") + ")"
		}
		val += "}}}"
		return M{"type": "macro", "value": val, "postBlank": 0}
	case org.LatexFragment:
		return M{
			"type": "latex-fragment",
			"value": v.OpeningPair + contentText(v.Content) + v.ClosingPair, "postBlank": 0,
		}
	case org.ExplicitLineBreak:
		return M{"type": "line-break", "postBlank": 0}
	case org.InlineBlock:
		if v.Name == "src" && len(v.Parameters) > 0 {
			return M{
				"type": "inline-src-block", "language": v.Parameters[0],
				"parameters": nullIfEmpty(strings.Join(v.Parameters[1:], " ")),
				"value":      contentText(v.Children), "postBlank": 0,
			}
		}
		return nil
	default:
		return nil
	}
}

// cookie decomposes an already-isolated repeater token ("+1w") into {type,value,unit}.
func cookie(raw string) any {
	if raw == "" {
		return nil
	}
	ty := ""
	for _, p := range []string{"++", ".+", "--", "+", "-"} {
		if strings.HasPrefix(raw, p) {
			ty = p
			break
		}
	}
	if ty == "" {
		return nil
	}
	rest := raw[len(ty):]
	i := 0
	for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
		i++
	}
	if i == 0 {
		return nil
	}
	value := 0
	for _, c := range rest[:i] {
		value = value*10 + int(c-'0')
	}
	return M{"type": ty, "value": value, "unit": rest[i:]}
}

func contentText(nodes []org.Node) string {
	var b strings.Builder
	for _, n := range nodes {
		switch v := n.(type) {
		case org.Text:
			b.WriteString(v.Content)
		case org.LineBreak:
			b.WriteString(strings.Repeat("\n", v.Count))
		}
	}
	return b.String()
}

// ---- final-newline fixup -----------------------------------------------------------------

func stripFinalNewline(node M) {
	children, ok := node["children"].([]any)
	if !ok || len(children) == 0 {
		return
	}
	last, ok := children[len(children)-1].(M)
	if !ok {
		return
	}
	if last["type"] == "text" {
		v, _ := last["value"].(string)
		if strings.HasSuffix(v, "\n") {
			trimmed := strings.TrimSuffix(v, "\n")
			if trimmed == "" {
				node["children"] = children[:len(children)-1]
			} else {
				last["value"] = trimmed
			}
		}
	} else {
		stripFinalNewline(last)
	}
}
