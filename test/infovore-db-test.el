;;; infovore-db-test.el --- Tests for infovore-db.el  -*- lexical-binding: t; -*-

;; Tests for encoding helpers, row conversion, and database CRUD operations.
;; DB tests use a temporary database file cleaned up after each test.

;;; Code:

(require 'ert)
(require 'infovore-source)
(require 'infovore-db)

;;;; Encoding helpers

(ert-deftest infovore-db-bool-to-int/true-values ()
  (should (eql (infovore-db--bool-to-int t) 1))
  (should (eql (infovore-db--bool-to-int 'yes) 1))
  (should (eql (infovore-db--bool-to-int 1) 1))
  (should (eql (infovore-db--bool-to-int "truthy") 1)))

(ert-deftest infovore-db-bool-to-int/false-values ()
  (should (eql (infovore-db--bool-to-int nil) 0)))

(ert-deftest infovore-db-int-to-bool/converts-0-to-nil ()
  (should (null (infovore-db--int-to-bool 0))))

(ert-deftest infovore-db-int-to-bool/converts-1-to-t ()
  (should (eq (infovore-db--int-to-bool 1) t)))

(ert-deftest infovore-db-int-to-bool/converts-nil-to-nil ()
  (should (null (infovore-db--int-to-bool nil))))

(ert-deftest infovore-db-int-to-bool/converts-nonzero-to-t ()
  (should (eq (infovore-db--int-to-bool 42) t)))

;;;; Metadata encoding/decoding

(ert-deftest infovore-db-encode-metadata/nil-returns-nil ()
  (should (null (infovore-db--encode-metadata nil))))

(ert-deftest infovore-db-encode-metadata/alist-returns-json ()
  (let ((result (infovore-db--encode-metadata '((key . "value")))))
    (should (stringp result))
    (should (string-match-p "key" result))
    (should (string-match-p "value" result))))

(ert-deftest infovore-db-decode-metadata/nil-returns-nil ()
  (should (null (infovore-db--decode-metadata nil))))

(ert-deftest infovore-db-decode-metadata/empty-string-returns-nil ()
  (should (null (infovore-db--decode-metadata ""))))

(ert-deftest infovore-db-decode-metadata/roundtrip ()
  (let* ((original '((key . "value") (num . 42)))
         (encoded (infovore-db--encode-metadata original))
         (decoded (infovore-db--decode-metadata encoded)))
    ;; json-parse-string returns string keys by default.
    ;; Use a predicate that finds the key regardless of type.
    (should (or (equal (cdr (assoc "key" decoded)) "value")
                (equal (cdr (assoc 'key decoded)) "value")))
    (should (or (eql (cdr (assoc "num" decoded)) 42)
                (eql (cdr (assoc 'num decoded)) 42)))))

;;;; Field-to-column mapping

(ert-deftest infovore-db-field-to-column/maps-boolean-fields ()
  (should (eq (infovore-db--field-to-column :read-p) 'read))
  (should (eq (infovore-db--field-to-column :starred-p) 'starred))
  (should (eq (infovore-db--field-to-column :curated-p) 'curated)))

(ert-deftest infovore-db-field-to-column/maps-hyphenated-fields ()
  (should (eq (infovore-db--field-to-column :source-id) 'source-id))
  (should (eq (infovore-db--field-to-column :source-type) 'source-type))
  (should (eq (infovore-db--field-to-column :fetched-at) 'fetched-at)))

(ert-deftest infovore-db-field-to-column/maps-simple-fields ()
  (should (eq (infovore-db--field-to-column :score) 'score))
  (should (eq (infovore-db--field-to-column :title) 'title))
  (should (eq (infovore-db--field-to-column :summary) 'summary)))

;;;; Encode field value

(ert-deftest infovore-db-encode-field-value/booleans-become-ints ()
  (should (eql (infovore-db--encode-field-value :read-p t) 1))
  (should (eql (infovore-db--encode-field-value :starred-p nil) 0))
  (should (eql (infovore-db--encode-field-value :curated-p t) 1)))

(ert-deftest infovore-db-encode-field-value/metadata-becomes-json ()
  (let ((result (infovore-db--encode-field-value :metadata '((k . "v")))))
    (should (stringp result))))

(ert-deftest infovore-db-encode-field-value/other-fields-pass-through ()
  (should (eql (infovore-db--encode-field-value :score 0.75) 0.75))
  (should (equal (infovore-db--encode-field-value :title "Hello") "Hello")))

;;;; Row-to-item conversion

(ert-deftest infovore-db-row-to-item/converts-complete-row ()
  (let* ((row '("id1" "src1" "rss" "Title" "Author" "https://x.com"
                "content" "summary" 0.8 1700000000 1700001000
                0 1 1 nil))
         (item (infovore-db--row-to-item row)))
    (should (equal (infovore-item-id item) "id1"))
    (should (equal (infovore-item-source-id item) "src1"))
    (should (equal (infovore-item-source-type item) "rss"))
    (should (equal (infovore-item-title item) "Title"))
    (should (equal (infovore-item-author item) "Author"))
    (should (eql (infovore-item-score item) 0.8))
    (should (null (infovore-item-read-p item)))
    (should (infovore-item-starred-p item))
    (should (infovore-item-curated-p item))
    (should (null (infovore-item-metadata item)))))

(ert-deftest infovore-db-row-to-item/handles-nil-values ()
  (let* ((row '("id2" "src2" "twitter" nil nil nil
                nil nil nil nil nil
                0 0 0 nil))
         (item (infovore-db--row-to-item row)))
    (should (null (infovore-item-title item)))
    (should (null (infovore-item-score item)))
    (should (null (infovore-item-read-p item)))
    (should (null (infovore-item-starred-p item)))))

;;;; Database CRUD operations (requires emacsql)

(defmacro infovore-db-test-with-temp-db (&rest body)
  "Execute BODY with a temporary database, cleaning up afterwards."
  (declare (indent 0))
  `(let* ((infovore-database-file (make-temp-file "infovore-test-" nil ".db"))
          (infovore-db--connection nil))
     (unwind-protect
         (progn ,@body)
       (infovore-db-close)
       (when (file-exists-p infovore-database-file)
         (delete-file infovore-database-file)))))

(defun infovore-db-test--make-item (id &rest overrides)
  "Create a test item with ID and optional OVERRIDES plist."
  (make-infovore-item
   :id id
   :source-id (or (plist-get overrides :source-id) "rss:test")
   :source-type (or (plist-get overrides :source-type) "rss")
   :title (or (plist-get overrides :title) (format "Test item %s" id))
   :author (or (plist-get overrides :author) "Test Author")
   :url (or (plist-get overrides :url) (format "https://example.com/%s" id))
   :content (or (plist-get overrides :content) "Test content body")
   :summary (plist-get overrides :summary)
   :score (plist-get overrides :score)
   :timestamp (or (plist-get overrides :timestamp) 1700000000)
   :fetched-at (or (plist-get overrides :fetched-at) 1700001000)
   :read-p (plist-get overrides :read-p)
   :starred-p (plist-get overrides :starred-p)
   :curated-p (plist-get overrides :curated-p)
   :metadata (plist-get overrides :metadata)))

(ert-deftest infovore-db-ensure/creates-database ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (should infovore-db--connection)
    (should (emacsql-live-p infovore-db--connection))))

(ert-deftest infovore-db-ensure/is-idempotent ()
  (infovore-db-test-with-temp-db
    (let ((conn1 (infovore-db-ensure))
          (conn2 (infovore-db-ensure)))
      (should (eq conn1 conn2)))))

(ert-deftest infovore-db-insert-and-get/roundtrip ()
  (infovore-db-test-with-temp-db
    (let ((item (infovore-db-test--make-item "roundtrip-1"
                  :score 0.75 :summary "A summary" :curated-p t)))
      (infovore-db-insert-item item)
      (let ((retrieved (infovore-db-get-item "roundtrip-1")))
        (should retrieved)
        (should (equal (infovore-item-id retrieved) "roundtrip-1"))
        (should (equal (infovore-item-title retrieved) "Test item roundtrip-1"))
        (should (eql (infovore-item-score retrieved) 0.75))
        (should (equal (infovore-item-summary retrieved) "A summary"))
        (should (infovore-item-curated-p retrieved))
        (should (null (infovore-item-read-p retrieved)))))))

(ert-deftest infovore-db-insert/ignores-duplicate-ids ()
  (infovore-db-test-with-temp-db
    (let ((item1 (infovore-db-test--make-item "dup-1" :title "First"))
          (item2 (infovore-db-test--make-item "dup-1" :title "Second")))
      (infovore-db-insert-item item1)
      (infovore-db-insert-item item2)
      ;; Should keep the first insert, ignore the second.
      (let ((retrieved (infovore-db-get-item "dup-1")))
        (should (equal (infovore-item-title retrieved) "First"))))))

(ert-deftest infovore-db-item-exists-p/returns-t-for-existing ()
  (infovore-db-test-with-temp-db
    (infovore-db-insert-item (infovore-db-test--make-item "exists-1"))
    (should (infovore-db-item-exists-p "exists-1"))))

(ert-deftest infovore-db-item-exists-p/returns-nil-for-missing ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (should (null (infovore-db-item-exists-p "nonexistent")))))

(ert-deftest infovore-db-get-item/returns-nil-for-missing ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (should (null (infovore-db-get-item "missing")))))

(ert-deftest infovore-db-update-item/updates-score ()
  (infovore-db-test-with-temp-db
    (infovore-db-insert-item (infovore-db-test--make-item "upd-1"))
    (infovore-db-update-item "upd-1" :score 0.95)
    (let ((item (infovore-db-get-item "upd-1")))
      (should (eql (infovore-item-score item) 0.95)))))

(ert-deftest infovore-db-update-item/updates-boolean-fields ()
  (infovore-db-test-with-temp-db
    (infovore-db-insert-item (infovore-db-test--make-item "upd-bool"))
    (infovore-db-update-item "upd-bool" :read-p t :starred-p t)
    (let ((item (infovore-db-get-item "upd-bool")))
      (should (infovore-item-read-p item))
      (should (infovore-item-starred-p item)))))

(ert-deftest infovore-db-update-item/updates-multiple-fields ()
  (infovore-db-test-with-temp-db
    (infovore-db-insert-item (infovore-db-test--make-item "upd-multi"))
    (infovore-db-update-item "upd-multi"
                             :score 0.8
                             :summary "New summary"
                             :curated-p t)
    (let ((item (infovore-db-get-item "upd-multi")))
      (should (eql (infovore-item-score item) 0.8))
      (should (equal (infovore-item-summary item) "New summary"))
      (should (infovore-item-curated-p item)))))

(ert-deftest infovore-db-uncurated-items/returns-only-uncurated ()
  (infovore-db-test-with-temp-db
    (infovore-db-insert-item (infovore-db-test--make-item "cur-1" :curated-p t :score 0.8))
    (infovore-db-insert-item (infovore-db-test--make-item "uncur-1"))
    (infovore-db-insert-item (infovore-db-test--make-item "uncur-2"))
    (let ((uncurated (infovore-db-uncurated-items)))
      (should (= (length uncurated) 2))
      (should (cl-every (lambda (item) (null (infovore-item-curated-p item)))
                        uncurated)))))

(ert-deftest infovore-db-uncurated-items/respects-limit ()
  (infovore-db-test-with-temp-db
    (infovore-db-insert-item (infovore-db-test--make-item "lim-1" :fetched-at 100))
    (infovore-db-insert-item (infovore-db-test--make-item "lim-2" :fetched-at 200))
    (infovore-db-insert-item (infovore-db-test--make-item "lim-3" :fetched-at 300))
    (let ((items (infovore-db-uncurated-items 2)))
      (should (= (length items) 2)))))

(ert-deftest infovore-db-count-unread-curated/counts-correctly ()
  (infovore-db-test-with-temp-db
    ;; Curated + unread
    (infovore-db-insert-item (infovore-db-test--make-item "cnt-1" :curated-p t :score 0.8))
    ;; Curated + read
    (infovore-db-insert-item (infovore-db-test--make-item "cnt-2" :curated-p t :score 0.7 :read-p t))
    ;; Not curated
    (infovore-db-insert-item (infovore-db-test--make-item "cnt-3"))
    ;; Curated + unread
    (infovore-db-insert-item (infovore-db-test--make-item "cnt-4" :curated-p t :score 0.9))
    (should (= (infovore-db-count-unread-curated) 2))))

;;;; Budget operations

(ert-deftest infovore-db-budget/get-returns-0-for-missing-date ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (should (= (infovore-db-get-budget-tokens "2026-01-01") 0))))

(ert-deftest infovore-db-budget/add-and-get-roundtrip ()
  (infovore-db-test-with-temp-db
    (infovore-db-add-budget-tokens "2026-03-07" 5000)
    (should (= (infovore-db-get-budget-tokens "2026-03-07") 5000))))

(ert-deftest infovore-db-budget/add-accumulates ()
  (infovore-db-test-with-temp-db
    (infovore-db-add-budget-tokens "2026-03-07" 3000)
    (infovore-db-add-budget-tokens "2026-03-07" 2000)
    (should (= (infovore-db-get-budget-tokens "2026-03-07") 5000))))

(ert-deftest infovore-db-budget/separate-dates-are-independent ()
  (infovore-db-test-with-temp-db
    (infovore-db-add-budget-tokens "2026-03-06" 1000)
    (infovore-db-add-budget-tokens "2026-03-07" 2000)
    (should (= (infovore-db-get-budget-tokens "2026-03-06") 1000))
    (should (= (infovore-db-get-budget-tokens "2026-03-07") 2000))))

;;;; Close and reconnect

(ert-deftest infovore-db-close/closes-connection ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (should infovore-db--connection)
    (infovore-db-close)
    (should (null infovore-db--connection))))

(ert-deftest infovore-db-close/is-idempotent ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (infovore-db-close)
    (infovore-db-close)
    (should (null infovore-db--connection))))

(ert-deftest infovore-db-ensure/reopens-after-close ()
  (infovore-db-test-with-temp-db
    (infovore-db-ensure)
    (infovore-db-insert-item (infovore-db-test--make-item "reopen-1"))
    (infovore-db-close)
    ;; Reopening should find the data still there.
    (infovore-db-ensure)
    (should (infovore-db-item-exists-p "reopen-1"))))

;;; infovore-db-test.el ends here
