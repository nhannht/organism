;; EMACS side of F19: every scalar whose `upcase` CHANGES it. Hex in, hex out, so no
;; coding system can double-encode the measurement.
(let ((out (car command-line-args-left)) (acc '()))
  (cl-loop for c from 0 to #x10FFFF do
    (unless (and (>= c #xD800) (<= c #xDFFF))
      (let* ((s (char-to-string c)) (u (upcase s)))
        (unless (string= s u) (push (format "%X\n" c) acc)))))
  (with-temp-file out (insert (apply #'concat (nreverse acc))))
  (message "emacs upcase changes: %d" (length acc)))
