;;; infovore-ebib.el --- Ebib/Zotra integration for infovore  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, bib
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

;; Optional integration between infovore and ebib/zotra for saving
;; bibliographic entries.  When both `zotra' and `ebib' are installed,
;; the command `infovore-ebib-save' fetches citation metadata for the
;; current item's URL via zotra and imports it into the ebib database.
;;
;; This is a soft dependency: when either package is missing, the
;; feature is gracefully unavailable and the save command reports
;; what is needed.
;;
;; The command works from both `infovore-list-mode' and
;; `infovore-show-mode' buffers.
;;
;; Note on zotra API: This module calls `zotra-get-entry-from-url' to
;; retrieve a BibTeX string, then passes it to `ebib-import-entries'.
;; If your version of zotra uses a different function name (e.g.,
;; `zotra-get-entry' or `zotra-add-entry'), you may need to adjust
;; the call in `infovore-ebib--fetch-and-import'.

;;; Code:

(require 'infovore-source)

;; Soft-require zotra and ebib; do not error if absent.
(require 'zotra nil t)
(require 'ebib nil t)

;;;; Availability check

(defun infovore-ebib-available-p ()
  "Return non-nil if both `zotra' and `ebib' are available."
  (and (featurep 'zotra)
       (featurep 'ebib)))

;;;; Item retrieval helpers

(defun infovore-ebib--item-at-point ()
  "Return the `infovore-item' at point in the current buffer.
Works in both `infovore-list-mode' and `infovore-show-mode'.
Returns nil if no item can be determined."
  (cond
   ;; In show mode, the item is stored in a buffer-local variable.
   ((and (boundp 'infovore-show--item)
         (symbol-value 'infovore-show--item))
    (symbol-value 'infovore-show--item))
   ;; In list mode, the item is associated with the current line
   ;; via a text property or tabulated-list entry.
   ((and (boundp 'infovore-list-mode)
         (derived-mode-p 'infovore-list-mode))
    (or (and (boundp 'infovore-list--get-item-at-point)
             (fboundp 'infovore-list--get-item-at-point)
             (infovore-list--get-item-at-point))
        (get-text-property (line-beginning-position) 'infovore-item)))
   ;; Fallback: check for item text property at point.
   (t (get-text-property (line-beginning-position) 'infovore-item))))

;;;; BibTeX import

(defun infovore-ebib--fetch-and-import (url)
  "Fetch BibTeX for URL via zotra and import into ebib.
Signals a `user-error' if the fetch fails or yields no entry."
  ;; `zotra-get-entry-from-url' is the standard zotra function that
  ;; takes a URL and returns a BibTeX entry string.  If your zotra
  ;; version exposes a different API, adjust this call accordingly.
  (unless (fboundp 'zotra-get-entry-from-url)
    (user-error "Function `zotra-get-entry-from-url' not found; \
check your zotra version"))
  (let ((bibtex (zotra-get-entry-from-url url)))
    (unless (and bibtex (stringp bibtex) (not (string-empty-p bibtex)))
      (user-error "Zotra returned no BibTeX entry for %s" url))
    ;; Import into ebib.
    (unless (fboundp 'ebib-import-entries)
      (user-error "Function `ebib-import-entries' not found; \
check your ebib version"))
    (ebib-import-entries bibtex)
    (message "Imported BibTeX entry for %s into ebib" url)))

;;;; Interactive command

;;;###autoload
(defun infovore-ebib-save ()
  "Save the current infovore item to ebib via zotra.
Fetch citation metadata for the item's URL with zotra and import
the resulting BibTeX entry into the ebib database.

This command works from both `infovore-list-mode' and
`infovore-show-mode' buffers."
  (interactive)
  (unless (infovore-ebib-available-p)
    (user-error "Both `zotra' and `ebib' are required for this command; \
install the missing package(s)"))
  (let ((item (infovore-ebib--item-at-point)))
    (unless item
      (user-error "No infovore item at point"))
    (let ((url (infovore-item-url item)))
      (unless (and url (stringp url) (not (string-empty-p url)))
        (user-error "Item has no URL"))
      (infovore-ebib--fetch-and-import url))))

(provide 'infovore-ebib)
;;; infovore-ebib.el ends here
