;;; elfeed-ai-test.el --- Tests for elfeed-ai  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for elfeed-ai's core functions: prompt building, response
;; parsing, budget tracking, and content extraction.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Stub elfeed dependencies so tests run without a live elfeed database.
(unless (featurep 'elfeed)
  (provide 'elfeed)
  (provide 'elfeed-search)
  (provide 'elfeed-show)
  (cl-defstruct (elfeed-entry (:constructor elfeed-entry--create))
    id title link date content content-type enclosures tags feed-id meta)
  (defun elfeed-meta (entry key &optional default)
    (let ((pair (assq key (elfeed-entry-meta entry))))
      (if pair (cdr pair) default)))
  (gv-define-setter elfeed-meta (value entry key)
    `(let ((pair (assq ,key (elfeed-entry-meta ,entry))))
       (if pair
           (setcdr pair ,value)
         (push (cons ,key ,value) (elfeed-entry-meta ,entry)))
       ,value))
  (defun elfeed-meta--put (entry key value)
    (let ((pair (assq key (elfeed-entry-meta entry))))
      (if pair
          (setcdr pair value)
        (setf (elfeed-entry-meta entry)
              (cons (cons key value) (elfeed-entry-meta entry)))))
    value)
  (defun elfeed-deref (content) content)
  (defun elfeed-entry-feed (_entry) nil)
  (defun elfeed-feed-title (_feed) nil)
  (defun elfeed-tagged-p (_tag _entry) nil)
  (defun elfeed-tag (entry &rest tags)
    (dolist (tag tags)
      (unless (memq tag (elfeed-entry-tags entry))
        (push tag (elfeed-entry-tags entry)))))
  (defun elfeed-untag (entry &rest tags)
    (dolist (tag tags)
      (setf (elfeed-entry-tags entry)
            (delq tag (elfeed-entry-tags entry))))))

(unless (featurep 'gptel)
  (provide 'gptel)
  (cl-defun gptel-request (_prompt &key callback)
    (when callback
      (funcall callback nil '(:status "stubbed")))))

(require 'elfeed-ai)

;;;; Response parsing tests

(ert-deftest elfeed-ai-test-parse-valid-response ()
  "Parse a well-formed JSON response."
  (let ((result (elfeed-ai--parse-response
                 "{\"score\": 0.85, \"summary\": \"An article about Emacs.\"}")))
    (should result)
    (should (= (car result) 0.85))
    (should (equal (cdr result) "An article about Emacs."))))

(ert-deftest elfeed-ai-test-parse-response-with-fences ()
  "Parse a response wrapped in markdown code fences."
  (let ((result (elfeed-ai--parse-response
                 "```json\n{\"score\": 0.6, \"summary\": \"Test.\"}\n```")))
    (should result)
    (should (= (car result) 0.6))
    (should (equal (cdr result) "Test."))))

(ert-deftest elfeed-ai-test-parse-invalid-score ()
  "Return nil for out-of-range score."
  (should-not (elfeed-ai--parse-response
               "{\"score\": 1.5, \"summary\": \"Test.\"}")))

(ert-deftest elfeed-ai-test-parse-missing-summary ()
  "Return nil when summary is missing."
  (should-not (elfeed-ai--parse-response "{\"score\": 0.5}")))

(ert-deftest elfeed-ai-test-parse-nil-response ()
  "Return nil for nil input."
  (should-not (elfeed-ai--parse-response nil)))

(ert-deftest elfeed-ai-test-parse-garbage ()
  "Return nil for unparseable input."
  (should-not (elfeed-ai--parse-response "not json at all")))

;;;; Budget tests

(ert-deftest elfeed-ai-test-budget-tracking ()
  "Budget tracking records usage and detects exhaustion."
  (let ((elfeed-ai-budget-file (make-temp-file "elfeed-ai-budget-test"))
        (elfeed-ai-daily-budget '(tokens . 1000))
        (elfeed-ai--budget-cache nil))
    (unwind-protect
        (progn
          (setq elfeed-ai--budget-cache nil)
          (elfeed-ai--ensure-budget)
          (should (= (elfeed-ai--budget-remaining) 1000))
          (should-not (elfeed-ai-budget-exhausted-p))
          (elfeed-ai--record-usage 600)
          (should (= (elfeed-ai--budget-remaining) 400))
          (elfeed-ai--record-usage 400)
          (should (= (elfeed-ai--budget-remaining) 0))
          (should (elfeed-ai-budget-exhausted-p)))
      (setq elfeed-ai--budget-cache nil)
      (delete-file elfeed-ai-budget-file))))

(ert-deftest elfeed-ai-test-budget-persistence ()
  "Budget data survives save/load cycle."
  (let ((elfeed-ai-budget-file (make-temp-file "elfeed-ai-budget-test"))
        (elfeed-ai-daily-budget '(tokens . 5000))
        (elfeed-ai--budget-cache nil))
    (unwind-protect
        (progn
          (setq elfeed-ai--budget-cache nil)
          (elfeed-ai--ensure-budget)
          (elfeed-ai--record-usage 1234)
          ;; Clear cache and reload from file.
          (setq elfeed-ai--budget-cache nil)
          (elfeed-ai--ensure-budget)
          (should (= (alist-get 'used elfeed-ai--budget-cache) 1234)))
      (setq elfeed-ai--budget-cache nil)
      (delete-file elfeed-ai-budget-file))))

;;;; Token estimation tests

(ert-deftest elfeed-ai-test-estimate-tokens ()
  "Token estimation returns roughly length/4."
  (should (= (elfeed-ai--estimate-tokens "abcdefgh") 2))
  (should (= (elfeed-ai--estimate-tokens "") 0))
  (should (= (elfeed-ai--estimate-tokens nil) 0)))

;;;; Content extraction tests

(ert-deftest elfeed-ai-test-entry-content-strips-html ()
  "HTML tags are stripped from entry content."
  (let ((entry (elfeed-entry--create
                :content "<p>Hello <b>world</b></p>")))
    (should (equal (elfeed-ai--entry-content entry) "Hello world"))))

(ert-deftest elfeed-ai-test-entry-content-nil ()
  "Nil content returns nil."
  (let ((entry (elfeed-entry--create :content nil)))
    (should-not (elfeed-ai--entry-content entry))))

;;;; Prompt construction tests

(ert-deftest elfeed-ai-test-system-message ()
  "System message includes interest profile and instructions."
  (let ((elfeed-ai-interest-profile "Emacs, Lisp"))
    (let ((system (elfeed-ai--system-message)))
      (should (string-match-p "Emacs, Lisp" system))
      (should (string-match-p "score" system))
      (should (string-match-p "summary" system)))))

(ert-deftest elfeed-ai-test-build-prompt ()
  "Prompt includes title and content but not the profile."
  (let ((elfeed-ai-interest-profile "Emacs, Lisp")
        (entry (elfeed-entry--create
                :title "Elisp tips"
                :content "Some useful tips.")))
    (let ((prompt (elfeed-ai--build-prompt entry)))
      (should (string-match-p "Elisp tips" prompt))
      (should (string-match-p "Some useful tips" prompt))
      (should-not (string-match-p "Emacs, Lisp" prompt)))))

(ert-deftest elfeed-ai-test-build-prompt-truncates ()
  "Content longer than `elfeed-ai-max-content-length' is truncated."
  (let ((elfeed-ai-max-content-length 10)
        (entry (elfeed-entry--create
                :title "Test"
                :content "This is a very long piece of content.")))
    (let ((prompt (elfeed-ai--build-prompt entry)))
      (should (string-match-p "This is a " prompt))
      (should-not (string-match-p "very long piece" prompt)))))

;;;; Apply-result tests

(ert-deftest elfeed-ai-test-apply-result-stores-metadata ()
  "Apply-result stores score, summary, and cost on entry."
  (let ((elfeed-ai-relevance-threshold 0.5)
        (elfeed-ai-score-tag 'ai-relevant)
        (elfeed-ai-scored-tag 'ai-scored)
        (entry (elfeed-entry--create :title "Test")))
    (elfeed-ai--apply-result entry '(0.8 . "Great article.") 0.0012)
    (should (= (elfeed-meta entry :ai-score) 0.8))
    (should (equal (elfeed-meta entry :ai-summary) "Great article."))
    (should (= (elfeed-meta entry :ai-cost) 0.0012))
    (should (memq 'ai-scored (elfeed-entry-tags entry)))
    (should (memq 'ai-relevant (elfeed-entry-tags entry)))))

(ert-deftest elfeed-ai-test-apply-result-below-threshold ()
  "Apply-result does not tag entries below the threshold."
  (let ((elfeed-ai-relevance-threshold 0.5)
        (elfeed-ai-score-tag 'ai-relevant)
        (elfeed-ai-scored-tag 'ai-scored)
        (entry (elfeed-entry--create :title "Test")))
    (elfeed-ai--apply-result entry '(0.3 . "Not relevant.") nil)
    (should (= (elfeed-meta entry :ai-score) 0.3))
    (should (memq 'ai-scored (elfeed-entry-tags entry)))
    (should-not (memq 'ai-relevant (elfeed-entry-tags entry)))))

(provide 'elfeed-ai-test)
;;; elfeed-ai-test.el ends here
