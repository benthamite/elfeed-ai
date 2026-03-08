# `elfeed-ai`: AI-powered content curation for elfeed

`elfeed-ai` brings AI-powered relevance scoring to [elfeed](https://github.com/skeeto/elfeed), the Emacs feed reader. Describe your interests in natural language, and `elfeed-ai` evaluates every new entry against that profile, tagging the ones that matter and showing you a quick AI-generated summary before you read the full article.

Instead of scanning hundreds of entries manually, you write a short interest profile once—or point to a file containing a detailed one—and let a language model do the triage. Entries scoring above a configurable threshold are tagged `ai-relevant` (or any tag you choose), so you can filter your elfeed search to `+ai-relevant +unread` and see only curated content.

Key capabilities:

- **Automatic scoring**: new entries are scored asynchronously as they arrive, with scores and summaries stored as elfeed metadata.
- **Search buffer integration**: a color-coded score column appears next to each entry, and you can sort by score instead of date.
- **Show buffer summaries**: AI-generated summaries are injected above the original content for a quick overview.
- **Budget control**: daily usage limits in tokens or dollars prevent runaway API costs.
- **Transient menu**: a centralized menu (`elfeed-ai-menu`) for adjusting all settings on the fly—model, thresholds, budget, and more.

## Installation

Requires Emacs 29.1 or later, plus [elfeed](https://github.com/skeeto/elfeed) (3.4.1+), [gptel](https://github.com/karthink/gptel) (0.9+), and [transient](https://github.com/magit/transient) (0.7+).

### package-vc (Emacs 30+)

```emacs-lisp
(package-vc-install "https://github.com/benthamite/elfeed-ai")
```

### Elpaca

```emacs-lisp
(use-package elfeed-ai
  :ensure (elfeed-ai :host github :repo "benthamite/elfeed-ai"))
```

### straight.el

```emacs-lisp
(straight-use-package
 '(elfeed-ai :type git :host github :repo "benthamite/elfeed-ai"))
```

## Quick start

```emacs-lisp
(require 'elfeed-ai)

(setq elfeed-ai-interest-profile
      "AI safety, Emacs, functional programming, philosophy of mind")

(elfeed-ai-mode 1)
```

Run `M-x elfeed-update` as usual. New entries are scored automatically, and those meeting the relevance threshold are tagged `ai-relevant`. Filter your search buffer with `+ai-relevant +unread` to see curated content.

To score entries that arrived before you enabled the mode, use `M-x elfeed-ai-score-unscored`. To open the settings menu, use `M-x elfeed-ai-menu`.

## Documentation

For a comprehensive description of all user options, commands, and functions, see the [manual](README.org).
