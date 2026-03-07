;;; infovore-modeline.el --- Mode line indicator for infovore  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm
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

;; A lightweight mode line element showing the count of unread curated
;; items in infovore.  Displays `[IV:N]' where N is the unread count.
;; When there are no unread items the indicator is dimmed; when there
;; are unread items it is displayed with a noticeable face.
;;
;; Enable with `infovore-mode-line-mode'.  The count is refreshed by
;; calling `infovore-modeline-update' (typically done by the main
;; module after each fetch cycle).

;;; Code:

(require 'infovore-db)

;;;; Faces

(defface infovore-modeline-face
  '((t :inherit mode-line))
  "Default face for the infovore mode line indicator.
Used when the unread count is zero."
  :group 'infovore)

(defface infovore-modeline-active-face
  '((t :inherit mode-line :weight bold :foreground "#e0a030"))
  "Face for the infovore mode line indicator when there are unread items."
  :group 'infovore)

;;;; State

(defvar infovore-modeline--count 0
  "Cached count of unread curated items.")

;;;; Mode line construct

(defvar infovore-modeline--string
  '(:eval (infovore-modeline--format))
  "Mode line construct for the infovore indicator.
Displays `[IV:N]' with appropriate face.")

;; Allow the :eval form to be used in the mode line.
(put 'infovore-modeline--string 'risky-local-variable t)

(defun infovore-modeline--format ()
  "Return the formatted mode line string for infovore."
  (let ((count infovore-modeline--count))
    (if (> count 0)
        (propertize (format " [IV:%d]" count)
                    'face 'infovore-modeline-active-face
                    'help-echo (format "infovore: %d unread curated item%s"
                                       count (if (= count 1) "" "s")))
      (propertize " [IV:0]"
                  'face 'infovore-modeline-face
                  'help-echo "infovore: no unread curated items"))))

;;;; Update function

(defun infovore-modeline-update ()
  "Query the database for unread curated items and update the mode line.
This function is intended to be called after each fetch cycle by the
main infovore module."
  (condition-case err
      (setq infovore-modeline--count (infovore-db-count-unread-curated))
    (error
     (setq infovore-modeline--count 0)
     (message "infovore-modeline: failed to query unread count: %S" err)))
  (force-mode-line-update t))

;;;; Global minor mode

;;;###autoload
(define-minor-mode infovore-mode-line-mode
  "Toggle the infovore mode line indicator.
When enabled, display the count of unread curated items in the
mode line as `[IV:N]'."
  :global t
  :group 'infovore
  (if infovore-mode-line-mode
      (progn
        (unless (member 'infovore-modeline--string global-mode-string)
          (setq global-mode-string
                (append global-mode-string '(infovore-modeline--string))))
        (infovore-modeline-update))
    (setq global-mode-string
          (remove 'infovore-modeline--string global-mode-string))
    (force-mode-line-update t)))

(provide 'infovore-modeline)
;;; infovore-modeline.el ends here
