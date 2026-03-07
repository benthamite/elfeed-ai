;;; infovore-show.el --- Item detail view for infovore  -*- lexical-binding: t; -*-

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

;; Item detail view for infovore.  Opens in a split buffer below the
;; feed list, displaying either an AI-generated summary or the original
;; content.  Provides keybindings for toggling views, browsing the
;; original URL, and navigating between items.

;;; Code:

(require 'shr)
(require 'infovore-source)

(declare-function infovore-list--get-item-at-point "infovore-list" ())
(declare-function infovore-list-refresh "infovore-list" ())

;;;; Faces

(defface infovore-show-header-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for header fields in the item detail view."
  :group 'infovore)

(defface infovore-show-url-face
  '((t :inherit link))
  "Face for the URL line in the item detail view."
  :group 'infovore)

;;;; Buffer-local state

(defvar-local infovore-show--item nil
  "The `infovore-item' currently displayed in this buffer.")

(defvar-local infovore-show--view 'summary
  "Current view mode: `summary' or `original'.")

;;;; Source type label

(defun infovore-show--source-label (source-type)
  "Return a human-readable label for SOURCE-TYPE."
  (pcase source-type
    ('rss      "RSS")
    ("rss"     "RSS")
    ('twitter  "Twitter")
    ("twitter" "Twitter")
    ('substack "Substack")
    ("substack" "Substack")
    (_ (format "%s" source-type))))

;;;; Timestamp formatting

(defun infovore-show--format-date (unix-timestamp)
  "Format UNIX-TIMESTAMP as a readable date string."
  (if unix-timestamp
      (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time unix-timestamp))
    "unknown"))

;;;; Header rendering

(defun infovore-show--insert-header (item)
  "Insert the header section for ITEM into the current buffer."
  (let ((author (or (infovore-item-author item) "unknown"))
        (source-type (infovore-show--source-label (infovore-item-source-type item)))
        (date (infovore-show--format-date (infovore-item-timestamp item)))
        (score (infovore-item-score item))
        (title (infovore-item-title item))
        (url (infovore-item-url item)))
    ;; Title
    (when title
      (insert (propertize title 'face '(:weight bold :height 1.3))
              "\n\n"))
    ;; Metadata line
    (insert (propertize "Author: " 'face 'infovore-show-header-face)
            author "  "
            (propertize "Source: " 'face 'infovore-show-header-face)
            source-type "  "
            (propertize "Date: " 'face 'infovore-show-header-face)
            date)
    (when score
      (insert "  "
              (propertize "Score: " 'face 'infovore-show-header-face)
              (format "%.2f" score)))
    (insert "\n")
    ;; URL
    (when url
      (insert (propertize "Link: " 'face 'infovore-show-header-face)
              (propertize url
                          'face 'infovore-show-url-face
                          'mouse-face 'highlight
                          'help-echo "Open in browser"
                          'keymap (let ((map (make-sparse-keymap)))
                                    (define-key map [mouse-1]
                                      (lambda () (interactive) (browse-url url)))
                                    (define-key map (kbd "RET")
                                      (lambda () (interactive) (browse-url url)))
                                    map))
              "\n"))
    ;; Separator
    (insert "\n"
            (propertize (make-string 60 ?-) 'face 'shadow)
            "\n\n")))

;;;; View rendering

(defun infovore-show--render-summary (item)
  "Render the summary view of ITEM in the current buffer."
  (infovore-show--insert-header item)
  (let ((summary (infovore-item-summary item)))
    (if (and summary (not (string-empty-p summary)))
        (insert summary "\n")
      (insert (propertize "No summary available." 'face 'shadow) "\n"))))

(defun infovore-show--render-original (item)
  "Render the original content of ITEM in the current buffer.
If the content looks like HTML, render it with `shr'.
Otherwise, insert it as plain text."
  (infovore-show--insert-header item)
  (let ((content (infovore-item-content item)))
    (if (and content (not (string-empty-p content)))
        (if (string-match-p "<[a-zA-Z][^>]*>" content)
            ;; HTML content: render with shr.
            (let ((start (point)))
              (insert content)
              (shr-render-region start (point))
              (goto-char (point-max))
              (insert "\n"))
          ;; Plain text content.
          (insert content "\n"))
      (insert (propertize "No content available." 'face 'shadow) "\n"))))

(defun infovore-show--render (item view)
  "Render ITEM according to VIEW (`summary' or `original')."
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; View indicator
    (insert (propertize (format "[%s]"
                                (if (eq view 'summary) "Summary" "Original"))
                        'face 'bold)
            "  "
            (propertize "(press TAB to toggle)" 'face 'shadow)
            "\n\n")
    (pcase view
      ('summary  (infovore-show--render-summary item))
      ('original (infovore-show--render-original item)))
    (goto-char (point-min))))

;;;; Major mode

(defvar infovore-show-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'infovore-show-toggle-view)
    (define-key map (kbd "t")   #'infovore-show-toggle-view)
    (define-key map (kbd "b")   #'infovore-show-browse-url)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "n")   #'infovore-show-next)
    (define-key map (kbd "p")   #'infovore-show-prev)
    map)
  "Keymap for `infovore-show-mode'.")

(define-derived-mode infovore-show-mode special-mode "Infovore-Show"
  "Major mode for viewing an infovore item in detail.
Displays either an AI-generated summary or the original content.

\\{infovore-show-mode-map}")

;;;; Public API

(defun infovore-show-item (item)
  "Display ITEM in the infovore detail buffer.
Create or reuse the `*infovore-entry*' buffer and show it in a
window below the current one.  Default to the summary view."
  (let ((buf (get-buffer-create "*infovore-entry*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'infovore-show-mode)
        (infovore-show-mode))
      (setq infovore-show--item item)
      (setq infovore-show--view 'summary)
      (infovore-show--render item 'summary))
    (display-buffer buf
                    '(display-buffer-below-selected
                      (window-height . 0.4)))))

;;;; Interactive commands

(defun infovore-show-toggle-view ()
  "Toggle between summary and original content views."
  (interactive)
  (unless infovore-show--item
    (user-error "No item displayed"))
  (setq infovore-show--view
        (if (eq infovore-show--view 'summary) 'original 'summary))
  (infovore-show--render infovore-show--item infovore-show--view))

(defun infovore-show-browse-url ()
  "Open the current item's URL in the default browser."
  (interactive)
  (unless infovore-show--item
    (user-error "No item displayed"))
  (if-let ((url (infovore-item-url infovore-show--item)))
      (browse-url url)
    (user-error "Item has no URL")))

(defun infovore-show-next ()
  "Show the next item from the feed list."
  (interactive)
  (when-let ((list-win (get-buffer-window "*infovore*")))
    (with-selected-window list-win
      (forward-line 1)
      (when-let ((item (infovore-list--get-item-at-point)))
        (infovore-show-item item)))))

(defun infovore-show-prev ()
  "Show the previous item from the feed list."
  (interactive)
  (when-let ((list-win (get-buffer-window "*infovore*")))
    (with-selected-window list-win
      (forward-line -1)
      (when-let ((item (infovore-list--get-item-at-point)))
        (infovore-show-item item)))))

(provide 'infovore-show)
;;; infovore-show.el ends here
