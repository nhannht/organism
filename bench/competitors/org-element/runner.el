;;; runner.el --- org-element side of the bench protocol -*- lexical-binding: t; -*-
;;
;; Usage: emacs -Q --batch -l runner.el -- <file.org> <warmup> <min-time-seconds>
;; Prints one ns-per-iteration line per measured parse; the orchestrator does the stats.
;;
;; The element cache is disabled: with it on, every iteration after the first would
;; measure a cache lookup rather than a parse. GC time stays inside the measurement
;; because a real consumer pays it too; the raised threshold below only keeps GC from
;; firing MID-parse on every iteration, and the median absorbs the ones that remain.

(setq gc-cons-threshold (* 1024 1024 1024))
(require 'org)
(require 'org-element)
(setq org-element-use-cache nil)

(let* ((args (if (equal (car command-line-args-left) "--")
                 (cdr command-line-args-left)
               command-line-args-left))
       (file (nth 0 args))
       (warmup (string-to-number (or (nth 1 args) "")))
       (min-time (string-to-number (or (nth 2 args) ""))))
  (unless (and file (> min-time 0))
    (message "usage: emacs -Q --batch -l runner.el -- <file.org> <warmup> <min-time-seconds>")
    (kill-emacs 1))
  (message "emacs=%s org=%s" emacs-version (org-version))
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (dotimes (_ warmup) (org-element-parse-buffer))
    (let* ((est (car (benchmark-run 1 (org-element-parse-buffer))))
           (iters (min 20000 (max 5 (floor (/ min-time (max est 1e-9)))))))
      (dotimes (_ iters)
        (princ (format "%d\n"
                       (round (* (car (benchmark-run 1 (org-element-parse-buffer)))
                                 1e9))))))))
