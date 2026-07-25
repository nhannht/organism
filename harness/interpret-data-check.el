;;; interpret-data-check.el --- Non-circular round-trip check: org-element-interpret-data vs original bytes  -*- lexical-binding: t; -*-

;; Purpose: Layer 3's real correctness signal, independent of oracle-dump.el's
;; own JSON-shape decisions entirely. Where OracleConformanceCrossCheckTests
;; compares oracle-dump.el's output to expected.json (circular once
;; expected.json is GENERATED from that same oracle - see that test's own
;; docstring), this script asks a completely different question, using only
;; org-element's OWN parse function and its OWN unparse function, with none
;; of orgswift's JSON machinery anywhere in the loop:
;;
;;   org-element-interpret-data(org-element-parse-buffer(FILE)) == FILE's bytes?
;;
;; If this holds, it proves org-element's parse tree - properties, contents,
;; and :post-blank, but explicitly NOT :begin/:end/:contents-begin/
;; :contents-end, since `org-element-interpret-data' never reads those -
;; carries enough information to reconstruct the source exactly. That is the
;; empirical foundation for going reference-faithful (SCHEMA.md section 1):
;; if buffer positions are truly redundant here, a schema that keeps
;; everything BUT positions can, in principle, round-trip too.
;;
;; Scope note (reported to main, not a silent gap): this does NOT prove
;; orgswift's own JSON tree round-trips - only that org-element's tree does.
;; orgswift's oracle keeps a curated per-type field set (see SCHEMA.md) plus
;; :post-blank, not literally every org-element property. A property this
;; script never exercises - because `org-element-interpret-data' does not
;; need it, or because no fixture in this corpus triggers it (:pre-blank,
;; src-block :switches, etc.) - could still be silently dropped by the JSON
;; projection without this check ever noticing, since it never passes
;; through orgswift's JSON at all.
;;
;; Usage (from the repo root):
;;   emacs --batch -Q -l harness/interpret-data-check.el --eval '(org-swift-check-roundtrip "path/to/file.org")'
;;
;; Prints one JSON object to stdout:
;;   {"match": true}
;;   {"match": false, "originalLength": N, "interpretedLength": M,
;;    "firstDiffOffset": K, "originalContext": "...", "interpretedContext": "..."}

(unless (fboundp 'json-serialize)
  (error "interpret-data-check.el requires Emacs 27+ with native JSON support (json-serialize)"))

(require 'org)

(defun org-swift--context (string offset)
  "Return up to 20 characters of STRING centered on OFFSET, for a readable
mismatch report. Clamped to STRING's bounds - OFFSET may legitimately land at
either end when one string is a strict prefix of the other."
  (let* ((len (length string))
         (safe-offset (max 0 (min offset len)))
         (start (max 0 (- safe-offset 10)))
         (end (min len (+ safe-offset 10))))
    (substring string start end)))

(defun org-swift-check-roundtrip (path)
  "Parse the .org file at PATH, run `org-element-interpret-data' on the
result of `org-element-parse-buffer', and compare that reconstructed text
against PATH's original bytes byte-for-byte. Prints one JSON result object
to stdout - see the file header for the two possible shapes."
  (unless (file-readable-p path)
    (error "interpret-data-check.el: cannot read file: %s" path))
  (let ((coding-system-for-read 'utf-8)
        original interpreted)
    (with-temp-buffer
      (insert-file-contents path)
      (setq original (buffer-string))
      ;; `org-mode' must run AFTER the text is inserted, same reasoning as
      ;; oracle-dump.el's `org-swift-dump': it needs to scan this buffer's
      ;; own `#+TODO:' line before `org-element-parse-buffer' runs, so
      ;; runtime TODO keywords round-trip correctly too.
      (org-mode)
      (setq interpreted (org-element-interpret-data (org-element-parse-buffer))))
    (let ((result (make-hash-table :test 'equal)))
      (if (string= original interpreted)
          (puthash "match" t result)
        (let* ((cmp (compare-strings original nil nil interpreted nil nil))
               ;; `compare-strings' returns t on equality (handled above) or
               ;; a 1-based mismatch index, signed to indicate which string
               ;; sorts later at that point - the sign carries no meaning
               ;; here, only the magnitude (the offset itself) does.
               (offset (1- (abs cmp))))
          (puthash "match" :false result)
          (puthash "originalLength" (length original) result)
          (puthash "interpretedLength" (length interpreted) result)
          (puthash "firstDiffOffset" offset result)
          (puthash "originalContext" (org-swift--context original offset) result)
          (puthash "interpretedContext" (org-swift--context interpreted offset) result)))
      (princ (decode-coding-string (json-serialize result) 'utf-8))
      (princ "\n"))))

(provide 'interpret-data-check)
;;; interpret-data-check.el ends here
