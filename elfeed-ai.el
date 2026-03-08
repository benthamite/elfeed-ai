;;; elfeed-ai.el --- AI-powered content curation for elfeed -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1") (elfeed "3.4.1") (gptel "0.9") (transient "0.7"))
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

;; elfeed-ai adds AI-powered content curation to elfeed.  It uses gptel
;; to score each entry for relevance against a natural-language interest
;; profile, tags entries that meet a configurable threshold, displays
;; scores in the search buffer, and injects AI-generated summaries into
;; the show buffer.
;;
;; Quick start:
;;
;;   (require 'elfeed-ai)
;;
;;   (setq elfeed-ai-interest-profile
;;         "AI safety, Emacs, functional programming, philosophy of mind")
;;
;;   (elfeed-ai-mode 1)
;;
;; New entries are automatically scored when fetched.  Entries scoring
;; above `elfeed-ai-relevance-threshold' are tagged `ai-relevant'.
;; Use "+ai-relevant" in your elfeed search filter to see curated content.

;;; Code:

(require 'cl-lib)
(require 'elfeed)
(require 'elfeed-log)
(require 'elfeed-search)
(require 'elfeed-show)
(require 'gptel)
(require 'json)
(require 'transient)

;;;; Customization group

(defgroup elfeed-ai nil
  "AI-powered content curation for elfeed."
  :group 'elfeed
  :prefix "elfeed-ai-")

;;;; User options

(defcustom elfeed-ai-interest-profile ""
  "Natural language description of your interests, or a file containing one.
If the value is a path to an existing readable file, its contents are
used as the profile text.  Otherwise the value is included verbatim in
every AI scoring prompt.  When empty, scoring is skipped."
  :type '(choice (string :tag "Inline text")
                 (file :tag "File containing profile"))
  :group 'elfeed-ai)

(defcustom elfeed-ai-relevance-threshold 0.5
  "Minimum AI score (0.0-1.0) for tagging an entry as relevant."
  :type 'float
  :group 'elfeed-ai)

(defcustom elfeed-ai-daily-budget '(dollars . 1.00)
  "Daily budget for AI scoring, as a (TYPE . LIMIT) cons cell.
TYPE is `tokens' or `dollars'.

In `tokens' mode, usage is estimated heuristically at one token
per four characters.  In `dollars' mode, actual cost is computed
via `gptel-plus'; if that package is not available, the budget is
not enforced."
  :type '(choice (cons :tag "Token limit" (const :tag "" tokens) integer)
                 (cons :tag "Dollar limit" (const :tag "" dollars) number))
  :group 'elfeed-ai)

(make-obsolete-variable 'elfeed-ai-daily-token-budget
                        'elfeed-ai-daily-budget "0.2.0")

(defcustom elfeed-ai-budget-reset-hour 0
  "Hour of day (0-23) when the daily token budget resets."
  :type 'integer
  :group 'elfeed-ai)

(defcustom elfeed-ai-budget-file
  (expand-file-name "elfeed-ai-budget.eld" user-emacs-directory)
  "File for persisting daily token budget data."
  :type 'file
  :group 'elfeed-ai)

(defcustom elfeed-ai-max-content-length 4000
  "Maximum content length (in characters) sent to the AI.
Longer content is truncated."
  :type 'integer
  :group 'elfeed-ai)

(defcustom elfeed-ai-score-tag 'ai-relevant
  "Tag added to entries scoring above `elfeed-ai-relevance-threshold'."
  :type 'symbol
  :group 'elfeed-ai)

(defcustom elfeed-ai-scored-tag 'ai-scored
  "Tag added to entries after AI scoring, regardless of score."
  :type 'symbol
  :group 'elfeed-ai)

(defcustom elfeed-ai-backend nil
  "The gptel backend name for AI scoring, e.g. \"Gemini\" or \"Claude\".
When nil, the backend is inferred from `elfeed-ai-model', falling
back to `gptel-backend'."
  :type '(choice (const :tag "Infer from model or use gptel default" nil)
                 (string :tag "Backend name"))
  :group 'elfeed-ai)

(defcustom elfeed-ai-model nil
  "The gptel model for AI scoring, e.g. `claude-sonnet-4-5-20250514'.
When nil, defaults to `gptel-model'."
  :type '(choice (const :tag "Use gptel default" nil)
                 (symbol :tag "Model name"))
  :group 'elfeed-ai)

(defcustom elfeed-ai-auto-score t
  "When non-nil, automatically score new entries as they arrive."
  :type 'boolean
  :group 'elfeed-ai)

(defcustom elfeed-ai-score-unscored-days 7
  "Default number of days to look back when scoring unscored entries.
Used by `elfeed-ai-score-unscored'.  With a prefix argument, the
command prompts for a custom number of days."
  :type 'integer
  :group 'elfeed-ai)

(defcustom elfeed-ai-generate-summary t
  "When non-nil, request a summary alongside the score.
The summary is shown in the elfeed show buffer.  Disabling this
reduces token usage per entry."
  :type 'boolean
  :group 'elfeed-ai)

(defcustom elfeed-ai-sort-by-score t
  "When non-nil, sort the search buffer by AI score (highest first).
Unscored entries are sorted after scored ones.  Entries with equal
scores are sorted by date."
  :type 'boolean
  :group 'elfeed-ai)

(defcustom elfeed-ai-score-high-threshold 0.7
  "Minimum score for the high-score face in the search buffer.
Scores at or above this value use `elfeed-ai-score-high-face'."
  :type 'float
  :group 'elfeed-ai)

(defcustom elfeed-ai-score-low-threshold 0.3
  "Maximum score for the low-score face in the search buffer.
Scores at or below this value use `elfeed-ai-score-low-face'."
  :type 'float
  :group 'elfeed-ai)

;;;; Option resolution

(defun elfeed-ai--find-backend-for-model (model)
  "Return the gptel backend that provides MODEL, or nil."
  (cl-loop for (_name . backend) in gptel--known-backends
           when (member model (gptel-backend-models backend))
           return backend))

(defun elfeed-ai--resolve-backend-and-model ()
  "Return (backend . model) for AI scoring.
Resolves `elfeed-ai-backend' and `elfeed-ai-model', inferring the
backend from the model when needed."
  (let* ((model (or elfeed-ai-model gptel-model))
         (backend (cond
                   (elfeed-ai-backend
                    (gptel-get-backend elfeed-ai-backend))
                   (elfeed-ai-model
                    (or (elfeed-ai--find-backend-for-model elfeed-ai-model)
                        gptel-backend))
                   (t gptel-backend))))
    (cons backend model)))

;;;; Profile resolution

(defun elfeed-ai--resolve-profile ()
  "Return the interest profile as a string.
If `elfeed-ai-interest-profile' names a readable file, return its
contents; otherwise return the value itself."
  (let ((val elfeed-ai-interest-profile))
    (if (and (stringp val)
             (not (string-empty-p val))
             (file-readable-p val))
        (string-trim (with-temp-buffer
                       (insert-file-contents val)
                       (buffer-string)))
      val)))

;;;; Faces

(defface elfeed-ai-score-face
  '((t :inherit shadow))
  "Default face for mid-range AI scores in the search buffer."
  :group 'elfeed-ai)

(defface elfeed-ai-score-high-face
  '((t :inherit success :weight bold))
  "Face for high AI scores in the search buffer.
Applied when the score is at or above `elfeed-ai-score-high-threshold'."
  :group 'elfeed-ai)

(defface elfeed-ai-score-low-face
  '((t :inherit shadow))
  "Face for low AI scores in the search buffer.
Applied when the score is at or below `elfeed-ai-score-low-threshold'."
  :group 'elfeed-ai)

(defface elfeed-ai-summary-heading-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the AI summary heading in the show buffer."
  :group 'elfeed-ai)

;;;; Internal state

(defvar elfeed-ai--pending-queue nil
  "Queue of elfeed entries waiting to be scored.")

(defvar elfeed-ai--scoring-in-progress nil
  "Non-nil while the scoring queue is being processed.")

(defvar elfeed-ai--batch-count 0
  "Number of entries scored in the current batch.")

(defvar elfeed-ai--batch-cost 0.0
  "Accumulated cost for the current batch.")

(defvar elfeed-ai--budget-cache nil
  "Cached budget data: alist with `date' and `tokens-used' keys.")

(defvar elfeed-ai--original-print-entry-function nil
  "Original value of `elfeed-search-print-entry-function'.")

(defvar elfeed-ai--original-sort-function nil
  "Original value of `elfeed-search-sort-function'.")

;;;; Budget tracking

(defun elfeed-ai--budget-date-string ()
  "Return the current budget date string (YYYY-MM-DD).
If the current hour is before `elfeed-ai-budget-reset-hour',
return yesterday's date."
  (let ((hour (decoded-time-hour (decode-time))))
    (if (< hour elfeed-ai-budget-reset-hour)
        (format-time-string "%Y-%m-%d"
                            (time-subtract (current-time) (* 24 60 60)))
      (format-time-string "%Y-%m-%d"))))

(defun elfeed-ai--load-budget ()
  "Load budget data from `elfeed-ai-budget-file'."
  (when (file-exists-p elfeed-ai-budget-file)
    (with-temp-buffer
      (insert-file-contents elfeed-ai-budget-file)
      (condition-case nil
          (read (current-buffer))
        (error nil)))))

(defun elfeed-ai--save-budget ()
  "Save current budget cache to `elfeed-ai-budget-file'."
  (when elfeed-ai--budget-cache
    (with-temp-file elfeed-ai-budget-file
      (prin1 elfeed-ai--budget-cache (current-buffer)))))

(defun elfeed-ai--budget-type ()
  "Return the current budget type: `tokens' or `dollars'."
  (car elfeed-ai-daily-budget))

(defun elfeed-ai--budget-limit ()
  "Return the current budget limit amount."
  (cdr elfeed-ai-daily-budget))

(defun elfeed-ai--ensure-budget ()
  "Ensure budget cache is loaded for the current period."
  (let ((today (elfeed-ai--budget-date-string))
        (btype (elfeed-ai--budget-type)))
    (unless (and elfeed-ai--budget-cache
                 (equal today (alist-get 'date elfeed-ai--budget-cache))
                 (eq btype (alist-get 'budget-type elfeed-ai--budget-cache)))
      (let ((saved (elfeed-ai--load-budget)))
        (setq elfeed-ai--budget-cache
              (if (and saved
                       (equal today (alist-get 'date saved))
                       (eq btype (alist-get 'budget-type saved)))
                  saved
                (list (cons 'date today)
                      (cons 'budget-type btype)
                      (cons 'used 0))))))))

(defun elfeed-ai--budget-remaining ()
  "Return the amount remaining in today's budget."
  (elfeed-ai--ensure-budget)
  (- (elfeed-ai--budget-limit)
     (alist-get 'used elfeed-ai--budget-cache 0)))

(defun elfeed-ai--record-usage (amount)
  "Add AMOUNT to today's usage and persist."
  (elfeed-ai--ensure-budget)
  (cl-incf (alist-get 'used elfeed-ai--budget-cache 0) amount)
  (elfeed-ai--save-budget))

(defun elfeed-ai--estimate-tokens (text)
  "Return a rough token estimate for TEXT (one token per four characters)."
  (if (and text (stringp text) (> (length text) 0))
      (/ (length text) 4)
    0))

(defun elfeed-ai-budget-exhausted-p ()
  "Return non-nil if the daily budget is exhausted."
  (<= (elfeed-ai--budget-remaining) 0))

;;;; Cost tracking

(defvar gptel-use-cache)
(declare-function gptel-plus-compute-cost "gptel-plus")

;;;; Content extraction

(defun elfeed-ai--entry-content (entry)
  "Extract content from elfeed ENTRY as plain text."
  (when-let* ((content-obj (elfeed-entry-content entry))
              (text (elfeed-deref content-obj)))
    (when (and (stringp text) (not (string-empty-p text)))
      (with-temp-buffer
        (insert text)
        ;; Strip HTML tags.
        (goto-char (point-min))
        (while (re-search-forward "<[^>]*>" nil t)
          (replace-match "" nil t))
        ;; Collapse whitespace.
        (goto-char (point-min))
        (while (re-search-forward "[ \t\n]+" nil t)
          (replace-match " "))
        (string-trim (buffer-string))))))

(defun elfeed-ai--entry-author (entry)
  "Extract author name from elfeed ENTRY."
  (or (when-let ((authors (elfeed-meta entry :authors)))
        (mapconcat (lambda (a)
                     (or (plist-get a :name)
                         (plist-get a :email)
                         ""))
                   authors ", "))
      (when-let ((feed (elfeed-entry-feed entry)))
        (or (elfeed-meta feed :title)
            (elfeed-feed-title feed)))
      "unknown"))

;;;; Prompt construction

(defun elfeed-ai--system-message ()
  "Return the system message for scoring requests.
This contains the interest profile and scoring instructions, which
remain constant across requests and benefit from prompt caching."
  (format
   "You are a content relevance scorer. Given a user's interest profile and a \
content item, evaluate how relevant the item is to the user's interests.

## User's interest profile

%s

## Instructions

Rate the relevance of this content item on a scale from 0.0 to 1.0, \
where 0.0 means completely irrelevant and 1.0 means extremely relevant.

Respond with ONLY a JSON object (no markdown fences, no extra text)%s

Example response:
%s"
   (elfeed-ai--resolve-profile)
   (if elfeed-ai-generate-summary
       " with \
exactly two keys:
- \"score\": a float between 0.0 and 1.0
- \"summary\": a 1-3 sentence summary of the content"
     " with \
exactly one key:
- \"score\": a float between 0.0 and 1.0")
   (if elfeed-ai-generate-summary
       "{\"score\": 0.75, \"summary\": \"The article discusses recent advances in ...\"}"
     "{\"score\": 0.75}")))

(defun elfeed-ai--build-prompt (entry)
  "Build the user prompt for scoring elfeed ENTRY."
  (let* ((title (or (elfeed-entry-title entry) "(no title)"))
         (author (elfeed-ai--entry-author entry))
         (content (or (elfeed-ai--entry-content entry) ""))
         (truncated (if (> (length content) elfeed-ai-max-content-length)
                        (substring content 0 elfeed-ai-max-content-length)
                      content)))
    (format "Title: %s\nAuthor: %s\nContent:\n%s"
            title author truncated)))

;;;; Response parsing

(defun elfeed-ai--parse-response (response)
  "Parse AI RESPONSE into a (score . summary) cons cell, or nil."
  (when (and response (stringp response))
    (let ((cleaned response))
      ;; Strip markdown code fences if present.
      (when (string-match "```\\(?:json\\)?\\s-*\n?" cleaned)
        (setq cleaned (substring cleaned (match-end 0))))
      (when (string-match "\n?\\s-*```" cleaned)
        (setq cleaned (substring cleaned 0 (match-beginning 0))))
      (setq cleaned (string-trim cleaned))
      (condition-case err
          (let* ((json-object-type 'alist)
                 (json-key-type 'string)
                 (parsed (json-read-from-string cleaned))
                 (score (cdr (assoc "score" parsed)))
                 (summary (cdr (assoc "summary" parsed))))
            (if (and score (numberp score)
                     (<= 0.0 score) (<= score 1.0)
                     (or (not elfeed-ai-generate-summary)
                         (and summary (stringp summary))))
                (cons score (or summary ""))
              (elfeed-log 'warn "elfeed-ai: invalid response structure: %S" parsed)
              nil))
        (error
         (elfeed-log 'error "elfeed-ai: parse error: %s"
                    (error-message-string err))
         nil)))))

;;;; Scoring

(defun elfeed-ai--apply-result (entry result cost)
  "Store scoring RESULT on ENTRY and update tags.
RESULT is a (score . summary) cons cell.  COST is the request cost
or nil."
  (setf (elfeed-meta entry :ai-score) (car result))
  (setf (elfeed-meta entry :ai-summary) (cdr result))
  (when cost
    (setf (elfeed-meta entry :ai-cost) cost))
  (elfeed-tag entry elfeed-ai-scored-tag)
  (if (>= (car result) elfeed-ai-relevance-threshold)
      (elfeed-tag entry elfeed-ai-score-tag)
    (elfeed-untag entry elfeed-ai-score-tag)))

(defun elfeed-ai-score-entry (entry callback)
  "Score ENTRY asynchronously using gptel.
CALLBACK is called with (score . summary) on success, or nil."
  (cond
   ((string-empty-p (elfeed-ai--resolve-profile))
    (elfeed-log 'warn "elfeed-ai: interest profile is empty")
    (funcall callback nil))
   ((elfeed-ai-budget-exhausted-p)
    (elfeed-log 'warn "elfeed-ai: daily token budget exhausted")
    (funcall callback nil))
   ((and (null (elfeed-ai--entry-content entry))
         (null (elfeed-entry-title entry)))
    (elfeed-log 'debug "elfeed-ai: entry has no title or content")
    (funcall callback nil))
   (t
    (let* ((prompt (elfeed-ai--build-prompt entry))
           (system (elfeed-ai--system-message))
           (prompt-tokens (+ (elfeed-ai--estimate-tokens prompt)
                             (elfeed-ai--estimate-tokens system)))
           (resolved (elfeed-ai--resolve-backend-and-model))
           (backend (car resolved))
           (model (cdr resolved))
           (gptel-backend backend)
           (gptel-model model)
           (gptel-use-cache '(system)))
      (gptel-request prompt
        :system system
        :callback (lambda (response info)
                    (if (not response)
                        (progn
                          (elfeed-log 'error "elfeed-ai: gptel request failed: %S" info)
                          (funcall callback nil))
                      (let* ((result (elfeed-ai--parse-response response))
                             (cost (and (require 'gptel-plus nil t)
                                        (fboundp 'gptel-plus-compute-cost)
                                        (gptel-plus-compute-cost info model)))
                             (response-tokens
                              (elfeed-ai--estimate-tokens response))
                             (total-tokens (+ prompt-tokens response-tokens)))
                        (pcase (elfeed-ai--budget-type)
                          ('tokens
                           (elfeed-ai--record-usage total-tokens))
                          ('dollars
                           (if cost
                               (elfeed-ai--record-usage cost)
                             (elfeed-log 'warn
                              "elfeed-ai: dollar budget requires gptel-plus for cost tracking"))))
                        (when result
                          (elfeed-ai--apply-result entry result cost))
                        (funcall callback result)))))))))

;;;; Queue processing

(defun elfeed-ai--enqueue (entry)
  "Add ENTRY to the scoring queue and start processing if idle."
  (unless (or (elfeed-tagged-p elfeed-ai-scored-tag entry)
              (memq entry elfeed-ai--pending-queue))
    (push entry elfeed-ai--pending-queue))
  (when (and elfeed-ai--pending-queue
             (not elfeed-ai--scoring-in-progress))
    (elfeed-ai--process-queue)))

(defun elfeed-ai--process-queue ()
  "Process the next entry in the scoring queue."
  (if (or (null elfeed-ai--pending-queue)
          (elfeed-ai-budget-exhausted-p))
      (progn
        (setq elfeed-ai--scoring-in-progress nil)
        (cond
         ((and elfeed-ai--pending-queue
               (elfeed-ai-budget-exhausted-p))
          (elfeed-log 'warn "elfeed-ai: budget exhausted, %d entries pending"
                      (length elfeed-ai--pending-queue)))
         ((> elfeed-ai--batch-count 0)
          (if (> elfeed-ai--batch-cost 0)
              (message "elfeed-ai: scored %d entries (total cost $%.4f)"
                       elfeed-ai--batch-count elfeed-ai--batch-cost)
            (message "elfeed-ai: scored %d entries"
                     elfeed-ai--batch-count))))
        (setq elfeed-ai--batch-count 0
              elfeed-ai--batch-cost 0.0)
        ;; Refresh search buffer to show updated scores.
        (elfeed-ai--refresh-search))
    (setq elfeed-ai--scoring-in-progress t)
    (let ((entry (pop elfeed-ai--pending-queue)))
      (elfeed-ai-score-entry
       entry
       (lambda (result)
         (when result
           (cl-incf elfeed-ai--batch-count)
           (when-let ((cost (elfeed-meta entry :ai-cost)))
             (cl-incf elfeed-ai--batch-cost cost)))
         (elfeed-ai--process-queue))))))

(defun elfeed-ai--refresh-search ()
  "Refresh the elfeed search buffer if it exists."
  (when-let ((buf (get-buffer "*elfeed-search*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (elfeed-search-update--force)))))

;;;; Display — search buffer

(defun elfeed-ai-search-print-entry (entry)
  "Print ENTRY to the elfeed search buffer with an AI score column."
  (let* ((date (elfeed-search-format-date (elfeed-entry-date entry)))
         (title (or (elfeed-meta entry :title)
                    (elfeed-entry-title entry) ""))
         (title-faces (elfeed-search--faces (elfeed-entry-tags entry)))
         (feed (elfeed-entry-feed entry))
         (feed-title (when feed
                       (or (elfeed-meta feed :title)
                           (elfeed-feed-title feed))))
         (tags (mapcar #'symbol-name (elfeed-entry-tags entry)))
         (tags-str (mapconcat
                    (lambda (s) (propertize s 'face 'elfeed-search-tag-face))
                    tags ","))
         (score (elfeed-meta entry :ai-score))
         (score-str (if score (format "%4.2f" score) "  - "))
         (score-face (cond
                      ((null score) 'elfeed-ai-score-face)
                      ((>= score elfeed-ai-score-high-threshold)
                       'elfeed-ai-score-high-face)
                      ((<= score elfeed-ai-score-low-threshold)
                       'elfeed-ai-score-low-face)
                      (t 'elfeed-ai-score-face)))
         (score-width 6) ; "0.85" or "  - " (4) + padding
         ;; 10 accounts for the date column, matching elfeed's default.
         (title-width (- (window-width) 10 score-width
                         elfeed-search-trailing-width))
         (title-column (elfeed-format-column
                        title (elfeed-clamp
                               elfeed-search-title-min-width
                               title-width
                               elfeed-search-title-max-width)
                        :left)))
    (insert (propertize date 'face 'elfeed-search-date-face) " ")
    (insert (propertize score-str 'face score-face) " ")
    (insert (propertize title-column 'face title-faces 'kbd-help title) " ")
    (when feed-title
      (insert (propertize feed-title 'face 'elfeed-search-feed-face) " "))
    (when tags
      (insert "(" tags-str ")"))))

;;;; Sorting

(defun elfeed-ai-sort (a b)
  "Sort predicate for elfeed entries: highest AI score first.
Unscored entries sort after scored ones.  Entries with equal
scores are sorted by date (newest first)."
  (let ((score-a (or (elfeed-meta a :ai-score) -1.0))
        (score-b (or (elfeed-meta b :ai-score) -1.0)))
    (if (/= score-a score-b)
        (> score-a score-b)
      (> (elfeed-entry-date a) (elfeed-entry-date b)))))

;;;###autoload
(defun elfeed-ai-toggle-sort ()
  "Toggle sorting by AI score in the elfeed search buffer.
When sorting is enabled, `elfeed-search-sort-function' is set to
`elfeed-ai-sort'; when disabled, the original sort function is
restored."
  (interactive)
  (if (eq elfeed-search-sort-function #'elfeed-ai-sort)
      (progn
        (setq elfeed-search-sort-function elfeed-ai--original-sort-function)
        (message "elfeed-ai: sorting by date"))
    (unless elfeed-ai--original-sort-function
      (setq elfeed-ai--original-sort-function elfeed-search-sort-function))
    (setq elfeed-search-sort-function #'elfeed-ai-sort)
    (message "elfeed-ai: sorting by score"))
  (elfeed-ai--refresh-search))

;;;; Display — show buffer

(defun elfeed-ai--show-inject-summary (&rest _)
  "Inject AI summary at the top of the elfeed show buffer."
  (when-let* ((entry elfeed-show-entry)
              (summary (elfeed-meta entry :ai-summary))
              ((not (string-empty-p summary))))
    (let ((inhibit-read-only t)
          (score (elfeed-meta entry :ai-score))
          (cost (elfeed-meta entry :ai-cost)))
      (save-excursion
        (goto-char (point-min))
        ;; Find the blank line separating header from content.
        (when (re-search-forward "^$" nil t)
          (forward-line 1)
          (insert
           (propertize "AI Summary" 'face 'elfeed-ai-summary-heading-face)
           (if score (format " (%.2f)" score) "")
           (if cost (format " [$%.4f]" cost) "")
           "\n\n"
           summary
           "\n\n"
           (propertize (make-string 60 ?─) 'face 'shadow) ; visual separator

           "\n\n"))))))

;;;; Minor mode

;;;###autoload
(define-minor-mode elfeed-ai-mode
  "Global minor mode for AI-powered content curation in elfeed.
When enabled, new elfeed entries are automatically scored for
relevance against `elfeed-ai-interest-profile'.  Entries scoring
above `elfeed-ai-relevance-threshold' are tagged with
`elfeed-ai-score-tag' (default `ai-relevant').

The search buffer displays an AI score column, and the show
buffer displays AI-generated summaries above the original content."
  :global t
  :group 'elfeed-ai
  (if elfeed-ai-mode
      (elfeed-ai--enable)
    (elfeed-ai--disable)))

(defun elfeed-ai--enable ()
  "Enable elfeed-ai integrations."
  (unless elfeed-ai--original-print-entry-function
    (setq elfeed-ai--original-print-entry-function
          elfeed-search-print-entry-function))
  (setq elfeed-search-print-entry-function
        #'elfeed-ai-search-print-entry)
  (when elfeed-ai-sort-by-score
    (setq elfeed-ai--original-sort-function elfeed-search-sort-function)
    (setq elfeed-search-sort-function #'elfeed-ai-sort))
  (when elfeed-ai-auto-score
    (add-hook 'elfeed-new-entry-hook #'elfeed-ai--enqueue))
  (advice-add 'elfeed-show-refresh :after #'elfeed-ai--show-inject-summary))

(defun elfeed-ai--disable ()
  "Disable elfeed-ai integrations."
  (when elfeed-ai--original-print-entry-function
    (setq elfeed-search-print-entry-function
          elfeed-ai--original-print-entry-function)
    (setq elfeed-ai--original-print-entry-function nil))
  (when elfeed-ai-sort-by-score
    (setq elfeed-search-sort-function elfeed-ai--original-sort-function)
    (setq elfeed-ai--original-sort-function nil))
  (remove-hook 'elfeed-new-entry-hook #'elfeed-ai--enqueue)
  (advice-remove 'elfeed-show-refresh #'elfeed-ai--show-inject-summary))

;;;; Interactive commands

;;;###autoload
(defun elfeed-ai-score (&optional force)
  "Score elfeed entries.
In the show buffer, score the displayed entry.  In the search
buffer, score all selected entries (or the entry at point when no
region is active).  With prefix argument FORCE, re-score already
scored entries."
  (interactive "P")
  (cond
   ((derived-mode-p 'elfeed-show-mode)
    (let ((entry elfeed-show-entry))
      (unless entry (user-error "No entry"))
      (when (and (not force) (elfeed-tagged-p elfeed-ai-scored-tag entry))
        (user-error "Entry already scored (%.2f); use C-u to re-score"
                    (or (elfeed-meta entry :ai-score) 0)))
      (message "elfeed-ai: scoring...")
      (elfeed-ai-score-entry
       entry
       (lambda (result)
         (when result
           (let ((cost (elfeed-meta entry :ai-cost)))
             (if cost
                 (message "elfeed-ai: score %.2f (cost $%.4f)" (car result) cost)
               (message "elfeed-ai: score %.2f" (car result))))
           (elfeed-show-refresh))))))
   ((derived-mode-p 'elfeed-search-mode)
    (let* ((entries (elfeed-search-selected))
           (to-score (if force
                         entries
                       (cl-remove-if
                        (lambda (e) (elfeed-tagged-p elfeed-ai-scored-tag e))
                        entries))))
      (dolist (entry to-score)
        (when force
          (elfeed-untag entry elfeed-ai-scored-tag))
        (elfeed-ai--enqueue entry))
      (message "elfeed-ai: queued %d entries for scoring (%d already scored)"
               (length to-score) (- (length entries) (length to-score)))))
   (t (user-error "Not in an elfeed buffer"))))

;;;###autoload
(defun elfeed-ai-score-unscored (&optional days)
  "Queue unscored entries from the last DAYS days for scoring.
Defaults to `elfeed-ai-score-unscored-days'.  With a prefix
argument, prompt for the number of days."
  (interactive (list (if current-prefix-arg
                        (read-number "Days to look back: "
                                     elfeed-ai-score-unscored-days)
                      elfeed-ai-score-unscored-days)))
  (let ((count 0)
        (cutoff (float-time
                 (time-subtract (current-time)
                                (* (or days elfeed-ai-score-unscored-days)
                                   24 60 60)))))
    (with-elfeed-db-visit (entry _feed)
      (when (and (> (elfeed-entry-date entry) cutoff)
                 (not (elfeed-tagged-p elfeed-ai-scored-tag entry)))
        (elfeed-ai--enqueue entry)
        (cl-incf count)))
    (message "elfeed-ai: queued %d entries for scoring" count)))

;;;###autoload
(defun elfeed-ai-budget-status ()
  "Display the current AI token budget status."
  (interactive)
  (elfeed-ai--ensure-budget)
  (let ((used (alist-get 'used elfeed-ai--budget-cache 0))
        (limit (elfeed-ai--budget-limit))
        (remaining (elfeed-ai--budget-remaining)))
    (pcase (elfeed-ai--budget-type)
      ('tokens
       (message "elfeed-ai: %d/%d tokens used (%d remaining)"
                used limit remaining))
      ('dollars
       (message "elfeed-ai: $%.4f/$%.2f used ($%.4f remaining)"
                used limit remaining)))))

;;;; Transient menu

(transient-define-infix elfeed-ai--set-auto-score ()
  :class 'transient-lisp-variable
  :variable 'elfeed-ai-auto-score
  :description "Auto-score new entries"
  :reader (lambda (&rest _) (not elfeed-ai-auto-score)))

(transient-define-infix elfeed-ai--set-generate-summary ()
  :class 'transient-lisp-variable
  :variable 'elfeed-ai-generate-summary
  :description "Generate summaries"
  :reader (lambda (&rest _) (not elfeed-ai-generate-summary)))

(transient-define-infix elfeed-ai--set-relevance-threshold ()
  :class 'transient-lisp-variable
  :variable 'elfeed-ai-relevance-threshold
  :description "Relevance threshold"
  :reader (lambda (prompt _initial-input _history)
            (read-number prompt elfeed-ai-relevance-threshold)))

(transient-define-infix elfeed-ai--set-max-content-length ()
  :class 'transient-lisp-variable
  :variable 'elfeed-ai-max-content-length
  :description "Max content length"
  :reader (lambda (prompt _initial-input _history)
            (read-number prompt elfeed-ai-max-content-length)))

(transient-define-infix elfeed-ai--set-score-unscored-days ()
  :class 'transient-lisp-variable
  :variable 'elfeed-ai-score-unscored-days
  :description "Days to look back"
  :reader (lambda (prompt _initial-input _history)
            (read-number prompt elfeed-ai-score-unscored-days)))

(transient-define-infix elfeed-ai--set-model ()
  :class 'transient-lisp-variable
  :variable 'elfeed-ai-model
  :description "AI model"
  :reader (lambda (prompt _initial-input _history)
            (let ((input (read-string
                          prompt
                          (when elfeed-ai-model
                            (symbol-name elfeed-ai-model)))))
              (if (string-empty-p input) nil (intern input)))))

(defclass elfeed-ai--budget-type-variable (transient-lisp-variable) ()
  "Transient variable that displays only the budget type.")

(cl-defmethod transient-format-value ((_obj elfeed-ai--budget-type-variable))
  (propertize (symbol-name (elfeed-ai--budget-type)) 'face 'transient-value))

(transient-define-infix elfeed-ai--set-budget-type ()
  :class 'elfeed-ai--budget-type-variable
  :variable 'elfeed-ai-daily-budget
  :description "Budget type"
  :reader (lambda (&rest _)
            (let ((new-type (if (eq (elfeed-ai--budget-type) 'tokens)
                                'dollars 'tokens)))
              (cons new-type (elfeed-ai--budget-limit)))))

(defclass elfeed-ai--budget-limit-variable (transient-lisp-variable) ()
  "Transient variable that displays only the budget limit.")

(cl-defmethod transient-format-value ((_obj elfeed-ai--budget-limit-variable))
  (propertize (pcase (elfeed-ai--budget-type)
                ('tokens (format "%d" (elfeed-ai--budget-limit)))
                ('dollars (format "$%.2f" (elfeed-ai--budget-limit))))
              'face 'transient-value))

(transient-define-infix elfeed-ai--set-budget-limit ()
  :class 'elfeed-ai--budget-limit-variable
  :variable 'elfeed-ai-daily-budget
  :description
  (lambda ()
    (elfeed-ai--ensure-budget)
    (let ((used (alist-get 'used elfeed-ai--budget-cache 0)))
      (pcase (elfeed-ai--budget-type)
        ('tokens (format "Budget limit (used %d)" used))
        ('dollars (format "Budget limit (used $%.4f)" used)))))
  :reader (lambda (prompt _initial-input _history)
            (cons (elfeed-ai--budget-type)
                  (read-number prompt (elfeed-ai--budget-limit)))))

;;;###autoload
(transient-define-prefix elfeed-ai-menu ()
  "Transient menu for elfeed-ai."
  [["Score"
    ("s" "Score entry/selection" elfeed-ai-score)
    ("S" "Score unscored entries" elfeed-ai-score-unscored)]
   ["Display"
    ("t" "Toggle sort by score" elfeed-ai-toggle-sort)
    ("m" "Toggle mode" elfeed-ai-mode)]
   ["Scoring"
    ("-m" elfeed-ai--set-model)
    ("-a" elfeed-ai--set-auto-score)
    ("-s" elfeed-ai--set-generate-summary)
    ("-r" elfeed-ai--set-relevance-threshold)
    ("-l" elfeed-ai--set-max-content-length)
    ("-d" elfeed-ai--set-score-unscored-days)]
   ["Budget"
    ("-t" elfeed-ai--set-budget-type)
    ("-b" elfeed-ai--set-budget-limit)]])

(provide 'elfeed-ai)
;;; elfeed-ai.el ends here
