;;; infovore-source.el --- Base source class and data model for infovore -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; This file defines the base data model and source protocol for infovore.
;; It provides the `infovore-item' struct for representing content items,
;; the `infovore-source' abstract EIEIO class that all source plugins must
;; inherit from, URL normalization for deduplication, and error handling /
;; retry infrastructure shared across all sources.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'url)
(require 'url-parse)

;;;; Customization group

(defgroup infovore nil
  "AI-curated content aggregator."
  :group 'comm
  :prefix "infovore-")

;;;; Custom variables

(defcustom infovore-max-retries 3
  "Maximum number of retry attempts for failed fetches."
  :type 'integer
  :group 'infovore)

(defcustom infovore-retry-base-delay 30
  "Base delay in seconds for retry backoff.
The delay for attempt N is (* base-delay (expt 4 N)), yielding
intervals of 30s, 120s, 480s with the default base delay."
  :type 'integer
  :group 'infovore)

;;;; Data model

(cl-defstruct infovore-item
  "A content item fetched from a source."
  id           ; string -- Unique ID (URL-based, for deduplication)
  source-id    ; string -- ID of the source that produced this item
  source-type  ; symbol -- rss, twitter, substack
  title        ; string -- Item title (may be nil for tweets)
  author       ; string -- Author name
  url          ; string -- Original URL
  content      ; string -- Full original content (HTML or plain text)
  summary      ; string -- AI-generated summary (populated after curation)
  score        ; float  -- AI relevance score 0.0-1.0
  timestamp    ; integer -- Unix timestamp of original publication
  fetched-at   ; integer -- Unix timestamp when fetched
  read-p       ; boolean -- Whether the user has read this item
  starred-p    ; boolean -- Whether the user has starred this item
  curated-p    ; boolean -- Whether the AI has evaluated this item
  metadata)    ; alist  -- Additional source-specific metadata

;;;; Base EIEIO class

(defclass infovore-source ()
  ((id
    :initarg :id
    :accessor infovore-source-id
    :documentation "Unique identifier string for this source instance.")
   (name
    :initarg :name
    :accessor infovore-source-name
    :documentation "Human-readable name for this source.")
   (enabled
    :initarg :enabled
    :initform t
    :accessor infovore-source-enabled-p
    :documentation "Whether this source is active for fetching."))
  :abstract t
  :documentation "Abstract base class for all infovore content sources.
Subclasses must implement `infovore-source-fetch' and `infovore-source-parse'.")

;;;; Generic methods

(cl-defgeneric infovore-source-fetch (source callback)
  "Asynchronously fetch new items from SOURCE.
Call CALLBACK with a list of `infovore-item' structs when done.
On failure, CALLBACK may be called with nil.")

(cl-defgeneric infovore-source-parse (source raw-data)
  "Parse RAW-DATA into a list of `infovore-item' structs for SOURCE.")

;;;; URL normalization

(defun infovore-normalize-url (url)
  "Normalize URL for deduplication.
Strip trailing slashes, remove utm_* query parameters, and lowercase
the scheme and host."
  (when (and url (stringp url) (not (string-empty-p url)))
    (let* ((parsed (url-generic-parse-url url))
           (scheme (and (url-type parsed)
                        (downcase (url-type parsed))))
           (host (and (url-host parsed)
                      (downcase (url-host parsed))))
           (path (or (url-filename parsed) "/"))
           ;; url-filename includes both path and query; split them.
           (path-and-query (if (string-match "\\?" path)
                               (cons (substring path 0 (match-beginning 0))
                                     (substring path (match-end 0)))
                             (cons path nil)))
           (clean-path (replace-regexp-in-string "/+\\'" "" (car path-and-query)))
           (query-string (cdr path-and-query))
           (filtered-query (infovore--filter-query-params query-string))
           (fragment (url-target parsed)))
      (concat scheme "://" host
              (if (string-empty-p clean-path) "" clean-path)
              (if (and filtered-query (not (string-empty-p filtered-query)))
                  (concat "?" filtered-query)
                "")
              (if (and fragment (not (string-empty-p fragment)))
                  (concat "#" fragment)
                "")))))

(defun infovore--filter-query-params (query-string)
  "Remove utm_* tracking parameters from QUERY-STRING.
Return the filtered query string, or nil if no params remain."
  (when query-string
    (let* ((pairs (split-string query-string "&" t))
           (filtered (cl-remove-if
                      (lambda (pair)
                        (string-match-p "\\`utm_" pair))
                      pairs)))
      (when filtered
        (mapconcat #'identity filtered "&")))))

;;;; Logging

(defvar infovore-log-buffer-name "*infovore-log*"
  "Name of the infovore log buffer.")

(defun infovore-log (level format-string &rest args)
  "Log a message to the `*infovore-log*' buffer.
LEVEL is one of `info', `warn', or `error'.
FORMAT-STRING and ARGS are passed to `format'."
  (let ((buf (get-buffer-create infovore-log-buffer-name))
        (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
        (level-str (upcase (symbol-name level)))
        (msg (apply #'format format-string args)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert (format "[%s] [%s] %s\n" timestamp level-str msg)))))

;;;; Fetch with retry

(defun infovore-fetch-with-retry (url callback &optional retries)
  "Fetch URL asynchronously with exponential backoff retry.
On success, call CALLBACK with the response buffer.
On final failure (after RETRIES attempts), call CALLBACK with nil.
RETRIES defaults to `infovore-max-retries'."
  (let ((retries (or retries infovore-max-retries))
        (attempt 0))
    (infovore--fetch-attempt url callback attempt retries)))

(defun infovore--fetch-attempt (url callback attempt max-retries)
  "Internal: attempt to fetch URL.
CALLBACK is called with the response buffer on success, or nil on
final failure.  ATTEMPT is the current attempt number (0-based).
MAX-RETRIES is the maximum number of retries."
  (infovore-log 'info "Fetching %s (attempt %d/%d)" url (1+ attempt) (1+ max-retries))
  (condition-case err
      (url-retrieve
       url
       (lambda (status)
         (if (or (plist-get status :error)
                 (not (buffer-live-p (current-buffer))))
             (progn
               (infovore-log 'warn "Fetch failed for %s: %S" url (plist-get status :error))
               (if (< attempt max-retries)
                   (let ((delay (* infovore-retry-base-delay
                                   (expt 4 attempt))))
                     (infovore-log 'info "Retrying %s in %d seconds" url delay)
                     (run-at-time delay nil
                                  #'infovore--fetch-attempt
                                  url callback (1+ attempt) max-retries))
                 (infovore-log 'error "All retries exhausted for %s" url)
                 (funcall callback nil)))
           ;; Success: pass the current response buffer to the callback.
           (funcall callback (current-buffer))))
       nil t)                           ; SILENT = t to suppress messages
    (error
     (infovore-log 'error "Exception fetching %s: %S" url err)
     (if (< attempt max-retries)
         (let ((delay (* infovore-retry-base-delay
                         (expt 4 attempt))))
           (infovore-log 'info "Retrying %s in %d seconds (after exception)" url delay)
           (run-at-time delay nil
                        #'infovore--fetch-attempt
                        url callback (1+ attempt) max-retries))
       (infovore-log 'error "All retries exhausted for %s (after exception)" url)
       (funcall callback nil)))))

(provide 'infovore-source)
;;; infovore-source.el ends here
