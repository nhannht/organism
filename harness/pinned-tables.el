;;; pinned-tables.el --- regenerate every Emacs table this parser pins  -*- lexical-binding: t; -*-

;; Usage, from the repository root:
;;
;;     emacs --batch -Q -l harness/pinned-tables.el --eval '(org-swift-dump-pinned-tables)'
;;
;; Prints one dataset per line-group to stdout, in a flat tab-separated form meant for a
;; program rather than a person. `Tests/OrgSwiftTests/PinnedTableDriftTests.swift' is that
;; program; it recomputes the Swift half itself and diffs.
;;
;; ## Why this file exists (ORG-17)
;;
;; Five constants in `Sources/OrgSwift' are Emacs data transcribed, enumerated or differenced
;; into Swift. Every one of them was measured once, against Emacs 30.2 / org 9.7.11 and
;; Swift 6.3.3 / Unicode 17.0, and then NOTHING re-ran the measurement. Their own doc comments
;; say so in as many words -- "staleness is NOT self-detecting", "nothing in this repository
;; re-runs the enumeration", "re-measuring on a toolchain bump is a manual obligation".
;;
;; A manual obligation attached to no gate is the shape this project keeps finding: a reasoned
;; invariant nothing enforces. Two independent tables move underneath these constants (Emacs's
;; case tables and Swift's Unicode tables), each on its own release schedule, and a stale
;; entry fails exactly as quietly as the bug it was written to fix.
;;
;; ## The three regeneration SHAPES, which are not interchangeable
;;
;; The five tables do not regenerate the same way, and writing one uniform differ for them
;; would have to fake three of them:
;;
;;   TRANSCRIPTION      org owns a data structure; dump it and compare as-is.
;;                      `org-element-object-restrictions'.
;;   DIFFERENCE SET     neither side owns the table -- it IS the disagreement between Emacs
;;                      and Swift, so both halves must be computed independently and diffed.
;;                      `upcaseDeclined', `radioCanonExtra' / `radioCanonDeclined'.
;;   BEHAVIOURAL        no table exists anywhere; the answer is what org DOES, one probe at a
;;   ENUMERATION        time. `radioBlockingRanges' (a predicate over the scalar space) and
;;                      the inline-callable boundary table (a live parse per character).
;;
;; Reading a difference set as a transcription is the specific error to avoid: `upcaseDeclined'
;; is not "Emacs's table", it is what Emacs's table lacks relative to Swift's, and a differ
;; that dumped only the Emacs side would report drift on every entry.

(require 'org)
(require 'org-element)

(defun org-swift--pt-emit (tag &rest fields)
  (princ (mapconcat #'identity (cons tag (mapcar (lambda (f) (format "%s" f)) fields)) "\t"))
  (princ "\n"))

(defun org-swift--pt-restrictions ()
  "TRANSCRIPTION: `org-element-object-restrictions', one row per container."
  (dolist (row org-element-object-restrictions)
    (org-swift--pt-emit
     "RESTRICT" (car row)
     (mapconcat #'symbol-name (sort (copy-sequence (cdr row)) #'string<) ","))))

(defun org-swift--pt-upcase ()
  "DIFFERENCE SET, Emacs half: every scalar Emacs's `upcase' CHANGES.
The Swift half is `String(scalar).uppercased() != String(scalar)'; the pinned
`upcaseDeclined' table is the Swift set minus this one. Emitting only this half
is deliberate -- the table is a disagreement, and elisp cannot see Swift's side."
  (dotimes (v (1+ #x10FFFF))
    (unless (and (>= v #xD800) (<= v #xDFFF))
      ;; STRING upcase, not `(upcase CHAR)'. The character form can only ever return one
      ;; character, so it reports ŉ, և and the other 72 multi-character expansions as unchanged
      ;; -- and Emacs DOES upcase every one of them (ŉ -> ʼN, և -> ԵՒ). Getting this wrong made
      ;; the first run of the drift guard report 74 spurious entries on a table that was right.
      ;; The Swift half compares `String(scalar).uppercased()` against the scalar, so this is
      ;; also the only form that asks the two authorities the SAME question.
      (let ((one (string v)))
        (unless (string= one (upcase one))
          (org-swift--pt-emit "UPCASE" (format "%X" v)))))))

(defun org-swift--pt-canon ()
  "DIFFERENCE SET, Emacs half: the case-fold CANON slot, for every scalar it folds.
Read from an ORG-MODE buffer, because the case table is what `case-fold-search'
translates through and a radio link is matched under it."
  (with-temp-buffer
    (org-mode)
    (let ((table (case-table-get-table (current-case-table) 'canon)))
      (dotimes (v (1+ #x10FFFF))
        (unless (and (>= v #xD800) (<= v #xDFFF))
          (let ((folded (aref table v)))
            (when (and folded (/= folded v))
              (org-swift--pt-emit "CANON" (format "%X" v) (format "%X" folded)))))))))

(defun org-swift--pt-radio-blocking ()
  "BEHAVIOURAL ENUMERATION: the scalars that BLOCK a radio-link match, as ranges.

`org-target-link-regexp' treats a scalar as a BOUNDARY when it is non-alphanumeric
OR carries category `|' (line-breakable), so a scalar blocks when it is alnum AND
not category `|'. Both halves are asked of Emacs here rather than reasoned about --
Emacs's `[[:alnum:]]' is not `[:alpha:]' union `[:digit:]' (they differ on 660
scalars), and no Swift predicate stands in for either."
  (with-temp-buffer
    (org-mode)
    (let ((start nil) (previous nil))
      (dotimes (v (1+ #x10FFFF))
        (let ((blocking (and (not (and (>= v #xD800) (<= v #xDFFF)))
                             (string-match-p "[[:alnum:]]" (string v))
                             (not (string-match-p "\\c|" (string v))))))
          (cond
           ((and blocking (null start)) (setq start v previous v))
           ((and blocking (= v (1+ previous))) (setq previous v))
           (blocking
            (org-swift--pt-emit "BLOCK" (format "%X" start) (format "%X" previous))
            (setq start v previous v))
           (t nil))))
      (when start
        (org-swift--pt-emit "BLOCK" (format "%X" start) (format "%X" previous))))))

(defun org-swift--pt-inline-boundary ()
  "BEHAVIOURAL ENUMERATION: org's leading `\\<' for `src_' / `call_', by LIVE PARSE.

One parse per candidate preceding character over the whole ASCII range, asking the
only question that matters: with this scalar in front, does org build an
inline-src-block at all? Emits SUPPRESS for the ones where it does not.

This is the shape that cannot be transcribed. The rule LOOKS like org-mode's
word-constituent syntax table and behaves like it on the nine characters anyone
checks, and then `$ % ' \\' suppress while `_' allows -- the first three through the
latex machinery rather than through any syntax table at all. Only the outcome is
pinned, because only the outcome is what the parser has to agree with."
  (dotimes (v 128)
    (let ((probe (format "x %csrc_python{q} y\n" v)))
      ;; A newline or a `*' at column 0 would change WHICH element is parsed rather than which
      ;; object, so the probe puts a `x ' in front and the candidate scalar after it.
      (with-temp-buffer
        (insert probe)
        (org-mode)
        (let ((found nil))
          (org-element-map (org-element-parse-buffer) 'inline-src-block
            (lambda (_) (setq found t)))
          (unless found (org-swift--pt-emit "SUPPRESS" (format "%X" v))))))))

(defun org-swift-dump-pinned-tables ()
  "Print every dataset above, tab-separated, to stdout."
  (org-swift--pt-emit "VERSION" emacs-version (org-version nil nil t))
  (org-swift--pt-restrictions)
  (org-swift--pt-upcase)
  (org-swift--pt-canon)
  (org-swift--pt-radio-blocking)
  (org-swift--pt-inline-boundary))

(provide 'pinned-tables)
;;; pinned-tables.el ends here
