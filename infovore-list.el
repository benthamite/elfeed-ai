;;; infovore-list.el --- Feed list view for infovore  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1"))

;; This file is NOT part of GNU Emacs.

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

;; An elfeed-style major mode showing curated items in a tabulated list.
;; Provides the main `infovore' entry point command and keybindings for
;; browsing, toggling read/starred state, and opening items in a detail
;; view.

;;; Code:

(require 'tabulated-list)
(require 'infovore-source)
(require 'infovore-db)

(declare-function infovore-show-item "infovore-show" (item))
(declare-function infovore-fetch-now "infovore" ())
(declare-function infovore-ebib-save "infovore-ebib" ())

;;;; Customization

(defcustom infovore-list-format
  '((:source 6 t) (:author 20 t) (:title 0 t) (:score 5 t) (:time 12 t))
  "Format specification for the feed list columns.
Each element is (FIELD WIDTH SORTABLE-P)."
  :type '(repeat (list symbol integer boolean))
  :group 'infovore)

;;;; Faces

(defface infovore-read-face
  '((t :inherit shadow))
  "Face for read items in the feed list."
  :group 'infovore)

(defface infovore-starred-face
  '((t :inherit warning :weight bold))
  "Face for starred items in the feed list."
  :group 'infovore)

(defface infovore-score-high-face
  '((t :inherit success))
  "Face for high relevance scores in the feed list."
  :group 'infovore)

(defface infovore-score-low-face
  '((t :inherit shadow))
  "Face for low relevance scores in the feed list."
  :group 'infovore)

;;;; Buffer-local state

(defvar-local infovore-list--items nil
  "List of `infovore-item' structs currently displayed.")

(defvar-local infovore-list--show-all nil
  "When non-nil, show all items including uncurated.")

;;;; External variables

(defvar infovore-relevance-threshold)

;;;; Relative time formatting

(defun infovore-list--relative-time (unix-timestamp)
  "Format UNIX-TIMESTAMP as a relative time string.
Returns strings like \"2h ago\", \"yesterday\", \"3d ago\"."
  (if (null unix-timestamp)
      ""
    (let* ((now (float-time))
           (delta (- now unix-timestamp))
           (minutes (/ delta 60))
           (hours (/ delta 3600))
           (days (/ delta 86400)))
      (cond
       ((< delta 60) "just now")
       ((< minutes 60) (format "%dm ago" (floor minutes)))
       ((< hours 24) (format "%dh ago" (floor hours)))
       ((< hours 48) "yesterday")
       ((< days 30) (format "%dd ago" (floor days)))
       ((< days 365) (format "%dmo ago" (floor (/ days 30))))
       (t (format "%dy ago" (floor (/ days 365))))))))

;;;; Source type icon

(defun infovore-list--source-icon (source-type)
  "Return a short icon string for SOURCE-TYPE."
  (pcase source-type
    ('rss      "[RSS]")
    ("rss"     "[RSS]")
    ('twitter  "[TW]")
    ("twitter" "[TW]")
    ('substack "[SS]")
    ("substack" "[SS]")
    (_ "[??]")))

;;;; Entry formatting

(defun infovore-list--format-entry (item)
  "Convert an `infovore-item' ITEM to a `tabulated-list' entry.
Return a list (ID VECTOR) suitable for `tabulated-list-entries'.
Apply faces based on read/starred state."
  (let* ((read-p (infovore-item-read-p item))
         (starred-p (infovore-item-starred-p item))
         (score (infovore-item-score item))
         (face (cond
                (starred-p 'infovore-starred-face)
                (read-p 'infovore-read-face)
                (t nil)))
         (source-str (infovore-list--source-icon (infovore-item-source-type item)))
         (author-str (or (infovore-item-author item) ""))
         (title-str (or (infovore-item-title item)
                        (when-let ((summary (infovore-item-summary item)))
                          (truncate-string-to-width summary 80))
                        ""))
         (score-str (if score (format "%.2f" score) ""))
         (score-face (cond
                      ((null score) nil)
                      ((>= score 0.7) 'infovore-score-high-face)
                      ((<= score 0.3) 'infovore-score-low-face)
                      (t nil)))
         (time-str (infovore-list--relative-time (infovore-item-timestamp item)))
         ;; Apply the overall face to source, author, title, time.
         (source-propertized (if face (propertize source-str 'face face) source-str))
         (author-propertized (if face (propertize author-str 'face face) author-str))
         (title-propertized (if face (propertize title-str 'face face) title-str))
         (score-propertized (propertize score-str 'face (or score-face face)))
         (time-propertized (if face (propertize time-str 'face face) time-str)))
    (list (infovore-item-id item)
          (vector source-propertized
                  author-propertized
                  title-propertized
                  score-propertized
                  time-propertized))))

;;;; Item at point

(defun infovore-list--get-item-at-point ()
  "Return the `infovore-item' at point, or nil."
  (when-let ((id (tabulated-list-get-id)))
    (cl-find id infovore-list--items
             :key #'infovore-item-id
             :test #'equal)))

;;;; Tabulated list setup

(defun infovore-list--build-format ()
  "Build `tabulated-list-format' from `infovore-list-format'."
  (let ((field-names '((:source . "Source")
                       (:author . "Author")
                       (:title  . "Title")
                       (:score  . "Score")
                       (:time   . "Time"))))
    (vconcat
     (mapcar (lambda (spec)
               (let ((field (nth 0 spec))
                     (width (nth 1 spec))
                     (sortable (nth 2 spec)))
                 (list (or (alist-get field field-names) (symbol-name field))
                       width
                       sortable)))
             infovore-list-format))))

;;;; Refresh

(defun infovore-list-refresh ()
  "Query items from the database and populate the tabulated list.
When `infovore-list--show-all' is nil (the default), show only
curated items with score >= `infovore-relevance-threshold', sorted
by timestamp descending."
  (interactive)
  (let ((items (if infovore-list--show-all
                   (infovore-db-query-items :order-by "timestamp DESC")
                 (infovore-db-query-items
                  :curated-only t
                  :min-score (and (boundp 'infovore-relevance-threshold)
                                  infovore-relevance-threshold)
                  :order-by "timestamp DESC"))))
    (setq infovore-list--items items)
    (setq tabulated-list-entries
          (mapcar #'infovore-list--format-entry items))
    (tabulated-list-print t)
    (message "Infovore: %d items" (length items))))

;;;; Major mode

(defvar infovore-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'infovore-list-show-item)
    (define-key map (kbd "b")   #'infovore-list-browse-url)
    (define-key map (kbd "r")   #'infovore-list-toggle-read)
    (define-key map (kbd "s")   #'infovore-list-toggle-starred)
    (define-key map (kbd "g")   #'infovore-list-refresh)
    (define-key map (kbd "G")   #'infovore-fetch-now)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "S")   #'infovore-ebib-save)
    (define-key map (kbd "+")   #'infovore-list-show-all)
    (define-key map (kbd "-")   #'infovore-list-show-curated)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    map)
  "Keymap for `infovore-list-mode'.")

(define-derived-mode infovore-list-mode tabulated-list-mode "Infovore"
  "Major mode for the infovore feed list.
Displays curated content items in a tabulated list with columns
for source type, author, title, relevance score, and timestamp.

\\{infovore-list-mode-map}"
  (setq tabulated-list-format (infovore-list--build-format))
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

;;;; Entry point

;;;###autoload
(defun infovore ()
  "Open the infovore feed list buffer."
  (interactive)
  (let ((buf (get-buffer-create "*infovore*")))
    (switch-to-buffer buf)
    (unless (derived-mode-p 'infovore-list-mode)
      (infovore-list-mode))
    (infovore-list-refresh)))

;;;; Interactive commands

(defun infovore-list-show-item ()
  "Open the item at point in the detail view."
  (interactive)
  (if-let ((item (infovore-list--get-item-at-point)))
      (infovore-show-item item)
    (user-error "No item at point")))

(defun infovore-list-browse-url ()
  "Open the URL of the item at point in the default browser."
  (interactive)
  (if-let ((item (infovore-list--get-item-at-point)))
      (if-let ((url (infovore-item-url item)))
          (browse-url url)
        (user-error "Item has no URL"))
    (user-error "No item at point")))

(defun infovore-list-toggle-read ()
  "Toggle the read/unread state of the item at point."
  (interactive)
  (if-let ((item (infovore-list--get-item-at-point)))
      (let ((new-state (not (infovore-item-read-p item))))
        (setf (infovore-item-read-p item) new-state)
        (infovore-db-update-item (infovore-item-id item) :read-p new-state)
        (infovore-list-refresh)
        (message "Item marked as %s" (if new-state "read" "unread")))
    (user-error "No item at point")))

(defun infovore-list-toggle-starred ()
  "Toggle the starred state of the item at point."
  (interactive)
  (if-let ((item (infovore-list--get-item-at-point)))
      (let ((new-state (not (infovore-item-starred-p item))))
        (setf (infovore-item-starred-p item) new-state)
        (infovore-db-update-item (infovore-item-id item) :starred-p new-state)
        (infovore-list-refresh)
        (message "Item %s" (if new-state "starred" "unstarred")))
    (user-error "No item at point")))

(defun infovore-list-show-all ()
  "Show all items, including uncurated ones."
  (interactive)
  (setq infovore-list--show-all t)
  (infovore-list-refresh)
  (message "Showing all items"))

(defun infovore-list-show-curated ()
  "Show only curated items (score >= threshold)."
  (interactive)
  (setq infovore-list--show-all nil)
  (infovore-list-refresh)
  (message "Showing curated items only"))

(provide 'infovore-list)
;;; infovore-list.el ends here
