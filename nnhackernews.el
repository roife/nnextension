;;; nnhackernews.el --- Read Hacker News through Gnus  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nnextension contributors

;; Author: nnextension contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.0"))
;; Keywords: news, hypermedia
;; URL: https://github.com/roife/nnextension
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; nnhackernews exposes recent Hacker News stories and their comments as
;; threaded Gnus articles.  It is deliberately read-only.

;;; Code:

(require 'cl-lib)
(require 'gnus)
(require 'gnus-int)
(require 'gnus-range)
(require 'gnus-srvr)
(require 'mail-parse)
(require 'nnheader)
(require 'nnoo)
(require 'nnextension-core)
(require 'seq)
(require 'sqlite)
(require 'subr-x)
(require 'url-util)
(require 'xml)

(declare-function gnus-summary-article-number "gnus-sum")
(declare-function gnus-summary-buffer-name "gnus-sum" (group))
(declare-function gnus-summary-reselect-current-group "gnus-sum"
                  (&optional all no-article))
(declare-function gnus-group-update-group "gnus-group"
                  (group &optional visible-only info-unchanged))

(defgroup nnhackernews nil
  "Read Hacker News through Gnus."
  :group 'gnus)

(defmacro nnhackernews--with-report (&rest body)
  "Run BODY, reporting errors through the Gnus backend."
  (declare (indent 0) (debug t))
  `(nnextension-core-with-report 'nnhackernews ,@body))

(nnoo-declare nnhackernews)

(defcustom nnhackernews-directory
  (file-name-concat gnus-directory "nnhackernews")
  "Directory in which nnhackernews stores its SQLite databases."
  :type 'directory
  :group 'nnhackernews)

(defcustom nnhackernews-feed-limit 100
  "Maximum number of current root stories retained from each feed scan."
  :type '(integer 1)
  :group 'nnhackernews)

(defcustom nnhackernews-request-timeout 30
  "Maximum number of seconds to wait for a Hacker News HTTP response."
  :type 'natnum
  :group 'nnhackernews)

(defcustom nnhackernews-reply-subject-length 72
  "Maximum number of characters in a comment body-derived subject."
  :type '(integer 1)
  :group 'nnhackernews)

(defcustom nnhackernews-comment-page-size 50
  "Number of comments fetched by each on-demand page request."
  :type '(integer 1)
  :group 'nnhackernews)

(defcustom nnhackernews-thread-refresh-days 7
  "Days after opening a story during which normal scans refresh comments."
  :type 'natnum
  :group 'nnhackernews)

(dolist (variable '(nnhackernews-directory
                    nnhackernews-feed-limit
                    nnhackernews-request-timeout
                    nnhackernews-reply-subject-length
                    nnhackernews-comment-page-size
                    nnhackernews-thread-refresh-days))
  (nnoo-define variable nil))

(defvoo nnhackernews--database nil)
(defvoo nnhackernews--current-group nil)
(defvoo nnhackernews-status-string "")

(cl-defstruct nnhackernews--background-sync server database)

(cl-defstruct nnhackernews--comment-sync
  server database story-id group mode remaining page new-count)

(defvar nnhackernews--background-syncs (make-hash-table :test #'equal))
(defvar nnhackernews--comment-syncs (make-hash-table :test #'equal))

(defconst nnhackernews--firebase-base-url
  "https://hacker-news.firebaseio.com/v0")

(defconst nnhackernews--algolia-base-url
  "https://hn.algolia.com/api/v1")

(defconst nnhackernews--site-url "https://news.ycombinator.com")

(defconst nnhackernews--algolia-batch-size 50)

(defconst nnhackernews--groups
  '(("news" . "New Stories")
    ("ask" . "Ask HN")
    ("show" . "Show HN")
    ("job" . "Jobs")))

(defconst nnhackernews--item-columns
  '(:id :group-name :article-no :story-id :parent-id :type :author
    :created-at :title :text :url :score :descendants :deleted :dead
    :fetched-at))

(defconst nnhackernews--item-select
  "SELECT id, group_name, article_no, story_id, parent_id, type, author,
          created_at, title, text, url, score, descendants, deleted, dead,
          fetched_at
     FROM items WHERE ")

(defvar-keymap nnhackernews-mode-map
  :doc "Bindings active in nnhackernews Gnus buffers."
  "C-c C-r" #'nnhackernews-refresh-thread
  "C-c C-o" #'nnhackernews-fetch-older)

(define-minor-mode nnhackernews-mode
  "Minor mode enabled in Gnus buffers backed by nnhackernews."
  :lighter " HN"
  :keymap nnhackernews-mode-map)

(defun nnhackernews--initialize-database (database)
  "Create the nnhackernews schema in DATABASE."
  (nnextension-core-initialize-metadata database)
  (sqlite-execute
   database
   "CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY,
      group_name TEXT NOT NULL,
      article_no INTEGER NOT NULL,
      story_id INTEGER NOT NULL,
      parent_id INTEGER,
      type TEXT NOT NULL,
      author TEXT,
      created_at INTEGER NOT NULL,
      title TEXT,
      text TEXT,
      url TEXT,
      score INTEGER,
      descendants INTEGER,
      deleted INTEGER NOT NULL DEFAULT 0,
      dead INTEGER NOT NULL DEFAULT 0,
      fetched_at INTEGER NOT NULL,
      UNIQUE(group_name, article_no)
    )")
  (sqlite-execute
   database
   "CREATE INDEX IF NOT EXISTS items_story_id
       ON items(story_id)")
  (sqlite-execute
   database
   "CREATE INDEX IF NOT EXISTS items_parent_id
       ON items(parent_id)"))

(defun nnhackernews--find-item (where values)
  "Return the first cached item matching SQL WHERE with VALUES."
  (when-let* ((row
               (car
                (sqlite-select
                 nnhackernews--database
                 (concat nnhackernews--item-select where)
                 values))))
    (cl-mapcan #'list nnhackernews--item-columns row)))

(defun nnhackernews--item-by-id (id)
  "Return the cached Hacker News item identified by ID."
  (nnhackernews--find-item "id = ?" (vector id)))

(defun nnhackernews--item-by-article (group article)
  "Return the cached item for GROUP and local ARTICLE number."
  (nnhackernews--find-item
   "group_name = ? AND article_no = ?"
   (vector group article)))

(defun nnhackernews--next-article-number (group)
  "Return the next dense local article number for GROUP."
  (caar
   (sqlite-select
    nnhackernews--database
    "SELECT COALESCE(MAX(article_no), 0) + 1
       FROM items WHERE group_name = ?"
    (vector group))))

(defun nnhackernews--remote-id (item)
  "Return ITEM's numeric Hacker News identifier."
  (let ((id (or (plist-get item :id)
                (plist-get item :objectID))))
    (if (stringp id) (string-to-number id) id)))

(defun nnhackernews--tagged-p (item tag)
  "Return non-nil when Algolia ITEM has TAG."
  (member tag (plist-get item :_tags)))

(defun nnhackernews--item-type (item)
  "Return a normalized type string for remote ITEM."
  (or (plist-get item :type)
      (cond
       ((nnhackernews--tagged-p item "comment") "comment")
       ((nnhackernews--tagged-p item "job") "job")
       (t "story"))))

(defun nnhackernews--classify-story (item fallback)
  "Classify root ITEM into a group, using FALLBACK when necessary."
  (let ((title (plist-get item :title)))
    (cond
     ((or (equal (nnhackernews--item-type item) "job")
          (nnhackernews--tagged-p item "job"))
      "job")
     ((or (nnhackernews--tagged-p item "ask_hn")
          (string-match-p "\\`\\(?:Ask\\|Tell\\) HN\\(?:[: ]\\|\\'\\)"
                          title))
      "ask")
     ((or (nnhackernews--tagged-p item "show_hn")
          (string-match-p "\\`Show HN\\(?:[: ]\\|\\'\\)" title))
      "show")
     (t fallback))))

(defun nnhackernews--normalize-item (item group story-id)
  "Normalize remote ITEM for GROUP and STORY-ID."
  (let* ((id (nnhackernews--remote-id item))
         (type (nnhackernews--item-type item))
         (root-p (not (equal type "comment")))
         (author (or (plist-get item :author) (plist-get item :by)))
         (text (or (plist-get item :text)
                   (plist-get item :story_text)
                   (plist-get item :comment_text)))
         (deleted
          (or (eq (plist-get item :deleted) t)
              (and (equal type "comment")
                   (null author) (null text))))
         (created-at
          (or (plist-get item :created_at_i)
              (plist-get item :time))))
    (list
     :id id
     :group-name (if root-p
                     (nnhackernews--classify-story item group)
                   group)
     :story-id (or story-id
                   (plist-get item :story_id)
                   (and root-p id))
     :parent-id (or (plist-get item :parent_id)
                    (plist-get item :parent))
     :type type
     :author author
     :created-at created-at
     :title (plist-get item :title)
     :text text
     :url (plist-get item :url)
     :score (or (plist-get item :points)
                (plist-get item :score))
     :descendants (or (plist-get item :num_comments)
                      (plist-get item :descendants))
     :deleted (if deleted 1 0)
     :dead (if (eq (plist-get item :dead) t) 1 0))))

(defun nnhackernews--upsert-item (remote group story-id)
  "Insert or update REMOTE in GROUP for STORY-ID."
  (let* ((normalized (nnhackernews--normalize-item remote group story-id))
         (id (plist-get normalized :id))
         (existing (and id (nnhackernews--item-by-id id)))
         (group (or (plist-get existing :group-name)
                    (plist-get normalized :group-name)))
         (article-no (or (plist-get existing :article-no)
                         (nnhackernews--next-article-number group)))
         (now (time-convert nil 'integer)))
    (sqlite-execute
     nnhackernews--database
     "INSERT INTO items
        (id, group_name, article_no, story_id, parent_id, type, author,
         created_at, title, text, url, score, descendants, deleted, dead,
         fetched_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        parent_id = excluded.parent_id,
        author = excluded.author,
        created_at = excluded.created_at,
        title = excluded.title,
        text = excluded.text,
        url = excluded.url,
        score = excluded.score,
        descendants = COALESCE(excluded.descendants, items.descendants),
        deleted = excluded.deleted,
        dead = excluded.dead,
        fetched_at = excluded.fetched_at"
     (vector
      id group article-no (plist-get normalized :story-id)
      (plist-get normalized :parent-id) (plist-get normalized :type)
      (plist-get normalized :author) (plist-get normalized :created-at)
      (plist-get normalized :title) (plist-get normalized :text)
      (plist-get normalized :url) (plist-get normalized :score)
      (plist-get normalized :descendants) (plist-get normalized :deleted)
      (plist-get normalized :dead) now))
    (nnhackernews--item-by-id id)))

(defun nnhackernews--firebase-url (path)
  "Return the Firebase URL for PATH."
  (format "%s/%s.json" nnhackernews--firebase-base-url path))

(defun nnhackernews--algolia-url (path &optional query)
  "Return the Algolia URL for PATH and QUERY."
  (concat nnhackernews--algolia-base-url path
          (and query (concat "?" (url-build-query-string query)))))

(defun nnhackernews--store-roots (database roots)
  "Store ROOTS in DATABASE and return their count."
  (let ((nnhackernews--database database))
    (setq roots
          (seq-sort-by
           (lambda (entry) (nnhackernews--remote-id (cdr entry))) #'<
           roots))
    (with-sqlite-transaction database
      (dolist (entry roots)
        (nnhackernews--upsert-item
         (cdr entry) (car entry) (nnhackernews--remote-id (cdr entry)))))
    (length roots)))

(defun nnhackernews--async-get (key url)
  "Return a background JSON request for KEY and URL."
  `(:key ,key :method "GET" :url ,url
    :headers (("User-Agent" . "nnextension-nnhackernews/0.1"))
    :timeout ,nnhackernews-request-timeout :service "Hacker News"))

(defun nnhackernews--background-root-requests (feeds)
  "Return parallel Algolia requests for FEEDS."
  (cl-mapcan
   (lambda (feed)
     (let ((group (car feed))
           (ids (cdr feed)))
       (if (equal group "job")
           (list
            (nnhackernews--async-get
             (cons group 0)
             (nnhackernews--algolia-url
              "/search_by_date"
              `(("tags" "job")
                ("hitsPerPage" ,(number-to-string (length ids)))))))
         (cl-loop
          for chunk in (seq-partition ids nnhackernews--algolia-batch-size)
          for index from 0
          collect
          (nnhackernews--async-get
           (cons group index)
           (nnhackernews--algolia-url
            "/search_by_date"
            `(("tags"
               ,(format
                 "story,(%s)"
                 (mapconcat
                  (lambda (id) (format "story_%d" id)) chunk ",")))
              ("hitsPerPage" ,(number-to-string (length chunk))))))))))
   feeds))

(defun nnhackernews--background-root-table (results)
  "Return an ID-indexed table of Algolia root RESULTS."
  (let ((table (make-hash-table :test #'eql)))
    (dolist (result results table)
      (dolist (hit (plist-get (cdr result) :hits))
        (puthash (nnhackernews--remote-id hit) hit table)))))

(defun nnhackernews--background-roots (feeds table)
  "Return grouped roots from FEEDS and ID-indexed TABLE."
  (let (roots)
    (dolist (id (cdr (assoc "news" feeds)))
      (when-let* ((root (gethash id table)))
        (when (and (< (length (alist-get "news" roots nil nil #'equal))
                      nnhackernews-feed-limit)
                   (equal (nnhackernews--classify-story root "news") "news"))
          (push root (alist-get "news" roots nil nil #'equal)))))
    (dolist (feed (cdr feeds))
      (dolist (id (cdr feed))
        (when-let* ((root (gethash id table)))
          (push root (alist-get (car feed) roots nil nil #'equal)))))
    (cl-mapcan
     (lambda (feed)
       (mapcar (lambda (root) (cons (car feed) root)) (cdr feed)))
     roots)))

(defun nnhackernews--publish-active (database server &optional update-buffer)
  "Publish cached group ranges from DATABASE for SERVER.
When UPDATE-BUFFER is non-nil, redraw existing Group buffer lines."
  (let ((nnhackernews--database database)
        groups)
    (dolist (entry nnhackernews--groups)
      (pcase-let* ((group (car entry))
                   (full (gnus-group-full-name
                          group `(nnhackernews ,server)))
                   (`(,_count ,minimum ,maximum)
                    (nnhackernews--group-stats group)))
        (gnus-set-active full (cons minimum maximum))
        (push full groups)))
    (when-let* ((buffer (and update-buffer (get-buffer gnus-group-buffer))))
      (with-current-buffer buffer
        (dolist (group groups)
          (gnus-group-update-group group nil nil))))))

(defun nnhackernews--finish-background-sync (sync roots errors)
  "Finish SYNC by storing ROOTS or reporting ERRORS."
  (let ((server (nnhackernews--background-sync-server sync))
        (database (nnhackernews--background-sync-database sync)))
    (unwind-protect
        (if errors
            (nnheader-message
             3 "nnhackernews background sync failed: %s"
             (error-message-string (cdar errors)))
          (let ((count (nnhackernews--store-roots database roots)))
            (setq nnhackernews-status-string
                  (format "Synchronized %d Hacker News stories" count))
            (nnhackernews--publish-active database server t)
            (nnheader-message 5 "%s" nnhackernews-status-string)))
      (sqlite-close database)
      (remhash server nnhackernews--background-syncs))))

(defun nnhackernews--background-fallbacks (sync feeds results errors)
  "Fetch roots missing from Algolia RESULTS for SYNC and FEEDS.
Finish immediately when ERRORS is non-nil."
  (if errors
      (nnhackernews--finish-background-sync sync nil errors)
    (let* ((table (nnhackernews--background-root-table results))
           (ids (delete-dups (mapcan #'copy-sequence (mapcar #'cdr feeds))))
           (missing (seq-remove (lambda (id) (gethash id table)) ids)))
      (nnextension-core-json-batch
       (mapcar
        (lambda (id)
          (nnhackernews--async-get
           id (nnhackernews--firebase-url (format "item/%d" id))))
        missing)
       (lambda (fallbacks fallback-errors)
         (dolist (fallback fallbacks)
           (puthash (car fallback) (cdr fallback) table))
         (nnhackernews--finish-background-sync
          sync (nnhackernews--background-roots feeds table)
          fallback-errors))))))

(defun nnhackernews--background-feeds (sync results errors)
  "Start root metadata requests for SYNC from feed RESULTS.
Finish immediately when ERRORS is non-nil."
  (if errors
      (nnhackernews--finish-background-sync sync nil errors)
    (let* ((new (alist-get 'new results))
           (ask (alist-get 'ask results))
           (show (alist-get 'show results))
           (job (alist-get 'job results))
           (special (append ask show job))
           (feeds
            `(("news" . ,(seq-take
                          (seq-remove (lambda (id) (memq id special)) new)
                          (+ nnhackernews-feed-limit
                             nnhackernews--algolia-batch-size)))
              ("ask" . ,(seq-take ask nnhackernews-feed-limit))
              ("show" . ,(seq-take show nnhackernews-feed-limit))
              ("job" . ,(seq-take job nnhackernews-feed-limit)))))
      (nnextension-core-json-batch
       (nnhackernews--background-root-requests feeds)
       (lambda (root-results root-errors)
         (nnhackernews--background-fallbacks
          sync feeds root-results root-errors))))))

(defun nnhackernews--start-background-sync (server)
  "Start or return the background synchronization for SERVER."
  (or (gethash server nnhackernews--background-syncs)
      (let* ((database
              (sqlite-open
               (nnextension-core-database-file nnhackernews-directory server)))
             (sync
              (make-nnhackernews--background-sync
               :server server :database database)))
        (nnhackernews--initialize-database database)
        (puthash server sync nnhackernews--background-syncs)
        (nnextension-core-json-batch
         (mapcar
          (lambda (feed)
            (nnhackernews--async-get
             (car feed) (nnhackernews--firebase-url (cdr feed))))
          '((new . "newstories") (ask . "askstories")
            (show . "showstories") (job . "jobstories")))
         (lambda (results errors)
           (nnhackernews--background-feeds sync results errors)))
        sync)))

(defun nnhackernews--thread-metadata-key (story-id field)
  "Return the metadata key for STORY-ID and FIELD."
  (format "thread.%d.%s" story-id field))

(defun nnhackernews--thread-metadata-get (database story-id field)
  "Return FIELD metadata for STORY-ID in DATABASE."
  (nnextension-core-metadata-get
   database (nnhackernews--thread-metadata-key story-id field)))

(defun nnhackernews--thread-metadata-set (database story-id field value)
  "Store FIELD metadata VALUE for STORY-ID in DATABASE."
  (nnextension-core-metadata-set
   database (nnhackernews--thread-metadata-key story-id field) value))

(defun nnhackernews--comment-cursor (database story-id direction)
  "Return the comment cursor in DATABASE for STORY-ID and DIRECTION."
  (or (when-let* ((value
                   (nnhackernews--thread-metadata-get
                    database story-id direction)))
        (string-to-number value))
      (caar
       (sqlite-select
        database
        (format "SELECT %s(created_at) FROM items
                  WHERE story_id = ? AND type = 'comment'"
                (if (equal direction "newest") "MAX" "MIN"))
        (vector story-id)))))

(defun nnhackernews--comment-url (sync)
  "Return the next Algolia comment URL for SYNC."
  (let* ((mode (nnhackernews--comment-sync-mode sync))
         (database (nnhackernews--comment-sync-database sync))
         (story-id (nnhackernews--comment-sync-story-id sync))
         (cursor
          (pcase mode
            ('new (nnhackernews--comment-cursor database story-id "newest"))
            ('older (nnhackernews--comment-cursor database story-id "oldest"))))
         (filters
          (pcase mode
            ('new (and cursor (format "created_at_i>=%d" cursor)))
            ('older (and cursor (format "created_at_i<%d" cursor)))))
         (query
          `(("tags" ,(format "comment,story_%d" story-id))
            ("hitsPerPage" ,(number-to-string nnhackernews-comment-page-size))
            ("page" ,(number-to-string
                       (nnhackernews--comment-sync-page sync))))))
    (nnhackernews--algolia-url
     "/search_by_date"
     (append query (and filters `(("numericFilters" ,filters)))))))

(defun nnhackernews--store-comment-hits (sync hits)
  "Store comment HITS for SYNC and return the new-item count."
  (let* ((database (nnhackernews--comment-sync-database sync))
         (story-id (nnhackernews--comment-sync-story-id sync))
         (group (nnhackernews--comment-sync-group sync))
         (nnhackernews--database database)
         (new 0))
    (with-sqlite-transaction database
      (dolist (hit (seq-sort-by #'nnhackernews--remote-id #'< hits))
        (unless (nnhackernews--item-by-id (nnhackernews--remote-id hit))
          (cl-incf new))
        (nnhackernews--upsert-item hit group story-id)))
    (pcase-let
        ((`(,oldest ,newest)
          (car
           (sqlite-select
            database
            "SELECT MIN(created_at), MAX(created_at) FROM items
              WHERE story_id = ? AND type = 'comment'"
            (vector story-id)))))
      (when oldest
        (nnhackernews--thread-metadata-set database story-id "oldest" oldest)
        (nnhackernews--thread-metadata-set database story-id "newest" newest)))
    new))

(defun nnhackernews--finish-comment-sync (sync &optional error)
  "Finish comment SYNC, optionally reporting ERROR."
  (let ((database (nnhackernews--comment-sync-database sync))
        (server (nnhackernews--comment-sync-server sync))
        (group (nnhackernews--comment-sync-group sync))
        (new (nnhackernews--comment-sync-new-count sync)))
    (unwind-protect
        (if error
            (nnheader-message
             3 "nnhackernews comment sync failed: %s"
             (error-message-string error))
          (nnhackernews--publish-active database server t)
          (when (> new 0)
            (nnhackernews--schedule-reselect group server))
          (nnheader-message 5 "Loaded %d new Hacker News comments" new))
      (sqlite-close database)
      (remhash (cons server (nnhackernews--comment-sync-story-id sync))
               nnhackernews--comment-syncs))))

(defun nnhackernews--comment-page-result (sync data error)
  "Process one comment page DATA or ERROR for SYNC."
  (if error
      (nnhackernews--finish-comment-sync sync error)
    (let* ((hits (plist-get data :hits))
           (page (plist-get data :page))
           (pages (plist-get data :nbPages))
           (mode (nnhackernews--comment-sync-mode sync)))
      (cl-incf (nnhackernews--comment-sync-new-count sync)
               (nnhackernews--store-comment-hits sync hits))
      (pcase mode
        ('new
         (if (< (1+ page) pages)
             (progn
               (setf (nnhackernews--comment-sync-page sync) (1+ page))
               (nnhackernews--request-comment-page sync))
           (nnhackernews--finish-comment-sync sync)))
        ('older
         (cl-decf (nnhackernews--comment-sync-remaining sync))
         (when (< (length hits) nnhackernews-comment-page-size)
           (nnhackernews--thread-metadata-set
            (nnhackernews--comment-sync-database sync)
            (nnhackernews--comment-sync-story-id sync) "older_exhausted" 1))
         (if (and (> (nnhackernews--comment-sync-remaining sync) 0) hits)
             (nnhackernews--request-comment-page sync)
           (nnhackernews--finish-comment-sync sync)))
        (_
         (when (<= pages 1)
           (nnhackernews--thread-metadata-set
            (nnhackernews--comment-sync-database sync)
            (nnhackernews--comment-sync-story-id sync) "older_exhausted" 1))
         (nnhackernews--finish-comment-sync sync))))))

(defun nnhackernews--request-comment-page (sync)
  "Request the next comment page for SYNC."
  (nnextension-core-json-request-async
   "GET" (nnhackernews--comment-url sync)
   (lambda (data error)
     (nnhackernews--comment-page-result sync data error))
   :headers '(("User-Agent" . "nnextension-nnhackernews/0.1"))
   :timeout nnhackernews-request-timeout
   :service "Hacker News"))

(defun nnhackernews--start-comment-sync
    (server story-id mode &optional pages touch)
  "Start MODE comment sync for STORY-ID on SERVER.
PAGES controls older-page loading.  TOUCH renews local watch state."
  (let ((key (cons server story-id)))
    (or (gethash key nnhackernews--comment-syncs)
        (let* ((database
                (sqlite-open
                 (nnextension-core-database-file nnhackernews-directory server)))
               (nnhackernews--database database)
               (_initialized (nnhackernews--initialize-database database))
               (root (nnhackernews--item-by-id story-id))
               (sync
                (make-nnhackernews--comment-sync
                 :server server :database database
                 :story-id story-id :group (plist-get root :group-name)
                 :mode mode :remaining (or pages 1) :page 0
                 :new-count 0)))
          (puthash key sync nnhackernews--comment-syncs)
          (when touch
            (nnhackernews--thread-metadata-set
             database story-id "watched_at" (time-convert nil 'integer)))
          (if (and (eq mode 'older)
                   (nnhackernews--thread-metadata-get
                    database story-id "older_exhausted"))
              (nnhackernews--finish-comment-sync sync)
            (nnhackernews--request-comment-page sync))
          sync))))

(defun nnhackernews--refresh-watched-threads (server)
  "Refresh recently watched threads for SERVER."
  (when (> nnhackernews-thread-refresh-days 0)
    (let ((cutoff (- (time-convert nil 'integer)
                     (* nnhackernews-thread-refresh-days 86400))))
      (dolist
          (row
           (sqlite-select
            nnhackernews--database
            "SELECT key FROM metadata
              WHERE key GLOB 'thread.*.watched_at'
                AND CAST(value AS INTEGER) >= ?"
            (vector cutoff)))
        (when (string-match "\\`thread\\.\\([0-9]+\\)\\.watched_at\\'"
                            (car row))
          (nnhackernews--start-comment-sync
           server (string-to-number (match-string 1 (car row))) 'new))))))

(defun nnhackernews--message-id (id)
  "Return a stable message ID for Hacker News ID."
  (format "<%d@ycombinator.com>" id))

(defun nnhackernews--item-from-message-id (message-id)
  "Return the cached item matching MESSAGE-ID."
  (when (string-match "\\`<\\([0-9]+\\)@ycombinator\\.com>\\'" message-id)
    (nnhackernews--item-by-id
     (string-to-number (match-string 1 message-id)))))

(defun nnhackernews--visible-p (item)
  "Return non-nil when ITEM should appear as a Gnus article."
  (and (= (plist-get item :deleted) 0)
       (= (plist-get item :dead) 0)))

(defun nnhackernews--references (item)
  "Return root and direct-parent message IDs for ITEM."
  (let ((parent (plist-get item :parent-id))
        (story (plist-get item :story-id)))
    (cond
     ((null parent) "")
     ((= parent story) (nnhackernews--message-id story))
     (t (format "%s %s"
                (nnhackernews--message-id story)
                (nnhackernews--message-id parent))))))

(defun nnhackernews--permalink (item)
  "Return the Hacker News permalink for ITEM."
  (format "%s/item?id=%d" nnhackernews--site-url (plist-get item :id)))

(defun nnhackernews--subject (item)
  "Return the story title or a body-derived comment subject for ITEM."
  (if (not (equal (plist-get item :type) "comment"))
      (nnextension-core-sanitize-header (plist-get item :title))
    (truncate-string-to-width
     (nnextension-core-sanitize-header
      (nnextension-core-html-to-text (plist-get item :text)))
     nnhackernews-reply-subject-length nil nil "…")))

(defun nnhackernews--make-header (item)
  "Create a Gnus mail header from cached ITEM."
  (when (nnhackernews--visible-p item)
    (make-full-mail-header
     (plist-get item :article-no)
     (nnhackernews--subject item)
     (nnextension-core-mail-from
      (plist-get item :author) "news.ycombinator.com")
     (format-time-string
      "%a, %d %b %Y %T %z"
      (seconds-to-time (plist-get item :created-at)))
     (nnhackernews--message-id (plist-get item :id))
     (nnhackernews--references item)
     (length (or (plist-get item :text) ""))
     (string-lines (or (plist-get item :text) ""))
     nil
     `((X-Hacker-News-ID . ,(number-to-string (plist-get item :id)))
       (X-Hacker-News-Story-ID
        . ,(number-to-string (plist-get item :story-id)))
       (X-Hacker-News-Score
        . ,(number-to-string (or (plist-get item :score) 0)))
       (X-Hacker-News-Comments
        . ,(number-to-string (or (plist-get item :descendants) 0)))
       (Archived-At . ,(nnhackernews--permalink item))))))

(defun nnhackernews--story-html (item)
  "Return the summary HTML used to display root story ITEM."
  (let* ((title (xml-escape-string (nnhackernews--subject item)))
         (author (xml-escape-string (plist-get item :author)))
         (permalink (xml-escape-string (nnhackernews--permalink item)))
         (external (plist-get item :url))
         (text (plist-get item :text)))
    (concat
     "<article><h1>" title "</h1>\n"
     "<p>By " author " · "
     (number-to-string (or (plist-get item :score) 0)) " points · "
     (number-to-string (or (plist-get item :descendants) 0))
     " comments</p>\n"
     (unless (string-empty-p (or text ""))
       (concat "<section>" text "</section>\n"))
     "<p>"
     (when (not (string-empty-p (or external "")))
       (format "<a href=\"%s\">Open original article</a> · "
               (xml-escape-string external)))
     (format "<a href=\"%s\">View on Hacker News</a></p></article>"
             permalink))))

(defun nnhackernews--group-stats (group)
  "Return visible article count, minimum, and maximum for GROUP."
  (car
   (sqlite-select
    nnhackernews--database
    "SELECT COUNT(*), COALESCE(MIN(article_no), 1),
            COALESCE(MAX(article_no), 0)
       FROM items
      WHERE group_name = ? AND deleted = 0 AND dead = 0"
    (vector group))))

(defun nnhackernews--possibly-open (server)
  "Select and, if necessary, open SERVER."
  (let ((server (or server (nnoo-current-server 'nnhackernews))))
    (unless server
      (error "No nnhackernews server selected"))
    (unless (and (nnoo-current-server-p 'nnhackernews server)
                 (sqlitep nnhackernews--database))
      (unless (nnhackernews-open-server server)
        (error "Could not open nnhackernews server %s" server)))
    server))

(nnoo-define-basics nnhackernews)

(deffoo nnhackernews-open-server (server &optional defs)
  "Open virtual SERVER using Gnus server definitions DEFS."
  (condition-case err
      (progn
        (nnoo-change-server 'nnhackernews server defs)
        (unless (sqlitep nnhackernews--database)
          (make-directory nnhackernews-directory t)
          (setq nnhackernews--database
                (sqlite-open
                 (nnextension-core-database-file
                  nnhackernews-directory server)))
          (nnhackernews--initialize-database nnhackernews--database))
        (nnheader-report 'nnhackernews "Opened Hacker News")
        t)
    (error
     (when (sqlitep nnhackernews--database)
       (sqlite-close nnhackernews--database)
       (setq nnhackernews--database nil))
     (nnheader-report 'nnhackernews "%s" (error-message-string err))
     nil)))

(deffoo nnhackernews-server-opened (&optional server)
  "Return non-nil when SERVER is the open nnhackernews server."
  (and (nnoo-current-server-p
        'nnhackernews
        (or server (nnoo-current-server 'nnhackernews)))
       (sqlitep nnhackernews--database)))

(deffoo nnhackernews-close-server (&optional server _defs)
  "Close SERVER and its database."
  (when (nnhackernews-server-opened server)
    (sqlite-close nnhackernews--database)
    (setq nnhackernews--database nil))
  (nnoo-close-server 'nnhackernews server))

(deffoo nnhackernews-close-group (_group &optional _server)
  "Close the current nnhackernews group."
  (setq nnhackernews--current-group nil)
  t)

(deffoo nnhackernews-request-close ()
  "Close all nnhackernews resources."
  (nnhackernews-close-server))

(deffoo nnhackernews-request-type (_group &optional _article)
  "Return the nnhackernews article type."
  'news)

(deffoo nnhackernews-status-message (&optional _server)
  "Return the latest nnhackernews status string."
  nnhackernews-status-string)

(deffoo nnhackernews-request-list (&optional server)
  "Insert the active Hacker News group list for SERVER."
  (nnhackernews--with-report
    (setq server (nnhackernews--possibly-open server))
    (when (zerop (caar (sqlite-select nnhackernews--database
                                      "SELECT COUNT(*) FROM items")))
      (nnhackernews--start-background-sync server))
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (entry nnhackernews--groups)
        (pcase-let ((`(,count ,minimum ,maximum)
                     (nnhackernews--group-stats (car entry))))
          (ignore count)
          (insert (format "%s %d %d y\n"
                          (car entry) maximum minimum)))))
    t))

(deffoo nnhackernews-request-list-newsgroups (&optional server)
  "Insert friendly Hacker News group descriptions for SERVER."
  (nnhackernews--with-report
    (nnhackernews--possibly-open server)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (entry nnhackernews--groups)
        (insert (format "%s\t%s\n" (car entry) (cdr entry)))))
    t))

(deffoo nnhackernews-retrieve-groups (_groups &optional server)
  "Retrieve active Hacker News data for SERVER."
  (and (nnhackernews-request-list server) 'active))

(deffoo nnhackernews-request-newgroups (_date &optional server)
  "Insert every static Hacker News group for SERVER."
  (nnhackernews-request-list server))

(deffoo nnhackernews-request-group
    (group &optional server _dont-check _info)
  "Select GROUP on SERVER."
  (nnhackernews--with-report
    (nnhackernews--possibly-open server)
    (setq nnhackernews--current-group group)
    (pcase-let ((`(,count ,minimum ,maximum)
                 (nnhackernews--group-stats group)))
      (nnheader-insert "211 %d %d %d %s\n"
                       count minimum maximum group))
    t))

(deffoo nnhackernews-request-scan (&optional _group server)
  "Start fetching Hacker News story roots for SERVER."
  (nnhackernews--with-report
    (setq server (nnhackernews--possibly-open server))
    (nnhackernews--start-background-sync server)
    (nnhackernews--refresh-watched-threads server)
    (nnheader-report 'nnhackernews "Hacker News sync running in background")
    t))

(deffoo nnhackernews-request-group-scan
    (_group &optional server _info)
  "Scan a Hacker News group on SERVER."
  (nnhackernews-request-scan nil server))

(deffoo nnhackernews-retrieve-group-data-early (server infos)
  "Start background retrieval for SERVER when INFOS is non-nil."
  (when infos
    (nnhackernews--start-background-sync
     (nnhackernews--possibly-open server))))

(deffoo nnhackernews-finish-retrieve-group-infos (server _infos _sync)
  "Publish cached group ranges for SERVER without waiting for _SYNC."
  (setq server (nnhackernews--possibly-open server))
  (nnhackernews--publish-active nnhackernews--database server)
  t)

(deffoo nnhackernews-retrieve-headers
    (articles &optional group server _fetch-old)
  "Insert NOV data for ARTICLES in GROUP on SERVER."
  (nnhackernews--with-report
    (nnhackernews--possibly-open server)
    (setq group (or group nnhackernews--current-group))
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (article (gnus-uncompress-sequence articles))
        (when-let* ((item (nnhackernews--item-by-article group article))
                    (header (nnhackernews--make-header item)))
          (nnheader-insert-nov header))))
    'nov))

(defun nnhackernews--schedule-reselect (group server)
  "Schedule a summary reselect for GROUP on SERVER."
  (let ((summary
         (get-buffer
          (gnus-summary-buffer-name
           (gnus-group-full-name group `(nnhackernews ,server))))))
    (when summary
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p summary)
           (with-current-buffer summary
             (when (equal (gnus-group-real-name gnus-newsgroup-name) group)
               (gnus-summary-reselect-current-group t nil)))))))))

(deffoo nnhackernews-request-article
    (article &optional group server buffer)
  "Retrieve ARTICLE from GROUP on SERVER into BUFFER."
  (nnhackernews--with-report
    (setq server (nnhackernews--possibly-open server))
    (setq group (or group nnhackernews--current-group))
    (let* ((item
            (if (stringp article)
                (nnhackernews--item-from-message-id article)
              (nnhackernews--item-by-article group article)))
           (root-p (and item (equal (plist-get item :type) "story"))))
      (unless item
        (error "No such Hacker News article: %s" article))
      (when root-p
        (nnhackernews--start-comment-sync
         server (plist-get item :story-id)
         (if (nnhackernews--comment-cursor
              nnhackernews--database (plist-get item :story-id) "newest")
             'new
           'latest)
         1 t))
      (let* ((header (nnhackernews--make-header item))
             (permalink (nnhackernews--permalink item)))
        (unless header
          (error "Hacker News article is deleted: %s" article))
        (nnextension-core-insert-html-article
         (or buffer nntp-server-buffer) group header permalink
         nnhackernews--site-url
         `(("X-Hacker-News-ID"
            . ,(number-to-string (plist-get item :id)))
           ("X-Hacker-News-Story-ID"
            . ,(number-to-string (plist-get item :story-id)))
           ("X-Hacker-News-Score"
            . ,(number-to-string (or (plist-get item :score) 0)))
           ("X-Hacker-News-Comments"
            . ,(number-to-string (or (plist-get item :descendants) 0))))
         (if (equal (plist-get item :type) "comment")
             (or (plist-get item :text)
                 "<p>This comment has no available body.</p>")
           (nnhackernews--story-html item)))
        (cons group (plist-get item :article-no))))))

(defun nnhackernews--current-location ()
  "Return (SERVER GROUP ARTICLE SUMMARY-BUFFER) at point."
  (let (group article summary)
    (cond
     ((derived-mode-p 'gnus-summary-mode)
      (setq group gnus-newsgroup-name
            article (gnus-summary-article-number)
            summary (current-buffer)))
     (gnus-article-current
      (setq group (car gnus-article-current)
            article (cdr gnus-article-current)
            summary gnus-summary-buffer))
     (t (user-error "No Gnus article at point")))
    (let ((method (gnus-find-method-for-group group)))
      (unless (eq (car method) 'nnhackernews)
        (user-error "Current article is not from nnhackernews"))
      (list (cadr method) (gnus-group-real-name group) article summary))))

;;;###autoload
(defun nnhackernews-refresh-thread ()
  "Start refreshing new comments for the thread at point."
  (interactive)
  (pcase-let* ((`(,server ,group ,article ,_summary)
                (nnhackernews--current-location)))
    (nnhackernews--possibly-open server)
    (let* ((item (or (nnhackernews--item-by-article group article)
                     (user-error "No cached Hacker News item at point")))
           (story-id (plist-get item :story-id)))
      (nnhackernews--start-comment-sync server story-id 'new 1 t)
      (message "Refreshing Hacker News comments in background"))))

;;;###autoload
(defun nnhackernews-fetch-older (&optional pages)
  "Fetch PAGES of older comments for the thread at point."
  (interactive "P")
  (pcase-let* ((`(,server ,group ,article ,_summary)
                (nnhackernews--current-location))
               (item (or (nnhackernews--item-by-article group article)
                         (user-error "No cached Hacker News item at point")))
               (pages (max 1 (prefix-numeric-value (or pages 1)))))
    (nnhackernews--possibly-open server)
    (nnhackernews--start-comment-sync
     server (plist-get item :story-id) 'older pages t)
    (message "Loading %d older Hacker News comment page%s in background"
             pages (if (= pages 1) "" "s"))))

(defun nnhackernews--current-group-p ()
  "Return non-nil when the current Gnus buffer uses nnhackernews."
  (let ((group (if (derived-mode-p 'gnus-summary-mode)
                   gnus-newsgroup-name
                 (car gnus-article-current))))
    (and group
         (eq (car-safe (gnus-find-method-for-group group))
             'nnhackernews))))

(defun nnhackernews--activate-mode ()
  "Update `nnhackernews-mode' for the current Gnus group."
  (nnhackernews-mode (if (nnhackernews--current-group-p) 1 -1)))

(add-hook 'gnus-summary-mode-hook #'nnhackernews--activate-mode)
(add-hook 'gnus-article-prepare-hook #'nnhackernews--activate-mode)

(nnoo-define-skeleton nnhackernews)
(gnus-declare-backend "nnhackernews" 'none)

(provide 'nnhackernews)

;;; nnhackernews.el ends here
