;;; nndiscourse-test.el --- Tests for nndiscourse  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'nndiscourse)

(defmacro nndiscourse-test--with-database (&rest body)
  "Run BODY with a fresh in-memory nndiscourse database."
  (declare (indent 0) (debug t))
  `(let ((nndiscourse--database (sqlite-open))
         (nndiscourse-base-url "https://forum.example")
         (nndiscourse-auth-type 'anonymous)
         (nndiscourse-cache-refresh-interval 300)
         (nndiscourse-initial-sync-limit 500))
     (unwind-protect
         (progn
           (nndiscourse--initialize-database nndiscourse--database)
           ,@body)
       (when (sqlitep nndiscourse--database)
         (sqlite-close nndiscourse--database)))))

(cl-defun nndiscourse-test--post
    (id &key (category 1) (topic 10) (number 1) parent
        (title "A useful topic") (username "alice") liked
        (can-like t) (can-unlike liked)
        (can-edit t) (can-delete t))
  "Return a representative Discourse post fixture."
  `(:id ,id
    :category_id ,category
    :topic_id ,topic
    :topic_slug "a-useful-topic"
    :topic_title ,title
    :post_number ,number
    :reply_to_post_number ,parent
    :username ,username
    :display_username ,(capitalize username)
    :created_at "2026-07-20T12:34:56.000Z"
    :updated_at "2026-07-20T12:34:56.000Z"
    :raw "Raw **Markdown**"
    :cooked "<p>Raw <strong>Markdown</strong></p>"
    :post_url ,(format "/t/a-useful-topic/%d/%d" topic number)
    :deleted_at nil
    :can_edit ,can-edit
    :can_delete ,can-delete
    :yours t
    :actions_summary
    (,(append
       '(:id 2 :count 3)
       (when can-like '(:can_act t))
       (when liked '(:acted t))
       (when can-unlike '(:can_undo t))))))

(defun nndiscourse-test--http-buffer (status body)
  "Return a URL response buffer with STATUS and BODY."
  (let ((buffer (generate-new-buffer " *nndiscourse HTTP test*")))
    (with-current-buffer buffer
      (set-buffer-multibyte t)
      (insert (format "HTTP/1.1 %d Test\r\nContent-Type: application/json\r\n\r\n"
                      status))
      (setq-local url-http-response-status status)
      (setq-local url-http-end-of-headers (copy-marker (point)))
      (insert body))
    buffer))

(ert-deftest nndiscourse-test-dense-article-numbers-are-persistent ()
  (nndiscourse-test--with-database
    (let ((first (nndiscourse--upsert-post
                  (nndiscourse-test--post 101)))
          (second (nndiscourse--upsert-post
                   (nndiscourse-test--post 205 :number 2)))
          (other (nndiscourse--upsert-post
                  (nndiscourse-test--post
                   150 :category 2 :topic 11 :number 1))))
      (should (= (plist-get first :article-no) 1))
      (should (= (plist-get second :article-no) 2))
      (should (= (plist-get other :article-no) 1))
      (let ((updated
             (nndiscourse--upsert-post
              (nndiscourse-test--post 101 :title "Renamed"))))
        (should (= (plist-get updated :article-no) 1))
        (should (equal (plist-get updated :topic-title) "Renamed"))))))

(ert-deftest nndiscourse-test-database-adds-like-permission-columns ()
  (let ((database (sqlite-open)))
    (unwind-protect
        (progn
          (sqlite-execute
           database "CREATE TABLE posts (remote_id INTEGER PRIMARY KEY)")
          (nndiscourse--initialize-database database)
          (let ((columns
                 (mapcar
                  (lambda (row) (nth 1 row))
                  (sqlite-select database "PRAGMA table_info(posts)"))))
            (should (member "like_can_act" columns))
            (should (member "like_can_undo" columns))))
      (sqlite-close database))))

(ert-deftest nndiscourse-test-message-ids-and-references-are-deterministic ()
  (nndiscourse-test--with-database
    (let* ((root
            (nndiscourse--upsert-post
             (nndiscourse-test--post 101 :topic 44 :number 1)))
           (direct
            (nndiscourse--upsert-post
             (nndiscourse-test--post
              102 :topic 44 :number 2 :parent 1)))
           (nested
            (nndiscourse--upsert-post
             (nndiscourse-test--post
              103 :topic 44 :number 3 :parent 2))))
      (should
       (equal (nndiscourse--message-id-for
               (plist-get root :topic-id)
               (plist-get root :post-number))
              "<discourse.topic-44.post-1@forum.example>"))
      (should (equal (nndiscourse--references root) ""))
      (should
       (equal (nndiscourse--references direct)
              "<discourse.topic-44.post-1@forum.example>"))
      (should
       (equal
        (nndiscourse--references nested)
        (concat "<discourse.topic-44.post-1@forum.example> "
                "<discourse.topic-44.post-2@forum.example>"))))))

(ert-deftest nndiscourse-test-empty-display-name-falls-back-to-username ()
  (let ((nndiscourse-base-url "https://emacs-china.org"))
    (should
     (equal
      (nndiscourse--from
       '(:username "kukmp7g72jn9" :display-name ""))
      "\"kukmp7g72jn9\" <kukmp7g72jn9@emacs-china.org>"))))

(ert-deftest nndiscourse-test-replies-use-body-derived-subjects ()
  (nndiscourse-test--with-database
    (let* ((nndiscourse-reply-subject-length 12)
           (root
            (nndiscourse--upsert-post
             (nndiscourse-test--post 101 :number 1)))
           (reply
            (nndiscourse--upsert-post
             (nndiscourse-test--post 102 :number 2))))
      (plist-put
       reply :cooked
       (concat
        "<aside class=\"quote\"><p>Old quoted text</p></aside>"
        "<p>Hello <code>world</code> &amp; friends.</p>"
        "<div class=\"meta\">image metadata</div>"))
      (should (equal (nndiscourse--subject root) "A useful topic"))
      (should (equal (nndiscourse--body-text reply)
                     "Hello world & friends."))
      (should (equal (nndiscourse--subject reply) "Hello world…"))
      (plist-put reply :cooked "")
      (plist-put reply :raw "  A fallback\n\nsubject  ")
      (should (equal (nndiscourse--subject reply)
                     "A fallback…"))
      (plist-put reply :raw "")
      (should (equal (nndiscourse--subject reply) "A useful topic")))))

(ert-deftest nndiscourse-test-browse-buffer-shows-category-names ()
  (nndiscourse-test--with-database
    (sqlite-execute
     nndiscourse--database
     "INSERT INTO categories
        (id, slug, name, description, parent_id, position, refreshed_at)
      VALUES (12, 'programming', 'Programming', '', NULL, 1, 0)")
    (with-temp-buffer
      (gnus-browse-mode)
      (let ((inhibit-read-only t)
            (gnus-browse-current-method '(nndiscourse "test")))
        (insert "      16: category.12\n")
        (add-text-properties
         (point-min) (1+ (point-min)) '(gnus-group "category.12"))
        (nndiscourse--decorate-browse-buffer)
        (should (equal (buffer-string)
                       "      16: Programming [category.12]\n"))
        (should (equal (get-text-property (point-min) 'gnus-group)
                       "category.12"))))))

(ert-deftest nndiscourse-test-authentication-header-selection ()
  (let ((nndiscourse-base-url "https://forum.example"))
    (let ((nndiscourse-auth-type 'anonymous))
      (should-not (nndiscourse--auth-headers)))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _)
                 (list
                  (list :user "alice"
                        :secret (lambda () "api-secret"))))))
      (let ((nndiscourse-auth-type 'api-key))
        (should
         (equal (nndiscourse--auth-headers)
                '(("Api-Key" . "api-secret")
                  ("Api-Username" . "alice")))))
      (let ((nndiscourse-auth-type 'user-api-key))
        (should
         (equal (nndiscourse--auth-headers)
                '(("User-Api-Key" . "api-secret"))))))))

(ert-deftest nndiscourse-test-auto-detects-stored-user-api-key ()
  (nndiscourse-test--with-database
    (nndiscourse--metadata-set "user_api_client_id" "stable-client")
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _)
                 (list
                  (list :user "user-api-key"
                        :secret (lambda () "user-secret"))))))
      (let ((nndiscourse-auth-type 'auto))
        (should
         (equal
          (nndiscourse--auth-headers)
          '(("User-Api-Key" . "user-secret")
            ("User-Api-Client-Id" . "stable-client"))))))))

(ert-deftest nndiscourse-test-authorization-url-and-payload-extraction ()
  (let* ((nndiscourse-base-url "https://forum.example")
         (url (nndiscourse--authorization-url
               "PUBLIC+KEY\n" "nonce-value" "client-value")))
    (should (string-prefix-p
             "https://forum.example/user-api-key/new?" url))
    (should (string-match-p "application_name=nndiscourse" url))
    (should (string-match-p "client_id=client-value" url))
    (should (string-match-p "nonce=nonce-value" url))
    (should (string-match-p "scopes=write" url))
    (should-not (string-match-p "padding=" url))
    (should (string-match-p "public_key=PUBLIC%2BKEY%0A" url))
    (should-not (string-match-p "public_key=[^&]*[+]" url))
    (should
     (equal
      (nndiscourse--extract-authorization-payload
       "https://callback.example/?payload=abc%2Bdef%3D&other=x")
      "abc+def="))
    (should
     (equal (nndiscourse--extract-authorization-payload
             " payload=abc%2Fdef%3D ")
            "abc/def="))))

(ert-deftest nndiscourse-test-authorization-uses-external-browser ()
  (let ((browse-url-browser-function #'eww-browse-url)
        call)
    (cl-letf (((symbol-function 'browse-url-with-browser-kind)
               (lambda (kind url &optional _arg)
                 (setq call (list kind url)))))
      (nndiscourse--browse-authorization-url "https://forum.example/auth")
      (should
       (equal call '(external "https://forum.example/auth"))))))

(ert-deftest nndiscourse-test-read-server-ignores-internal-placeholder ()
  (let ((gnus-secondary-select-methods
         '((nndiscourse "emacs-china"
                        (nndiscourse-base-url
                         "https://emacs-china.org")))))
    (cl-letf (((symbol-function 'nnoo-current-server)
               (lambda (&rest _) "*internal-non-initialized-backend*")))
      (should (equal (nndiscourse--read-server) "emacs-china")))))

(ert-deftest nndiscourse-test-rsa-authorization-payload-round-trip ()
  (skip-unless (executable-find "openssl"))
  (let ((private-key-file (make-temp-file "nndiscourse-test-key-"))
        (public-key-file (make-temp-file "nndiscourse-test-pub-"))
        (nonce "test-nonce")
        (key "0123456789abcdef0123456789abcdef")
        ciphertext)
    (unwind-protect
        (progn
          (nndiscourse--make-private-key private-key-file)
          (with-temp-file public-key-file
            (insert (nndiscourse--public-key private-key-file)))
          (setq ciphertext
                (nndiscourse--openssl
                 (json-serialize `(:key ,key :nonce ,nonce
                                   :push :false :api 4))
                 "pkeyutl" "-encrypt" "-pubin"
                 "-inkey" public-key-file
                 "-pkeyopt" "rsa_padding_mode:pkcs1"))
          (should
           (equal
            (nndiscourse--decrypt-authorization-payload
             (base64-encode-string ciphertext t)
             private-key-file nonce)
            key))
          (should-error
           (nndiscourse--decrypt-authorization-payload
            (base64-encode-string ciphertext t)
            private-key-file "wrong-nonce")
           :type 'user-error))
      (dolist (file (list private-key-file public-key-file))
        (when (file-exists-p file)
          (delete-file file))))))

(ert-deftest nndiscourse-test-user-api-key-is-saved-to-authinfo ()
  (let* ((auth-file (make-temp-file "nndiscourse-test-authinfo-"))
         (decoy-file (make-temp-file "nndiscourse-test-authinfo-decoy-"))
         (nndiscourse-auth-source-file auth-file)
         (nndiscourse-base-url "https://forum.example")
         (auth-source-netrc-cache nil))
    (unwind-protect
        (progn
          (with-temp-file decoy-file
            (insert
             (concat
              "machine forum.example port discourse "
              "login alice password wrong-key\n")))
          (nndiscourse--save-user-api-key "first-key")
          (nndiscourse--save-user-api-key "replacement-key")
          (with-temp-buffer
            (insert-file-contents auth-file)
            (should
             (string-prefix-p
              (concat
               "machine forum.example port discourse "
               "login user-api-key password replacement-key\n")
              (buffer-string))))
          (should (= (file-modes auth-file) #o600))
          (auth-source-forget-all-cached)
          (let ((auth-sources (list decoy-file auth-file))
                (nndiscourse-auth-type 'user-api-key))
            (should
             (equal (nndiscourse--auth-headers)
                    '(("User-Api-Key" . "replacement-key"))))))
      (auth-source-forget-all-cached)
      (dolist (file (list auth-file decoy-file))
        (when (file-exists-p file)
          (delete-file file))))))

(ert-deftest nndiscourse-test-http-json-and-errors ()
  (let ((nndiscourse-base-url "https://forum.example")
        (nndiscourse-auth-type 'anonymous))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (nndiscourse-test--http-buffer
                  200 "{\"ok\":true,\"items\":[1,2]}"))))
      (should
       (equal (nndiscourse--request "GET" "/ok.json")
              '(:ok t :items (1 2)))))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (nndiscourse-test--http-buffer
                  422 "{\"errors\":[\"Title is too short\"]}"))))
      (let ((error (should-error
                    (nndiscourse--request "POST" "/posts.json"
                                         :data '(:raw "x"))
                    :type 'nndiscourse-http-error)))
        (should (= (nth 1 error) 422))
        (should (equal (nth 2 error) "Title is too short"))))
    (should-error
     (nndiscourse--request "POST" "/posts.json"
                           :data '(:raw "x") :authenticated t)
     :type 'nndiscourse-error)))

(ert-deftest nndiscourse-test-http-request-is-unibyte-and-errors-are-safe ()
  (nndiscourse-test--with-database
    (let ((nndiscourse-auth-type 'user-api-key)
          (secret (string-to-multibyte "user-api-secret"))
          request-data request-headers)
      (nndiscourse--metadata-set
       "user_api_client_id" "multibyte-sqlite-client")
      (cl-letf
          (((symbol-function 'auth-source-search)
            (lambda (&rest _)
              (list
               (list :user "user-api-key"
                     :secret (lambda () secret)))))
           ((symbol-function 'url-retrieve-synchronously)
            (lambda (&rest _)
              (setq request-data url-request-data
                    request-headers url-request-extra-headers)
              (nndiscourse-test--http-buffer 200 "{\"ok\":true}"))))
        (should
         (equal
          (nndiscourse--request
           "POST" "/posts.json" :data '(:raw "中文回复")
           :authenticated t)
          '(:ok t)))
        (should-not (multibyte-string-p request-data))
        (should
         (equal
          (plist-get
           (json-parse-string
            (decode-coding-string request-data 'utf-8)
            :object-type 'plist)
           :raw)
          "中文回复"))
        (dolist (header request-headers)
          (should-not (multibyte-string-p (car header)))
          (should-not (multibyte-string-p (cdr header)))))
      (cl-letf
          (((symbol-function 'auth-source-search)
            (lambda (&rest _)
              (list
               (list :user "user-api-key"
                     :secret (lambda () secret)))))
           ((symbol-function 'url-retrieve-synchronously)
            (lambda (&rest _)
              (error
               (concat
                "Multibyte text in HTTP request: POST /posts.json"
                "\nUser-Api-Key: " secret "\n\nprivate body")))))
        (let* ((error
                (should-error
                 (nndiscourse--request
                  "POST" "/posts.json" :data '(:raw "private body")
                  :authenticated t)
                 :type 'nndiscourse-http-error))
               (message (nth 2 error)))
          (should-not (string-match-p (regexp-quote secret) message))
          (should-not (string-match-p "private body" message))
          (should-not (string-match-p "\n" message)))))))

(ert-deftest nndiscourse-test-category-sync-flattens-subcategories ()
  (nndiscourse-test--with-database
    (cl-letf (((symbol-function 'nndiscourse--request)
               (lambda (&rest _)
                 '(:category_list
                   (:categories
                    ((:id 1 :slug "parent" :name "Parent"
                      :description_text "Top"
                      :position 1
                      :subcategory_list
                      ((:id 2 :slug "child" :name "Child"
                        :description_text "Nested"
                        :parent_category_id 1 :position 2)))))))))
      (nndiscourse--sync-categories)
      (should
       (equal
        (sqlite-select
         nndiscourse--database
         "SELECT id, name, parent_id FROM categories
           WHERE id > 0 ORDER BY id")
        '((1 "Parent" nil) (2 "Child" 1)))))))

(ert-deftest nndiscourse-test-initial-and-incremental-sync ()
  (nndiscourse-test--with-database
    (let ((nndiscourse-initial-sync-limit 3)
          (initial
           (list (nndiscourse-test--post 3 :number 3)
                 (nndiscourse-test--post 2 :number 2)
                 (nndiscourse-test--post 1 :number 1))))
      (cl-letf (((symbol-function 'nndiscourse--fetch-post-page)
                 (lambda (&optional before)
                   (unless before initial))))
        (should (= (nndiscourse--initial-sync) 3)))
      (should
       (equal
        (sqlite-select nndiscourse--database
                       "SELECT remote_id, article_no FROM posts
                         ORDER BY article_no")
        '((1 1) (2 2) (3 3))))
      (cl-letf (((symbol-function 'nndiscourse--fetch-post-page)
                 (lambda (&optional before)
                   (unless before
                     (list (nndiscourse-test--post 5 :number 5)
                           (nndiscourse-test--post 4 :number 4)
                           (nndiscourse-test--post 3 :number 3))))))
        (should (= (nndiscourse--incremental-sync) 2)))
      (should
       (equal
        (sqlite-select nndiscourse--database
                       "SELECT remote_id, article_no FROM posts
                         ORDER BY article_no")
        '((1 1) (2 2) (3 3) (4 4) (5 5)))))))

(ert-deftest nndiscourse-test-nov-and-html-article-generation ()
  (nndiscourse-test--with-database
    (let* ((post
            (nndiscourse--upsert-post
             (nndiscourse-test--post 101 :topic 44 :number 1)))
           (nntp-server-buffer (get-buffer-create
                                " *nndiscourse article test*")))
      (unwind-protect
          (cl-letf (((symbol-function 'nndiscourse--possibly-open)
                     #'ignore))
            (should
             (equal
              (nndiscourse-request-article
               (plist-get post :article-no) "category.1" "test"
               nntp-server-buffer)
              '("category.1" . 1)))
            (with-current-buffer nntp-server-buffer
              (goto-char (point-min))
              (should (search-forward
                       "Message-ID: <discourse.topic-44.post-1@forum.example>"
                       nil t))
              (should (search-forward
                       "Content-Type: text/html; charset=utf-8" nil t))
              (should (search-forward
                       "<p>Raw <strong>Markdown</strong></p>" nil t))))
        (kill-buffer nntp-server-buffer)))))

(ert-deftest nndiscourse-test-new-topic-and-reply-payloads ()
  (nndiscourse-test--with-database
    (let (calls)
      (cl-letf (((symbol-function 'nndiscourse--possibly-open) #'ignore)
                ((symbol-function 'nndiscourse--request)
                 (lambda (method path &rest options)
                   (push (list method path options) calls)
                   (nndiscourse-test--post
                    (if (plist-get (plist-get options :data) :topic_id)
                        102 101)
                    :topic 44
                    :number
                    (if (plist-get (plist-get options :data) :topic_id)
                        2 1)))))
        (with-temp-buffer
          (insert "Newsgroups: category.1\n"
                  "Subject: A useful topic\n\n"
                  "New topic body\n")
          (should (nndiscourse-request-post "test")))
        (should
         (equal
          (plist-get (nth 2 (car calls)) :data)
          '(:title "A useful topic" :raw "New topic body" :category 1)))
        (with-temp-buffer
          (insert "Newsgroups: category.1\n"
                  "Subject: Re: A useful topic\n"
                  "References: "
                  "<discourse.topic-44.post-1@forum.example>\n\n"
                  "Reply body\n")
          (should (nndiscourse-request-post "test")))
        (should
         (equal
          (plist-get (nth 2 (car calls)) :data)
          '(:raw "Reply body" :topic_id 44
            :reply_to_post_number 1)))))))

(ert-deftest nndiscourse-test-message-body-decoding-and-multipart-rejection ()
  (with-temp-buffer
    (insert "Content-Type: text/plain; charset=utf-8\n"
            "Content-Transfer-Encoding: quoted-printable\n\n"
            "caf=C3=A9\n")
    (should (equal (nndiscourse--decode-message-body) "café\n")))
  (with-temp-buffer
    (insert "Content-Type: multipart/mixed; boundary=x\n\n"
            "--x\nContent-Type: text/plain\n\nbody\n--x--\n")
    (should-error (nndiscourse--decode-message-body)))
  (with-temp-buffer
    (insert "Content-Type: text/html; charset=utf-8\n\n<p>body</p>\n")
    (should-error (nndiscourse--decode-message-body))))

(ert-deftest nndiscourse-test-expiry-matches-mail-semantics ()
  (nndiscourse-test--with-database
    (nndiscourse--upsert-post
     (nndiscourse-test--post 101 :can-delete t))
    (let (deleted)
      (cl-letf (((symbol-function 'nndiscourse--possibly-open) #'ignore)
                ((symbol-function 'nndiscourse--request)
                 (lambda (method path &rest _)
                   (if (equal method "GET")
                       (nndiscourse-test--post 101 :can-delete t)
                     (push (cons method path) deleted)
                     nil)))
                ((symbol-function 'nnmail-expired-article-p)
                 (lambda (_group _time force &optional _inhibit)
                   force)))
        (should
         (equal
          (nndiscourse-request-expire-articles
           '(1) "category.1" "test" nil)
          '(1)))
        (should-not deleted)
        (should-not
         (nndiscourse-request-expire-articles
          '(1) "category.1" "test" t))
        (should
         (equal deleted '(("DELETE" . "/posts/101.json"))))
        (should
         (= (plist-get (nndiscourse--post-by-remote-id 101) :deleted)
            1))))))

(ert-deftest nndiscourse-test-raw-markdown-edit-submit ()
  (nndiscourse-test--with-database
    (let* ((post
            (nndiscourse--upsert-post
             (nndiscourse-test--post 101 :can-edit t)))
           (buffer (generate-new-buffer " *nndiscourse edit test*"))
           request)
      (unwind-protect
          (cl-letf (((symbol-function 'nndiscourse--possibly-open)
                     #'ignore)
                    ((symbol-function 'nndiscourse--request)
                     (lambda (method path &rest options)
                       (setq request (list method path options))
                       `(:post
                         ,(plist-put
                           (nndiscourse-test--post 101 :can-edit t)
                           :raw "Edited Markdown")))))
            (with-current-buffer buffer
              (insert "Edited Markdown")
              (nndiscourse-edit-post-mode)
              (setq-local
               nndiscourse--edit-context
               `(:server "test" :group "category.1" :article 1
                 :summary-buffer nil :post ,post))
              (nndiscourse-edit-submit))
            (should-not (buffer-live-p buffer))
            (should
             (equal (seq-take request 2)
                    '("PUT" "/posts/101.json")))
            (should
             (equal (plist-get (nth 2 request) :data)
                    '(:post (:raw "Edited Markdown")))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest nndiscourse-test-like-and-notification-requests ()
  (nndiscourse-test--with-database
    (let ((post (nndiscourse--upsert-post
                 (nndiscourse-test--post 101)))
          calls updated)
      (cl-letf (((symbol-function 'nndiscourse--current-post)
                 (lambda (&optional _) post))
                ((symbol-function 'nndiscourse--request)
                 (lambda (method path &rest options)
                   (push (list method path options) calls)
                   (nndiscourse-test--post 101 :liked t)))
                ((symbol-function 'nndiscourse--update-current-summary-line)
                 (lambda (value) (setq updated value))))
        (nndiscourse-toggle-like)
        (should
         (equal
          (seq-take (car calls) 2)
          '("POST" "/post_actions.json")))
        (should (= (plist-get updated :liked) 1))
        (should
         (equal
          (substring-no-properties
           (nndiscourse-summary-liked-mark
            (nndiscourse--make-header updated)))
          "♥"))
        (nndiscourse-set-topic-notification-level 3)
        (should
         (equal
          (seq-take (car calls) 2)
          '("POST" "/t/10/notifications.json")))
        (should
         (equal
          (plist-get (nth 2 (car calls)) :data)
          '(:notification_level "3")))))
    (cl-letf (((symbol-function 'nndiscourse--current-post)
               (lambda (&optional _)
                 (nndiscourse--upsert-post
                  (nndiscourse-test--post
                   102 :topic 11 :can-like nil)))))
      (should-error
       (nndiscourse-toggle-like) :type 'user-error))
    (cl-letf (((symbol-function 'nndiscourse--current-post)
               (lambda (&optional _)
                 (nndiscourse--upsert-post
                  (nndiscourse-test--post
                   103 :topic 12 :liked t :can-unlike nil)))))
      (should-error
       (nndiscourse-toggle-like) :type 'user-error))))

(provide 'nndiscourse-test)

;;; nndiscourse-test.el ends here
