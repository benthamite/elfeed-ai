;;; infovore-db.el --- SQLite database layer for infovore  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, data
;; Package-Requires: ((emacs "27.1") (emacsql "4.0.0"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Database access layer for infovore.  All item storage, retrieval, and
;; querying goes through this module.  Uses emacsql to
;; manage a single SQLite database that holds fetched items and daily
;; token-budget accounting.

;;; Code:

(require 'cl-lib)
(require 'emacsql)
(require 'emacsql-sqlite)
(require 'json)
(require 'infovore-source)

;;;; Customization

(defcustom infovore-database-file
  (expand-file-name "infovore.db" user-emacs-directory)
  "Path to the SQLite database file."
  :type 'file
  :group 'infovore)

;;;; Internal state

(defvar infovore-db--connection nil
  "Active emacsql database connection, or nil if not open.")

;;;; Schema

(defconst infovore-db--items-schema
  '([(id :text :primary-key)
     (source-id :text :not-null)
     (source-type :text :not-null)
     (title :text)
     (author :text)
     (url :text)
     (content :text)
     (summary :text)
     (score :real)
     (timestamp :integer)
     (fetched-at :integer)
     (read :integer :default 0)
     (starred :integer :default 0)
     (curated :integer :default 0)
     (metadata :text)])
  "Schema for the items table.")

(defconst infovore-db--budget-schema
  '([(date :text :primary-key)
     (tokens-used :integer :default 0)])
  "Schema for the budget table.")

;;;; Connection management

(defun infovore-db-ensure ()
  "Open the database connection if needed and ensure tables exist.
Return the active connection."
  (unless (and infovore-db--connection
               (emacsql-live-p infovore-db--connection))
    (setq infovore-db--connection
          (emacsql-sqlite-open infovore-database-file))
    (infovore-db--create-tables))
  infovore-db--connection)

(defun infovore-db-close ()
  "Close the database connection if open."
  (when (and infovore-db--connection
             (emacsql-live-p infovore-db--connection))
    (emacsql-close infovore-db--connection)
    (setq infovore-db--connection nil)))

(defun infovore-db--create-tables ()
  "Create tables and indexes if they do not already exist."
  (let ((db infovore-db--connection))
    (emacsql db [:create-table-if-not-exists items $S1]
             infovore-db--items-schema)
    (emacsql db [:create-table-if-not-exists budget $S1]
             infovore-db--budget-schema)
    (emacsql db [:create-index-if-not-exists idx-items-timestamp
                 :on items [timestamp]])
    (emacsql db [:create-index-if-not-exists idx-items-score
                 :on items [score]])
    (emacsql db [:create-index-if-not-exists idx-items-source
                 :on items [source-id]])
    (emacsql db [:create-index-if-not-exists idx-items-curated
                 :on items [curated]])))

;;;; Encoding helpers

(defun infovore-db--bool-to-int (val)
  "Convert boolean VAL to 0 or 1 for storage."
  (if val 1 0))

(defun infovore-db--int-to-bool (val)
  "Convert integer VAL (0 or 1) to nil or t."
  (not (or (null val) (eql val 0))))

(defun infovore-db--encode-metadata (alist)
  "Encode metadata ALIST as a JSON string, or nil if ALIST is nil."
  (if alist
      (json-serialize alist)
    nil))

(defun infovore-db--decode-metadata (json-str)
  "Decode JSON-STR back to an alist, or nil if JSON-STR is nil or empty."
  (if (and json-str (not (string-empty-p json-str)))
      (json-parse-string json-str :object-type 'alist)
    nil))

;;;; Row conversion

(defun infovore-db--row-to-item (row)
  "Convert a database ROW to an `infovore-item' struct.
ROW is a list of column values in table definition order."
  (make-infovore-item
   :id          (nth 0 row)
   :source-id   (nth 1 row)
   :source-type (nth 2 row)
   :title       (nth 3 row)
   :author      (nth 4 row)
   :url         (nth 5 row)
   :content     (nth 6 row)
   :summary     (nth 7 row)
   :score       (nth 8 row)
   :timestamp   (nth 9 row)
   :fetched-at  (nth 10 row)
   :read-p      (infovore-db--int-to-bool (nth 11 row))
   :starred-p   (infovore-db--int-to-bool (nth 12 row))
   :curated-p   (infovore-db--int-to-bool (nth 13 row))
   :metadata    (infovore-db--decode-metadata (nth 14 row))))

(defun infovore-db--rows-to-items (rows)
  "Convert a list of database ROWS to a list of `infovore-item' structs."
  (mapcar #'infovore-db--row-to-item rows))

;;;; Public API -- insert / update

(defun infovore-db-insert-item (item)
  "Insert ITEM (an `infovore-item' struct) into the database.
Uses INSERT OR IGNORE so duplicate IDs are silently skipped."
  (let ((db (infovore-db-ensure)))
    (emacsql db [:insert-or-ignore :into items
                 :values $v1]
             (vector
              (infovore-item-id item)
              (infovore-item-source-id item)
              (infovore-item-source-type item)
              (infovore-item-title item)
              (infovore-item-author item)
              (infovore-item-url item)
              (infovore-item-content item)
              (infovore-item-summary item)
              (infovore-item-score item)
              (infovore-item-timestamp item)
              (infovore-item-fetched-at item)
              (infovore-db--bool-to-int (infovore-item-read-p item))
              (infovore-db--bool-to-int (infovore-item-starred-p item))
              (infovore-db--bool-to-int (infovore-item-curated-p item))
              (infovore-db--encode-metadata (infovore-item-metadata item))))))

(defun infovore-db-update-item (id &rest fields)
  "Update specific FIELDS of the item with ID.
FIELDS is a plist like `:score 0.8 :summary \"...\".
Field names are mapped to column names (e.g. :read-p -> read,
:starred-p -> starred, :curated-p -> curated)."
  (when fields
    (let ((db (infovore-db-ensure)))
      (emacsql-with-transaction db
        (cl-loop for (key val) on fields by #'cddr do
                 (let ((col (infovore-db--field-to-column key))
                       (stored-val (infovore-db--encode-field-value key val)))
                   (emacsql db [:update items
                                :set (= $i1 $s2)
                                :where (= id $s3)]
                            col stored-val id)))))))

(defun infovore-db--field-to-column (keyword)
  "Map a struct field KEYWORD to its database column symbol."
  (pcase keyword
    (:read-p    'read)
    (:starred-p 'starred)
    (:curated-p 'curated)
    (:source-id 'source-id)
    (:source-type 'source-type)
    (:fetched-at 'fetched-at)
    (_ (intern (substring (symbol-name keyword) 1)))))

(defun infovore-db--encode-field-value (keyword value)
  "Encode VALUE for storage based on the field KEYWORD."
  (pcase keyword
    ((or :read-p :starred-p :curated-p)
     (infovore-db--bool-to-int value))
    (:metadata
     (infovore-db--encode-metadata value))
    (_ value)))

;;;; Public API -- query

(defun infovore-db-get-item (id)
  "Retrieve the item with ID from the database.
Return an `infovore-item' struct, or nil if not found."
  (let* ((db (infovore-db-ensure))
         (rows (emacsql db [:select * :from items
                            :where (= id $s1)]
                        id)))
    (when rows
      (infovore-db--row-to-item (car rows)))))

(defun infovore-db-item-exists-p (id)
  "Return non-nil if an item with ID exists in the database."
  (let* ((db (infovore-db-ensure))
         (result (emacsql db [:select (funcall count id) :from items
                              :where (= id $s1)]
                          id)))
    (and result (> (caar result) 0))))

(cl-defun infovore-db-query-items (&key curated-only min-score source-id
                                       source-type limit offset order-by)
  "Query items with optional filtering.

Keywords:
  CURATED-ONLY -- when non-nil, only return items where curated=1.
  MIN-SCORE    -- when set, filter by score >= this value.
  SOURCE-ID    -- filter by source ID.
  SOURCE-TYPE  -- filter by source type.
  LIMIT        -- maximum number of items to return.
  OFFSET       -- number of items to skip.
  ORDER-BY     -- SQL ORDER BY clause as a string; defaults to
                  \"timestamp DESC\".

Return a list of `infovore-item' structs."
  (let* ((db (infovore-db-ensure))
         (conditions '())
         (params '())
         (param-idx 0))
    (when curated-only
      (push "curated = 1" conditions))
    (when min-score
      (cl-incf param-idx)
      (push (format "score >= $s%d" param-idx) conditions)
      (push min-score params))
    (when source-id
      (cl-incf param-idx)
      (push (format "source_id = $s%d" param-idx) conditions)
      (push source-id params))
    (when source-type
      (cl-incf param-idx)
      (push (format "source_type = $s%d" param-idx) conditions)
      (push (if (symbolp source-type) (symbol-name source-type) source-type)
            params))
    (let* ((where (if conditions
                      (concat " WHERE "
                              (mapconcat #'identity (nreverse conditions)
                                         " AND "))
                    ""))
           (order (format " ORDER BY %s" (or order-by "timestamp DESC")))
           (limit-clause (if limit (format " LIMIT %d" limit) ""))
           (offset-clause (if offset (format " OFFSET %d" offset) ""))
           (sql (concat "SELECT * FROM items" where order
                        limit-clause offset-clause))
           (rows (apply #'emacsql db sql (nreverse params))))
      (infovore-db--rows-to-items rows))))

(defun infovore-db-uncurated-items (&optional limit)
  "Return items where curated=0, ordered by fetched_at ASC.
Optional LIMIT caps the number of results."
  (let* ((db (infovore-db-ensure))
         (rows (if limit
                   (emacsql db [:select * :from items
                                :where (= curated 0)
                                :order-by (asc fetched-at)
                                :limit $s1]
                            limit)
                 (emacsql db [:select * :from items
                              :where (= curated 0)
                              :order-by (asc fetched-at)]))))
    (infovore-db--rows-to-items rows)))

(defun infovore-db-count-unread-curated ()
  "Return the count of items where curated=1 and read=0."
  (let* ((db (infovore-db-ensure))
         (result (emacsql db [:select (funcall count *) :from items
                              :where (and (= curated 1) (= read 0))])))
    (if result (caar result) 0)))

;;;; Public API -- budget

(defun infovore-db-get-budget-tokens (date-string)
  "Get the number of tokens used on DATE-STRING (\"YYYY-MM-DD\").
Return 0 if no entry exists for that date."
  (let* ((db (infovore-db-ensure))
         (result (emacsql db [:select [tokens-used] :from budget
                              :where (= date $s1)]
                          date-string)))
    (if result (caar result) 0)))

(defun infovore-db-add-budget-tokens (date-string amount)
  "Add AMOUNT to the token count for DATE-STRING.
Uses upsert semantics: creates the row if it does not exist, otherwise
adds AMOUNT to the existing total."
  (let* ((db (infovore-db-ensure))
         (current (infovore-db-get-budget-tokens date-string))
         (new-total (+ current amount)))
    (emacsql db [:insert-or-replace :into budget
                 :values $v1]
             (vector date-string new-total))))

(provide 'infovore-db)
;;; infovore-db.el ends here
