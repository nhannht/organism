;; parser-review: FULL enumeration of org's radio-match boundary predicate.
;;
;; org-target-link-regexp wraps the target in
;;     \(?:^\|[^[:alnum:]]\|\c|\)  TARGET  \(?:$\|[^[:alnum:]]\|\c|\)
;; so a scalar is a BOUNDARY iff  (not alnum)  OR  (category |).
;; Equivalently it BLOCKS a match iff  alnum AND (not category |).
;;
;; Emitted as maximal ranges of the BLOCKING predicate, so the Swift side can be
;; diffed against it wholesale rather than spot-checked. Sampling is what this
;; project has been burned by; F19 went 2 -> 29 -> 57 for exactly that reason.
(let ((out (car command-line-args-left))
      (prev nil) (start nil) (n 0))
  (with-temp-file out
    (cl-loop for c from 0 to #x10FFFF do
      ;; Skip the surrogate range: not scalar values, and Swift cannot hold them.
      (unless (and (>= c #xD800) (<= c #xDFFF))
        (let* ((s (char-to-string c))
               (blocks (and (string-match-p "[[:alnum:]]" s)
                            (not (string-match-p "\\c|" s)))))
          (when (null start) (setq start c prev blocks))
          (unless (eq blocks prev)
            (insert (format "%X %X %s\n" start (1- c) (if prev "B" ".")))
            (setq n (1+ n) start c prev blocks)))))
    (insert (format "%X %X %s\n" start #x10FFFF (if prev "B" "."))))
  (message "ranges written: %d" (1+ n)))
