;; parser-review's own minimal tree dumper. Independent of harness/oracle-dump.el on purpose.
;; Prints a compact S-expression of type + the fields that matter for object-restriction work.
(require 'org)
(require 'org-element)

(defun pr--strip (n)
  (cond
   ((stringp n) (list 'text (substring-no-properties n)))
   ((null n) nil)
   (t
    (let* ((type (org-element-type n))
           (kids (org-element-contents n)))
      (append
       (list type)
       (cond
        ((eq type 'headline)
         (list :title (mapcar (function pr--strip) (org-element-property :title n))))
        ((memq type '(subscript superscript))
         (list :brackets (org-element-property :use-brackets-p n)))
        ((eq type 'link)
         (list :ltype (org-element-property :type n)
               :path (org-element-property :path n)
               :format (org-element-property :format n)))
        ((eq type 'footnote-definition)
         (list :label (org-element-property :label n)
               :preblank (org-element-property :pre-blank n)))
        ((eq type 'footnote-reference)
         (list :label (org-element-property :label n)
               :fntype (org-element-property :type n)))
        ((eq type 'statistics-cookie)
         (list :value (org-element-property :value n)))
        ((eq type 'latex-fragment)
         (list :value (org-element-property :value n)))
        ((eq type 'entity)
         (list :name (org-element-property :name n)))
        ((eq type 'radio-target)
         (list :value (org-element-property :value n)))
        ((eq type 'table)
         (list :ttype (org-element-property :type n)
               :value (org-element-property :value n)))
        ((eq type 'dynamic-block)
         (list :bname (org-element-property :block-name n)
               :bargs (org-element-property :arguments n)))
        (t nil))
       (if kids (list :c (mapcar #'pr--strip kids)) nil))))))

(defun pr-dump-string (s)
  (with-temp-buffer
    ;; MULTIBYTE, always. Reading a probe file as raw bytes made `a_éx` report
    ;; "no subscript" and U+00A0 report "valid PRE char", both backwards. That is
    ;; the reader making a claim about itself, not about org.
    (set-buffer-multibyte t)
    (let ((org-inhibit-startup t))
      (insert s)
      (org-mode)
      (pr--strip (org-element-parse-buffer)))))

;; Read newline-separated NUL-delimited probes from the file named by the first arg.
(let* ((file (car command-line-args-left))
       (coding-system-for-read 'utf-8)
       (raw (with-temp-buffer
              (set-buffer-multibyte t)
              (insert-file-contents file)
              (buffer-string)))
       (probes (split-string raw "\0" t)))
  (dolist (p probes)
    (let ((name (car (split-string p "\36")))
          (body (cadr (split-string p "\36"))))
      (princ (format "=== %s\n" name))
      (princ (format "%S\n" (pr-dump-string body))))))
