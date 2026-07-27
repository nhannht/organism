;; ORG-28 probe. Reports, per case, every drawer-ish node org built: its TYPE
;; (property-drawer vs drawer), its parent chain, and the full type skeleton so a
;; case where org built NO drawer at all is visible as such rather than as silence.
;;
;; Two instrument rules, both learned the hard way in this run:
;;
;;   1. UTF-8, always. Reading probe bytes raw once made `a_ex` report "no
;;      subscript" and U+00A0 report "valid PRE char", both backwards -- the
;;      reader making a claim about itself, not about org.
;;   2. `org-inlinetask` is loaded only when the first arg is `inlinetask`. Without
;;      it `*************** IT` parses as a level-15 HEADLINE and the inlinetask
;;      cases return a wrong answer that looks like data. Running the whole set
;;      BOTH ways and diffing is what proves the load is inert for the other cases,
;;      rather than assuming it.
;; THE RULE, as measured here and confirmed against org-element.el 30.2 (extracted to
;; gen/org-element-30.2.el; dispatch at :4709, mode table at :5162).
;;
;; `:PROPERTIES:'...`:END:' is a property-drawer iff ALL THREE hold. Otherwise it is an
;; ordinary drawer named PROPERTIES -- never a refusal, never absent.
;;
;;   (1) SHAPE. The whole block matches `org-property-drawer-re':
;;         ^[ \t]*:PROPERTIES:[ \t]*\n
;;         \(?:[ \t]*:\S-+:\(?:[ \t].*\)?[ \t]*\n\)*?
;;         [ \t]*:END:[ \t]*$
;;       Zero interior lines is legal (empty property-drawer). ONE blank or non-property
;;       interior line fails the whole match. Case-insensitive; indentation free and need
;;       not agree line to line. Contents are part of the DISPATCH, not just the body.
;;
;;   (2) MODE is `planning', `property-drawer', or `top-comment'. From the mode table:
;;         headline      -> its section gets `planning'
;;         inlinetask    -> `planning'
;;         zeroth section-> `top-comment'
;;         planning ELEMENT while in `planning'   -> `property-drawer'
;;         comment  ELEMENT while in `top-comment' -> `property-drawer'
;;         everything else -> nil
;;       The table is CLOSED, so this is what rules out every other container --
;;       item, footnote definition, quote/center block, nested drawer -- without
;;       needing a container sweep.
;;
;;   (3) PREVIOUS LINE.
;;         mode `planning'  : previous line must start with `*'.
;;         mode `property-drawer' / `top-comment' : previous line non-blank, OR
;;           everything before it back to beginning-of-buffer is blank.
;;
;; Consequences that catch implementers out:
;;   - A blank line after the headline kills it; leading blanks at the TOP OF FILE do not
;;     (that is the bob escape in (3), and org comments it as deliberate).
;;   - `top-comment' exists only in the zeroth section, so `# c' above the drawer keeps it
;;     a property-drawer at top of file but NOT under a headline.
;;   - Two comment blocks separated by a blank line break it: the second comment is parsed
;;     in mode `property-drawer', which has no outgoing transition, so mode becomes nil.
;;   - An affiliated keyword (#+NAME:, #+CAPTION:) moves the element start onto the keyword
;;     line, so the previous-line test sees the keyword and fails.
;;   - A second property drawer immediately after the first is a plain drawer.

(require 'org)
(require 'org-element)

(when (equal (car command-line-args-left) "inlinetask")
  (require 'org-inlinetask)
  (setq command-line-args-left (cdr command-line-args-left)))

(defun pr--skeleton (n)
  "Compact type skeleton: TYPE, or (TYPE kid...)."
  (cond
   ((stringp n) 'text)
   ((null n) nil)
   (t (let ((type (org-element-type n))
            (kids (org-element-contents n)))
        (if kids
            (cons type (mapcar #'pr--skeleton kids))
          type)))))

(defun pr--drawers (n path acc)
  "Collect (TYPE NAME PATH) for every drawer / property-drawer node under N."
  (if (or (stringp n) (null n))
      acc
    (let* ((type (org-element-type n))
           (here (cons type path)))
      (when (memq type '(drawer property-drawer))
        (push (list type
                    (or (org-element-property :drawer-name n) "-")
                    (reverse path))
              acc))
      (dolist (k (org-element-contents n))
        (setq acc (pr--drawers k here acc)))
      acc)))

(defun pr-dump-string (s)
  (with-temp-buffer
    (set-buffer-multibyte t)
    (let ((org-inhibit-startup t))
      (insert s)
      (org-mode)
      (let ((tree (org-element-parse-buffer)))
        (list (pr--skeleton tree)
              (reverse (pr--drawers tree nil nil)))))))

(let* ((file (car command-line-args-left))
       (coding-system-for-read 'utf-8)
       (raw (with-temp-buffer
              (set-buffer-multibyte t)
              (insert-file-contents file)
              (buffer-string)))
       (probes (split-string raw "\0" t)))
  (dolist (p probes)
    (let* ((parts (split-string p "\36"))
           (name (car parts))
           (body (cadr parts))
           (res (pr-dump-string body)))
      (princ (format "=== %s\n" name))
      (princ (format "SKEL %S\n" (car res)))
      (dolist (d (cadr res))
        (princ (format "DRW  %s name=%s under=%S\n"
                       (nth 0 d) (nth 1 d) (nth 2 d))))
      (when (null (cadr res))
        (princ "DRW  <none>\n")))))
