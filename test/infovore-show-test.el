;;; infovore-show-test.el --- Tests for infovore-show.el  -*- lexical-binding: t; -*-

;; Tests for the item detail view helpers: source labels, date formatting,
;; and rendering logic.

;;; Code:

(require 'ert)
(require 'infovore-source)
(require 'infovore-show)

;;;; Source labels

(ert-deftest infovore-show-source-label/rss ()
  (should (equal (infovore-show--source-label 'rss) "RSS"))
  (should (equal (infovore-show--source-label "rss") "RSS")))

(ert-deftest infovore-show-source-label/twitter ()
  (should (equal (infovore-show--source-label 'twitter) "Twitter"))
  (should (equal (infovore-show--source-label "twitter") "Twitter")))

(ert-deftest infovore-show-source-label/substack ()
  (should (equal (infovore-show--source-label 'substack) "Substack"))
  (should (equal (infovore-show--source-label "substack") "Substack")))

(ert-deftest infovore-show-source-label/unknown ()
  (should (stringp (infovore-show--source-label 'mastodon))))

;;;; Date formatting

(ert-deftest infovore-show-format-date/formats-timestamp ()
  (let ((result (infovore-show--format-date 1700000000)))
    (should (stringp result))
    (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" result))))

(ert-deftest infovore-show-format-date/nil-returns-unknown ()
  (should (equal (infovore-show--format-date nil) "unknown")))

;;;; Summary rendering

(ert-deftest infovore-show-render-summary/inserts-summary-text ()
  (let ((item (make-infovore-item
               :id "show-1"
               :source-type 'rss
               :author "Author"
               :title "Test Article"
               :summary "This is the AI summary."
               :timestamp 1700000000
               :url "https://example.com/article")))
    (with-temp-buffer
      (infovore-show--render-summary item)
      (let ((text (buffer-string)))
        (should (string-match-p "Test Article" text))
        (should (string-match-p "Author" text))
        (should (string-match-p "This is the AI summary" text))
        (should (string-match-p "https://example.com/article" text))))))

(ert-deftest infovore-show-render-summary/shows-placeholder-when-no-summary ()
  (let ((item (make-infovore-item
               :id "show-2"
               :source-type 'twitter
               :author "User"
               :summary nil)))
    (with-temp-buffer
      (infovore-show--render-summary item)
      (should (string-match-p "No summary available" (buffer-string))))))

;;;; Original content rendering

(ert-deftest infovore-show-render-original/inserts-plain-text ()
  (let ((item (make-infovore-item
               :id "show-3"
               :source-type 'rss
               :author "A"
               :content "Just plain text content.")))
    (with-temp-buffer
      (infovore-show--render-original item)
      (should (string-match-p "Just plain text content" (buffer-string))))))

(ert-deftest infovore-show-render-original/shows-placeholder-when-no-content ()
  (let ((item (make-infovore-item
               :id "show-4"
               :source-type 'rss
               :author "A"
               :content nil)))
    (with-temp-buffer
      (infovore-show--render-original item)
      (should (string-match-p "No content available" (buffer-string))))))

;;;; View toggle rendering

(ert-deftest infovore-show-render/summary-view ()
  (let ((item (make-infovore-item
               :id "rv-1"
               :source-type 'rss
               :author "A"
               :title "T"
               :summary "Sum"
               :content "Con")))
    (with-temp-buffer
      (infovore-show--render item 'summary)
      (should (string-match-p "\\[Summary\\]" (buffer-string)))
      (should (string-match-p "Sum" (buffer-string))))))

(ert-deftest infovore-show-render/original-view ()
  (let ((item (make-infovore-item
               :id "rv-2"
               :source-type 'rss
               :author "A"
               :title "T"
               :summary "Sum"
               :content "Original content here")))
    (with-temp-buffer
      (infovore-show--render item 'original)
      (should (string-match-p "\\[Original\\]" (buffer-string)))
      (should (string-match-p "Original content here" (buffer-string))))))

;;;; Header rendering

(ert-deftest infovore-show-insert-header/includes-score-when-present ()
  (let ((item (make-infovore-item
               :id "hdr-1"
               :source-type 'rss
               :author "A"
               :score 0.92)))
    (with-temp-buffer
      (infovore-show--insert-header item)
      (should (string-match-p "0\\.92" (buffer-string))))))

(ert-deftest infovore-show-insert-header/omits-score-when-nil ()
  (let ((item (make-infovore-item
               :id "hdr-2"
               :source-type 'rss
               :author "A"
               :score nil)))
    (with-temp-buffer
      (infovore-show--insert-header item)
      (should-not (string-match-p "Score:" (buffer-string))))))

(ert-deftest infovore-show-insert-header/omits-title-when-nil ()
  (let ((item (make-infovore-item
               :id "hdr-3"
               :source-type 'twitter
               :author "A"
               :title nil)))
    (with-temp-buffer
      (infovore-show--insert-header item)
      ;; Should still have author and source.
      (should (string-match-p "Author:" (buffer-string))))))

;;; infovore-show-test.el ends here
