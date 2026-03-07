;;; infovore-source-substack.el --- Substack source plugin for infovore -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1") (elfeed "3.4.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Substack source plugin for infovore.  Fetches the RSS feed from a
;; Substack publication, then retrieves the full article HTML for each
;; entry by following the item link and extracting the article body
;; via `libxml-parse-html-region'.

;;; Code:

(require 'cl-lib)
(require 'infovore-source)
(require 'elfeed-xml)
(require 'dom)

;;;; EIEIO class

(defclass infovore-source-substack (infovore-source)
  ((publication
    :initarg :publication
    :accessor infovore-source-substack-publication
    :documentation "Substack publication name (e.g. \"astralcodexten\").
The feed URL is derived as https://<publication>.substack.com/feed."))
  :documentation "A Substack newsletter source for infovore.")

;;;; Fetch implementation

(cl-defmethod infovore-source-fetch ((source infovore-source-substack) callback)
  "Fetch the Substack RSS feed for SOURCE, then fetch full articles.
Call CALLBACK with a list of `infovore-item' structs."
  (let* ((publication (infovore-source-substack-publication source))
         (feed-url (format "https://%s.substack.com/feed" publication))
         (src source))
    (infovore-fetch-with-retry
     feed-url
     (lambda (buffer)
       (if (null buffer)
           (progn
             (infovore-log 'error "Substack feed fetch failed for %s" publication)
             (funcall callback nil))
         (condition-case err
             (let* ((xml (infovore-source-substack--extract-xml buffer))
                    (items (infovore-source-parse src xml)))
               (when (buffer-live-p buffer)
                 (kill-buffer buffer))
               (infovore-log 'info "Substack parsed %d items from %s"
                             (length items) publication)
               ;; Fetch full article content for each item asynchronously.
               (if items
                   (infovore-source-substack--fetch-full-articles items callback)
                 (funcall callback nil)))
           (error
            (infovore-log 'error "Substack parse error for %s: %S" publication err)
            (when (buffer-live-p buffer)
              (kill-buffer buffer))
            (funcall callback nil))))))))

(defun infovore-source-substack--extract-xml (buffer)
  "Extract and parse the XML body from an HTTP response BUFFER.
Return the elfeed XML parse tree."
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "\r?\n\r?\n" nil t)
      (elfeed-xml-parse-region (point) (point-max)))))

;;;; Parse implementation

(cl-defmethod infovore-source-parse ((source infovore-source-substack) raw-data)
  "Parse elfeed XML tree RAW-DATA into `infovore-item' structs.
Handles both RSS 2.0 and Atom formats (Substack typically uses RSS 2.0)."
  (let ((source-id (infovore-source-id source))
        (publication (infovore-source-substack-publication source))
        (items '()))
    (dolist (top-element raw-data)
      (when (listp top-element)
        (let ((tag (car top-element)))
          (cond
           ;; RSS 2.0
           ((eq tag 'rss)
            (let ((channel (infovore-source-substack--find-child 'channel top-element)))
              (when channel
                (dolist (child (cddr channel))
                  (when (and (listp child) (eq (car child) 'item))
                    (push (infovore-source-substack--parse-rss-item
                           child source-id publication)
                          items))))))
           ;; Atom
           ((eq tag 'feed)
            (dolist (child (cddr top-element))
              (when (and (listp child) (eq (car child) 'entry))
                (push (infovore-source-substack--parse-atom-entry
                       child source-id publication)
                      items))))))))
    (nreverse items)))

;;;; RSS 2.0 item parsing

(defun infovore-source-substack--parse-rss-item (item-element source-id publication)
  "Parse an RSS 2.0 ITEM-ELEMENT into an `infovore-item'.
SOURCE-ID and PUBLICATION identify the source."
  (let* ((title (infovore-source-substack--child-text 'title item-element))
         (link (infovore-source-substack--child-text 'link item-element))
         (author (or (infovore-source-substack--child-text 'author item-element)
                     (infovore-source-substack--child-text 'dc:creator item-element)
                     publication))
         (content (or (infovore-source-substack--child-text 'content:encoded item-element)
                      (infovore-source-substack--child-text 'description item-element)))
         (pub-date (or (infovore-source-substack--child-text 'pubDate item-element)
                       (infovore-source-substack--child-text 'dc:date item-element)))
         (guid (infovore-source-substack--child-text 'guid item-element))
         (item-url (or link guid))
         (normalized-url (and item-url (infovore-normalize-url item-url)))
         (timestamp (and pub-date
                         (condition-case nil
                             (floor (float-time (date-to-time pub-date)))
                           (error nil)))))
    (make-infovore-item
     :id (or normalized-url (md5 (or title content "")))
     :source-id source-id
     :source-type 'substack
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
     :metadata `((publication . ,publication)))))

;;;; Atom entry parsing

(defun infovore-source-substack--parse-atom-entry (entry-element source-id publication)
  "Parse an Atom ENTRY-ELEMENT into an `infovore-item'.
SOURCE-ID and PUBLICATION identify the source."
  (let* ((title (infovore-source-substack--child-text 'title entry-element))
         (link (infovore-source-substack--atom-link entry-element))
         (author (or (infovore-source-substack--atom-author entry-element)
                     publication))
         (content (or (infovore-source-substack--child-text 'content entry-element)
                      (infovore-source-substack--child-text 'summary entry-element)))
         (updated (or (infovore-source-substack--child-text 'updated entry-element)
                      (infovore-source-substack--child-text 'published entry-element)))
         (entry-id (infovore-source-substack--child-text 'id entry-element))
         (item-url (or link entry-id))
         (normalized-url (and item-url (infovore-normalize-url item-url)))
         (timestamp (and updated
                         (condition-case nil
                             (floor (float-time (date-to-time updated)))
                           (error nil)))))
    (make-infovore-item
     :id (or normalized-url (md5 (or title content "")))
     :source-id source-id
     :source-type 'substack
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
     :metadata `((publication . ,publication)))))

;;;; Full article fetching

(defun infovore-source-substack--fetch-full-articles (items callback)
  "Fetch full article HTML for each item in ITEMS.
When all fetches complete, call CALLBACK with the updated ITEMS list.
Each item's `:content' slot is replaced with the extracted article body."
  (let ((remaining (length items))
        (results (make-vector (length items) nil)))
    ;; Copy items into results vector, preserving order.
    (cl-loop for item in items
             for i from 0
             do (aset results i item))
    ;; Fetch each article asynchronously.
    (cl-loop
     for item in items
     for idx from 0
     do (let ((article-url (infovore-item-url item))
              (index idx))
          (if (null article-url)
              (progn
                (setq remaining (1- remaining))
                (when (zerop remaining)
                  (funcall callback (append results nil))))
            (infovore-fetch-with-retry
             article-url
             (lambda (buffer)
               (when buffer
                 (condition-case err
                     (let ((full-content
                            (infovore-source-substack--extract-article-body buffer)))
                       (when full-content
                         (setf (infovore-item-content (aref results index))
                               full-content)))
                   (error
                    (infovore-log 'warn "Could not extract article body from %s: %S"
                                  article-url err)))
                 (when (buffer-live-p buffer)
                   (kill-buffer buffer)))
               (setq remaining (1- remaining))
               (when (zerop remaining)
                 (funcall callback (append results nil))))))))))

(defun infovore-source-substack--extract-article-body (buffer)
  "Extract the article body text from an HTML response BUFFER.
Uses `libxml-parse-html-region' and looks for common Substack
article selectors: div.body, div.post-content, article, or
div.available-content."
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "\r?\n\r?\n" nil t)
      (let* ((dom (libxml-parse-html-region (point) (point-max)))
             (article-node
              (or
               ;; Substack uses div.body.markup for the article content.
               (infovore-source-substack--dom-by-class dom "body markup")
               ;; Alternative: div.post-content
               (infovore-source-substack--dom-by-class dom "post-content")
               ;; Alternative: div.available-content
               (infovore-source-substack--dom-by-class dom "available-content")
               ;; Generic fallback: <article> element
               (dom-by-tag dom 'article)
               ;; Last resort: entire <body>
               (dom-by-tag dom 'body))))
        (when article-node
          (let ((node (if (listp article-node)
                          ;; dom-by-tag and friends may return a list; take the first.
                          (if (and (listp (car article-node))
                                   (symbolp (caar article-node)))
                              article-node
                            (car article-node))
                        article-node)))
            ;; Return the HTML string of the article node.
            (with-temp-buffer
              (dom-print node)
              (buffer-string))))))))

(defun infovore-source-substack--dom-by-class (dom class-pattern)
  "Find the first element in DOM whose class attribute matches CLASS-PATTERN.
CLASS-PATTERN is matched as a substring of the class attribute value."
  (let ((result nil))
    (infovore-source-substack--dom-walk
     dom
     (lambda (node)
       (when (and (not result)
                  (listp node)
                  (symbolp (car node)))
         (let ((class-attr (dom-attr node 'class)))
           (when (and class-attr
                      (string-match-p (regexp-quote class-pattern) class-attr))
             (setq result node))))))
    result))

(defun infovore-source-substack--dom-walk (dom fn)
  "Walk the DOM tree, calling FN on each node."
  (when (listp dom)
    (funcall fn dom)
    (dolist (child (dom-children dom))
      (when (listp child)
        (infovore-source-substack--dom-walk child fn)))))

;;;; XML helper functions

(defun infovore-source-substack--find-child (tag element)
  "Find the first child with TAG in ELEMENT's children."
  (cl-find-if (lambda (child)
                (and (listp child) (eq (car child) tag)))
              (cddr element)))

(defun infovore-source-substack--child-text (tag element)
  "Extract the text content of the first child with TAG in ELEMENT."
  (let ((child (infovore-source-substack--find-child tag element)))
    (when child
      (let ((text-parts (cl-remove-if-not #'stringp (cddr child))))
        (when text-parts
          (mapconcat #'identity text-parts ""))))))

(defun infovore-source-substack--atom-link (entry-element)
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
             (infovore-source-substack--find-child 'link entry-element))))
    (when link-element
      (cdr (assq 'href (cadr link-element))))))

(defun infovore-source-substack--atom-author (entry-element)
  "Extract the author name from an Atom ENTRY-ELEMENT."
  (let ((author-element (infovore-source-substack--find-child 'author entry-element)))
    (when author-element
      (infovore-source-substack--child-text 'name author-element))))

(provide 'infovore-source-substack)
;;; infovore-source-substack.el ends here
