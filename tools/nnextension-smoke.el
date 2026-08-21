;;; nnextension-smoke.el --- Read-only smoke tests  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'nndiscourse)
(require 'nnhackernews)

(defun nnextension-smoke-discourse (url)
  "Read categories and recent posts from the Discourse instance at URL."
  (let* ((directory (make-temp-file "nnextension-discourse-smoke-" t))
         (nndiscourse-directory directory)
         (nndiscourse-base-url (string-trim-right url "/+"))
         (nndiscourse-auth-type 'anonymous)
         (nndiscourse--database (sqlite-open)))
    (unwind-protect
        (progn
          (nndiscourse--initialize-database nndiscourse--database)
          (let ((categories (nndiscourse--sync-categories))
                (posts (nndiscourse--fetch-post-page)))
            (unless categories
              (error "Discourse smoke test returned no categories"))
            (unless posts
              (error "Discourse smoke test returned no posts"))
            (princ
             (format "Discourse smoke: %d categories, %d recent posts\n"
                     (length categories) (length posts)))))
      (when (sqlitep nndiscourse--database)
        (sqlite-close nndiscourse--database))
      (delete-directory directory t))))

(defun nnextension-smoke-hackernews ()
  "Read recent Hacker News roots and one paginated comment batch."
  (let* ((directory (make-temp-file "nnextension-hn-smoke-" t))
         (nnhackernews-directory directory)
         (file (nnextension-core-database-file directory ""))
         nnhackernews--database
         (nnhackernews-feed-limit 2)
         story-id roots header comments)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'nnhackernews--publish-active) #'ignore))
            (nnhackernews--start-background-sync "")
            (url-queue-run-queue)
            (while (> (hash-table-count nnhackernews--background-syncs) 0)
              (accept-process-output nil 0.05)
              (url-queue-run-queue)))
          (setq nnhackernews--database (sqlite-open file)
                roots
                (caar
                 (sqlite-select
                  nnhackernews--database
                  "SELECT COUNT(*) FROM items WHERE type != 'comment'"))
                story-id
                (caar
                 (sqlite-select
                  nnhackernews--database
                  "SELECT id FROM items
                    WHERE type != 'comment'
                    ORDER BY descendants DESC, id DESC LIMIT 1"))
                header (nnhackernews--make-header
                        (nnhackernews--item-by-id story-id)))
          (unless (and story-id (> roots 0) header)
            (error "Hacker News smoke test returned no stories"))
          (sqlite-close nnhackernews--database)
          (setq nnhackernews--database nil)
          (cl-letf (((symbol-function 'nnhackernews--publish-active) #'ignore)
                    ((symbol-function 'nnhackernews--schedule-reselect) #'ignore))
            (nnhackernews--start-comment-sync "" story-id 'latest 1 t)
            (url-queue-run-queue)
            (while (> (hash-table-count nnhackernews--comment-syncs) 0)
              (accept-process-output nil 0.05)
              (url-queue-run-queue)))
          (setq nnhackernews--database (sqlite-open file)
                comments
                (caar
                 (sqlite-select
                  nnhackernews--database
                  "SELECT COUNT(*) FROM items WHERE type = 'comment'")))
          (unless (<= comments nnhackernews-comment-page-size)
            (error "Hacker News smoke test fetched more than one page"))
          (princ
           (format "Hacker News smoke: %d roots, story %d, %d comments\n"
                   roots story-id comments)))
      (when (sqlitep nnhackernews--database)
        (sqlite-close nnhackernews--database))
      (delete-directory directory t))))

(provide 'nnextension-smoke)

;;; nnextension-smoke.el ends here
