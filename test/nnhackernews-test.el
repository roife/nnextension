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

(ert-deftest nnhackernews-test-persistent-numbers-and-classification ()
  (nnhackernews-test--with-database
    (let ((news
           (nnhackernews--upsert-item
            (nnhackernews-test--story 101) "news" 101))
          (ask
           (nnhackernews--upsert-item
            (nnhackernews-test--story
             102 :title "Ask HN: Advice?" :tags '("story" "ask_hn"))
            "news" 102))
          (show
           (nnhackernews--upsert-item
            (nnhackernews-test--story 103 :title "Show HN: Tool")
            "news" 103)))
      (should (= (plist-get news :article-no) 1))
      (should (equal (plist-get ask :group-name) "ask"))
      (should (= (plist-get ask :article-no) 1))
      (should (equal (plist-get show :group-name) "show"))
      (let ((updated
             (nnhackernews--upsert-item
              (nnhackernews-test--story 101 :title "Updated" :points 20)
              "news" 101)))
        (should (= (plist-get updated :article-no) 1))
        (should (equal (plist-get updated :title) "Updated"))
        (should (= (plist-get updated :score) 20))))))

(ert-deftest nnhackernews-test-feed-sync-and-official-fallback ()
  (nnhackernews-test--with-database
    (let ((nnhackernews-feed-limit 2)
          fallback-calls)
      (cl-letf
          (((symbol-function 'nnhackernews--firebase-request)
            (lambda (path)
              (pcase path
                ("newstories" '(1 2 3 5))
                ("askstories" '(2))
                ("showstories" '(3))
                ("jobstories" '(4))
                ("item/1"
                 (push 1 fallback-calls)
                 '(:id 1 :type "story" :by "fallback"
                   :time 1787000001 :title "Official fallback"
                   :score 7 :descendants 0))
                (_ nil))))
           ((symbol-function 'nnhackernews--algolia-root-hits)
            (lambda (group ids)
              (if (equal group "job")
                  (list
                   (nnhackernews-test--story
                    4 :title "Example is hiring" :tags '("job")))
                (delq
                 nil
                 (mapcar
                  (lambda (id)
                    (pcase id
                      (2 (nnhackernews-test--story
                          2 :title "Ask HN: Test"
                          :tags '("story" "ask_hn")))
                      (3 (nnhackernews-test--story
                          3 :title "Show HN: Test"
                          :tags '("story" "show_hn")))
                      (5 (nnhackernews-test--story 5 :title "Regular"))))
                  ids))))))
        (should (= (nnhackernews--sync-stories) 5))
        (should (equal fallback-calls '(1)))
        (should
         (equal
          (sqlite-select
           nnhackernews--database
           "SELECT id, group_name FROM items ORDER BY id")
          '((1 "news") (2 "ask") (3 "show") (4 "job") (5 "news"))))
        (let ((first-number
               (plist-get (nnhackernews--item-by-id 1) :article-no)))
          (should (integerp first-number))
          (nnhackernews--upsert-item
           '(:id 1 :type "story" :by "fallback" :time 1787000001
             :title "Updated fallback" :score 8)
           "news" 1)
          (should
           (= (plist-get (nnhackernews--item-by-id 1) :article-no)
              first-number)))))))

(ert-deftest nnhackernews-test-thread-sync-and-visible-references ()
  (nnhackernews-test--with-database
    (nnhackernews--upsert-item
     (nnhackernews-test--story 100 :comments 2) "news" 100)
    (let* ((deleted
            (nnhackernews-test--comment
             101 100 100 :author nil :text nil
             :children
             (list (nnhackernews-test--comment
                    102 100 101 :text "Nested response"))))
           (remote
            (nnhackernews-test--story
             100 :comments 2 :children (list deleted))))
      (cl-letf (((symbol-function 'nnhackernews--algolia-request)
                 (lambda (&rest _) remote)))
        (should (= (nnhackernews--sync-thread 100) 1)))
      (let ((root (nnhackernews--item-by-id 100))
            (hidden (nnhackernews--item-by-id 101))
            (nested (nnhackernews--item-by-id 102)))
        (should (integerp (plist-get root :thread-fetched-at)))
        (should-not (nnhackernews--visible-p hidden))
        (should
         (equal (nnhackernews--references nested)
                "<100@ycombinator.com>"))
        (should (equal (nnhackernews--subject nested) "Nested response"))))))

(ert-deftest nnhackernews-test-message-headers-and-summary-html ()
  (nnhackernews-test--with-database
    (let* ((item
            (nnhackernews--upsert-item
             (nnhackernews-test--story
              100 :title "Safe\r\nInjected"
              :text "<p>Self text</p>" :points 42 :comments 9)
             "news" 100))
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

(ert-deftest nnhackernews-test-first-open-fetches-thread-once ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "news" 100))
           (article (plist-get root :article-no))
           (output (get-buffer-create " *nnhackernews article test*"))
           (sync-count 0)
           (reselect-count 0))
      (unwind-protect
          (cl-letf
              (((symbol-function 'nnhackernews--possibly-open) #'ignore)
               ((symbol-function 'nnhackernews--sync-thread)
                (lambda (story-id)
                  (cl-incf sync-count)
                  (sqlite-execute
                   nnhackernews--database
                   "UPDATE items SET thread_fetched_at = 1 WHERE id = ?"
                   (vector story-id))
                  1))
               ((symbol-function 'nnhackernews--schedule-reselect)
                (lambda (_group _server) (cl-incf reselect-count))))
            (should
             (equal
              (nnhackernews-request-article
               article "news" "" output)
              '("news" . 1)))
            (should
             (equal
              (nnhackernews-request-article
               article "news" "" output)
              '("news" . 1)))
            (should (= sync-count 1))
            (should (= reselect-count 1))
            (with-current-buffer output
              (goto-char (point-min))
              (should (search-forward
                       "Content-Type: text/html; charset=utf-8" nil t))
              (should (search-forward
                       "https://example.test/story" nil t))))
        (kill-buffer output)))))

(ert-deftest nnhackernews-test-reselects-the-real-summary-buffer ()
  (let* ((group "nnhackernews:show")
         (summary
          (get-buffer-create (gnus-summary-buffer-name group)))
         (reselects 0))
    (unwind-protect
        (progn
          (with-current-buffer summary
            (setq-local gnus-newsgroup-name group))
          (cl-letf
              (((symbol-function 'run-at-time)
                (lambda (_time _repeat function &rest arguments)
                  (apply function arguments)))
               ((symbol-function 'gnus-summary-reselect-current-group)
                (lambda (&rest _) (cl-incf reselects))))
            (let ((gnus-summary-buffer "*Summary*"))
              (nnhackernews--schedule-reselect "show" "")))
          (should (= reselects 1)))
      (kill-buffer summary))))

(ert-deftest nnhackernews-test-first-open-falls-back-to-cached-root ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "news" 100))
           (output (get-buffer-create " *nnhackernews cached article test*")))
      (unwind-protect
          (cl-letf
              (((symbol-function 'nnhackernews--possibly-open) #'ignore)
               ((symbol-function 'nnhackernews--sync-thread)
                (lambda (&rest _)
                  (signal 'nnextension-core-http-error
                          '(503 "unavailable")))))
            (should
             (equal
              (nnhackernews-request-article
               (plist-get root :article-no) "news" "" output)
              '("news" . 1)))
            (should-not
             (plist-get (nnhackernews--item-by-id 100) :thread-fetched-at))
            (with-current-buffer output
              (goto-char (point-min))
              (should (search-forward "A useful story" nil t))))
        (kill-buffer output)))))

(ert-deftest nnhackernews-test-gnus-read-protocol ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "news" 100))
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
              (should (search-forward "news 1 1 y" nil t))
              (should (search-forward "job 0 1 y" nil t)))
            (should (nnhackernews-request-list-newsgroups ""))
            (with-current-buffer nntp-server-buffer
              (goto-char (point-min))
              (should (search-forward "news\tNew Stories" nil t))
              (should (search-forward "job\tJobs" nil t)))
            (with-current-buffer nntp-server-buffer
              (erase-buffer)
              (should (nnhackernews-request-group "news" ""))
              (should (equal (buffer-string) "211 1 1 1 news\n")))
            (should
             (eq
              (nnhackernews-retrieve-headers
               (list (plist-get root :article-no)) "news" "")
              'nov))
            (with-current-buffer nntp-server-buffer
              (goto-char (point-min))
              (should (search-forward "A useful story" nil t))))
        (kill-buffer nntp-server-buffer)))))

(ert-deftest nnhackernews-test-manual-refresh-reselects-summary ()
  (nnhackernews-test--with-database
    (let* ((root
            (nnhackernews--upsert-item
             (nnhackernews-test--story 100) "news" 100))
           (summary (generate-new-buffer " *nnhackernews summary test*"))
           (refreshes 0)
           (reselects 0))
      (unwind-protect
          (cl-letf
              (((symbol-function 'nnhackernews--current-location)
                (lambda ()
                  (list "" "news" (plist-get root :article-no) summary)))
               ((symbol-function 'nnhackernews--possibly-open) #'ignore)
               ((symbol-function 'nnhackernews--sync-thread)
                (lambda (_story-id) (cl-incf refreshes) 2))
               ((symbol-function 'gnus-summary-reselect-current-group)
                (lambda (&rest _) (cl-incf reselects))))
            (nnhackernews-refresh-thread)
            (should (= refreshes 1))
            (should (= reselects 1)))
        (kill-buffer summary)))))

(ert-deftest nnhackernews-test-group-scan-starts-background-sync ()
  (nnhackernews-test--with-database
    (let ((background-scans 0)
          (thread-scans 0))
      (cl-letf (((symbol-function 'nnhackernews--possibly-open) #'identity)
                ((symbol-function 'nnhackernews--start-background-sync)
                 (lambda (_server) (cl-incf background-scans)))
                ((symbol-function 'nnhackernews--sync-thread)
                 (lambda (&rest _) (cl-incf thread-scans))))
        (should (nnhackernews-request-scan nil ""))
        (should (= background-scans 1))
        (should (= thread-scans 0))))))

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
  (should-not (fboundp 'nnhackernews-request-expire-articles)))

(provide 'nnhackernews-test)

;;; nnhackernews-test.el ends here
