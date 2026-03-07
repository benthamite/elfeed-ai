;;; infovore-ai.el --- AI curation layer for infovore -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, convenience
;; Package-Requires: ((emacs "29.1") (gptel "0.9"))

;; This file is part of infovore.

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

;; AI curation layer for infovore.  This module handles scoring items for
;; relevance using gptel and managing the daily token budget.  All AI
;; operations are fully asynchronous.

;;; Code:

(require 'gptel)
(require 'json)
(require 'infovore-source)
(require 'infovore-db)

;;;; Customizations

(defcustom infovore-interest-profile ""
  "Natural language description of user's interests.
Used in the AI prompt to determine content relevance.
Example: \"AI safety, Emacs, functional programming, philosophy of mind\""
  :type 'string
  :group 'infovore)

(defcustom infovore-relevance-threshold 0.5
  "Minimum AI score (0.0-1.0) for an item to appear in the curated feed."
  :type 'float
  :group 'infovore)

(defcustom infovore-daily-token-budget 100000
  "Maximum estimated tokens to use per day for AI curation."
  :type 'integer
  :group 'infovore)

(defcustom infovore-budget-reset-hour 0
  "Hour of day (0-23) when the daily token budget resets."
  :type 'integer
  :group 'infovore)

;;;; Internal state

(defvar infovore-ai--daily-tokens-used 0
  "Current session accumulator for tokens used today.
Synced with the database.")

(defvar infovore-ai--budget-date nil
  "The date string (YYYY-MM-DD) for the current budget period.")

;;;; Budget tracking

(defun infovore-ai--budget-date-string ()
  "Return the current budget date string (YYYY-MM-DD).
If the current hour is before `infovore-budget-reset-hour', return
yesterday's date, since the budget period has not yet reset."
  (let* ((now (decode-time))
         (hour (decoded-time-hour now)))
    (if (< hour infovore-budget-reset-hour)
        ;; Before reset hour: we are still in yesterday's budget period.
        (format-time-string "%Y-%m-%d" (time-subtract (current-time)
                                                       (* 24 60 60)))
      (format-time-string "%Y-%m-%d"))))

(defun infovore-ai--ensure-budget-loaded ()
  "Ensure the budget state is loaded for the current period.
If the budget date has changed (new day), reset the in-memory counter
and load the persisted value from the database."
  (let ((today (infovore-ai--budget-date-string)))
    (unless (equal today infovore-ai--budget-date)
      (setq infovore-ai--budget-date today)
      (setq infovore-ai--daily-tokens-used
            (or (infovore-db-get-budget-tokens today) 0)))))

(defun infovore-ai--budget-remaining ()
  "Return the number of tokens remaining in today's budget."
  (infovore-ai--ensure-budget-loaded)
  (- infovore-daily-token-budget infovore-ai--daily-tokens-used))

(defun infovore-ai--record-usage (tokens)
  "Add TOKENS to today's usage.
Update both the in-memory counter and the database."
  (infovore-ai--ensure-budget-loaded)
  (setq infovore-ai--daily-tokens-used
        (+ infovore-ai--daily-tokens-used tokens))
  (infovore-db-add-budget-tokens infovore-ai--budget-date tokens))

(defun infovore-ai--estimate-tokens (text)
  "Return a rough token estimate for TEXT.
Uses a simple heuristic of one token per four characters."
  (if (and text (stringp text) (> (length text) 0))
      (/ (length text) 4)
    0))

(defun infovore-ai-budget-exhausted-p ()
  "Return non-nil if the daily token budget is exhausted."
  (<= (infovore-ai--budget-remaining) 0))

;;;; Prompt construction

(defun infovore-ai--build-prompt (item)
  "Build the scoring prompt for ITEM.
ITEM is an `infovore-item' struct.  The prompt asks the AI to return a
JSON object with a relevance score and a brief summary."
  (let* ((title (or (infovore-item-title item) "(no title)"))
         (author (or (infovore-item-author item) "(unknown author)"))
         (content (or (infovore-item-content item) ""))
         (truncated-content (if (> (length content) 4000)
                                (substring content 0 4000)
                              content)))
    (format
     "You are a content relevance scorer. Given a user's interest profile and a \
content item, you must evaluate how relevant the item is to the user's interests.

## User's interest profile

%s

## Content item

Title: %s
Author: %s
Content:
%s

## Instructions

Rate the relevance of this content item to the user's interest profile on a \
scale from 0.0 to 1.0, where 0.0 means completely irrelevant and 1.0 means \
extremely relevant and interesting.

Respond with ONLY a JSON object (no markdown fences, no extra text) containing \
exactly two keys:
- \"score\": a float between 0.0 and 1.0 representing relevance
- \"summary\": a 1-3 sentence summary of the content item

Example response:
{\"score\": 0.75, \"summary\": \"The article discusses recent advances in ...\"}"
     infovore-interest-profile
     title
     author
     truncated-content)))

;;;; Scoring

(defun infovore-ai--parse-response (response)
  "Parse the AI RESPONSE string into a (score . summary) cons cell.
Handle possible markdown code fences around the JSON.  Return nil on
parse failure."
  (when (and response (stringp response))
    (let ((cleaned response))
      ;; Strip markdown code fences if present.
      (when (string-match "```\\(?:json\\)?\\s-*\n?" cleaned)
        (setq cleaned (substring cleaned (match-end 0))))
      (when (string-match "\n?\\s-*```" cleaned)
        (setq cleaned (substring cleaned 0 (match-beginning 0))))
      ;; Trim whitespace.
      (setq cleaned (string-trim cleaned))
      (condition-case err
          (let* ((json-object-type 'alist)
                 (json-key-type 'string)
                 (parsed (json-read-from-string cleaned))
                 (score (cdr (assoc "score" parsed)))
                 (summary (cdr (assoc "summary" parsed))))
            (if (and score (numberp score)
                     (<= 0.0 score) (<= score 1.0)
                     summary (stringp summary))
                (cons score summary)
              (infovore-log 'error
                            "AI response has invalid score or summary: %S"
                            parsed)
              nil))
        (error
         (infovore-log 'error "Failed to parse AI response: %s\nResponse: %s"
                       (error-message-string err)
                       (substring response 0 (min (length response) 200)))
         nil)))))

(defun infovore-ai-score-item (item callback)
  "Score ITEM asynchronously using the AI.
ITEM is an `infovore-item' struct.  CALLBACK is called with a cons
cell (score . summary) on success, or nil on failure or budget
exhaustion."
  (cond
   ;; No interest profile configured.
   ((or (null infovore-interest-profile)
        (string-empty-p infovore-interest-profile))
    (infovore-log 'warn "Cannot score items: `infovore-interest-profile' is empty")
    (funcall callback nil))
   ;; Budget exhausted.
   ((infovore-ai-budget-exhausted-p)
    (infovore-log 'info "Daily token budget exhausted, skipping AI scoring")
    (funcall callback nil))
   ;; Item has no meaningful content.
   ((and (or (null (infovore-item-content item))
             (string-empty-p (infovore-item-content item)))
         (or (null (infovore-item-title item))
             (string-empty-p (infovore-item-title item))))
    (infovore-log 'warn "Skipping item with no title or content: %s"
                  (infovore-item-id item))
    (funcall callback nil))
   ;; Normal case: build prompt and send request.
   (t
    (let* ((prompt (infovore-ai--build-prompt item))
           (prompt-tokens (infovore-ai--estimate-tokens prompt)))
      (gptel-request prompt
        :callback (lambda (response info)
                    (if (not response)
                        (progn
                          (infovore-log 'error "AI request failed: %s"
                                        (plist-get info :status))
                          (funcall callback nil))
                      (let* ((result (infovore-ai--parse-response response))
                             (response-tokens (infovore-ai--estimate-tokens
                                               response))
                             (total-tokens (+ prompt-tokens response-tokens)))
                        (infovore-ai--record-usage total-tokens)
                        (funcall callback result)))))))))

(defun infovore-ai-curate-pending (callback)
  "Score all uncurated items sequentially, then call CALLBACK.
CALLBACK is called with the count of items successfully scored.
Stops early if the daily token budget is exhausted."
  (let ((items (infovore-db-uncurated-items))
        (scored-count 0))
    (if (null items)
        (progn
          (infovore-log 'info "No uncurated items to process")
          (funcall callback 0))
      (infovore-log 'info "Curating %d pending items" (length items))
      (let ((process-next nil))
        (setq process-next
              (lambda (remaining)
                (if (or (null remaining)
                        (infovore-ai-budget-exhausted-p))
                    (progn
                      (when (and remaining (infovore-ai-budget-exhausted-p))
                        (infovore-log 'info
                                      "Budget exhausted, %d items remaining"
                                      (length remaining)))
                      (infovore-log 'info "Curation complete: %d items scored"
                                    scored-count)
                      (funcall callback scored-count))
                  (let ((item (car remaining)))
                    (infovore-ai-score-item
                     item
                     (lambda (result)
                       (when result
                         (let ((score (car result))
                               (summary (cdr result)))
                           (setf (infovore-item-score item) score)
                           (setf (infovore-item-summary item) summary)
                           (setf (infovore-item-curated-p item) t)
                           (infovore-db-update-item item)
                           (setq scored-count (1+ scored-count))))
                       (funcall process-next (cdr remaining))))))))
        (funcall process-next items)))))

(provide 'infovore-ai)
;;; infovore-ai.el ends here
