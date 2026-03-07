;;; infovore-source-twitter.el --- Twitter source plugin for infovore -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1") (elfeed "3.4.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Twitter source plugin for infovore.  Supports three pluggable backends
;; for fetching tweets: RSS-Bridge (recommended), the official Twitter
;; API v2, or an external scraper command.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'infovore-source)

;; elfeed-xml is only needed for the rss-bridge backend; require it softly
;; so the file loads even when elfeed is not installed, as long as the user
;; picks a different backend.
(require 'elfeed-xml nil t)

;;;; Custom variables

(defcustom infovore-twitter-backend 'rss-bridge
  "Method for fetching Twitter content.
One of `rss-bridge', `api', or `scraper'."
  :type '(choice (const :tag "RSS-Bridge" rss-bridge)
                 (const :tag "Official API v2" api)
                 (const :tag "External scraper" scraper))
  :group 'infovore)

(defcustom infovore-twitter-rss-bridge-url nil
  "URL of the RSS-Bridge instance for Twitter fetching.
Required when `infovore-twitter-backend' is `rss-bridge'.
Example: \"https://rss-bridge.example.com\""
  :type '(choice (const nil) string)
  :group 'infovore)

(defcustom infovore-twitter-api-bearer-token nil
  "Bearer token for the official Twitter API v2.
Required when `infovore-twitter-backend' is `api'."
  :type '(choice (const nil) string)
  :group 'infovore)

(defcustom infovore-twitter-scraper-command nil
  "External command for scraping tweets.
Required when `infovore-twitter-backend' is `scraper'.
The command is called with the username as the sole argument and
must write JSON to stdout.  The JSON should be an array of objects
with at least `id', `text', `created_at', and `url' keys."
  :type '(choice (const nil) string)
  :group 'infovore)

;;;; EIEIO class

(defclass infovore-source-twitter (infovore-source)
  ((username
    :initarg :username
    :accessor infovore-source-twitter-username
    :documentation "Twitter username (without the @ prefix)."))
  :documentation "A Twitter account source for infovore.")

;;;; Fetch implementation (dispatcher)

(cl-defmethod infovore-source-fetch ((source infovore-source-twitter) callback)
  "Fetch tweets for SOURCE asynchronously via the configured backend.
Call CALLBACK with a list of `infovore-item' structs."
  (let ((backend infovore-twitter-backend))
    (pcase backend
      ('rss-bridge (infovore-source-twitter--fetch-rss-bridge source callback))
      ('api        (infovore-source-twitter--fetch-api source callback))
      ('scraper    (infovore-source-twitter--fetch-scraper source callback))
      (_
       (infovore-log 'error "Unknown Twitter backend: %S" backend)
       (funcall callback nil)))))

;;;; Backend 1: RSS-Bridge

(defun infovore-source-twitter--fetch-rss-bridge (source callback)
  "Fetch tweets for SOURCE via RSS-Bridge, then call CALLBACK with items."
  (unless infovore-twitter-rss-bridge-url
    (infovore-log 'error "infovore-twitter-rss-bridge-url is not configured")
    (funcall callback nil)
    (cl-return-from infovore-source-twitter--fetch-rss-bridge))
  (unless (featurep 'elfeed-xml)
    (infovore-log 'error "elfeed-xml is required for the rss-bridge backend")
    (funcall callback nil)
    (cl-return-from infovore-source-twitter--fetch-rss-bridge))
  (let* ((username (infovore-source-twitter-username source))
         (bridge-url (format "%s/?action=display&bridge=TwitterBridge&context=By+username&u=%s&format=Atom"
                             (string-trim-right infovore-twitter-rss-bridge-url "/")
                             (url-hexify-string username)))
         (src source))
    (infovore-fetch-with-retry
     bridge-url
     (lambda (buffer)
       (if (null buffer)
           (progn
             (infovore-log 'error "RSS-Bridge fetch failed for @%s" username)
             (funcall callback nil))
         (condition-case err
             (let* ((xml (with-current-buffer buffer
                           (goto-char (point-min))
                           (when (re-search-forward "\r?\n\r?\n" nil t)
                             (elfeed-xml-parse-region (point) (point-max)))))
                    (items (infovore-source-twitter--parse-atom xml src)))
               (infovore-log 'info "Twitter (RSS-Bridge) parsed %d items for @%s"
                             (length items) username)
               (funcall callback items))
           (error
            (infovore-log 'error "Twitter RSS-Bridge parse error for @%s: %S" username err)
            (funcall callback nil))
           (:success nil))
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))))))

(defun infovore-source-twitter--parse-atom (xml source)
  "Parse Atom XML tree from RSS-Bridge into `infovore-item' structs.
SOURCE is the `infovore-source-twitter' instance."
  (let ((source-id (infovore-source-id source))
        (username (infovore-source-twitter-username source))
        (items '()))
    (dolist (top-element xml)
      (when (and (listp top-element) (eq (car top-element) 'feed))
        (dolist (child (cddr top-element))
          (when (and (listp child) (eq (car child) 'entry))
            (let* ((title (infovore-source-twitter--xml-child-text 'title child))
                   (link (infovore-source-twitter--atom-link child))
                   (content (or (infovore-source-twitter--xml-child-text 'content child)
                                (infovore-source-twitter--xml-child-text 'summary child)))
                   (updated (or (infovore-source-twitter--xml-child-text 'updated child)
                                (infovore-source-twitter--xml-child-text 'published child)))
                   (normalized-url (and link (infovore-normalize-url link)))
                   (timestamp (and updated
                                   (condition-case nil
                                       (floor (float-time (date-to-time updated)))
                                     (error nil)))))
              (push (make-infovore-item
                     :id (or normalized-url (md5 (or content title "")))
                     :source-id source-id
                     :source-type 'twitter
                     :title title
                     :author username
                     :url link
                     :content content
                     :summary nil
                     :score nil
                     :timestamp timestamp
                     :fetched-at (floor (float-time))
                     :read-p nil
                     :starred-p nil
                     :curated-p nil
                     :metadata nil)
                    items))))))
    (nreverse items)))

;;;; Backend 2: Official Twitter API v2

(defun infovore-source-twitter--fetch-api (source callback)
  "Fetch tweets for SOURCE via the official Twitter API v2.
Call CALLBACK with items."
  (unless infovore-twitter-api-bearer-token
    (infovore-log 'error "infovore-twitter-api-bearer-token is not configured")
    (funcall callback nil)
    (cl-return-from infovore-source-twitter--fetch-api))
  (let* ((username (infovore-source-twitter-username source))
         (src source))
    ;; Step 1: resolve username to user ID.
    (infovore-source-twitter--api-get
     (format "https://api.twitter.com/2/users/by/username/%s"
             (url-hexify-string username))
     (lambda (user-data)
       (if (null user-data)
           (progn
             (infovore-log 'error "Twitter API: could not resolve user @%s" username)
             (funcall callback nil))
         (let ((user-id (cdr (assq 'id (cdr (assq 'data user-data))))))
           (if (null user-id)
               (progn
                 (infovore-log 'error "Twitter API: no user ID in response for @%s" username)
                 (funcall callback nil))
             ;; Step 2: fetch tweets for the user ID.
             (infovore-source-twitter--api-get
              (format "https://api.twitter.com/2/users/%s/tweets?tweet.fields=created_at,author_id,text&max_results=20"
                      user-id)
              (lambda (tweets-data)
                (if (null tweets-data)
                    (progn
                      (infovore-log 'error "Twitter API: tweet fetch failed for @%s" username)
                      (funcall callback nil))
                  (let ((items (infovore-source-twitter--parse-api-response
                                tweets-data src)))
                    (infovore-log 'info "Twitter API parsed %d items for @%s"
                                  (length items) username)
                    (funcall callback items))))))))))))

(defun infovore-source-twitter--api-get (url callback)
  "Make an authenticated GET request to URL using the Twitter API bearer token.
Call CALLBACK with the parsed JSON response, or nil on failure."
  (let ((url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer " infovore-twitter-api-bearer-token)))))
    (url-retrieve
     url
     (lambda (status)
       (if (plist-get status :error)
           (progn
             (infovore-log 'warn "Twitter API request failed for %s: %S"
                           url (plist-get status :error))
             (funcall callback nil))
         (condition-case err
             (progn
               (goto-char (point-min))
               (when (re-search-forward "\r?\n\r?\n" nil t)
                 (let ((json-data (json-read)))
                   (funcall callback json-data))))
           (error
            (infovore-log 'error "Twitter API JSON parse error: %S" err)
            (funcall callback nil)))))
     nil t)))

(defun infovore-source-twitter--parse-api-response (json-data source)
  "Parse Twitter API v2 JSON-DATA into `infovore-item' structs.
SOURCE is the `infovore-source-twitter' instance."
  (let ((source-id (infovore-source-id source))
        (username (infovore-source-twitter-username source))
        (data-array (cdr (assq 'data json-data)))
        (items '()))
    (when (arrayp data-array)
      (cl-loop for tweet across data-array
               do (let* ((tweet-id (cdr (assq 'id tweet)))
                         (text (cdr (assq 'text tweet)))
                         (created-at (cdr (assq 'created_at tweet)))
                         (tweet-url (format "https://twitter.com/%s/status/%s"
                                            username tweet-id))
                         (normalized-url (infovore-normalize-url tweet-url))
                         (timestamp (and created-at
                                         (condition-case nil
                                             (floor (float-time (date-to-time created-at)))
                                           (error nil)))))
                    (push (make-infovore-item
                           :id normalized-url
                           :source-id source-id
                           :source-type 'twitter
                           :title nil
                           :author username
                           :url tweet-url
                           :content text
                           :summary nil
                           :score nil
                           :timestamp timestamp
                           :fetched-at (floor (float-time))
                           :read-p nil
                           :starred-p nil
                           :curated-p nil
                           :metadata `((tweet-id . ,tweet-id)))
                          items))))
    (nreverse items)))

;;;; Backend 3: External scraper

(defun infovore-source-twitter--fetch-scraper (source callback)
  "Fetch tweets for SOURCE via an external scraper command.
Call CALLBACK with items."
  (unless infovore-twitter-scraper-command
    (infovore-log 'error "infovore-twitter-scraper-command is not configured")
    (funcall callback nil)
    (cl-return-from infovore-source-twitter--fetch-scraper))
  (let* ((username (infovore-source-twitter-username source))
         (command infovore-twitter-scraper-command)
         (src source)
         (output-buffer (generate-new-buffer " *infovore-scraper*")))
    (infovore-log 'info "Running scraper for @%s: %s %s" username command username)
    (set-process-sentinel
     (start-process "infovore-scraper" output-buffer command username)
     (lambda (process _event)
       (if (not (eq (process-exit-status process) 0))
           (progn
             (infovore-log 'error "Scraper exited with status %d for @%s"
                           (process-exit-status process) username)
             (when (buffer-live-p output-buffer)
               (kill-buffer output-buffer))
             (funcall callback nil))
         (condition-case err
             (let* ((json-data
                     (with-current-buffer output-buffer
                       (goto-char (point-min))
                       (json-read)))
                    (items (infovore-source-twitter--parse-scraper-output
                            json-data src)))
               (infovore-log 'info "Scraper parsed %d items for @%s"
                             (length items) username)
               (when (buffer-live-p output-buffer)
                 (kill-buffer output-buffer))
               (funcall callback items))
           (error
            (infovore-log 'error "Scraper JSON parse error for @%s: %S" username err)
            (when (buffer-live-p output-buffer)
              (kill-buffer output-buffer))
            (funcall callback nil))))))))

(defun infovore-source-twitter--parse-scraper-output (json-data source)
  "Parse scraper JSON-DATA into `infovore-item' structs.
JSON-DATA should be a JSON array of tweet objects.
SOURCE is the `infovore-source-twitter' instance."
  (let ((source-id (infovore-source-id source))
        (username (infovore-source-twitter-username source))
        (items '()))
    (when (arrayp json-data)
      (cl-loop for tweet across json-data
               do (let* ((tweet-id (cdr (assq 'id tweet)))
                         (text (cdr (assq 'text tweet)))
                         (created-at (cdr (assq 'created_at tweet)))
                         (tweet-url (or (cdr (assq 'url tweet))
                                        (and tweet-id
                                             (format "https://twitter.com/%s/status/%s"
                                                     username tweet-id))))
                         (normalized-url (and tweet-url
                                              (infovore-normalize-url tweet-url)))
                         (timestamp (and created-at
                                         (condition-case nil
                                             (floor (float-time (date-to-time created-at)))
                                           (error nil)))))
                    (push (make-infovore-item
                           :id (or normalized-url (md5 (or text "")))
                           :source-id source-id
                           :source-type 'twitter
                           :title nil
                           :author username
                           :url tweet-url
                           :content text
                           :summary nil
                           :score nil
                           :timestamp timestamp
                           :fetched-at (floor (float-time))
                           :read-p nil
                           :starred-p nil
                           :curated-p nil
                           :metadata `((tweet-id . ,tweet-id)))
                          items))))
    (nreverse items)))

;;;; Parse generic method implementation

(cl-defmethod infovore-source-parse ((source infovore-source-twitter) raw-data)
  "Parse RAW-DATA into `infovore-item' structs for SOURCE.
RAW-DATA interpretation depends on the active backend.
For the `api' and `scraper' backends, RAW-DATA is a JSON-parsed
alist/vector.  For `rss-bridge', it is an elfeed XML parse tree."
  (pcase infovore-twitter-backend
    ('rss-bridge (infovore-source-twitter--parse-atom raw-data source))
    ('api        (infovore-source-twitter--parse-api-response raw-data source))
    ('scraper    (infovore-source-twitter--parse-scraper-output raw-data source))
    (_
     (infovore-log 'error "Unknown Twitter backend in parse: %S" infovore-twitter-backend)
     nil)))

;;;; XML helper functions (for RSS-Bridge Atom parsing)

(defun infovore-source-twitter--xml-find-child (tag element)
  "Find the first child with TAG in ELEMENT's children."
  (cl-find-if (lambda (child)
                (and (listp child) (eq (car child) tag)))
              (cddr element)))

(defun infovore-source-twitter--xml-child-text (tag element)
  "Extract the text content of the first child with TAG in ELEMENT."
  (let ((child (infovore-source-twitter--xml-find-child tag element)))
    (when child
      (let ((text-parts (cl-remove-if-not #'stringp (cddr child))))
        (when text-parts
          (mapconcat #'identity text-parts ""))))))

(defun infovore-source-twitter--atom-link (entry-element)
  "Extract the href from the first alternate link in ENTRY-ELEMENT."
  (let ((link-element
         (or (cl-find-if
              (lambda (child)
                (and (listp child)
                     (eq (car child) 'link)
                     (let ((attrs (cadr child)))
                       (or (equal (cdr (assq 'rel attrs)) "alternate")
                           (null (assq 'rel attrs))))))
              (cddr entry-element))
             (infovore-source-twitter--xml-find-child 'link entry-element))))
    (when link-element
      (cdr (assq 'href (cadr link-element))))))

(provide 'infovore-source-twitter)
;;; infovore-source-twitter.el ends here
