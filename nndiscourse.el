;;; nndiscourse.el --- Gnus backend for Discourse forums  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nnextension contributors

;; Author: nnextension contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.0"))
;; Keywords: news, hypermedia
;; URL: https://github.com/roife/nnextension
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; nndiscourse exposes Discourse categories as Gnus groups and posts as
;; threaded Gnus articles.  See the README for setup and authentication.

;;; Code:

(require 'auth-source)
(require 'browse-url)
(require 'cl-lib)
(require 'dom)
(require 'gnus)
(require 'gnus-int)
(require 'gnus-msg)
(require 'gnus-range)
(require 'gnus-srvr)
(require 'json)
(require 'mail-parse)
(require 'message)
(require 'mm-decode)
(require 'nnheader)
(require 'nnmail)
(require 'nnoo)
(require 'nnextension-core)
(require 'seq)
(require 'shr)
(require 'sqlite)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'url-util)

(declare-function gnus-summary-article-number "gnus-sum")
(declare-function gnus-summary-reselect-current-group "gnus-sum"
                  (&optional all rescan))
(declare-function gnus-summary-rescan-group "gnus-sum" (&optional all))
(declare-function gnus-summary-update-article-line "gnus-sum"
                  (article header))

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defgroup nndiscourse nil
  "Read and write Discourse forums through Gnus."
  :group 'gnus)

(define-error 'nndiscourse-error "nndiscourse error")
(define-error 'nndiscourse-http-error "Discourse HTTP error"
  'nndiscourse-error)

(defmacro nndiscourse--with-report (&rest body)
  "Run BODY, reporting errors through the Gnus backend."
  (declare (indent 0) (debug t))
  `(nnextension-core-with-report 'nndiscourse ,@body))

(nnoo-declare nndiscourse)

(defcustom nndiscourse-directory
  (file-name-concat gnus-directory "nndiscourse")
  "Directory in which nndiscourse stores its SQLite databases."
  :type 'directory
  :group 'nndiscourse)

(defcustom nndiscourse-initial-sync-limit 500
  "Maximum number of posts fetched during the initial synchronization."
  :type '(integer 1)
  :group 'nndiscourse)

(defcustom nndiscourse-request-timeout 30
  "Maximum number of seconds to wait for a Discourse HTTP response."
  :type 'natnum
  :group 'nndiscourse)

(defcustom nndiscourse-cache-refresh-interval 300
  "Seconds before a displayed cached post is refreshed from Discourse.
A failed refresh leaves the cached article available."
  :type 'natnum
  :group 'nndiscourse)

(defcustom nndiscourse-reply-subject-length 72
  "Maximum number of characters in a reply's body-derived subject."
  :type '(integer 1)
  :group 'nndiscourse)

(defcustom nndiscourse-auth-source-file "~/.authinfo.gpg"
  "Auth-source netrc file in which User API Keys are stored.
The default uses GPG encryption.  Set this to \"~/.authinfo\" only when
unencrypted credential storage is intentional."
  :type 'file
  :group 'nndiscourse)

(dolist (variable '(nndiscourse-directory
                    nndiscourse-initial-sync-limit
                    nndiscourse-request-timeout
                    nndiscourse-cache-refresh-interval
                    nndiscourse-reply-subject-length
                    nndiscourse-auth-source-file))
  (nnoo-define variable nil))

(defvoo nndiscourse-base-url nil
  "Base URL of the Discourse forum.
When nil, use https and the Gnus virtual server name.")

(defvoo nndiscourse-auth-type 'auto
  "Authentication method.
Valid values are `auto', `anonymous', `api-key', and `user-api-key'.")

(defvoo nndiscourse--database nil)
(defvoo nndiscourse--current-group nil)
(defvoo nndiscourse-status-string "")

(defconst nndiscourse--page-size 50)

(defconst nndiscourse--auth-source-user "user-api-key")

(defconst nndiscourse--notification-levels
  '(("muted" . 0) ("normal" . 1) ("tracking" . 2) ("watching" . 3)))

(defconst nndiscourse--post-columns
  '(:remote-id :category-id :article-no :topic-id :topic-slug :topic-title
    :post-number :reply-to-post-number :username :display-name :created-at
    :updated-at :raw :cooked :post-url :deleted :can-edit :can-delete :yours
    :like-count :liked :like-can-act :like-can-undo :notification-level
    :fetched-at))

(defconst nndiscourse--post-select
  "SELECT remote_id, category_id, article_no, topic_id, topic_slug,
          topic_title, post_number, reply_to_post_number, username,
          display_name, created_at, updated_at, raw, cooked, post_url,
          deleted, can_edit, can_delete, yours, like_count, liked,
          like_can_act, like_can_undo, notification_level, fetched_at
     FROM posts WHERE ")

(defvar-keymap nndiscourse-edit-post-mode-map
  :doc "Keymap used while editing a Discourse post."
  :parent text-mode-map
  "C-c C-c" #'nndiscourse-edit-submit
  "C-c C-k" #'nndiscourse-edit-abort)

(define-derived-mode nndiscourse-edit-post-mode text-mode "Discourse-Edit"
  "Major mode for editing a Discourse post as raw Markdown."
  (setq-local require-final-newline nil
              header-line-format
              "Edit Discourse Markdown; C-c C-c saves, C-c C-k aborts"))

(defvar-local nndiscourse--edit-context nil)

(defvar-keymap nndiscourse-mode-map
  :doc "Bindings active in nndiscourse Gnus buffers."
  "C-c C-l" #'nndiscourse-toggle-like
  "C-c C-n" #'nndiscourse-set-topic-notification-level
  "C-c C-o" #'nndiscourse-fetch-older
  "<remap> <gnus-summary-edit-article>" #'nndiscourse-edit-post)

(define-minor-mode nndiscourse-mode
  "Minor mode enabled in Gnus buffers backed by nndiscourse."
  :lighter " Discourse"
  :keymap nndiscourse-mode-map)

(defun nndiscourse--sanitize-header (value)
  "Return VALUE without characters that can inject a mail header."
  (nnextension-core-sanitize-header value))

(defun nndiscourse--normalize-base-url (server)
  "Return the normalized base URL for SERVER."
  (string-trim-right
   (or nndiscourse-base-url (format "https://%s" server))
   "/+"))

(defun nndiscourse--server-host ()
  "Return the hostname of the current forum."
  (url-host (url-generic-parse-url nndiscourse-base-url)))

(defun nndiscourse--database-file (server)
  "Return the database file used for virtual SERVER."
  (nnextension-core-database-file nndiscourse-directory server))

(defun nndiscourse--ensure-column (database table column declaration)
  "Ensure TABLE in DATABASE has COLUMN with SQL DECLARATION."
  (nnextension-core-ensure-column database table column declaration))

(defun nndiscourse--initialize-database (database)
  "Create the nndiscourse schema in DATABASE."
  (nnextension-core-initialize-metadata database)
  (sqlite-execute
   database
   "CREATE TABLE IF NOT EXISTS categories (
      id INTEGER PRIMARY KEY,
      slug TEXT,
      name TEXT NOT NULL,
      description TEXT,
      parent_id INTEGER,
      position INTEGER,
      refreshed_at INTEGER NOT NULL
    )")
  (sqlite-execute
   database
   "CREATE TABLE IF NOT EXISTS posts (
      remote_id INTEGER PRIMARY KEY,
      category_id INTEGER NOT NULL,
      article_no INTEGER NOT NULL,
      topic_id INTEGER NOT NULL,
      topic_slug TEXT,
      topic_title TEXT NOT NULL,
      post_number INTEGER NOT NULL,
      reply_to_post_number INTEGER,
      username TEXT,
      display_name TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT,
      raw TEXT,
      cooked TEXT,
      post_url TEXT,
      deleted INTEGER NOT NULL DEFAULT 0,
      can_edit INTEGER NOT NULL DEFAULT 0,
      can_delete INTEGER NOT NULL DEFAULT 0,
      yours INTEGER NOT NULL DEFAULT 0,
      like_count INTEGER NOT NULL DEFAULT 0,
      liked INTEGER NOT NULL DEFAULT 0,
      like_can_act INTEGER NOT NULL DEFAULT 0,
      like_can_undo INTEGER NOT NULL DEFAULT 0,
      notification_level INTEGER,
      fetched_at INTEGER NOT NULL,
      UNIQUE(category_id, article_no),
      UNIQUE(topic_id, post_number)
    )")
  (nndiscourse--ensure-column
   database "posts" "like_can_act" "INTEGER NOT NULL DEFAULT 0")
  (nndiscourse--ensure-column
   database "posts" "like_can_undo" "INTEGER NOT NULL DEFAULT 0")
  (sqlite-execute
   database
   "INSERT INTO categories
      (id, slug, name, description, parent_id, position, refreshed_at)
    VALUES (0, 'uncategorized', 'Uncategorized',
            'Topics without a category', NULL, 0, ?)
    ON CONFLICT(id) DO NOTHING"
   (vector (time-convert nil 'integer))))

(defun nndiscourse--metadata-get (key)
  "Return the current database metadata value for KEY."
  (nnextension-core-metadata-get nndiscourse--database key))

(defun nndiscourse--metadata-set (key value)
  "Set current database metadata KEY to VALUE."
  (nnextension-core-metadata-set nndiscourse--database key value))

(defun nndiscourse--user-api-client-id ()
  "Return the persistent User API client ID, or nil without a database."
  (when (sqlitep nndiscourse--database)
    (nndiscourse--metadata-get "user_api_client_id")))

(defun nndiscourse--auth-headers ()
  "Return HTTP authentication headers for the current server."
  (unless (eq nndiscourse-auth-type 'anonymous)
    (let* ((user-api-key-p (eq nndiscourse-auth-type 'user-api-key))
           (preferred-source
            (expand-file-name nndiscourse-auth-source-file))
           (auth-sources
            (cond
             (user-api-key-p (list preferred-source))
             ((eq nndiscourse-auth-type 'auto)
              (cons preferred-source
                    (delete preferred-source (copy-sequence auth-sources))))
             (t auth-sources))))
      (when-let* ((entry
                   (car
                    (apply
                     #'auth-source-search
                     (append
                      (list :host (nndiscourse--server-host)
                            :port "discourse"
                            :max 1
                            :require '(:secret))
                      (when user-api-key-p
                        (list :user nndiscourse--auth-source-user))))))
                (secret (auth-info-password entry)))
        (let* ((user (plist-get entry :user))
               (user-api-key-p
                (or user-api-key-p
                    (and (eq nndiscourse-auth-type 'auto)
                         (equal user nndiscourse--auth-source-user)))))
          (if user-api-key-p
              (append
               `(("User-Api-Key" . ,secret))
               (when-let* ((client-id (nndiscourse--user-api-client-id)))
                 `(("User-Api-Client-Id" . ,client-id))))
            (when user
              `(("Api-Key" . ,secret)
                ("Api-Username" . ,user)))))))))

(defun nndiscourse--configured-method (server)
  "Return the configured nndiscourse method for SERVER."
  (seq-find
   (lambda (method)
     (and (eq (car-safe method) 'nndiscourse)
          (equal (cadr method) server)))
   gnus-secondary-select-methods))

(defun nndiscourse--configured-servers ()
  "Return configured nndiscourse virtual server names."
  (delq nil
        (mapcar
         (lambda (method)
           (when (eq (car-safe method) 'nndiscourse)
             (cadr method)))
         gnus-secondary-select-methods)))

(defun nndiscourse--read-server ()
  "Read a configured nndiscourse virtual server name."
  (let* ((current (nnoo-current-server 'nndiscourse))
         (current
          (and (stringp current)
               (not (string-prefix-p "*" current))
               current))
         (servers (delete-dups
                   (append (and current (list current))
                           (nndiscourse--configured-servers)))))
    (unless servers
      (user-error "No nndiscourse server is configured"))
    (if (= (length servers) 1)
        (car servers)
      (completing-read "Discourse server: " servers nil t nil nil current))))

(defun nndiscourse--open-configured-server (server)
  "Open configured nndiscourse SERVER and return its name."
  (unless (and (nnoo-current-server-p 'nndiscourse server)
               (sqlitep nndiscourse--database))
    (let ((method (nndiscourse--configured-method server)))
      (unless (and method
                   (nndiscourse-open-server server (cddr method)))
        (error "Could not open configured nndiscourse server %s" server))))
  server)

(cl-defun nndiscourse--openssl (&optional input &rest arguments)
  "Run OpenSSL with ARGUMENTS and optional binary INPUT.
Return its standard output as a unibyte string."
  (let ((program (or (executable-find "openssl")
                     (user-error "The openssl executable is required")))
        (stderr-file (make-temp-file "nndiscourse-openssl-"))
        status output)
    (unwind-protect
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (setq status
                (if input
                    (apply #'call-process-region
                           input nil program nil (list t stderr-file) nil
                           arguments)
                  (apply #'call-process
                         program nil (list t stderr-file) nil arguments))
                output (buffer-string))
          (unless (and (integerp status) (zerop status))
            (let ((detail
                   (with-temp-buffer
                     (insert-file-contents stderr-file)
                     (string-trim (buffer-string)))))
              (error "OpenSSL failed%s"
                     (if (string-empty-p detail)
                         ""
                       (format ": %s" detail)))))
          output)
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun nndiscourse--make-private-key (file)
  "Generate a temporary RSA private key in FILE."
  (nndiscourse--openssl
   nil "genpkey" "-algorithm" "RSA"
   "-pkeyopt" "rsa_keygen_bits:2048" "-out" file)
  (set-file-modes file #o600)
  file)

(defun nndiscourse--public-key (private-key-file)
  "Return the public key for PRIVATE-KEY-FILE in PEM format."
  (decode-coding-string
   (nndiscourse--openssl
    nil "pkey" "-in" private-key-file "-pubout")
   'utf-8))

(defun nndiscourse--random-hex ()
  "Return 32 cryptographically random bytes encoded as hexadecimal."
  (string-trim
   (decode-coding-string
    (nndiscourse--openssl nil "rand" "-hex" "32")
    'utf-8)))

(defun nndiscourse--authorization-client-id ()
  "Return or create the persistent client ID for the current server."
  (or (nndiscourse--user-api-client-id)
      (let ((client-id (concat "nndiscourse-" (nndiscourse--random-hex))))
        (nndiscourse--metadata-set "user_api_client_id" client-id)
        client-id)))

(defun nndiscourse--authorization-url (public-key nonce client-id)
  "Build a User API Key URL from PUBLIC-KEY, NONCE, and CLIENT-ID."
  (concat
   nndiscourse-base-url
   "/user-api-key/new?"
   (mapconcat
    (lambda (parameter)
      (format "%s=%s"
              (url-hexify-string (car parameter))
              (url-hexify-string (cadr parameter))))
    `(("application_name" "nndiscourse")
      ("client_id" ,client-id)
      ("nonce" ,nonce)
      ("scopes" "write")
      ("public_key" ,public-key))
    "&")))

(defun nndiscourse--browse-authorization-url (url)
  "Open authorization URL in an external web browser."
  (browse-url-with-browser-kind 'external url))

(defun nndiscourse--extract-authorization-payload (input)
  "Extract an encrypted User API Key payload from INPUT."
  (let ((input (string-trim input)))
    (cond
     ((string-match "[?&]payload=\\([^&#]+\\)" input)
      (url-unhex-string (match-string 1 input)))
     ((string-match "\\`payload=\\(.+\\)\\'" input)
      (url-unhex-string (match-string 1 input)))
     (t input))))

(defun nndiscourse--decrypt-authorization-payload
    (payload private-key-file nonce)
  "Decrypt PAYLOAD with PRIVATE-KEY-FILE and verify NONCE.
Return the User API Key contained in the payload."
  (let* ((ciphertext
          (condition-case nil
              (base64-decode-string
               (replace-regexp-in-string
                "[[:space:]]+" ""
                (nndiscourse--extract-authorization-payload payload)))
            (error
             (user-error "The authorization payload is not valid Base64"))))
         (plaintext
          (decode-coding-string
           (nndiscourse--openssl
            ciphertext "pkeyutl" "-decrypt"
            "-inkey" private-key-file
            "-pkeyopt" "rsa_padding_mode:pkcs1")
           'utf-8))
         (result
          (condition-case nil
              (json-parse-string
               plaintext :object-type 'plist :null-object nil
               :false-object :false)
            (json-parse-error
             (user-error "The decrypted authorization payload is invalid"))))
         (returned-nonce (plist-get result :nonce))
         (key (plist-get result :key)))
    (unless (and (stringp returned-nonce)
                 (string= returned-nonce nonce))
      (user-error "The authorization payload nonce does not match"))
    (unless (and (stringp key) (not (string-empty-p key)))
      (user-error "The authorization payload contains no User API Key"))
    key))

(defun nndiscourse--auth-source-line (host key)
  "Return a netrc auth-source line for HOST and User API KEY."
  (format "machine %s port discourse login %s password %s"
          host nndiscourse--auth-source-user key))

(defun nndiscourse--save-user-api-key (key)
  "Save User API KEY for the current server and return its authinfo file."
  (let* ((host (nndiscourse--server-host))
         (file (expand-file-name nndiscourse-auth-source-file))
         (auth-sources (list file))
         (auth-source-save-behavior t)
         (auth-source-creation-defaults `((secret . ,key)))
         (spec
          (list :host host :port "discourse"
                :user nndiscourse--auth-source-user
                :type 'netrc :max 1 :require '(:secret)))
         (existing (car (apply #'auth-source-search spec))))
    (make-directory (file-name-directory file) t)
    (if (and existing (equal (auth-info-password existing) key))
        file
      (if existing
          (auth-source-netrc-saver
           file (nndiscourse--auth-source-line host key))
        (let* ((created
                (car
                 (apply #'auth-source-search
                        (append spec (list :secret key :create t)))))
               (save-function (plist-get created :save-function)))
          (unless save-function
            (error "The auth-source backend cannot save to %s" file))
          (funcall save-function)))
      (auth-source-forget-all-cached)
      (let ((saved (car (apply #'auth-source-search spec))))
        (unless (and saved (equal (auth-info-password saved) key))
          (error "Could not verify the User API Key in %s" file)))
      file)))

;;;###autoload
(defun nndiscourse-authorize (&optional server)
  "Authorize nndiscourse for write access to SERVER.
Open Discourse in a browser, ask the user to copy the encrypted payload
back into Emacs, and store the resulting User API Key with auth-source."
  (interactive (list (nndiscourse--read-server)))
  (setq server (or server (nndiscourse--read-server)))
  (nndiscourse--open-configured-server server)
  (let* ((private-key-file (make-temp-file "nndiscourse-key-" nil ".pem"))
         (nonce (nndiscourse--random-hex))
         (client-id (nndiscourse--authorization-client-id))
         key auth-file)
    (unwind-protect
        (progn
          (nndiscourse--make-private-key private-key-file)
          (nndiscourse--browse-authorization-url
           (nndiscourse--authorization-url
            (nndiscourse--public-key private-key-file)
            nonce client-id))
          (message
           (concat
            "Log in, approve nndiscourse, click Copy API Key, "
            "then return to Emacs"))
          (setq key
                (nndiscourse--decrypt-authorization-payload
                 (read-passwd "Paste the copied encrypted payload: ")
                 private-key-file nonce)
                auth-file (nndiscourse--save-user-api-key key)
                nndiscourse-auth-type 'user-api-key)
          (message "Discourse authorization saved to %s" auth-file)
          auth-file)
      (when (file-exists-p private-key-file)
        (delete-file private-key-file)))))

(defun nndiscourse--json-error-message (data fallback)
  "Extract an error message from JSON DATA, or return FALLBACK."
  (let ((errors (plist-get data :errors)))
    (cond
     ((stringp errors) errors)
     (errors (string-join errors "; "))
     ((plist-get data :error))
     (t fallback))))

(cl-defun nndiscourse--request
    (method path &key data authenticated)
  "Send METHOD to PATH and return parsed JSON.
DATA is encoded as JSON.  When AUTHENTICATED is non-nil, fail before
the request if no credentials are configured."
  (let ((auth-headers (nndiscourse--auth-headers)))
    (when (and authenticated (null auth-headers))
      (signal 'nndiscourse-error
              '("Authentication is required for this operation")))
    (nnextension-core-json-request
     method (concat nndiscourse-base-url path)
     :data data
     :headers (append '(("User-Agent" . "nndiscourse/0.1"))
                      auth-headers)
     :timeout nndiscourse-request-timeout
     :error-type 'nndiscourse-http-error
     :service "Discourse"
     :error-message-function #'nndiscourse--json-error-message
     :sensitive-values (mapcar #'cdr auth-headers)
     :request-target path)))

(defun nndiscourse--category-list (categories)
  "Flatten CATEGORIES and their nested subcategory lists."
  (cl-mapcan
   (lambda (category)
     (cons category
           (nndiscourse--category-list
            (plist-get category :subcategory_list))))
   categories))

(defun nndiscourse--sync-categories ()
  "Refresh the current server's category metadata."
  (let* ((response
          (nndiscourse--request
           "GET" "/categories.json?include_subcategories=true"))
         (categories
          (nndiscourse--category-list
           (plist-get (plist-get response :category_list) :categories)))
         (now (time-convert nil 'integer)))
    (with-sqlite-transaction nndiscourse--database
      (dolist (category categories)
        (sqlite-execute
         nndiscourse--database
         "INSERT INTO categories
            (id, slug, name, description, parent_id, position, refreshed_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            slug = excluded.slug,
            name = excluded.name,
            description = excluded.description,
            parent_id = excluded.parent_id,
            position = excluded.position,
            refreshed_at = excluded.refreshed_at"
         (vector
          (plist-get category :id)
          (plist-get category :slug)
          (plist-get category :name)
          (plist-get category :description_text)
          (plist-get category :parent_category_id)
          (plist-get category :position)
          now))))
    categories))

(defun nndiscourse--find-post (where values)
  "Return the first cached post matching SQL WHERE with VALUES."
  (when-let*
      ((row
        (car
         (sqlite-select
          nndiscourse--database
          (concat nndiscourse--post-select where)
          values))))
    (cl-mapcan #'list nndiscourse--post-columns row)))

(defun nndiscourse--post-by-remote-id (remote-id)
  "Return the cached post identified by REMOTE-ID."
  (nndiscourse--find-post "remote_id = ?" (vector remote-id)))

(defun nndiscourse--group-category-id (group)
  "Return the numeric category ID encoded in GROUP."
  (when (and group (string-match "\\`category\\.\\([0-9]+\\)\\'" group))
    (string-to-number (match-string 1 group))))

(defun nndiscourse--post-by-article (group article)
  "Return the cached post for GROUP and local ARTICLE number."
  (when-let* ((category-id (nndiscourse--group-category-id group)))
    (nndiscourse--find-post
     "category_id = ? AND article_no = ?"
     (vector category-id article))))

(defun nndiscourse--post-by-topic-number (topic-id post-number)
  "Return the cached post in TOPIC-ID with POST-NUMBER."
  (nndiscourse--find-post
   "topic_id = ? AND post_number = ?"
   (vector topic-id post-number)))

(defun nndiscourse--next-article-number (category-id)
  "Return the next dense local article number for CATEGORY-ID."
  (caar
   (sqlite-select
    nndiscourse--database
    "SELECT COALESCE(MAX(article_no), 0) + 1
       FROM posts WHERE category_id = ?"
    (vector category-id))))

(defun nndiscourse--like-state (post)
  "Return the current user's like state and permissions for POST."
  (let ((action
         (seq-find
          (lambda (entry) (= (plist-get entry :id) 2))
          (plist-get post :actions_summary))))
    (list
     :count (or (plist-get action :count) 0)
     :liked (eq (plist-get action :acted) t)
     :can-act (eq (plist-get action :can_act) t)
     :can-undo (eq (plist-get action :can_undo) t))))

(defun nndiscourse--upsert-post (post &optional context)
  "Insert or update POST and return its cached representation.
CONTEXT supplies values omitted by single-post API responses."
  (let* ((remote-id (plist-get post :id))
         (existing (and remote-id
                        (nndiscourse--post-by-remote-id remote-id)))
         (category-id
          (or (plist-get post :category_id)
              (plist-get context :category-id)
              (plist-get existing :category-id)
              0))
         (topic-id
          (or (plist-get post :topic_id)
              (plist-get existing :topic-id)))
         (post-number
          (or (plist-get post :post_number)
              (plist-get existing :post-number)))
         (article-no
          (or (plist-get existing :article-no)
              (nndiscourse--next-article-number category-id)))
         (like-state (nndiscourse--like-state post))
         (now (time-convert nil 'integer)))
    (sqlite-execute
     nndiscourse--database
     "INSERT INTO posts
        (remote_id, category_id, article_no, topic_id, topic_slug,
         topic_title, post_number, reply_to_post_number, username,
         display_name, created_at, updated_at, raw, cooked, post_url,
         deleted, can_edit, can_delete, yours, like_count, liked,
         like_can_act, like_can_undo, notification_level, fetched_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
              ?, ?, ?, ?, ?, ?)
      ON CONFLICT(remote_id) DO UPDATE SET
        topic_slug = COALESCE(excluded.topic_slug, posts.topic_slug),
        topic_title = COALESCE(excluded.topic_title, posts.topic_title),
        reply_to_post_number = excluded.reply_to_post_number,
        username = COALESCE(excluded.username, posts.username),
        display_name = COALESCE(excluded.display_name, posts.display_name),
        updated_at = COALESCE(excluded.updated_at, posts.updated_at),
        raw = COALESCE(excluded.raw, posts.raw),
        cooked = COALESCE(excluded.cooked, posts.cooked),
        post_url = COALESCE(excluded.post_url, posts.post_url),
        deleted = excluded.deleted,
        can_edit = excluded.can_edit,
        can_delete = excluded.can_delete,
        yours = excluded.yours,
        like_count = excluded.like_count,
        liked = excluded.liked,
        like_can_act = excluded.like_can_act,
        like_can_undo = excluded.like_can_undo,
        fetched_at = excluded.fetched_at"
     (vector
      remote-id category-id article-no topic-id
      (plist-get post :topic_slug)
      (or (plist-get post :topic_title)
          (plist-get context :topic-title)
          (plist-get existing :topic-title))
      post-number
      (plist-get post :reply_to_post_number)
      (plist-get post :username)
      (plist-get post :display_username)
      (or (plist-get post :created_at)
          (plist-get existing :created-at))
      (plist-get post :updated_at)
      (plist-get post :raw)
      (plist-get post :cooked)
      (plist-get post :post_url)
      (if (or (plist-get post :deleted_at)
              (eq (plist-get post :user_deleted) t))
          1 0)
      (if (eq (plist-get post :can_edit) t) 1 0)
      (if (eq (plist-get post :can_delete) t) 1 0)
      (if (eq (plist-get post :yours) t) 1 0)
      (plist-get like-state :count)
      (if (plist-get like-state :liked) 1 0)
      (if (plist-get like-state :can-act) 1 0)
      (if (plist-get like-state :can-undo) 1 0)
      nil
      now))
    (nndiscourse--post-by-remote-id remote-id)))

(defun nndiscourse--fetch-post-page (&optional before)
  "Fetch a page of posts, optionally those before remote ID BEFORE."
  (plist-get
   (nndiscourse--request
    "GET"
    (if before
        (format "/posts.json?before=%d" before)
      "/posts.json"))
   :latest_posts))

(defun nndiscourse--post-id (post)
  "Return the remote ID from POST."
  (plist-get post :id))

(defun nndiscourse--insert-posts (posts)
  "Persist POSTS in ascending remote-ID order."
  (with-sqlite-transaction nndiscourse--database
    (dolist (post (seq-sort-by #'nndiscourse--post-id #'< posts))
      (nndiscourse--upsert-post post))))

(defun nndiscourse--initial-sync ()
  "Fetch the initial recent-post window for the current server."
  (let ((remaining nndiscourse-initial-sync-limit)
        before posts page oldest)
    (while (> remaining 0)
      (setq page (nndiscourse--fetch-post-page before))
      (if (null page)
          (setq remaining 0)
        (setq page (seq-take page remaining)
              posts (nconc posts page)
              oldest (seq-min (mapcar #'nndiscourse--post-id page))
              remaining (- remaining (length page)))
        (if (or (< (length page) nndiscourse--page-size)
                (equal before oldest))
            (setq remaining 0)
          (setq before oldest))))
    (when posts
      (nndiscourse--insert-posts posts)
      (let ((ids (mapcar #'nndiscourse--post-id posts)))
        (nndiscourse--metadata-set "newest_remote_id" (seq-max ids))
        (nndiscourse--metadata-set "oldest_remote_id" (seq-min ids))))
    (nndiscourse--metadata-set "initial_sync_complete" "1")
    (length posts)))

(defun nndiscourse--incremental-sync ()
  "Fetch posts newer than the current server cursor."
  (let ((cursor (string-to-number
                 (or (nndiscourse--metadata-get "newest_remote_id") "0")))
        before posts updates page done)
    (while (not done)
      (setq page (nndiscourse--fetch-post-page before))
      (if (null page)
          (setq done t)
        (let* ((minimum
                (seq-min (mapcar #'nndiscourse--post-id page)))
               (new
                (seq-filter
                 (lambda (post) (> (nndiscourse--post-id post) cursor))
                 page)))
          ;; Upserting the boundary page also refreshes recent edits.
          (setq posts (nconc posts new)
                updates (nconc updates page))
          (if (or (<= minimum cursor)
                  (equal before minimum))
              (setq done t)
            (setq before minimum)))))
    (when updates
      (nndiscourse--insert-posts updates))
    (when posts
      (nndiscourse--metadata-set
       "newest_remote_id"
       (seq-max (mapcar #'nndiscourse--post-id posts))))
    (length posts)))

(defun nndiscourse--fetch-older-pages (pages)
  "Fetch PAGES pages older than the current oldest cursor."
  (let ((before-string (nndiscourse--metadata-get "oldest_remote_id"))
        posts page done)
    (cl-loop repeat pages
             until done
             do
             (setq page
                   (nndiscourse--fetch-post-page
                    (and before-string (string-to-number before-string))))
             (if (null page)
                 (setq done t)
               (let ((oldest
                      (number-to-string
                       (seq-min (mapcar #'nndiscourse--post-id page)))))
                 (setq posts (nconc posts page))
                 (if (equal oldest before-string)
                     (setq done t)
                   (setq before-string oldest)))))
    (when posts
      (nndiscourse--insert-posts posts)
      (nndiscourse--metadata-set "oldest_remote_id" before-string))
    (length posts)))

(defun nndiscourse--message-id-for (topic-id post-number)
  "Return the Message-ID for TOPIC-ID and POST-NUMBER."
  (format "<discourse.topic-%d.post-%d@%s>"
          topic-id post-number (nndiscourse--server-host)))

(defun nndiscourse--references (post)
  "Return a Gnus References value for POST."
  (let ((number (plist-get post :post-number))
        (parent (plist-get post :reply-to-post-number))
        (topic (plist-get post :topic-id)))
    (cond
     ((= number 1) "")
     ((and parent (/= parent 1))
      (format "%s %s"
              (nndiscourse--message-id-for topic 1)
              (nndiscourse--message-id-for topic parent)))
     (t (nndiscourse--message-id-for topic 1)))))

(defun nndiscourse--permalink (post)
  "Return the absolute web URL for POST."
  (let ((url (plist-get post :post-url)))
    (cond
     ((and url (string-match-p "\\`https?://" url)) url)
     (url (concat nndiscourse-base-url url))
     (t
      (format "%s/t/%s/%d/%d"
              nndiscourse-base-url
              (or (plist-get post :topic-slug) "-")
              (plist-get post :topic-id)
              (plist-get post :post-number))))))

(defun nndiscourse--from (post)
  "Return a mail-style From value for POST."
  (nnextension-core-mail-from
   (plist-get post :username)
   (nndiscourse--server-host)
   (plist-get post :display-name)))

(defun nndiscourse--body-text (post)
  "Return POST's rendered body as compact plain text."
  (let ((cooked (plist-get post :cooked)))
    (if (string-empty-p (or cooked ""))
        (string-trim
         (replace-regexp-in-string
          "[[:space:]]+" " " (or (plist-get post :raw) "")))
      (nnextension-core-html-to-text cooked '("quote" "meta")))))

(defun nndiscourse--subject (post)
  "Return the topic title or a body-derived reply subject for POST."
  (let* ((topic-title
          (nndiscourse--sanitize-header (plist-get post :topic-title)))
         (body
          (and (> (or (plist-get post :post-number) 1) 1)
               (nndiscourse--sanitize-header
                (nndiscourse--body-text post)))))
    (if (string-empty-p (or body ""))
        topic-title
      (if (> (length body) nndiscourse-reply-subject-length)
          (let ((excerpt
                 (string-trim-right
                  (substring body 0 nndiscourse-reply-subject-length))))
            (when
                (and
                 (string-match
                  "\\`\\(.+\\)[[:space:]][^[:space:]]*\\'" excerpt)
                 (> (length (match-string 1 excerpt))
                    (/ nndiscourse-reply-subject-length 2)))
              (setq excerpt (match-string 1 excerpt)))
            (concat excerpt "…"))
        body))))

(defun nndiscourse-summary-liked-mark (header)
  "Return a heart when Discourse HEADER is liked by the current user."
  (if (equal
       (cdr (assq 'X-Discourse-Liked (mail-header-extra header)))
       "yes")
      (propertize "♥" 'face 'success)
    " "))

(defun nndiscourse--make-header (post)
  "Create a Gnus mail header from cached POST."
  (unless (= (plist-get post :deleted) 1)
    (make-full-mail-header
     (plist-get post :article-no)
     (nndiscourse--subject post)
     (nndiscourse--from post)
     (format-time-string
      "%a, %d %b %Y %T %z"
      (date-to-time (plist-get post :created-at)))
     (nndiscourse--message-id-for
      (plist-get post :topic-id)
      (plist-get post :post-number))
     (nndiscourse--references post)
     (length (or (plist-get post :cooked) ""))
     (string-lines (or (plist-get post :cooked) ""))
     nil
     `((X-Discourse-Post-ID
        . ,(number-to-string (plist-get post :remote-id)))
       (X-Discourse-Topic-ID
        . ,(number-to-string (plist-get post :topic-id)))
       (X-Discourse-Post-Number
        . ,(number-to-string (plist-get post :post-number)))
       (X-Discourse-Likes
        . ,(number-to-string (plist-get post :like-count)))
       (X-Discourse-Liked
        . ,(if (= (plist-get post :liked) 1) "yes" "no"))
       (Archived-At . ,(nndiscourse--permalink post))))))

(defun nndiscourse--refresh-post (post &optional force)
  "Refresh POST when stale, or when FORCE is non-nil.
Return the refreshed post, falling back to POST on transient errors."
  (if (and (not force)
           (< (- (time-convert nil 'integer)
                 (plist-get post :fetched-at))
              nndiscourse-cache-refresh-interval))
      post
    (condition-case err
        (nndiscourse--upsert-post
         (nndiscourse--request
          "GET" (format "/posts/%d.json" (plist-get post :remote-id)))
         post)
      (nndiscourse-http-error
       (if (= (nth 1 err) 404)
           (progn
             (sqlite-execute nndiscourse--database
                             "UPDATE posts SET deleted = 1 WHERE remote_id = ?"
                             (vector (plist-get post :remote-id)))
             (plist-put (copy-sequence post) :deleted 1))
         (nnheader-message
          3 "nndiscourse: using cached post after refresh failure: %s"
          (error-message-string err))
         post))
      (error
       (nnheader-message
        3 "nndiscourse: using cached post after refresh failure: %s"
        (error-message-string err))
       post))))

(defun nndiscourse--possibly-open (server)
  "Select and, if necessary, open SERVER."
  (let ((server (or server (nnoo-current-server 'nndiscourse))))
    (unless server
      (error "No nndiscourse server selected"))
    (unless (and (nnoo-current-server-p 'nndiscourse server)
                 (sqlitep nndiscourse--database))
      (unless (nndiscourse-open-server server)
        (error "Could not open nndiscourse server %s" server)))
    server))

(nnoo-define-basics nndiscourse)

(deffoo nndiscourse-open-server (server &optional defs)
  "Open virtual SERVER using Gnus server definitions DEFS."
  (condition-case err
      (progn
        (nnoo-change-server 'nndiscourse server defs)
        (setq nndiscourse-base-url
              (nndiscourse--normalize-base-url server))
        (unless (memq nndiscourse-auth-type
                      '(auto anonymous api-key user-api-key))
          (error "Invalid authentication type %S" nndiscourse-auth-type))
        (unless (sqlitep nndiscourse--database)
          (make-directory nndiscourse-directory t)
          (setq nndiscourse--database
                (sqlite-open (nndiscourse--database-file server)))
          (nndiscourse--initialize-database nndiscourse--database))
        (let ((stored-url (nndiscourse--metadata-get "base_url")))
          (when (and stored-url
                     (not (equal stored-url nndiscourse-base-url)))
            (error
             (concat "Server %s was previously associated with %s; "
                     "use a new virtual server name for %s")
             server stored-url nndiscourse-base-url))
          (unless stored-url
            (nndiscourse--metadata-set "base_url" nndiscourse-base-url)))
        (nnheader-report 'nndiscourse "Opened %s" nndiscourse-base-url)
        t)
    (error
     (when (sqlitep nndiscourse--database)
       (sqlite-close nndiscourse--database)
       (setq nndiscourse--database nil))
     (nnheader-report 'nndiscourse "%s" (error-message-string err))
     nil)))

(deffoo nndiscourse-server-opened (&optional server)
  "Return non-nil when SERVER is the open nndiscourse server."
  (and (nnoo-current-server-p
        'nndiscourse
        (or server (nnoo-current-server 'nndiscourse)))
       (sqlitep nndiscourse--database)))

(deffoo nndiscourse-close-server (&optional server _defs)
  "Close SERVER and its database."
  (when (nndiscourse-server-opened server)
    (sqlite-close nndiscourse--database)
    (setq nndiscourse--database nil))
  (nnoo-close-server 'nndiscourse server))

(deffoo nndiscourse-close-group (_group &optional _server)
  "Close the current nndiscourse group."
  (setq nndiscourse--current-group nil)
  t)

(deffoo nndiscourse-request-close ()
  "Close all nndiscourse resources."
  (nndiscourse-close-server))

(deffoo nndiscourse-request-type (_group &optional _article)
  "Return the nndiscourse article type."
  'news)

(deffoo nndiscourse-request-list (&optional server)
  "Insert the active group list for SERVER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (nndiscourse--sync-categories)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist
          (row
           (sqlite-select
            nndiscourse--database
            "SELECT c.id,
                    COALESCE(MIN(CASE WHEN p.deleted = 0
                                      THEN p.article_no END), 1),
                    COALESCE(MAX(CASE WHEN p.deleted = 0
                                      THEN p.article_no END), 0)
               FROM categories c
               LEFT JOIN posts p ON p.category_id = c.id
              GROUP BY c.id
              ORDER BY c.position, c.id"))
        (pcase-let ((`(,id ,minimum ,maximum) row))
          (insert (format "category.%d %d %d y\n"
                          id maximum minimum)))))
    t))

(deffoo nndiscourse-request-list-newsgroups (&optional server)
  "Insert category descriptions for SERVER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist
          (row
           (sqlite-select
            nndiscourse--database
            "SELECT child.id,
                    CASE WHEN parent.name IS NULL THEN child.name
                         ELSE parent.name || ' / ' || child.name END,
                    child.description
               FROM categories child
               LEFT JOIN categories parent ON parent.id = child.parent_id
              ORDER BY child.position, child.id"))
        (pcase-let ((`(,id ,name ,description) row))
          (insert
           (format "category.%d\t%s%s\n"
                   id name
                   (if (string-empty-p (or description ""))
                       ""
                     (format " — %s"
                             (replace-regexp-in-string
                              "[\r\n\t ]+" " " description))))))))
    t))

(deffoo nndiscourse-retrieve-groups (_groups &optional server)
  "Retrieve active data for SERVER."
  (and (nndiscourse-request-list server) 'active))

(deffoo nndiscourse-request-group
    (group &optional server _dont-check _info)
  "Select GROUP on SERVER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (let ((category-id (nndiscourse--group-category-id group)))
      (unless category-id
        (error "Invalid nndiscourse group %s" group))
      (setq nndiscourse--current-group group)
      (pcase-let
          ((`(,count ,minimum ,maximum)
            (car
             (sqlite-select
              nndiscourse--database
              "SELECT COUNT(*), COALESCE(MIN(article_no), 1),
                      COALESCE(MAX(article_no), 0)
                 FROM posts
                WHERE category_id = ? AND deleted = 0"
              (vector category-id)))))
        (nnheader-insert "211 %d %d %d %s\n"
                         count minimum maximum group)))
    t))

(deffoo nndiscourse-request-scan (&optional _group server)
  "Fetch new categories and posts for SERVER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (nndiscourse--sync-categories)
    (nnheader-report 'nndiscourse "Synchronized %d posts"
                     (if (nndiscourse--metadata-get "initial_sync_complete")
                         (nndiscourse--incremental-sync)
                       (nndiscourse--initial-sync)))
    t))

(deffoo nndiscourse-request-group-scan
    (_group &optional server _info)
  "Scan GROUP on SERVER."
  (nndiscourse-request-scan nil server))

(deffoo nndiscourse-retrieve-headers
    (articles &optional group server _fetch-old)
  "Insert NOV data for ARTICLES in GROUP on SERVER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (setq group (or group nndiscourse--current-group))
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (article (gnus-uncompress-sequence articles))
        (when-let* ((post (nndiscourse--post-by-article group article))
                    (header (nndiscourse--make-header post)))
          (nnheader-insert-nov header))))
    'nov))

(defun nndiscourse--article-from-message-id (message-id)
  "Find a cached post matching MESSAGE-ID."
  (when (string-match
         "\\`<discourse\\.topic-\\([0-9]+\\)\\.post-\\([0-9]+\\)@[^>]+>\\'"
         message-id)
    (nndiscourse--post-by-topic-number
     (string-to-number (match-string 1 message-id))
     (string-to-number (match-string 2 message-id)))))

(deffoo nndiscourse-request-article
    (article &optional group server buffer)
  "Retrieve ARTICLE from GROUP on SERVER into BUFFER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (setq group (or group nndiscourse--current-group))
    (let* ((post
            (if (stringp article)
                (nndiscourse--article-from-message-id article)
              (nndiscourse--post-by-article group article)))
           (post (and post (nndiscourse--refresh-post post)))
           (header (and post (nndiscourse--make-header post)))
           (permalink (and post (nndiscourse--permalink post))))
      (unless header
        (error "No such article: %s" article))
      (with-current-buffer (or buffer nntp-server-buffer)
        (erase-buffer)
        (insert "Newsgroups: " group "\n"
                "Subject: " (mail-header-subject header) "\n"
                "From: " (mail-header-from header) "\n"
                "Date: " (mail-header-date header) "\n"
                "Message-ID: " (mail-header-id header) "\n")
        (unless (string-empty-p (mail-header-references header))
          (insert "References: " (mail-header-references header) "\n"))
        (insert "Archived-At: " permalink "\n"
                "X-Discourse-Post-ID: "
                (number-to-string (plist-get post :remote-id)) "\n"
                "X-Discourse-Topic-ID: "
                (number-to-string (plist-get post :topic-id)) "\n"
                "X-Discourse-Post-Number: "
                (number-to-string (plist-get post :post-number)) "\n"
                "X-Discourse-Likes: "
                (number-to-string (plist-get post :like-count))
                "\nX-Discourse-Liked: "
                (if (= (plist-get post :liked) 1) "yes" "no")
                "\n"
                "MIME-Version: 1.0\n"
                "Content-Type: text/html; charset=utf-8\n"
                "Content-Transfer-Encoding: 8bit\n"
                "Content-Base: " permalink "\n\n"
                "<html><head><base href=\""
                nndiscourse-base-url
                "/\"></head><body>\n"
                (or (plist-get post :cooked)
                    "<p>This post has no available body.</p>")
                "\n</body></html>\n"))
      (cons group (plist-get post :article-no)))))

(defun nndiscourse--decode-message-body ()
  "Return the current RFC message body as decoded plain text."
  (save-restriction
    (widen)
    (let ((handle (mm-dissect-buffer t)))
      (unwind-protect
          (progn
            (unless (equal (mm-handle-media-type handle) "text/plain")
              (error "Discourse posts require one plain-text Markdown part"))
            (mm-decode-string
             (mm-get-part handle)
             (or (cdr (assq 'charset (cdr (mm-handle-type handle))))
                 "utf-8")))
        (mm-destroy-parts handle)))))

(defun nndiscourse--reference-post ()
  "Return the post referenced by the current outgoing message."
  (let* ((references (or (mail-fetch-field "references")
                         (mail-fetch-field "in-reply-to")))
         (ids (and references
                   (gnus-split-references references))))
    (when ids
      (nndiscourse--article-from-message-id (car (last ids))))))

(deffoo nndiscourse-request-post (&optional server)
  "Create a Discourse topic or reply from the current message buffer."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (let* ((newsgroups
            (message-tokenize-header
             (or (mail-fetch-field "newsgroups") "")))
           (group (car newsgroups))
           (category-id (nndiscourse--group-category-id group)))
      (unless (= (length newsgroups) 1)
        (error "Exactly one Discourse category is required"))
      (unless category-id
        (error "Invalid Discourse category %s" group))
      (let* ((subject (nndiscourse--sanitize-header
                       (mail-decode-encoded-word-string
                        (or (mail-fetch-field "subject") ""))))
             (raw (string-trim-right
                   (nndiscourse--decode-message-body) "\n+")))
        (when (string-empty-p raw)
          (error "A Discourse post cannot be empty"))
        (let* ((parent (nndiscourse--reference-post))
               (payload
                (if parent
                    `(:raw ,raw
                      :topic_id ,(plist-get parent :topic-id)
                      :reply_to_post_number ,(plist-get parent :post-number))
                  (when (string-empty-p subject)
                    (error "A new Discourse topic requires a subject"))
                  `(:title ,subject :raw ,raw :category ,category-id)))
               (response
                (nndiscourse--request
                 "POST" "/posts.json" :data payload :authenticated t))
               (post
                (nndiscourse--upsert-post
                 response
                 `(:category-id ,category-id
                   :topic-id ,(and parent (plist-get parent :topic-id))
                   :topic-title ,(if parent
                                     (plist-get parent :topic-title)
                                   subject)))))
          (nnheader-report
           'nndiscourse "Created Discourse post %d"
           (plist-get post :remote-id))
          t)))))

(defun nndiscourse--update-post (post raw)
  "Update POST with RAW Markdown and return the cached result."
  (let ((response
         (nndiscourse--request
          "PUT" (format "/posts/%d.json" (plist-get post :remote-id))
          :data `(:post (:raw ,raw)) :authenticated t)))
    (nndiscourse--upsert-post
     (or (plist-get response :post) response) post)))

(deffoo nndiscourse-request-replace-article
    (article group buffer &optional server)
  "Replace ARTICLE in GROUP with the body from BUFFER."
  (nndiscourse--with-report
    (nndiscourse--possibly-open server)
    (let ((post (nndiscourse--refresh-post
                 (nndiscourse--post-by-article group article) t)))
      (unless (= (plist-get post :can-edit) 1)
        (error "Discourse does not permit editing this post"))
      (let ((raw (with-current-buffer buffer
                   (nndiscourse--decode-message-body))))
        (nndiscourse--update-post post (string-trim-right raw "\n+"))
        t))))

(deffoo nndiscourse-request-expire-articles
    (articles group &optional server force)
  "Delete eligible ARTICLES from GROUP on SERVER.
FORCE has the same semantics as in mail backends.  Without FORCE,
Gnus expiry age settings determine eligibility."
  (nndiscourse--possibly-open server)
  (let (not-deleted)
    (dolist (article articles)
      (let* ((cached (nndiscourse--post-by-article group article))
             (post (and cached (nndiscourse--refresh-post cached t))))
        (if
            (and post
                 (= (plist-get post :can-delete) 1)
                 (nnmail-expired-article-p
                  group (date-to-time (plist-get post :created-at)) force)
                 (condition-case err
                     (progn
                       (nndiscourse--request
                        "DELETE"
                        (format "/posts/%d.json"
                                (plist-get post :remote-id))
                        :authenticated t)
                       t)
                   (error
                    (nnheader-message
                     3 "Could not delete Discourse post %d: %s"
                     (plist-get post :remote-id)
                     (error-message-string err))
                    nil)))
            (sqlite-execute
             nndiscourse--database
             "UPDATE posts SET deleted = 1 WHERE remote_id = ?"
             (vector (plist-get post :remote-id)))
          (push article not-deleted))))
    (nreverse not-deleted)))

(defun nndiscourse--current-location ()
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
    (let* ((method (gnus-find-method-for-group group))
           (server (cadr method)))
      (unless (eq (car method) 'nndiscourse)
        (user-error "Current article is not from nndiscourse"))
      (list server (gnus-group-real-name group) article summary))))

(defun nndiscourse--current-post (&optional force-refresh)
  "Return the current Discourse post.
Refresh it first when FORCE-REFRESH is non-nil."
  (pcase-let* ((`(,server ,group ,article ,_summary)
                (nndiscourse--current-location)))
    (nndiscourse--possibly-open server)
    (when-let* ((post (nndiscourse--post-by-article group article)))
      (nndiscourse--refresh-post post force-refresh))))

(defun nndiscourse--update-current-summary-line (post)
  "Update the current Gnus summary line from cached POST."
  (pcase-let ((`(,_server ,_group ,article ,summary)
               (nndiscourse--current-location)))
    (when (buffer-live-p summary)
      (with-current-buffer summary
        (gnus-summary-update-article-line
         article (nndiscourse--make-header post))))))

;;;###autoload
(defun nndiscourse-fetch-older (&optional pages)
  "Fetch PAGES older Discourse pages and reselect the current group."
  (interactive "P")
  (pcase-let* ((`(,server ,_group ,_article ,summary)
                (nndiscourse--current-location))
               (pages (max 1 (prefix-numeric-value (or pages 1)))))
    (nndiscourse--possibly-open server)
    (let ((count (nndiscourse--fetch-older-pages pages)))
      (message "Fetched %d older Discourse posts" count)
      (when (and (> count 0) (buffer-live-p summary))
        (with-current-buffer summary
          (gnus-summary-reselect-current-group t nil))))))

;;;###autoload
(defun nndiscourse-toggle-like ()
  "Like or unlike the Discourse post at point."
  (interactive)
  (let* ((post (or (nndiscourse--current-post t)
                   (user-error "No cached Discourse post at point")))
         (remote-id (plist-get post :remote-id))
         (liked (= (plist-get post :liked) 1)))
    (cond
     ((and liked (= (plist-get post :like-can-undo) 0))
      (user-error
       "This like can no longer be undone; its undo window expired"))
     ((and (not liked) (= (plist-get post :like-can-act) 0))
      (user-error
       "This post cannot be liked, for example if it is your own")))
    (let ((response
           (if liked
               (nndiscourse--request
                "DELETE" (format "/post_actions/%d.json" remote-id)
                :data '(:post_action_type_id 2) :authenticated t)
             (nndiscourse--request
              "POST" "/post_actions.json"
              :data `(:id ,remote-id :post_action_type_id 2)
              :authenticated t))))
      (nndiscourse--update-current-summary-line
       (nndiscourse--upsert-post response post))
      (message "Discourse post %s" (if liked "unliked" "liked")))))

;;;###autoload
(defun nndiscourse-set-topic-notification-level (level)
  "Set the current topic notification LEVEL.
Interactively, prompt for muted, normal, tracking, or watching."
  (interactive
   (list
    (alist-get
     (completing-read "Notification level: "
                      nndiscourse--notification-levels
                      nil t nil nil "normal")
     nndiscourse--notification-levels nil nil #'string=)))
  (let* ((post (or (nndiscourse--current-post)
                   (user-error "No cached Discourse post at point")))
         (topic-id (plist-get post :topic-id))
         (name (car (rassq level nndiscourse--notification-levels))))
    (unless name
      (user-error "Invalid Discourse notification level %S" level))
    (nndiscourse--request
     "POST" (format "/t/%d/notifications.json" topic-id)
     :data `(:notification_level ,(number-to-string level))
     :authenticated t)
    (sqlite-execute
     nndiscourse--database
     "UPDATE posts SET notification_level = ? WHERE topic_id = ?"
     (vector level topic-id))
    (message "Discourse notification level set to %s" name)))

;;;###autoload
(defun nndiscourse-edit-post ()
  "Edit the Discourse post at point as raw Markdown."
  (interactive)
  (pcase-let* ((`(,server ,group ,article ,summary)
                (nndiscourse--current-location)))
    (nndiscourse--possibly-open server)
    (let ((post (nndiscourse--refresh-post
                 (nndiscourse--post-by-article group article) t)))
      (unless (= (plist-get post :can-edit) 1)
        (user-error "Discourse does not permit editing this post"))
      (let ((buffer
             (get-buffer-create
              (format "*Discourse edit %d*" (plist-get post :remote-id)))))
        (pop-to-buffer buffer)
        (erase-buffer)
        (insert (or (plist-get post :raw) ""))
        (goto-char (point-min))
        (nndiscourse-edit-post-mode)
        (setq-local
         nndiscourse--edit-context
         `(:server ,server :group ,group :article ,article
           :summary-buffer ,summary :post ,post))))))

(defun nndiscourse-edit-submit ()
  "Save the current Discourse Markdown edit."
  (interactive)
  (unless nndiscourse--edit-context
    (user-error "This is not an active Discourse edit buffer"))
  (let* ((context nndiscourse--edit-context)
         (server (plist-get context :server))
         (post (plist-get context :post))
         (summary (plist-get context :summary-buffer))
         (raw (buffer-substring-no-properties (point-min) (point-max))))
    (when (string-empty-p (string-trim raw))
      (user-error "A Discourse post cannot be empty"))
    (nndiscourse--possibly-open server)
    (nndiscourse--update-post post raw)
    (set-buffer-modified-p nil)
    (kill-buffer (current-buffer))
    (message "Discourse post updated")
    (when (buffer-live-p summary)
      (pop-to-buffer summary)
      (gnus-summary-rescan-group))))

(defun nndiscourse-edit-abort ()
  "Abort the current Discourse edit."
  (interactive)
  (unless nndiscourse--edit-context
    (user-error "This is not an active Discourse edit buffer"))
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard this Discourse edit? "))
    (set-buffer-modified-p nil)
    (kill-buffer (current-buffer))))

(defun nndiscourse--current-group-p ()
  "Return non-nil when the current Gnus buffer uses nndiscourse."
  (let ((group (if (derived-mode-p 'gnus-summary-mode)
                   gnus-newsgroup-name
                 (car gnus-article-current))))
    (and group
         (eq (car-safe (gnus-find-method-for-group group))
             'nndiscourse))))

(defun nndiscourse--decorate-browse-buffer (&rest _)
  "Show category names beside stable group IDs in a Gnus browse buffer."
  (when (and (derived-mode-p 'gnus-browse-mode)
             (eq (car-safe gnus-browse-current-method) 'nndiscourse)
             (sqlitep nndiscourse--database))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let*
              ((group (get-text-property (point) 'gnus-group))
               (category-id (nndiscourse--group-category-id group))
               (name
                (caar
                 (sqlite-select
                  nndiscourse--database
                  "SELECT name FROM categories WHERE id = ?"
                  (vector category-id)))))
            (when (re-search-forward ": \\(.*\\)$" (line-end-position) t)
              (replace-match
               (format "%s [%s]" name group) t t nil 1)))
          (forward-line 1))))))

(defun nndiscourse--activate-mode ()
  "Update `nndiscourse-mode' for the current Gnus group."
  (nndiscourse-mode (if (nndiscourse--current-group-p) 1 -1)))

(add-hook 'gnus-summary-mode-hook #'nndiscourse--activate-mode)
(add-hook 'gnus-article-prepare-hook #'nndiscourse--activate-mode)
(advice-add 'gnus-browse-foreign-server
            :after #'nndiscourse--decorate-browse-buffer)

(nnoo-define-skeleton nndiscourse)
(gnus-declare-backend "nndiscourse" 'post-mail 'address)

(provide 'nndiscourse)

;;; nndiscourse.el ends here
