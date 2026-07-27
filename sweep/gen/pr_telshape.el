;; EXHAUSTIVE rule-line shape enumeration. My earlier rule came from 16 hand-picked
;; variants, which is a sample. This enumerates every string over {+ - = space tab}
;; up to length 5 (5^1..5^5 = 3905 candidates), tests each as a doubled line
;; (two rule lines is the minimum that forms a table.el), and reports which form one.
;; Then it checks the inferred regexp against the full result set.
(require 'org-element)
(defun pr-tel-p (line)
  (with-temp-buffer
    (set-buffer-multibyte t)
    (insert line "\n" line "\n")
    (let ((org-inhibit-startup t)) (org-mode))
    (let (found)
      (org-element-map (org-element-parse-buffer) 'table
        (lambda (n) (when (eq (org-element-property :type n) 'table.el) (setq found t))))
      found)))
(let* ((alpha '(?+ ?- ?= ?\s ?\t))
       (yes '()) (no 0) (total 0)
       (re "\\`[ \t]*\\+-[-+]*\\+[ \t]*\\'"))
  (cl-labels ((gen (prefix depth)
                (when (> (length prefix) 0)
                  (setq total (1+ total))
                  (if (pr-tel-p prefix) (push prefix yes) (setq no (1+ no))))
                (when (< depth 5)
                  (dolist (c alpha) (gen (concat prefix (char-to-string c)) (1+ depth))))))
    (gen "" 0))
  (princ (format "candidates tested: %d\n" total))
  (princ (format "form a table.el:   %d\n" (length yes)))
  ;; Check the inferred regexp against EVERY candidate, both directions.
  (let ((fp '()) (fn '()))
    (cl-labels ((chk (prefix depth)
                  (when (> (length prefix) 0)
                    (let ((actual (member prefix yes))
                          (pred (string-match-p re prefix)))
                      (cond ((and pred (not actual)) (push prefix fp))
                            ((and actual (not pred)) (push prefix fn)))))
                  (when (< depth 5)
                    (dolist (c alpha) (chk (concat prefix (char-to-string c)) (1+ depth))))))
      (chk "" 0))
    (princ (format "\nINFERRED REGEXP: %s\n" re))
    (princ (format "  predicts YES but is NOT (false positives): %d %S\n" (length fp) (last fp 8)))
    (princ (format "  is YES but predicted NO (false negatives): %d %S\n" (length fn) (last fn 8)))))
