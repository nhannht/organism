;; Emacs `\s-` (whitespace SYNTAX) in an org-mode buffer, over the whole scalar space.
;; This is the predicate org's sub/superscript PRE test (`\S-`) is the negation of.
(require 'org)
(with-temp-buffer
  (let ((org-inhibit-startup t)) (org-mode))
  (let ((out (car command-line-args-left)) (prev nil) (start nil) (n 0) (acc '()))
    (cl-loop for c from 0 to #x10FFFF do
      (unless (and (>= c #xD800) (<= c #xDFFF))
        (let ((ws (string-match-p "\\s-" (char-to-string c))))
          (setq ws (and ws t))
          (when (null start) (setq start c prev ws))
          (unless (eq ws prev)
            (push (format "%X %X %s\n" start (1- c) (if prev "W" ".")) acc)
            (setq n (1+ n) start c prev ws)))))
    (push (format "%X %X %s\n" start #x10FFFF (if prev "W" ".")) acc)
    (with-temp-file out (insert (apply #'concat (nreverse acc))))
    (message "ranges: %d" (1+ n))))
