;;; test-stubs.el --- Minimal stubs for external dependencies in tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Provides minimal stubs for external packages that are not available
;; in batch mode but are needed to load infovore modules.
;; Only defines stubs for features that are not already loaded.

;;; Code:

;; elfeed-xml does not exist as a separate module in modern elfeed.
;; The infovore code references it, so we stub it here for testing.
(unless (featurep 'elfeed-xml)
  (defun elfeed-xml-parse-region (start end)
    "Stub: parse XML between START and END using built-in xml.el."
    (xml-parse-region start end))
  (provide 'elfeed-xml))

;; Stub gptel if not available (only the function used by infovore-ai).
(unless (featurep 'gptel)
  (defun gptel-request (_prompt &rest _args)
    "Stub: no-op gptel-request for testing."
    nil)
  (provide 'gptel))

;; Stub zotra and ebib (soft dependencies).
(unless (featurep 'zotra)
  (provide 'zotra))
(unless (featurep 'ebib)
  (provide 'ebib))

;;; test-stubs.el ends here
