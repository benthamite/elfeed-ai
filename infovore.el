;;; infovore.el --- AI-powered content curation for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1") (gptel "0.9") (emacsql "4.0.0") (emacsql-sqlite "4.0.0"))
;; Version: 0.1.0

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

;; Infovore fetches content from user-configured sources (Twitter accounts,
;; RSS feeds, Substack newsletters, etc.), stores everything in a SQLite
;; database, uses gptel to score each item for relevance against the user's
;; interest profile, and presents curated items in an elfeed-style list view
;; with a split-buffer detail view.
;;
;; This file is the main entry point.  It ties together all modules,
;; provides the source configuration and instantiation, the fetch
;; scheduling timer, and the public API.
;;
;; Quick start:
;;
;;   (require 'infovore)
;;
;;   (setq infovore-sources
;;         '((:type rss :url "https://example.com/feed.xml")
;;           (:type substack :publication "astralcodexten")
;;           (:type twitter :username "elonmusk")))
;;
;;   (setq infovore-interest-profile
;;         "AI safety, Emacs, functional programming, philosophy of mind")
;;
;;   (infovore)         ; open the feed list
;;   (infovore-start)   ; start the automatic fetch timer

;;; Code:

(require 'cl-lib)
(require 'infovore-source)
(require 'infovore-source-rss)
(require 'infovore-source-twitter)
(require 'infovore-source-substack)
(require 'infovore-db)
(require 'infovore-ai)
(require 'infovore-list)
(require 'infovore-show)
(require 'infovore-modeline)

;; Soft-require optional integration.
(require 'infovore-ebib nil t)

;;;; Customization

(defcustom infovore-sources '()
  "List of source configurations.
Each element is a plist with at least :type and type-specific keys.

Examples:
  (:type rss :url \"https://example.com/feed.xml\")
  (:type twitter :username \"elikiln\")
  (:type substack :publication \"astralcodexten\")"
  :type '(repeat plist)
  :group 'infovore)

(defcustom infovore-fetch-interval 60
  "Minutes between automatic fetch cycles."
  :type 'integer
  :group 'infovore)

;;;; Internal state

(defvar infovore--sources nil
  "List of instantiated source objects.")

(defvar infovore--fetch-timer nil
  "Timer for periodic fetch cycles, or nil when stopped.")

(defvar infovore--fetching nil
  "Non-nil while a fetch cycle is in progress.")

;;;; Source instantiation

(defun infovore--instantiate-source (config)
  "Create a source object from CONFIG plist.
CONFIG must contain at least :type.  Additional keys depend on the
source type:
  rss      — :url (required)
  twitter  — :username (required)
  substack — :publication (required)
All types accept an optional :name for display."
  (let ((type (plist-get config :type)))
    (pcase type
      ('rss
       (let ((url (plist-get config :url)))
         (unless url (error "RSS source requires :url"))
         (infovore-source-rss
          :id (format "rss:%s" url)
          :name (or (plist-get config :name) url)
          :url url)))
      ('twitter
       (let ((username (plist-get config :username)))
         (unless username (error "Twitter source requires :username"))
         (infovore-source-twitter
          :id (format "twitter:%s" username)
          :name (or (plist-get config :name) (format "@%s" username))
          :username username)))
      ('substack
       (let ((publication (plist-get config :publication)))
         (unless publication (error "Substack source requires :publication"))
         (infovore-source-substack
          :id (format "substack:%s" publication)
          :name (or (plist-get config :name) publication)
          :publication publication)))
      (_ (error "Unknown source type: %S" type)))))

(defun infovore--instantiate-sources ()
  "Create source objects from `infovore-sources' configuration.
Replaces `infovore--sources' with the new list."
  (setq infovore--sources
        (mapcar #'infovore--instantiate-source infovore-sources)))

;;;; Fetch cycle

(defun infovore--run-fetch-cycle ()
  "Run a complete fetch cycle.
For each enabled source, fetch new items asynchronously, deduplicate
against the database, insert new items, run AI curation on uncurated
items, and update the UI."
  (if infovore--fetching
      (infovore-log 'info "Fetch cycle already in progress, skipping")
    (unless infovore--sources
      (infovore--instantiate-sources))
    (let ((enabled-sources (cl-remove-if-not #'infovore-source-enabled-p
                                             infovore--sources)))
      (if (null enabled-sources)
          (progn
            (infovore-log 'warn "No enabled sources configured")
            (message "Infovore: no sources configured"))
        (setq infovore--fetching t)
        (infovore-log 'info "Starting fetch cycle (%d sources)"
                      (length enabled-sources))
        (let ((remaining (length enabled-sources))
              (total-new 0))
          (dolist (source enabled-sources)
            (infovore-source-fetch
             source
             (lambda (items)
               (let ((new-count 0))
                 (when items
                   (dolist (item items)
                     (let ((url (infovore-item-url item)))
                       (when url
                         (let ((normalized (infovore-normalize-url url)))
                           (when normalized
                             (setf (infovore-item-id item) normalized)))))
                     (unless (infovore-db-item-exists-p (infovore-item-id item))
                       (infovore-db-insert-item item)
                       (setq new-count (1+ new-count)))))
                 (setq total-new (+ total-new new-count))
                 (setq remaining (1- remaining))
                 (when (zerop remaining)
                   (infovore-log 'info "Fetch cycle complete: %d new items"
                                 total-new)
                   (if (> total-new 0)
                       (infovore-ai-curate-pending
                        (lambda (scored)
                          (infovore-log 'info "Scored %d items" scored)
                          (infovore--post-fetch-update)
                          (setq infovore--fetching nil)))
                     (infovore--post-fetch-update)
                     (setq infovore--fetching nil))))))))))))

(defun infovore--post-fetch-update ()
  "Update UI elements after a fetch cycle completes."
  (when (bound-and-true-p infovore-mode-line-mode)
    (infovore-modeline-update))
  (when-let ((buf (get-buffer "*infovore*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'infovore-list-mode)
          (infovore-list-refresh))))))

;;;; Scheduling

;;;###autoload
(defun infovore-start ()
  "Start the automatic fetch timer.
Instantiates sources, opens the database, and schedules periodic
fetches according to `infovore-fetch-interval'."
  (interactive)
  (infovore-stop)
  (infovore--instantiate-sources)
  (infovore-db-ensure)
  (setq infovore--fetch-timer
        (run-at-time 0 (* infovore-fetch-interval 60)
                     #'infovore--run-fetch-cycle))
  (infovore-log 'info "Infovore started (fetching every %d minutes)"
                infovore-fetch-interval)
  (message "Infovore started (fetching every %d minutes)"
           infovore-fetch-interval))

;;;###autoload
(defun infovore-stop ()
  "Stop the automatic fetch timer."
  (interactive)
  (when infovore--fetch-timer
    (cancel-timer infovore--fetch-timer)
    (setq infovore--fetch-timer nil)
    (infovore-log 'info "Infovore stopped")
    (message "Infovore stopped")))

;;;###autoload
(defun infovore-fetch-now ()
  "Manually trigger an immediate fetch cycle."
  (interactive)
  (if infovore--fetching
      (message "Infovore: fetch already in progress")
    (infovore-db-ensure)
    (infovore--run-fetch-cycle)))

;;;; Entry point

;;;###autoload
(defun infovore ()
  "Open the infovore feed list buffer.
Initialize sources and database on first invocation."
  (interactive)
  (infovore-db-ensure)
  (unless infovore--sources
    (infovore--instantiate-sources))
  (infovore-list-open))

(provide 'infovore)
;;; infovore.el ends here
