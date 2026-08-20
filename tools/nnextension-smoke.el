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
  "Read recent Hacker News roots and one comment thread."
  (let ((nnhackernews--database (sqlite-open))
        (nnhackernews-feed-limit 2))
    (unwind-protect
        (progn
          (nnhackernews--initialize-database nnhackernews--database)
          (let* ((roots (nnhackernews--sync-stories))
                 (story-id
                  (caar
                   (sqlite-select
                    nnhackernews--database
                    "SELECT id FROM items
                      WHERE type != 'comment'
                      ORDER BY descendants DESC, id DESC LIMIT 1"))))
            (unless (and story-id (> roots 0))
              (error "Hacker News smoke test returned no stories"))
            (let* ((new (nnhackernews--sync-thread story-id))
                   (root (nnhackernews--item-by-id story-id))
                   (header (nnhackernews--make-header root)))
              (unless (and header
                           (equal (mail-header-id header)
                                  (nnhackernews--message-id story-id)))
                (error "Hacker News smoke test produced an invalid header"))
              (princ
               (format "Hacker News smoke: %d roots, story %d, %d comments\n"
                       roots story-id new)))))
      (when (sqlitep nnhackernews--database)
        (sqlite-close nnhackernews--database)))))

(provide 'nnextension-smoke)

;;; nnextension-smoke.el ends here
