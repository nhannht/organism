;; Emacs's CASE-FOLD CANONICALIZATION -- the function regexp matching actually uses,
;; which is NOT `downcase'. Two characters match case-insensitively iff canon is equal.
;; Measuring `downcase' instead is measuring a proxy for the thing org does.
;;
;; RESULTS over the full 1,114,112-scalar space, against Swift `.lowercased()':
;;
;;   canon folds / swift does not : 21     org links, .lowercased() MISSES  (under-match)
;;   swift folds / canon does not : 57     .lowercased() links, org does NOT (over-match)
;;   both fold to different values: 0
;;   canon minus downcase         : 21     <- exactly the scalars downcase cannot see
;;   downcase minus canon         : 1      <- U+0130 only
;;
;; So a fold table built from `downcase' is wrong on precisely those 21, and no test
;; sharing the `downcase' assumption can detect it. The 21 are already-lowercase forms
;; that CASE-FOLD to a different letter, which is why a lowercase mapping cannot see them:
;;   U+00B5 U+0345 U+03C2 U+03D0 U+03D1 U+03D5 U+03D6 U+03F0 U+03F1 U+03F5
;;   U+1C80..U+1C88 U+1E9B U+1FBE
;;
;; All 21 verified to form a radio link in live org, all 57 verified not to. Positive
;; controls (ASCII, Latin-1, Greek, Cyrillic, Armenian, Fullwidth, Deseret U+10400) fire,
;; negative control `a` vs `z` does not -- so "0 of 57" is behaviour, not a dead probe.
;;
;; U+0130 is the sole multi-scalar case: Swift lowercases it to `i' + U+0307, Emacs canon
;; relates it to nothing, and live org matches it against ITSELF ONLY. It is an over-match
;; and belongs in the 57. U+0131 dotless i likewise relates to nothing but itself.
;;
;; Staged as cases/i7f-u-* (21) and cases/i7f-o-* (57).
(require 'cl-lib)
(let* ((ct (standard-case-table))
       (canon (char-table-extra-slot ct 1)))
  (cl-loop for c from 0 to #x10FFFF do
    (unless (and (>= c #xD800) (<= c #xDFFF))
      (let ((k (or (and canon (aref canon c)) c)))
        (princ (format "%X\t%X\n" c k))))))
