;;; infovore-main-test.el --- Tests for infovore.el  -*- lexical-binding: t; -*-

;; Tests for source instantiation, configuration validation,
;; and the top-level module.

;;; Code:

(require 'ert)
(require 'infovore)

;;;; Source instantiation

(ert-deftest infovore-instantiate-source/rss-source ()
  (let ((src (infovore--instantiate-source
              '(:type rss :url "https://example.com/feed.xml"))))
    (should (infovore-source-rss-p src))
    (should (equal (infovore-source-id src) "rss:https://example.com/feed.xml"))
    (should (equal (infovore-source-rss-url src) "https://example.com/feed.xml"))
    (should (equal (infovore-source-name src) "https://example.com/feed.xml"))))

(ert-deftest infovore-instantiate-source/rss-with-custom-name ()
  (let ((src (infovore--instantiate-source
              '(:type rss :url "https://blog.example.com/feed" :name "My Blog"))))
    (should (equal (infovore-source-name src) "My Blog"))))

(ert-deftest infovore-instantiate-source/rss-requires-url ()
  (should-error (infovore--instantiate-source '(:type rss))))

(ert-deftest infovore-instantiate-source/twitter-source ()
  (let ((src (infovore--instantiate-source
              '(:type twitter :username "testuser"))))
    (should (infovore-source-twitter-p src))
    (should (equal (infovore-source-id src) "twitter:testuser"))
    (should (equal (infovore-source-twitter-username src) "testuser"))
    (should (equal (infovore-source-name src) "@testuser"))))

(ert-deftest infovore-instantiate-source/twitter-requires-username ()
  (should-error (infovore--instantiate-source '(:type twitter))))

(ert-deftest infovore-instantiate-source/substack-source ()
  (let ((src (infovore--instantiate-source
              '(:type substack :publication "astralcodexten"))))
    (should (infovore-source-substack-p src))
    (should (equal (infovore-source-id src) "substack:astralcodexten"))
    (should (equal (infovore-source-substack-publication src) "astralcodexten"))
    (should (equal (infovore-source-name src) "astralcodexten"))))

(ert-deftest infovore-instantiate-source/substack-requires-publication ()
  (should-error (infovore--instantiate-source '(:type substack))))

(ert-deftest infovore-instantiate-source/unknown-type-errors ()
  (should-error (infovore--instantiate-source '(:type mastodon :handle "@test"))))

(ert-deftest infovore-instantiate-source/missing-type-errors ()
  (should-error (infovore--instantiate-source '(:url "https://example.com"))))

;;;; Source list instantiation

(ert-deftest infovore-instantiate-sources/creates-list ()
  (let ((infovore-sources
         '((:type rss :url "https://a.com/feed")
           (:type twitter :username "user1")
           (:type substack :publication "pub1")))
        (infovore--sources nil))
    (infovore--instantiate-sources)
    (should (= (length infovore--sources) 3))
    (should (infovore-source-rss-p (nth 0 infovore--sources)))
    (should (infovore-source-twitter-p (nth 1 infovore--sources)))
    (should (infovore-source-substack-p (nth 2 infovore--sources)))))

(ert-deftest infovore-instantiate-sources/empty-config ()
  (let ((infovore-sources '())
        (infovore--sources nil))
    (infovore--instantiate-sources)
    (should (null infovore--sources))))

;;;; Enabled/disabled sources

(ert-deftest infovore-source-enabled/defaults-to-enabled ()
  (let ((src (infovore--instantiate-source
              '(:type rss :url "https://example.com/feed"))))
    (should (infovore-source-enabled-p src))))

(ert-deftest infovore-source-enabled/can-be-disabled ()
  (let ((src (infovore--instantiate-source
              '(:type rss :url "https://example.com/feed"))))
    (setf (infovore-source-enabled-p src) nil)
    (should (null (infovore-source-enabled-p src)))))

;;; infovore-main-test.el ends here
