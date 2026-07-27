;; EMACS side of the case-fold question, for increment 7's pinned fold table.
;;
;; Emits, per scalar, the DOWNCASED VALUE and not merely a "does it change" bit. The
;; reported 21/56 split is a set-membership predicate ("Emacs folds it, Swift does not"),
;; and that predicate is blind to the class that matters most: a scalar BOTH sides fold,
;; to DIFFERENT results. Such a scalar appears in neither set and so cannot be seen from
;; the 21/56 framing at all. Emitting the value makes that class measurable.
;;
;; Hex in, hex out, so no coding system can double-encode the measurement -- the reader
;; bug that twice made this kit report a backwards answer.
(require 'cl-lib)
(let ((out (car command-line-args-left)) (acc '()))
  (cl-loop for c from 0 to #x10FFFF do
    (unless (and (>= c #xD800) (<= c #xDFFF))
      (let* ((s (char-to-string c))
             (d (downcase s)))
        ;; codepoints of the result, space separated -- length may exceed 1
        (push (format "%X\t%s\n" c
                      (mapconcat (lambda (x) (format "%X" x)) (string-to-list d) " "))
              acc))))
  (with-temp-file out (insert (apply #'concat (nreverse acc))))
  (message "emacs downcase rows: %d" (length acc)))
