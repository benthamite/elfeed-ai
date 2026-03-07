;;; infovore-modeline-test.el --- Tests for infovore-modeline.el  -*- lexical-binding: t; -*-

;; Tests for the mode line indicator formatting.

;;; Code:

(require 'ert)
(require 'infovore-modeline)

;;;; Mode line format

(ert-deftest infovore-modeline-format/shows-zero-count ()
  (let ((infovore-modeline--count 0))
    (let ((result (infovore-modeline--format)))
      (should (string-match-p "IV:0" result))
      (should (eq (get-text-property 1 'face result)
                  'infovore-modeline-face)))))

(ert-deftest infovore-modeline-format/shows-positive-count ()
  (let ((infovore-modeline--count 12))
    (let ((result (infovore-modeline--format)))
      (should (string-match-p "IV:12" result))
      (should (eq (get-text-property 1 'face result)
                  'infovore-modeline-active-face)))))

(ert-deftest infovore-modeline-format/has-help-echo ()
  (let ((infovore-modeline--count 5))
    (let ((result (infovore-modeline--format)))
      (should (string-match-p "5 unread" (get-text-property 1 'help-echo result))))))

(ert-deftest infovore-modeline-format/singular-help-echo ()
  (let ((infovore-modeline--count 1))
    (let ((result (infovore-modeline--format)))
      (should (string-match-p "1 unread curated item\\b"
                              (get-text-property 1 'help-echo result))))))

(ert-deftest infovore-modeline-format/plural-help-echo ()
  (let ((infovore-modeline--count 3))
    (let ((result (infovore-modeline--format)))
      (should (string-match-p "3 unread curated items"
                              (get-text-property 1 'help-echo result))))))

;;; infovore-modeline-test.el ends here
