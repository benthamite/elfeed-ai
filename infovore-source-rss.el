;;; infovore-source-rss.el --- RSS/Atom source plugin for infovore -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; RSS/Atom source plugin for infovore.  Fetches and parses RSS 2.0 and
;; Atom feeds using Emacs's built-in XML parser.  Each feed URL is
;; represented as an `infovore-source-rss' instance.

;;; Code:

(require 'cl-lib)
(require 'infovore-source)
(require 'xml)

;;;; EIEIO class

(defclass infovore-source-rss (infovore-source)
  ((url
    :initarg :url
    :accessor infovore-source-rss-url
    :documentation "URL of the RSS or Atom feed."))
  :documentation "An RSS or Atom feed source for infovore.")

;;;; Fetch implementation

(cl-defmethod infovore-source-fetch ((source infovore-source-rss) callback)
  "Fetch the RSS/Atom feed for SOURCE asynchronously.
Call CALLBACK with a list of `infovore-item' structs."
  (let ((url (infovore-source-rss-url source))
        (src source))
    (infovore-fetch-with-retry
     url
     (lambda (buffer)
       (if (null buffer)
           (progn
             (infovore-log 'error "RSS fetch failed for %s" url)
             (funcall callback nil))
         (condition-case err
             (let* ((raw-data (infovore-source-rss--extract-xml buffer))
                    (items (infovore-source-parse src raw-data)))
               (infovore-log 'info "RSS parsed %d items from %s"
                             (length items) url)
               (funcall callback items))
           (error
            (infovore-log 'error "RSS parse error for %s: %S" url err)
            (funcall callback nil))
           (:success nil))
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))))))

(defun infovore-source-rss--extract-xml (buffer)
  "Extract and parse the XML body from an HTTP response BUFFER.
Return the XML parse tree."
  (with-current-buffer buffer
    (goto-char (point-min))
    ;; Skip past the HTTP headers to the body.
    (when (re-search-forward "\r?\n\r?\n" nil t)
      (xml-parse-region (point) (point-max)))))

;;;; Parse implementation

(cl-defmethod infovore-source-parse ((source infovore-source-rss) raw-data)
  "Parse XML tree RAW-DATA into `infovore-item' structs.
Handles both RSS 2.0 and Atom feed formats."
  (let ((source-id (infovore-source-id source))
        (items '()))
    (dolist (top-element raw-data)
      (when (listp top-element)
        (let ((tag (car top-element)))
          (cond
           ;; RSS 2.0: top element is `rss', channel items inside.
           ((eq tag 'rss)
            (let ((channel (infovore-source-rss--find-child 'channel top-element)))
              (when channel
                (dolist (child (cddr channel))
                  (when (and (listp child) (eq (car child) 'item))
                    (push (infovore-source-rss--parse-rss-item child source-id)
                          items))))))
           ;; Atom: top element is `feed', entries inside.
           ((eq tag 'feed)
            (dolist (child (cddr top-element))
              (when (and (listp child) (eq (car child) 'entry))
                (push (infovore-source-rss--parse-atom-entry child source-id)
                      items))))))))
    (nreverse items)))

;;;; RSS 2.0 item parsing

(defun infovore-source-rss--parse-rss-item (item-element source-id)
  "Parse an RSS 2.0 ITEM-ELEMENT into an `infovore-item'.
SOURCE-ID is the source's identifier."
  (let* ((title (infovore-source-rss--child-text 'title item-element))
         (link (infovore-source-rss--child-text 'link item-element))
         (author (or (infovore-source-rss--child-text 'author item-element)
                     (infovore-source-rss--child-text 'dc:creator item-element)))
         (content (or (infovore-source-rss--child-text 'content:encoded item-element)
                      (infovore-source-rss--child-text 'description item-element)))
         (pub-date (or (infovore-source-rss--child-text 'pubDate item-element)
                       (infovore-source-rss--child-text 'dc:date item-element)))
         (guid (infovore-source-rss--child-text 'guid item-element))
         (item-url (or link guid))
         (normalized-url (and item-url (infovore-normalize-url item-url)))
         (timestamp (and pub-date (infovore-source-rss--parse-date pub-date))))
    (make-infovore-item
     :id (or normalized-url (md5 (or title content "")))
     :source-id source-id
     :source-type 'rss
     :title title
     :author author
     :url item-url
     :content content
     :summary nil
     :score nil
     :timestamp timestamp
     :fetched-at (floor (float-time))
     :read-p nil
     :starred-p nil
     :curated-p nil
     :metadata nil)))

;;;; Atom entry parsing

(defun infovore-source-rss--parse-atom-entry (entry-element source-id)
  "Parse an Atom ENTRY-ELEMENT into an `infovore-item'.
SOURCE-ID is the source's identifier."
  (let* ((title (infovore-source-rss--child-text 'title entry-element))
         (link (infovore-source-rss--atom-link entry-element))
         (author (infovore-source-rss--atom-author entry-element))
         (content (or (infovore-source-rss--child-text 'content entry-element)
                      (infovore-source-rss--child-text 'summary entry-element)))
         (updated (or (infovore-source-rss--child-text 'updated entry-element)
                      (infovore-source-rss--child-text 'published entry-element)))
         (entry-id (infovore-source-rss--child-text 'id entry-element))
         (item-url (or link entry-id))
         (normalized-url (and item-url (infovore-normalize-url item-url)))
         (timestamp (and updated (infovore-source-rss--parse-date updated))))
    (make-infovore-item
     :id (or normalized-url (md5 (or title content "")))
     :source-id source-id
     :source-type 'rss
     :title title
     :author author
     :url item-url
     :content content
     :summary nil
     :score nil
     :timestamp timestamp
     :fetched-at (floor (float-time))
     :read-p nil
     :starred-p nil
     :curated-p nil
     :metadata nil)))

;;;; XML helper functions

(defun infovore-source-rss--find-child (tag element)
  "Find the first child with TAG in ELEMENT's children."
  (cl-find-if (lambda (child)
                (and (listp child) (eq (car child) tag)))
              (cddr element)))

(defun infovore-source-rss--child-text (tag element)
  "Extract the text content of the first child with TAG in ELEMENT.
Return nil if the child is not found or has no text."
  (let ((child (infovore-source-rss--find-child tag element)))
    (when child
      (let ((text-parts (cl-remove-if-not #'stringp (cddr child))))
        (when text-parts
          (mapconcat #'identity text-parts ""))))))

(defun infovore-source-rss--atom-link (entry-element)
  "Extract the href from the first `alternate' (or default) link in ENTRY-ELEMENT."
  (let ((link-element
         (or
          ;; Look for rel="alternate" first.
          (cl-find-if
           (lambda (child)
             (and (listp child)
                  (eq (car child) 'link)
                  (let ((attrs (cadr child)))
                    (or (equal (cdr (assq 'rel attrs)) "alternate")
                        ;; A link with no rel attribute is treated as alternate.
                        (null (assq 'rel attrs))))))
           (cddr entry-element))
          ;; Fallback: any link element.
          (infovore-source-rss--find-child 'link entry-element))))
    (when link-element
      (cdr (assq 'href (cadr link-element))))))

(defun infovore-source-rss--atom-author (entry-element)
  "Extract the author name from an Atom ENTRY-ELEMENT."
  (let ((author-element (infovore-source-rss--find-child 'author entry-element)))
    (when author-element
      (infovore-source-rss--child-text 'name author-element))))

;;;; Date parsing

(defun infovore-source-rss--parse-date (date-string)
  "Parse DATE-STRING into a Unix timestamp.
Handles RFC 822 (RSS) and ISO 8601 (Atom) date formats."
  (condition-case nil
      (floor (float-time (date-to-time date-string)))
    (error
     (infovore-log 'warn "Could not parse date: %s" date-string)
     nil)))

(provide 'infovore-source-rss)
;;; infovore-source-rss.el ends here
