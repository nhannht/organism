;; EXHAUSTIVE inline-footnote body delimitation. My rule ("balanced bracket, stops at
;; the first BALANCED close") came from 14 hand-picked shapes. Enumerate every string
;; over {[ ] a} up to length 5 placed as  x [fn::S] y  and record the body org gives.
(require 'org-element)
(defun pr-inl (s)
  (with-temp-buffer
    (set-buffer-multibyte t)
    (insert "x [fn::" s "] y\n")
    (let ((org-inhibit-startup t)) (org-mode))
    (let (v)
      (org-element-map (org-element-parse-buffer) 'footnote-reference
        (lambda (n)
          (unless v
            (setq v (buffer-substring-no-properties
                     (org-element-property :contents-begin n)
                     (org-element-property :contents-end n))))))
      v)))
;; My model: scan the text after `[fn::`; depth starts 0; `[` increments, `]`
;; decrements; the body ends at the `]` that would take depth below 0.
(defun pr-model (s)
  (let ((full (concat s "] y")) (depth 0) (i 0) (n nil))
    (catch 'done
      (while (< i (length full))
        (let ((c (aref full i)))
          (cond ((eq c ?\[) (setq depth (1+ depth)))
                ((eq c ?\]) (if (= depth 0) (throw 'done (setq n i)) (setq depth (1- depth))))))
        (setq i (1+ i)))
      nil)
    (if n (substring full 0 n) nil)))
(let* ((alpha '(?\[ ?\] ?a)) (tot 0) (agree 0) (bad '()))
  (cl-labels ((gen (p d)
                (when (> (length p) 0)
                  (setq tot (1+ tot))
                  (let ((a (pr-inl p)) (m (pr-model p)))
                    (if (equal a m) (setq agree (1+ agree))
                      (push (list p :org a :model m) bad))))
                (when (< d 5) (dolist (c alpha) (gen (concat p (char-to-string c)) (1+ d))))))
    (gen "" 0))
  (princ (format "candidates: %d   model agrees: %d   disagrees: %d\n" tot agree (length bad)))
  (dolist (b (last (nreverse bad) 12)) (princ (format "   %S\n" b))))
