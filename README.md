# Infovore

An Emacs package that uses AI to curate content from Twitter, RSS feeds, Substack, and other sources, filtering for quality and relevance based on a user-defined interest profile, and presenting a rolling feed of curated items in an elfeed-style interface.

## Overview

Infovore fetches content from user-configured sources (Twitter accounts, RSS feeds, Substack newsletters), stores everything in a SQLite database, uses gptel to score each item for relevance against your interest profile, and presents curated items in an elfeed-style list view with a split-buffer detail view.

## Quick start

```elisp
(require 'infovore)

(setq infovore-sources
      '((:type rss :url "https://example.com/feed.xml")
        (:type substack :publication "astralcodexten")
        (:type twitter :username "elonmusk")))

(setq infovore-interest-profile
      "AI safety, Emacs, functional programming, philosophy of mind")

(infovore)         ; open the feed list
(infovore-start)   ; start the automatic fetch timer
```

## Dependencies

### Required

- **gptel** — AI backend for content scoring and summarization
- **elfeed** — XML/RSS/Atom parsing (parser only, not UI or DB)
- **emacsql** + **emacsql-sqlite** — SQLite database access
- **Emacs 29.1+** (for native `libxml` support, `shr`, and built-in SQLite)

### Optional (soft dependencies)

- **zotra** — citation metadata fetching for ebib integration
- **ebib** — bibliography database management

## Architecture

### Source plugin system

Sources are implemented as EIEIO classes inheriting from a base `infovore-source` class:

```
infovore-source (abstract base)
├── infovore-source-rss        ; RSS/Atom feeds via elfeed's XML parser
├── infovore-source-twitter    ; Twitter/X accounts (pluggable fetch backend)
└── infovore-source-substack   ; Substack newsletters (full article fetch + RSS)
```

Each source class implements two generic methods:

- `infovore-source-fetch (source callback)` — asynchronously fetch new items, call CALLBACK with a list of `infovore-item` structs.
- `infovore-source-parse (source raw-data)` — parse raw fetched data into `infovore-item` structs.

### Data model

The `infovore-item` struct (`cl-defstruct`) holds all item data:

| Field         | Type     | Description                                      |
|---------------|----------|--------------------------------------------------|
| `id`          | string   | Unique ID (URL-based, used for deduplication)    |
| `source-id`   | string   | ID of the source that produced this item         |
| `source-type` | symbol   | Source type: `rss`, `twitter`, `substack`         |
| `title`       | string   | Item title (may be nil for tweets)               |
| `author`      | string   | Author name                                      |
| `url`         | string   | Original URL                                     |
| `content`     | string   | Full original content (HTML or plain text)       |
| `summary`     | string   | AI-generated summary (populated after curation)  |
| `score`       | float    | AI relevance score (0.0–1.0)                     |
| `timestamp`   | integer  | Unix timestamp of original publication           |
| `fetched-at`  | integer  | Unix timestamp when fetched                      |
| `read-p`      | boolean  | Whether the user has read this item              |
| `starred-p`   | boolean  | Whether the user has starred this item           |
| `curated-p`   | boolean  | Whether the AI has evaluated this item           |
| `metadata`    | alist    | Additional source-specific metadata              |

### Storage (SQLite via emacsql)

A single SQLite database stores all items. Schema:

```sql
CREATE TABLE items (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  source_type TEXT NOT NULL,
  title TEXT,
  author TEXT,
  url TEXT,
  content TEXT,
  summary TEXT,
  score REAL,
  timestamp INTEGER,
  fetched_at INTEGER,
  read INTEGER DEFAULT 0,
  starred INTEGER DEFAULT 0,
  curated INTEGER DEFAULT 0,
  metadata TEXT  -- JSON-encoded alist
);
```

Indexes on `timestamp`, `score`, `source_id`, and `curated` columns for efficient querying.

### AI curation

Each item is individually scored for relevance:

1. Construct a prompt with the user's interest profile and the item's title, author, and content (truncated to 4000 characters).
2. Send to gptel asynchronously.
3. Parse the JSON response to extract a `score` (0.0–1.0) and a `summary`.
4. Update the item in the database.
5. Items scoring above `infovore-relevance-threshold` (default: 0.5) appear in the default feed view.

A daily token budget (`infovore-daily-token-budget`, default: 100,000) prevents runaway API costs. Token usage is estimated heuristically and persisted to the database.

### Deduplication

URL-based deduplication: before inserting a new item, infovore checks if an item with the same normalized URL already exists. Normalization strips trailing slashes, removes `utm_*` tracking parameters, and lowercases the scheme and host.

### Error handling

Fetch failures retry with exponential backoff: up to `infovore-max-retries` (default: 3) attempts with delays of 30s, 120s, 480s (configurable via `infovore-retry-base-delay`). All errors are logged to the `*infovore-log*` buffer.

## Source plugins

### RSS (`infovore-source-rss`)

Fetches and parses RSS 2.0 and Atom feeds using elfeed's XML parser. Configuration: feed URLs.

### Twitter (`infovore-source-twitter`)

Three pluggable backends for fetching tweets:

1. **RSS-Bridge** (recommended) — self-hosted service that exposes Twitter accounts as RSS feeds. Requires `infovore-twitter-rss-bridge-url`.
2. **Official API v2** — direct API access with a bearer token. Requires `infovore-twitter-api-bearer-token`.
3. **External scraper** — shells out to a CLI tool (e.g. `twikit`). Requires `infovore-twitter-scraper-command`.

Selected via `infovore-twitter-backend` (default: `rss-bridge`).

### Substack (`infovore-source-substack`)

Fetches the RSS feed from `<publication>.substack.com/feed`, then retrieves full article HTML for each entry by following the link and extracting the article body via `libxml-parse-html-region`.

## User interface

### Feed list (`infovore-list-mode`)

Elfeed-style tabulated list with columns for source type, author, title, relevance score, and relative timestamp.

| Key   | Action                              |
|-------|-------------------------------------|
| `RET` | Open item in split buffer           |
| `b`   | Open original URL in browser        |
| `r`   | Toggle read/unread                  |
| `s`   | Toggle starred                      |
| `g`   | Refresh list                        |
| `G`   | Force re-fetch all sources now      |
| `q`   | Quit                                |
| `S`   | Save item to ebib via zotra         |
| `+`   | Show all items (including uncurated)|
| `-`   | Show only curated items (default)   |

### Item detail (`infovore-show-mode`)

Split buffer below the list showing header metadata and either the AI summary or full original content (toggle with `TAB`). HTML content is rendered via `shr`.

### Mode line indicator

`infovore-mode-line-mode` displays `[IV:N]` in the mode line, where N is the unread curated item count.

## File structure

```
infovore/
├── infovore.el                 ; Main entry point, autoloads, public API
├── infovore-db.el              ; Database layer (emacsql schema, queries)
├── infovore-source.el          ; Base source class (EIEIO) and protocol
├── infovore-source-rss.el      ; RSS source plugin
├── infovore-source-twitter.el  ; Twitter source plugin
├── infovore-source-substack.el ; Substack source plugin
├── infovore-ai.el              ; AI curation (gptel integration, prompts, budget)
├── infovore-list.el            ; Feed list view (major mode)
├── infovore-show.el            ; Item detail view (major mode)
├── infovore-modeline.el        ; Mode line indicator
├── infovore-ebib.el            ; Ebib/zotra integration (optional)
├── infovore.org                ; Documentation (Texinfo source)
└── README.md
```

## Roadmap

### Phase 1: Core infrastructure ✅

- Database schema and access layer
- Base source class and protocol
- Item data structure
- Deduplication logic

### Phase 2: Source plugins ✅

- RSS source
- Substack source
- Twitter source with RSS-Bridge backend

### Phase 3: AI curation ✅

- gptel integration
- Prompt engineering for scoring and summarization
- Budget tracking
- Async scoring pipeline

### Phase 4: User interface ✅

- Feed list view
- Item detail view
- Mode line indicator

### Phase 5: Integration and polish ✅

- Scheduling (fetch timer)
- Ebib/zotra integration
- Main entry point and autoloads
- Error handling and retry logic

### Future directions

- Additional source plugins (e.g. Mastodon, Bluesky, Hacker News)
- Batch scoring (multiple items per AI call) for efficiency
- User feedback loop (learn from read/starred patterns to improve scoring)
- Export and sharing (OPML import/export, share curated lists)
- Search and filtering within the feed list
- Customizable scoring prompts
