;;; elfeed-ai.el --- AI-powered content curation for elfeed -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini
;; Keywords: comm, news
;; Package-Requires: ((emacs "29.1") (elfeed "3.4.1") (gptel "0.9"))
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
(require 'elfeed-search)
(require 'elfeed-show)
(require 'gptel)
(require 'json)

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

(defcustom elfeed-ai-daily-token-budget 100000
  "Maximum estimated tokens to use per day for AI scoring.
Token usage is estimated heuristically (one token per four characters)."
  :type 'integer
  :group 'elfeed-ai)

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
  "gptel backend name for AI scoring, e.g. \"Gemini\" or \"Claude\".
When nil, the backend is inferred from `elfeed-ai-model', falling
back to `gptel-backend'."
  :type '(choice (const :tag "Infer from model or use gptel default" nil)
                 (string :tag "Backend name"))
  :group 'elfeed-ai)

(defcustom elfeed-ai-model nil
  "gptel model for AI scoring, e.g. `claude-sonnet-4-5-20250514'.
When nil, defaults to `gptel-model'."
  :type '(choice (const :tag "Use gptel default" nil)
                 (symbol :tag "Model name"))
  :group 'elfeed-ai)

(defcustom elfeed-ai-auto-score t
  "When non-nil, automatically score new entries as they arrive."
  :type 'boolean
  :group 'elfeed-ai)

;;;; Option resolution

(defun elfeed-ai--find-backend-for-model (model)
  "Return the gptel backend that offers MODEL, or nil."
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
  '((t :inherit elfeed-search-date-face))
  "Default face for AI scores in the search buffer."
  :group 'elfeed-ai)

(defface elfeed-ai-score-high-face
  '((t :inherit success))
  "Face for high AI scores (>= 0.7) in the search buffer."
  :group 'elfeed-ai)

(defface elfeed-ai-score-low-face
  '((t :inherit shadow))
  "Face for low AI scores (<= 0.3) in the search buffer."
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

(defvar elfeed-ai--budget-cache nil
  "Cached budget data: alist with `date' and `tokens-used' keys.")

(defvar elfeed-ai--original-print-entry-function nil
  "Original value of `elfeed-search-print-entry-function'.")

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

(defun elfeed-ai--ensure-budget ()
  "Ensure budget cache is loaded for the current period."
  (let ((today (elfeed-ai--budget-date-string)))
    (unless (and elfeed-ai--budget-cache
                 (equal today (alist-get 'date elfeed-ai--budget-cache)))
      (let ((saved (elfeed-ai--load-budget)))
        (setq elfeed-ai--budget-cache
              (if (and saved (equal today (alist-get 'date saved)))
                  saved
                (list (cons 'date today) (cons 'tokens-used 0))))))))

(defun elfeed-ai--budget-remaining ()
  "Return the number of tokens remaining in today's budget."
  (elfeed-ai--ensure-budget)
  (- elfeed-ai-daily-token-budget
     (alist-get 'tokens-used elfeed-ai--budget-cache 0)))

(defun elfeed-ai--record-usage (tokens)
  "Add TOKENS to today's usage and persist."
  (elfeed-ai--ensure-budget)
  (cl-incf (alist-get 'tokens-used elfeed-ai--budget-cache 0) tokens)
  (elfeed-ai--save-budget))

(defun elfeed-ai--estimate-tokens (text)
  "Return a rough token estimate for TEXT (one token per four characters)."
  (if (and text (stringp text) (> (length text) 0))
      (/ (length text) 4)
    0))

(defun elfeed-ai-budget-exhausted-p ()
  "Return non-nil if the daily token budget is exhausted."
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

Respond with ONLY a JSON object (no markdown fences, no extra text) with \
exactly two keys:
- \"score\": a float between 0.0 and 1.0
- \"summary\": a 1-3 sentence summary of the content

Example response:
{\"score\": 0.75, \"summary\": \"The article discusses recent advances in ...\"}"
   (elfeed-ai--resolve-profile)))

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
                     summary (stringp summary))
                (cons score summary)
              (message "elfeed-ai: invalid response structure: %S" parsed)
              nil))
        (error
         (message "elfeed-ai: parse error: %s"
                  (error-message-string err))
         nil)))))

;;;; Scoring

(defun elfeed-ai-score-entry (entry callback)
  "Score ENTRY asynchronously using gptel.
CALLBACK is called with (score . summary) on success, or nil."
  (cond
   ((string-empty-p (elfeed-ai--resolve-profile))
    (message "elfeed-ai: interest profile is empty")
    (funcall callback nil))
   ((elfeed-ai-budget-exhausted-p)
    (message "elfeed-ai: daily token budget exhausted")
    (funcall callback nil))
   ((and (null (elfeed-ai--entry-content entry))
         (null (elfeed-entry-title entry)))
    (message "elfeed-ai: entry has no title or content")
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
                          (message "elfeed-ai: gptel request failed: %S" info)
                          (funcall callback nil))
                      (let* ((result (elfeed-ai--parse-response response))
                             (cost (and (require 'gptel-plus nil t)
                                        (fboundp 'gptel-plus-compute-cost)
                                        (gptel-plus-compute-cost info model)))
                             (response-tokens
                              (elfeed-ai--estimate-tokens response))
                             (total-tokens (+ prompt-tokens response-tokens)))
                        (elfeed-ai--record-usage total-tokens)
                        (when result
                          (setf (elfeed-meta entry :ai-score) (car result))
                          (setf (elfeed-meta entry :ai-summary) (cdr result))
                          (when cost
                            (setf (elfeed-meta entry :ai-cost) cost))
                          (elfeed-tag entry elfeed-ai-scored-tag)
                          (if (>= (car result)
                                  elfeed-ai-relevance-threshold)
                              (elfeed-tag entry elfeed-ai-score-tag)
                            (elfeed-untag entry elfeed-ai-score-tag)))
                        (funcall callback result)))))))))

;;;; Queue processing

(defun elfeed-ai--enqueue (entry)
  "Add ENTRY to the scoring queue and start processing if idle."
  (unless (or (elfeed-tagged-p elfeed-ai-scored-tag entry)
              (memq entry elfeed-ai--pending-queue))
    (push entry elfeed-ai--pending-queue)
    (unless elfeed-ai--scoring-in-progress
      (elfeed-ai--process-queue))))

(defun elfeed-ai--process-queue ()
  "Process the next entry in the scoring queue."
  (if (or (null elfeed-ai--pending-queue)
          (elfeed-ai-budget-exhausted-p))
      (progn
        (setq elfeed-ai--scoring-in-progress nil)
        (when (and elfeed-ai--pending-queue
                   (elfeed-ai-budget-exhausted-p))
          (message "elfeed-ai: budget exhausted, %d entries pending"
                   (length elfeed-ai--pending-queue)))
        ;; Refresh search buffer to show updated scores.
        (elfeed-ai--refresh-search))
    (setq elfeed-ai--scoring-in-progress t)
    (let ((entry (pop elfeed-ai--pending-queue)))
      (elfeed-ai-score-entry
       entry
       (lambda (_result)
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
                      ((>= score 0.7) 'elfeed-ai-score-high-face)
                      ((<= score 0.3) 'elfeed-ai-score-low-face)
                      (t 'elfeed-ai-score-face)))
         (score-width 6)
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

;;;; Display — show buffer

(defun elfeed-ai--show-inject-summary (&rest _)
  "Inject AI summary at the top of the elfeed show buffer."
  (when-let* ((entry elfeed-show-entry)
              (summary (elfeed-meta entry :ai-summary)))
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
           (propertize (make-string 60 ?─) 'face 'shadow)
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
  (when elfeed-ai-auto-score
    (add-hook 'elfeed-new-entry-hook #'elfeed-ai--enqueue))
  (advice-add 'elfeed-show-refresh :after #'elfeed-ai--show-inject-summary))

(defun elfeed-ai--disable ()
  "Disable elfeed-ai integrations."
  (when elfeed-ai--original-print-entry-function
    (setq elfeed-search-print-entry-function
          elfeed-ai--original-print-entry-function)
    (setq elfeed-ai--original-print-entry-function nil))
  (remove-hook 'elfeed-new-entry-hook #'elfeed-ai--enqueue)
  (advice-remove 'elfeed-show-refresh #'elfeed-ai--show-inject-summary))

;;;; Interactive commands

;;;###autoload
(defun elfeed-ai-score-entry-at-point (&optional force)
  "Score the elfeed entry at point.
With prefix argument FORCE, re-score even if already scored."
  (interactive "P")
  (let ((entry (cond
                ((derived-mode-p 'elfeed-search-mode)
                 (car (elfeed-search-selected)))
                ((derived-mode-p 'elfeed-show-mode)
                 elfeed-show-entry)
                (t (user-error "Not in an elfeed buffer")))))
    (unless entry (user-error "No entry at point"))
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
         (elfeed-ai--refresh-search)
         (when (derived-mode-p 'elfeed-show-mode)
           (elfeed-show-refresh)))))))

;;;###autoload
(defun elfeed-ai-score-selected (&optional force)
  "Queue all selected entries in the search buffer for scoring.
With prefix argument FORCE, re-score already scored entries."
  (interactive "P")
  (unless (derived-mode-p 'elfeed-search-mode)
    (user-error "Not in elfeed search buffer"))
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

;;;###autoload
(defun elfeed-ai-score-unscored ()
  "Queue all unscored entries in the database for scoring."
  (interactive)
  (let ((count 0))
    (with-elfeed-db-visit (entry _feed)
      (unless (elfeed-tagged-p elfeed-ai-scored-tag entry)
        (elfeed-ai--enqueue entry)
        (cl-incf count)))
    (message "elfeed-ai: queued %d entries for scoring" count)))

;;;###autoload
(defun elfeed-ai-budget-status ()
  "Display the current AI token budget status."
  (interactive)
  (elfeed-ai--ensure-budget)
  (let ((used (alist-get 'tokens-used elfeed-ai--budget-cache 0))
        (total elfeed-ai-daily-token-budget)
        (remaining (elfeed-ai--budget-remaining)))
    (message "elfeed-ai: %d/%d tokens used (%d remaining)"
             used total remaining)))

(provide 'elfeed-ai)
;;; elfeed-ai.el ends here
