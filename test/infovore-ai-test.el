;;; infovore-ai-test.el --- Tests for infovore-ai.el  -*- lexical-binding: t; -*-

;; Tests for AI response parsing, token estimation, prompt construction,
;; and budget tracking logic.

;;; Code:

(require 'ert)
(require 'infovore-source)
(require 'infovore-ai)

;;;; Response parsing

(ert-deftest infovore-ai-parse-response/parses-valid-json ()
  (let ((result (infovore-ai--parse-response
                 "{\"score\": 0.75, \"summary\": \"A good article.\"}")))
    (should result)
    (should (eql (car result) 0.75))
    (should (equal (cdr result) "A good article."))))

(ert-deftest infovore-ai-parse-response/handles-markdown-code-fences ()
  (let ((result (infovore-ai--parse-response
                 "```json\n{\"score\": 0.6, \"summary\": \"About AI.\"}\n```")))
    (should result)
    (should (eql (car result) 0.6))
    (should (equal (cdr result) "About AI."))))

(ert-deftest infovore-ai-parse-response/handles-bare-code-fences ()
  (let ((result (infovore-ai--parse-response
                 "```\n{\"score\": 0.3, \"summary\": \"Not relevant.\"}\n```")))
    (should result)
    (should (eql (car result) 0.3))))

(ert-deftest infovore-ai-parse-response/handles-whitespace ()
  (let ((result (infovore-ai--parse-response
                 "  \n  {\"score\": 0.5, \"summary\": \"Average.\"}  \n  ")))
    (should result)
    (should (eql (car result) 0.5))))

(ert-deftest infovore-ai-parse-response/rejects-nil-response ()
  (should (null (infovore-ai--parse-response nil))))

(ert-deftest infovore-ai-parse-response/rejects-non-string ()
  (should (null (infovore-ai--parse-response 42))))

(ert-deftest infovore-ai-parse-response/rejects-empty-string ()
  (should (null (infovore-ai--parse-response ""))))

(ert-deftest infovore-ai-parse-response/rejects-invalid-json ()
  (should (null (infovore-ai--parse-response "not json at all"))))

(ert-deftest infovore-ai-parse-response/rejects-score-out-of-range-high ()
  (should (null (infovore-ai--parse-response
                 "{\"score\": 1.5, \"summary\": \"Too high.\"}"))))

(ert-deftest infovore-ai-parse-response/rejects-score-out-of-range-low ()
  (should (null (infovore-ai--parse-response
                 "{\"score\": -0.1, \"summary\": \"Too low.\"}"))))

(ert-deftest infovore-ai-parse-response/rejects-non-numeric-score ()
  (should (null (infovore-ai--parse-response
                 "{\"score\": \"high\", \"summary\": \"Not a number.\"}"))))

(ert-deftest infovore-ai-parse-response/rejects-missing-summary ()
  (should (null (infovore-ai--parse-response "{\"score\": 0.5}"))))

(ert-deftest infovore-ai-parse-response/rejects-missing-score ()
  (should (null (infovore-ai--parse-response
                 "{\"summary\": \"No score given.\"}"))))

(ert-deftest infovore-ai-parse-response/accepts-boundary-score-0 ()
  (let ((result (infovore-ai--parse-response
                 "{\"score\": 0.0, \"summary\": \"Irrelevant.\"}")))
    (should result)
    (should (eql (car result) 0.0))))

(ert-deftest infovore-ai-parse-response/accepts-boundary-score-1 ()
  (let ((result (infovore-ai--parse-response
                 "{\"score\": 1.0, \"summary\": \"Perfect match.\"}")))
    (should result)
    (should (eql (car result) 1.0))))

(ert-deftest infovore-ai-parse-response/handles-extra-json-fields ()
  (let ((result (infovore-ai--parse-response
                 "{\"score\": 0.5, \"summary\": \"OK.\", \"confidence\": 0.9}")))
    (should result)
    (should (eql (car result) 0.5))))

;;;; Token estimation

(ert-deftest infovore-ai-estimate-tokens/returns-rough-count ()
  (let ((tokens (infovore-ai--estimate-tokens "Hello, this is a test.")))
    (should (> tokens 0))
    ;; 22 chars / 4 = 5
    (should (eql tokens 5))))

(ert-deftest infovore-ai-estimate-tokens/returns-0-for-nil ()
  (should (eql (infovore-ai--estimate-tokens nil) 0)))

(ert-deftest infovore-ai-estimate-tokens/returns-0-for-empty ()
  (should (eql (infovore-ai--estimate-tokens "") 0)))

(ert-deftest infovore-ai-estimate-tokens/returns-0-for-non-string ()
  (should (eql (infovore-ai--estimate-tokens 42) 0)))

(ert-deftest infovore-ai-estimate-tokens/scales-with-length ()
  (let ((short (infovore-ai--estimate-tokens "short"))
        (long (infovore-ai--estimate-tokens (make-string 1000 ?x))))
    (should (> long short))
    (should (eql long 250))))

;;;; Prompt construction

(ert-deftest infovore-ai-build-prompt/includes-interest-profile ()
  (let ((infovore-interest-profile "AI safety and Emacs")
        (item (make-infovore-item :id "p1" :title "Test" :author "Auth"
                                  :content "Content")))
    (let ((prompt (infovore-ai--build-prompt item)))
      (should (string-match-p "AI safety and Emacs" prompt)))))

(ert-deftest infovore-ai-build-prompt/includes-item-fields ()
  (let ((infovore-interest-profile "anything")
        (item (make-infovore-item :id "p2" :title "My Title"
                                  :author "Jane Doe"
                                  :content "Article body here")))
    (let ((prompt (infovore-ai--build-prompt item)))
      (should (string-match-p "My Title" prompt))
      (should (string-match-p "Jane Doe" prompt))
      (should (string-match-p "Article body here" prompt)))))

(ert-deftest infovore-ai-build-prompt/truncates-long-content ()
  (let ((infovore-interest-profile "test")
        (item (make-infovore-item :id "p3" :title "T" :author "A"
                                  :content (make-string 10000 ?x))))
    (let ((prompt (infovore-ai--build-prompt item)))
      ;; Prompt should not contain all 10000 chars of content.
      (should (< (length prompt) 5000)))))

(ert-deftest infovore-ai-build-prompt/handles-nil-title ()
  (let ((infovore-interest-profile "test")
        (item (make-infovore-item :id "p4" :title nil :author nil
                                  :content "Something")))
    (let ((prompt (infovore-ai--build-prompt item)))
      (should (string-match-p "(no title)" prompt))
      (should (string-match-p "(unknown author)" prompt)))))

(ert-deftest infovore-ai-build-prompt/requests-json-response ()
  (let ((infovore-interest-profile "test")
        (item (make-infovore-item :id "p5" :title "T" :content "C")))
    (let ((prompt (infovore-ai--build-prompt item)))
      (should (string-match-p "JSON" prompt))
      (should (string-match-p "\"score\"" prompt))
      (should (string-match-p "\"summary\"" prompt)))))

;;;; Budget tracking

(ert-deftest infovore-ai-budget-date-string/returns-date-format ()
  (let ((date (infovore-ai--budget-date-string)))
    (should (stringp date))
    (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" date))))

(ert-deftest infovore-ai-budget-exhausted/not-exhausted-at-start ()
  ;; With a fresh budget and high limit, should not be exhausted.
  (let ((infovore-daily-token-budget 100000)
        (infovore-ai--daily-tokens-used 0)
        (infovore-ai--budget-date (infovore-ai--budget-date-string)))
    (should (null (infovore-ai-budget-exhausted-p)))))

(ert-deftest infovore-ai-budget-exhausted/exhausted-when-over-limit ()
  (let ((infovore-daily-token-budget 100)
        (infovore-ai--daily-tokens-used 200)
        (infovore-ai--budget-date (infovore-ai--budget-date-string)))
    (should (infovore-ai-budget-exhausted-p))))

(ert-deftest infovore-ai-budget-exhausted/exhausted-at-exact-limit ()
  (let ((infovore-daily-token-budget 100)
        (infovore-ai--daily-tokens-used 100)
        (infovore-ai--budget-date (infovore-ai--budget-date-string)))
    (should (infovore-ai-budget-exhausted-p))))

;;; infovore-ai-test.el ends here
