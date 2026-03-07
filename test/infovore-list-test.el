;;; infovore-list-test.el --- Tests for infovore-list.el  -*- lexical-binding: t; -*-

;; Tests for the feed list UI helpers: relative time formatting,
;; source type icons, and entry formatting.

;;; Code:

(require 'ert)
(require 'infovore-source)
(require 'infovore-list)

;;;; Relative time formatting

(ert-deftest infovore-list-relative-time/nil-returns-empty ()
  (should (equal (infovore-list--relative-time nil) "")))

(ert-deftest infovore-list-relative-time/just-now ()
  (let ((now (floor (float-time))))
    (should (equal (infovore-list--relative-time now) "just now"))))

(ert-deftest infovore-list-relative-time/minutes-ago ()
  (let ((ts (- (floor (float-time)) (* 15 60))))
    (should (equal (infovore-list--relative-time ts) "15m ago"))))

(ert-deftest infovore-list-relative-time/hours-ago ()
  (let ((ts (- (floor (float-time)) (* 3 3600))))
    (should (equal (infovore-list--relative-time ts) "3h ago"))))

(ert-deftest infovore-list-relative-time/yesterday ()
  (let ((ts (- (floor (float-time)) (* 30 3600))))
    (should (equal (infovore-list--relative-time ts) "yesterday"))))

(ert-deftest infovore-list-relative-time/days-ago ()
  (let ((ts (- (floor (float-time)) (* 5 86400))))
    (should (equal (infovore-list--relative-time ts) "5d ago"))))

(ert-deftest infovore-list-relative-time/months-ago ()
  (let ((ts (- (floor (float-time)) (* 60 86400))))
    (should (equal (infovore-list--relative-time ts) "2mo ago"))))

(ert-deftest infovore-list-relative-time/years-ago ()
  (let ((ts (- (floor (float-time)) (* 400 86400))))
    (should (equal (infovore-list--relative-time ts) "1y ago"))))

;;;; Source type icons

(ert-deftest infovore-list-source-icon/rss-symbol ()
  (should (equal (infovore-list--source-icon 'rss) "[RSS]")))

(ert-deftest infovore-list-source-icon/rss-string ()
  (should (equal (infovore-list--source-icon "rss") "[RSS]")))

(ert-deftest infovore-list-source-icon/twitter-symbol ()
  (should (equal (infovore-list--source-icon 'twitter) "[TW]")))

(ert-deftest infovore-list-source-icon/twitter-string ()
  (should (equal (infovore-list--source-icon "twitter") "[TW]")))

(ert-deftest infovore-list-source-icon/substack-symbol ()
  (should (equal (infovore-list--source-icon 'substack) "[SS]")))

(ert-deftest infovore-list-source-icon/substack-string ()
  (should (equal (infovore-list--source-icon "substack") "[SS]")))

(ert-deftest infovore-list-source-icon/unknown ()
  (should (equal (infovore-list--source-icon 'mastodon) "[??]")))

;;;; Entry formatting

(ert-deftest infovore-list-format-entry/produces-valid-entry ()
  (let ((item (make-infovore-item
               :id "fmt-1"
               :source-type 'rss
               :author "Jane"
               :title "Hello World"
               :score 0.85
               :timestamp (floor (float-time)))))
    (let ((entry (infovore-list--format-entry item)))
      (should (equal (car entry) "fmt-1"))
      (should (vectorp (cadr entry)))
      (should (= (length (cadr entry)) 5)))))

(ert-deftest infovore-list-format-entry/starred-items-get-face ()
  (let ((item (make-infovore-item
               :id "fmt-star"
               :source-type 'twitter
               :author "User"
               :title "Starred"
               :score 0.5
               :starred-p t)))
    (let* ((entry (infovore-list--format-entry item))
           (vec (cadr entry))
           (author-str (aref vec 1)))
      ;; The author string should have the starred face.
      (should (eq (get-text-property 0 'face author-str)
                  'infovore-starred-face)))))

(ert-deftest infovore-list-format-entry/read-items-get-face ()
  (let ((item (make-infovore-item
               :id "fmt-read"
               :source-type 'rss
               :author "User"
               :title "Read"
               :score 0.5
               :read-p t)))
    (let* ((entry (infovore-list--format-entry item))
           (vec (cadr entry))
           (title-str (aref vec 2)))
      (should (eq (get-text-property 0 'face title-str)
                  'infovore-read-face)))))

(ert-deftest infovore-list-format-entry/high-score-gets-face ()
  (let ((item (make-infovore-item
               :id "fmt-hi"
               :source-type 'rss
               :title "High"
               :score 0.85)))
    (let* ((entry (infovore-list--format-entry item))
           (vec (cadr entry))
           (score-str (aref vec 3)))
      (should (equal (substring-no-properties score-str) "0.85"))
      (should (eq (get-text-property 0 'face score-str)
                  'infovore-score-high-face)))))

(ert-deftest infovore-list-format-entry/low-score-gets-face ()
  (let ((item (make-infovore-item
               :id "fmt-lo"
               :source-type 'rss
               :title "Low"
               :score 0.2)))
    (let* ((entry (infovore-list--format-entry item))
           (vec (cadr entry))
           (score-str (aref vec 3)))
      (should (eq (get-text-property 0 'face score-str)
                  'infovore-score-low-face)))))

(ert-deftest infovore-list-format-entry/nil-score-shows-empty ()
  (let ((item (make-infovore-item
               :id "fmt-nil"
               :source-type 'rss
               :title "NoScore")))
    (let* ((entry (infovore-list--format-entry item))
           (vec (cadr entry))
           (score-str (aref vec 3)))
      (should (equal (substring-no-properties score-str) "")))))

(ert-deftest infovore-list-format-entry/uses-summary-when-no-title ()
  (let ((item (make-infovore-item
               :id "fmt-sum"
               :source-type 'twitter
               :title nil
               :summary "This is the AI summary of a tweet.")))
    (let* ((entry (infovore-list--format-entry item))
           (vec (cadr entry))
           (title-str (aref vec 2)))
      (should (string-match-p "This is the AI summary" (substring-no-properties title-str))))))

;;;; Tabulated list format builder

(ert-deftest infovore-list-build-format/returns-vector ()
  (let ((fmt (infovore-list--build-format)))
    (should (vectorp fmt))
    (should (= (length fmt) (length infovore-list-format)))))

(ert-deftest infovore-list-build-format/maps-field-names ()
  (let ((fmt (infovore-list--build-format)))
    (should (equal (car (aref fmt 0)) "Source"))
    (should (equal (car (aref fmt 1)) "Author"))
    (should (equal (car (aref fmt 2)) "Title"))))

;;; infovore-list-test.el ends here
