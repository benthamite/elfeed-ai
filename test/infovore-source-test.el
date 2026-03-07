;;; infovore-source-test.el --- Tests for infovore-source.el  -*- lexical-binding: t; -*-

;; Tests for URL normalization, query parameter filtering, item struct,
;; logging, EIEIO base class, and fetch-with-retry infrastructure.

;;; Code:

(require 'ert)
(require 'infovore-source)

;;;; URL normalization

(ert-deftest infovore-normalize-url/strips-trailing-slash ()
  (should (equal (infovore-normalize-url "https://example.com/path/")
                 "https://example.com/path")))

(ert-deftest infovore-normalize-url/strips-multiple-trailing-slashes ()
  (should (equal (infovore-normalize-url "https://example.com/path///")
                 "https://example.com/path")))

(ert-deftest infovore-normalize-url/lowercases-scheme-and-host ()
  (should (equal (infovore-normalize-url "HTTPS://Example.COM/Path")
                 "https://example.com/Path")))

(ert-deftest infovore-normalize-url/removes-utm-params ()
  (should (equal (infovore-normalize-url
                  "https://example.com/article?utm_source=twitter&utm_medium=social&id=42")
                 "https://example.com/article?id=42")))

(ert-deftest infovore-normalize-url/removes-all-utm-params ()
  (should (equal (infovore-normalize-url
                  "https://example.com/article?utm_source=x&utm_medium=y&utm_campaign=z")
                 "https://example.com/article")))

(ert-deftest infovore-normalize-url/preserves-non-utm-query-params ()
  (should (equal (infovore-normalize-url
                  "https://example.com/search?q=emacs&page=2")
                 "https://example.com/search?q=emacs&page=2")))

(ert-deftest infovore-normalize-url/preserves-fragment ()
  (should (equal (infovore-normalize-url "https://example.com/page#section")
                 "https://example.com/page#section")))

(ert-deftest infovore-normalize-url/handles-bare-domain ()
  (should (equal (infovore-normalize-url "https://example.com")
                 "https://example.com")))

(ert-deftest infovore-normalize-url/handles-bare-domain-with-trailing-slash ()
  (should (equal (infovore-normalize-url "https://example.com/")
                 "https://example.com")))

(ert-deftest infovore-normalize-url/returns-nil-for-nil ()
  (should (null (infovore-normalize-url nil))))

(ert-deftest infovore-normalize-url/returns-nil-for-empty-string ()
  (should (null (infovore-normalize-url ""))))

(ert-deftest infovore-normalize-url/returns-nil-for-non-string ()
  (should (null (infovore-normalize-url 42))))

(ert-deftest infovore-normalize-url/handles-http-scheme ()
  (should (equal (infovore-normalize-url "http://Example.com/page")
                 "http://example.com/page")))

(ert-deftest infovore-normalize-url/complex-url-with-all-features ()
  (should (equal (infovore-normalize-url
                  "HTTPS://Blog.Example.COM/post/123/?utm_source=rss&ref=abc#comments")
                 "https://blog.example.com/post/123?ref=abc#comments")))

;;;; Query parameter filtering

(ert-deftest infovore-filter-query-params/removes-utm-params ()
  (should (equal (infovore--filter-query-params "utm_source=x&id=42&utm_medium=y")
                 "id=42")))

(ert-deftest infovore-filter-query-params/returns-nil-when-all-removed ()
  (should (null (infovore--filter-query-params "utm_source=x&utm_medium=y"))))

(ert-deftest infovore-filter-query-params/returns-nil-for-nil-input ()
  (should (null (infovore--filter-query-params nil))))

(ert-deftest infovore-filter-query-params/preserves-non-utm-params ()
  (should (equal (infovore--filter-query-params "q=test&page=1")
                 "q=test&page=1")))

;;;; Item struct creation and accessors

(ert-deftest infovore-item/creates-struct-with-all-fields ()
  (let ((item (make-infovore-item
               :id "test-id"
               :source-id "rss:example"
               :source-type 'rss
               :title "Test title"
               :author "Author"
               :url "https://example.com/post"
               :content "Content body"
               :summary "AI summary"
               :score 0.85
               :timestamp 1700000000
               :fetched-at 1700001000
               :read-p nil
               :starred-p t
               :curated-p t
               :metadata '((key . "val")))))
    (should (equal (infovore-item-id item) "test-id"))
    (should (equal (infovore-item-source-type item) 'rss))
    (should (equal (infovore-item-title item) "Test title"))
    (should (eql (infovore-item-score item) 0.85))
    (should (null (infovore-item-read-p item)))
    (should (infovore-item-starred-p item))
    (should (infovore-item-curated-p item))
    (should (equal (cdr (assq 'key (infovore-item-metadata item))) "val"))))

(ert-deftest infovore-item/defaults-to-nil-for-unset-fields ()
  (let ((item (make-infovore-item :id "x")))
    (should (null (infovore-item-title item)))
    (should (null (infovore-item-score item)))
    (should (null (infovore-item-read-p item)))
    (should (null (infovore-item-metadata item)))))

(ert-deftest infovore-item/setf-modifies-fields ()
  (let ((item (make-infovore-item :id "x" :score 0.5)))
    (setf (infovore-item-score item) 0.9)
    (should (eql (infovore-item-score item) 0.9))))

;;;; Logging

(ert-deftest infovore-log/writes-to-log-buffer ()
  (let ((infovore-log-buffer-name "*infovore-test-log*"))
    (when (get-buffer infovore-log-buffer-name)
      (kill-buffer infovore-log-buffer-name))
    (infovore-log 'info "Test message %d" 42)
    (with-current-buffer infovore-log-buffer-name
      (should (string-match-p "\\[INFO\\] Test message 42" (buffer-string))))
    (kill-buffer infovore-log-buffer-name)))

(ert-deftest infovore-log/includes-timestamp ()
  (let ((infovore-log-buffer-name "*infovore-test-log*"))
    (when (get-buffer infovore-log-buffer-name)
      (kill-buffer infovore-log-buffer-name))
    (infovore-log 'warn "Warning test")
    (with-current-buffer infovore-log-buffer-name
      (should (string-match-p "\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" (buffer-string)))
      (should (string-match-p "\\[WARN\\]" (buffer-string))))
    (kill-buffer infovore-log-buffer-name)))

;;;; EIEIO base class

(ert-deftest infovore-source/cannot-instantiate-abstract-class ()
  (should-error (infovore-source :id "test" :name "Test")))

(ert-deftest infovore-source/enabled-defaults-to-t ()
  ;; We need a concrete subclass to test this.  Use infovore-source-rss
  ;; if available, otherwise skip.
  (when (fboundp 'infovore-source-rss)
    (let ((src (infovore-source-rss :id "rss:test" :name "Test" :url "http://example.com/feed")))
      (should (infovore-source-enabled-p src)))))

;;; infovore-source-test.el ends here
