;;; nnhackernews-test.el --- Tests for nnhackernews  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'nnhackernews)

(defmacro nnhackernews-test--with-database (&rest body)
  "Run BODY with a fresh in-memory nnhackernews database."
  (declare (indent 0) (debug t))
  `(let ((nnhackernews--database (sqlite-open))
         (nnhackernews-feed-limit 100)
         (nnhackernews-request-timeout 30))
     (unwind-protect
         (progn
           (nnhackernews--initialize-database nnhackernews--database)
           ,@body)
       (when (sqlitep nnhackernews--database)
         (sqlite-close nnhackernews--database)))))

(cl-defun nnhackernews-test--story
    (id &key (title "A useful story") (author "alice")
        (time 1787000000) (points 10) (comments 2)
        (url "https://example.test/story") text tags children)
  "Return a representative Algolia story fixture."
  `(:id ,id :type "story" :author ,author :created_at_i ,time
    :title ,title :points ,points :num_comments ,comments :url ,url
    :text ,text :_tags ,(or tags '("story")) :children ,children))

(cl-defun nnhackernews-test--comment
    (id story parent &key (author "bob") (time 1787000100)
        (text "A helpful <b>comment</b>.") children)
  "Return a representative Algolia comment fixture."
  `(:id ,id :type "comment" :author ,author :created_at_i ,time
    :story_id ,story :parent_id ,parent :text ,text :children ,children))

(ert-deftest nnhackernews-test-persistent-top-article-numbers ()
  (nnhackernews-test--with-database
    (let ((first
           (nnhackernews--upsert-item
            (nnhackernews-test--story 101) "top" 101))
          (second
           (nnhackernews--upsert-item
            (nnhackernews-test--story 102 :title "Ask HN: Advice?")
            "top" 102))
          (third
           (nnhackernews--upsert-item
            (nnhackernews-test--story 103 :title "Show HN: Tool")
            "top" 103)))
      (should (= (plist-get first :article-no) 1))
      (should (= (plist-get second :article-no) 2))
      (should (= (plist-get third :article-no) 3))
      (let ((updated
             (nnhackernews--upsert-item
              (nnhackernews-test--story 101 :title "Updated" :points 20)
              "top" 101)))
        (should (= (plist-get updated :article-no) 1))
        (should (equal (plist-get updated :title) "Updated"))
        (should (= (plist-get updated :score) 20))))))

(ert-deftest nnhackernews-test-background-roots-are-persistent ()
  (nnhackernews-test--with-database
    (let* ((ids '(1 2 3 4 5))
           (table (make-hash-table :test #'eql)))
      (dolist
          (story
           (list
            (nnhackernews-test--story 1 :title "Regular one")
            (nnhackernews-test--story 5 :title "Regular five")
            (nnhackernews-test--story
             2 :title "Ask HN: Test" :tags '("story" "ask_hn"))
            (nnhackernews-test--story
             3 :title "Show HN: Test" :tags '("story" "show_hn"))
            (nnhackernews-test--story
             4 :title "Example is hiring" :tags '("job"))))
        (puthash (nnhackernews--remote-id story) story table))
      (should
       (= (nnhackernews--store-roots
           nnhackernews--database
           (nnhackernews--background-roots ids table))
          5))
      (should
       (equal
        (sqlite-select
         nnhackernews--database
         "SELECT id, group_name FROM items ORDER BY id")
        '((1 "top") (2 "top") (3 "top") (4 "top") (5 "top"))))
      (let ((article (plist-get (nnhackernews--item-by-id 1) :article-no)))
        (nnhackernews--upsert-item
         (nnhackernews-test--story 1 :title "Updated") "top" 1)
        (should (= (plist-get (nnhackernews--item-by-id 1) :article-no)
                   article))))))

(ert-deftest nnhackernews-test-paged-comments-use-sparse-references ()
  (nnhackernews-test--with-database
    (nnhackernews--upsert-item
     (nnhackernews-test--story 100 :comments 2) "top" 100)
    (nnhackernews--upsert-item
     (nnhackernews-test--comment 101 100 100 :author nil :text nil)
     "top" 100)
    (nnhackernews--upsert-item
     (nnhackernews-test--comment 102 100 101 :text "Nested response")
     "top" 100)
    (let ((root (nnhackernews--item-by-id 100))
          (hidden (nnhackernews--item-by-id 101))
          (nested (nnhackernews--item-by-id 102)))
      (should root)
      (should-not (nnhackernews--visible-p hidden))
      (should
       (equal (nnhackernews--references nested)
              "<100@ycombinator.com> <101@ycombinator.com>"))
      (should (equal (nnhackernews--subject nested) "Nested response")))))

(ert-deftest nnhackernews-test-comment-cursors-drive-dynamic-queries ()
  (nnhackernews-test--with-database
    (nnhackernews--upsert-item
     (nnhackernews-test--story 100 :comments 2) "top" 100)
    (let ((sync
           (make-nnhackernews--comment-sync
            :server "" :database nnhackernews--database
            :story-id 100 :group "top" :mode 'latest
            :remaining 1 :page 0 :new-count 0)))
      (should
       (= (nnhackernews--store-comment-hits
           sync
           (list
            (nnhackernews-test--comment 101 100 100 :time 1000)
            (nnhackernews-test--comment 102 100 100 :time 2000)))
          2))
      (should (= (nnhackernews--comment-cursor
                  nnhackernews--database 100 "oldest") 1000))
      (should (= (nnhackernews--comment-cursor
                  nnhackernews--database 100 "newest") 2000))
      (setf (nnhackernews--comment-sync-mode sync) 'older)
      (should
       (string-match-p "created_at_i%3C1000"
                       (nnhackernews--comment-url sync)))
      (setf (nnhackernews--comment-sync-mode sync) 'new)
      (should
       (string-match-p "created_at_i%3E%3D2000"
                       (nnhackernews--comment-url sync))))))

(ert-deftest nnhackernews-test-message-headers-and-summary-html ()
  (nnhackernews-test--with-database
    (let* ((item
            (nnhackernews--upsert-item
             (nnhackernews-test--story
              100 :title "Safe\r\nInjected"
              :text "<p>Self text</p>" :points 42 :comments 9)
             "top" 100))
           (header (nnhackernews--make-header item))
           (html (nnhackernews--story-html item)))
      (should (equal (mail-header-subject header) "Safe Injected"))
      (should (equal (mail-header-id header) "<100@ycombinator.com>"))
      (should (string-match-p "alice@news.ycombinator.com"
                              (mail-header-from header)))
      (should (string-match-p "42 points" html))
      (should (string-match-p "9 comments" html))
      (should (string-match-p "Self text" html))
      (should (string-match-p "Open original article" html))
      (should (string-match-p "View on Hacker News" html)))))

(ert-deftest nnhackernews-test-first-open-starts-paged-comment-load ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "top" 100))
           (article (plist-get root :article-no))
           (output (get-buffer-create " *nnhackernews article test*"))
           call)
      (unwind-protect
          (cl-letf
              (((symbol-function 'nnhackernews--possibly-open) #'identity)
               ((symbol-function 'nnhackernews--start-comment-sync)
                (lambda (&rest arguments) (setq call arguments))))
            (should
             (equal
              (nnhackernews-request-article
               article "top" "" output)
              '("top" . 1)))
            (should (equal call '("" 100 latest 1 t)))
            (with-current-buffer output
              (goto-char (point-min))
              (should (search-forward
                       "Content-Type: text/html; charset=utf-8" nil t))
              (should (search-forward
                       "https://example.test/story" nil t))))
        (kill-buffer output)))))

(ert-deftest nnhackernews-test-updates-the-real-summary-buffer ()
  (let* ((group "nnhackernews:top")
         (summary
          (get-buffer-create (gnus-summary-buffer-name group)))
         (updates 0)
         cache-only)
    (unwind-protect
        (progn
          (with-current-buffer summary
            (setq-local gnus-newsgroup-name group))
          (cl-letf
              (((symbol-function 'run-at-time)
                (lambda (_time _repeat function &rest arguments)
                  (apply function arguments)))
               ((symbol-function 'gnus-summary-insert-new-articles)
                (lambda ()
                  (setq cache-only nnhackernews--cache-only-scan)
                  (cl-incf updates))))
            (let ((gnus-summary-buffer "*Summary*"))
              (nnhackernews--schedule-summary-update "top" "")))
          (should (= updates 1))
          (should cache-only))
      (kill-buffer summary))))

(ert-deftest nnhackernews-test-gnus-read-protocol ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "top" 100))
           (nntp-server-buffer
            (get-buffer-create " *nnhackernews protocol test*")))
      (unwind-protect
          (cl-letf
              (((symbol-function 'nnhackernews--possibly-open) #'identity)
               ((symbol-function 'nnhackernews--start-background-sync)
                #'ignore))
            (should (nnhackernews-request-list ""))
            (with-current-buffer nntp-server-buffer
              (goto-char (point-min))
              (should (search-forward "top 1 1 y" nil t)))
            (should (nnhackernews-request-list-newsgroups ""))
            (with-current-buffer nntp-server-buffer
              (goto-char (point-min))
              (should (search-forward "top\tTop Stories" nil t)))
            (with-current-buffer nntp-server-buffer
              (erase-buffer)
              (should (nnhackernews-request-group "top" ""))
              (should (equal (buffer-string) "211 1 1 1 top\n")))
            (should
             (eq
              (nnhackernews-retrieve-headers
               (list (plist-get root :article-no)) "top" "")
              'nov))
            (with-current-buffer nntp-server-buffer
              (goto-char (point-min))
              (should (search-forward "A useful story" nil t))))
        (kill-buffer nntp-server-buffer)))))

(ert-deftest nnhackernews-test-manual-refresh-starts-new-comment-load ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "top" 100))
           call)
      (cl-letf
          (((symbol-function 'nnhackernews--current-location)
            (lambda () (list "" "top" (plist-get root :article-no) nil)))
           ((symbol-function 'nnhackernews--possibly-open) #'identity)
           ((symbol-function 'nnhackernews--start-comment-sync)
            (lambda (&rest arguments) (setq call arguments))))
        (nnhackernews-refresh-thread)
        (should (equal call '("" 100 new 1 t)))))))

(ert-deftest nnhackernews-test-fetch-older-honors-prefix ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "top" 100))
           call)
      (cl-letf
          (((symbol-function 'nnhackernews--current-location)
            (lambda () (list "" "top" (plist-get root :article-no) nil)))
           ((symbol-function 'nnhackernews--possibly-open) #'identity)
           ((symbol-function 'nnhackernews--start-comment-sync)
            (lambda (&rest arguments) (setq call arguments))))
        (nnhackernews-fetch-older 3)
        (should (equal call '("" 100 older 3 t)))))))

(ert-deftest nnhackernews-test-fetch-older-reports-exhausted-thread ()
  (nnhackernews-test--with-database
    (let ((root
           (nnhackernews--upsert-item
            (nnhackernews-test--story 100) "top" 100))
          message)
      (cl-letf
          (((symbol-function 'nnhackernews--current-location)
            (lambda () (list "" "top" (plist-get root :article-no) nil)))
           ((symbol-function 'nnhackernews--possibly-open) #'identity)
           ((symbol-function 'nnhackernews--start-comment-sync) #'ignore)
           ((symbol-function 'message)
            (lambda (format-string &rest arguments)
              (setq message (apply #'format format-string arguments)))))
        (nnhackernews-fetch-older)
        (should (equal message
                       "All older Hacker News comments are already loaded"))))))

(ert-deftest nnhackernews-test-group-scan-starts-background-sync ()
  (nnhackernews-test--with-database
    (let ((background-scans 0)
          (watched-scans 0))
      (cl-letf (((symbol-function 'nnhackernews--possibly-open) #'identity)
                ((symbol-function 'nnhackernews--start-background-sync)
                 (lambda (_server) (cl-incf background-scans)))
                ((symbol-function 'nnhackernews--refresh-watched-threads)
                 (lambda (_server) (cl-incf watched-scans))))
        (should (nnhackernews-request-scan nil ""))
        (should (= background-scans 1))
        (should (= watched-scans 1))))))

(ert-deftest nnhackernews-test-early-finish-does-not-wait ()
  (let ((task 'background-task)
        (published 0))
    (cl-letf (((symbol-function 'nnhackernews--possibly-open) #'identity)
              ((symbol-function 'nnhackernews--start-background-sync)
               (lambda (_server) task))
              ((symbol-function 'nnhackernews--publish-active)
               (lambda (&rest _) (cl-incf published))))
      (should-not (nnhackernews-retrieve-group-data-early "" nil))
      (should
       (eq (nnhackernews-retrieve-group-data-early "" '((info))) task))
      (should (nnhackernews-finish-retrieve-group-infos "" '((info)) task))
      (should (= published 1)))))

(ert-deftest nnhackernews-test-backend-is-read-only ()
  (should (member 'none (cdr (assoc "nnhackernews"
                                    gnus-valid-select-methods))))
  ;; nnoo generates explicit "not implemented" stubs for absent methods.
  (let (reports)
    (cl-letf (((symbol-function 'nnheader-report)
               (lambda (&rest args) (push args reports) nil)))
      (should-not (nnhackernews-request-post ""))
      (should
       (seq-every-p
        (lambda (report)
          (string-match-p "not implemented" (cadr report)))
        reports))))
  (should-not (fboundp 'nnhackernews-request-expire-articles))
  (should-not (fboundp 'nnhackernews--sync-thread)))

(provide 'nnhackernews-test)

;;; nnhackernews-test.el ends here
