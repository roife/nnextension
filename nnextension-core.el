;;; nnextension-core.el --- Shared support for nnextension backends  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nnextension contributors

;; Author: nnextension contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.0"))
;; Keywords: news, hypermedia
;; URL: https://github.com/roife/nnextension
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Shared HTTP, SQLite, text, and mail-header support for nnextension
;; Gnus backends.

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'json)
(require 'nnheader)
(require 'shr)
(require 'sqlite)
(require 'subr-x)
(require 'url-http)
(require 'url-queue)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(define-error 'nnextension-core-http-error "nnextension HTTP error")

(cl-defstruct nnextension-core-batch
  pending results errors callback done)

(defmacro nnextension-core-with-report (backend &rest body)
  "Run BODY, reporting errors through Gnus BACKEND."
  (declare (indent 1) (debug t))
  `(condition-case err
       (progn ,@body)
     (error
      (nnheader-report ,backend "%s" (error-message-string err))
      nil)))

(defun nnextension-core--encode-http-headers (headers)
  "Encode names and values in HEADERS as unibyte UTF-8 strings."
  (mapcar
   (lambda (header)
     (cons (encode-coding-string (car header) 'utf-8)
           (encode-coding-string (cdr header) 'utf-8)))
   headers))

(defun nnextension-core--safe-error-detail (error-data sensitive-values)
  "Return one safe line from ERROR-DATA, redacting SENSITIVE-VALUES."
  (let ((detail
         (car (split-string (error-message-string error-data) "[\r\n]" t))))
    (dolist (value sensitive-values)
      (setq detail
            (replace-regexp-in-string
             (regexp-quote value) "<redacted>" detail t t)))
    detail))

(defun nnextension-core--parse-json-response
    (service error-type error-message-function)
  "Parse the current URL response for SERVICE.
Signal ERROR-TYPE, using ERROR-MESSAGE-FUNCTION to decode an error body."
  (let ((status url-http-response-status)
        parsed)
    (goto-char url-http-end-of-headers)
    (skip-chars-forward "\r\n")
    (unless (eobp)
      (setq parsed
            (json-parse-buffer
             :object-type 'plist
             :array-type 'list
             :null-object nil
             :false-object :false)))
    (if (and (>= status 200) (< status 300))
        parsed
      (let ((fallback (format "%s returned HTTP %s" service status)))
        (signal
         error-type
         (list status
               (if error-message-function
                   (funcall error-message-function parsed fallback)
                 fallback)))))))

(cl-defun nnextension-core-json-request
    (method url
            &key data headers (timeout 30)
            (error-type 'nnextension-core-http-error)
            (service "Server") error-message-function
            sensitive-values request-target)
  "Send METHOD to URL and return its parsed JSON response.

DATA, when non-nil, is serialized as JSON.  HEADERS is an alist of HTTP
header names and values.  TIMEOUT is measured in seconds.  ERROR-TYPE is
signaled with the HTTP status and a safe message.  SERVICE names the remote
service in generic errors.  ERROR-MESSAGE-FUNCTION receives parsed error JSON
and a fallback string.  SENSITIVE-VALUES are redacted from transport errors.
REQUEST-TARGET replaces URL in user-facing transport errors."
  (let* ((url-request-method method)
         (url-request-data
          (and data (encode-coding-string (json-serialize data) 'utf-8)))
         (url-request-extra-headers
          (nnextension-core--encode-http-headers
           (append '(("Accept" . "application/json"))
                   (and data '(("Content-Type" . "application/json")))
                   headers)))
         (target (or request-target url))
         buffer)
    (setq buffer
          (condition-case err
              (url-retrieve-synchronously url t t timeout)
            (error
             (signal
              error-type
              (list
               0
               (format "Could not send %s %s: %s"
                       method target
                       (nnextension-core--safe-error-detail
                        err sensitive-values)))))))
    (unless buffer
      (signal error-type
              (list 0 (format "Timed out requesting %s" target))))
    (unwind-protect
        (with-current-buffer buffer
          (nnextension-core--parse-json-response
           service error-type error-message-function))
      (kill-buffer buffer))))

(cl-defun nnextension-core-json-request-async
    (method url callback
            &key data headers (timeout 30)
            (error-type 'nnextension-core-http-error)
            (service "Server") error-message-function sensitive-values)
  "Retrieve URL with METHOD and call CALLBACK with (DATA ERROR)."
  (let ((url-request-method method)
        (url-request-data
         (and data (encode-coding-string (json-serialize data) 'utf-8)))
        (url-request-extra-headers
         (nnextension-core--encode-http-headers
          (append '(("Accept" . "application/json"))
                  (and data '(("Content-Type" . "application/json")))
                  headers))))
    (setq url-queue-timeout (max url-queue-timeout timeout))
    (url-queue-retrieve
     url
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (if-let* ((transport-error (plist-get status :error)))
               (funcall
                  callback nil
                  (list
                   error-type 0
                   (nnextension-core--safe-error-detail
                    transport-error sensitive-values)))
               (pcase-let
                   ((`(,data ,error)
                     (condition-case error
                         (list
                          (nnextension-core--parse-json-response
                           service error-type error-message-function)
                          nil)
                       (error (list nil error)))))
                 (funcall callback data error)))
           (when (buffer-live-p buffer)
             (kill-buffer buffer)))))
     nil t t)))

(defun nnextension-core--batch-result (batch key data error)
  "Record one DATA or ERROR result for BATCH under KEY."
  (if error
      (push (cons key error) (nnextension-core-batch-errors batch))
    (push (cons key data) (nnextension-core-batch-results batch)))
  (cl-decf (nnextension-core-batch-pending batch))
  (when (zerop (nnextension-core-batch-pending batch))
    (setf (nnextension-core-batch-done batch) t)
    (funcall (nnextension-core-batch-callback batch)
             (nreverse (nnextension-core-batch-results batch))
             (nreverse (nnextension-core-batch-errors batch)))))

(defun nnextension-core-json-batch (requests callback)
  "Start REQUESTS in parallel and call CALLBACK with (RESULTS ERRORS).
Each request is a plist containing :key, :method, :url, and options accepted
by `nnextension-core-json-request-async'."
  (let ((batch
         (make-nnextension-core-batch
          :pending (length requests) :callback callback)))
    (dolist (request requests)
      (let ((key (plist-get request :key)))
        (apply
         #'nnextension-core-json-request-async
         (plist-get request :method)
         (plist-get request :url)
         (lambda (data error)
           (nnextension-core--batch-result batch key data error))
         (cl-loop for (name value) on request by #'cddr
                  unless (memq name '(:key :method :url))
                  append (list name value)))))
    (when (null requests)
      (setf (nnextension-core-batch-done batch) t)
      (funcall callback nil nil))
    batch))

(defun nnextension-core-database-file (directory server)
  "Return the SQLite file in DIRECTORY for virtual SERVER."
  (file-name-concat directory
                    (concat (secure-hash 'sha256 server) ".sqlite")))

(defun nnextension-core-initialize-metadata (database)
  "Initialize common metadata storage in DATABASE."
  (sqlite-execute database "PRAGMA journal_mode = WAL")
  (sqlite-execute
   database
   "CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT
    )"))

(defun nnextension-core-metadata-get (database key)
  "Return metadata KEY from DATABASE, or nil when it is absent."
  (caar
   (sqlite-select database
                  "SELECT value FROM metadata WHERE key = ?"
                  (vector key))))

(defun nnextension-core-metadata-set (database key value)
  "Store metadata KEY as VALUE in DATABASE."
  (sqlite-execute
   database
   "INSERT INTO metadata(key, value) VALUES(?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value"
   (vector key (format "%s" value))))

(defun nnextension-core-sanitize-header (value)
  "Return VALUE without characters that can inject a mail header."
  (replace-regexp-in-string "[\r\n]+" " " value t t))

(defun nnextension-core-html-to-text (html &optional ignored-classes)
  "Return compact plain text rendered from HTML.
Nodes whose class is in IGNORED-CLASSES are removed before rendering."
  (with-temp-buffer
    (insert html)
    (let ((document (libxml-parse-html-region (point-min) (point-max))))
      (dolist (class ignored-classes)
        (dolist (node (dom-by-class document class))
          (dom-remove-node document node)))
      (erase-buffer)
      (let ((shr-inhibit-images t)
            (shr-use-colors nil)
            (shr-use-fonts nil)
            (shr-width 10000))
        (shr-insert-document document))
      (string-trim
       (replace-regexp-in-string "[[:space:]]+" " " (buffer-string))))))

(defun nnextension-core-mail-from (username host &optional display-name)
  "Return a mail-style From value for USERNAME at HOST.
DISPLAY-NAME defaults to USERNAME."
  (let* ((username (nnextension-core-sanitize-header username))
         (display-name
          (nnextension-core-sanitize-header (or display-name username)))
         (display-name
          (if (string-empty-p display-name) username display-name)))
    (format "\"%s\" <%s@%s>"
            (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" display-name)
            username host)))

(defun nnextension-core-insert-html-article
    (buffer group header permalink base-url extra-headers body)
  "Insert one HTML article into BUFFER.
GROUP and HEADER supply its standard mail headers.  PERMALINK is used for
Archived-At and Content-Base.  BASE-URL resolves relative links.  Insert
EXTRA-HEADERS before the MIME headers and wrap BODY in an HTML document."
  (with-current-buffer buffer
    (erase-buffer)
    (insert "Newsgroups: " group "\n"
            "Subject: " (mail-header-subject header) "\n"
            "From: " (mail-header-from header) "\n"
            "Date: " (mail-header-date header) "\n"
            "Message-ID: " (mail-header-id header) "\n")
    (unless (string-empty-p (mail-header-references header))
      (insert "References: " (mail-header-references header) "\n"))
    (insert "Archived-At: " permalink "\n")
    (dolist (field extra-headers)
      (insert (car field) ": " (cdr field) "\n"))
    (insert "MIME-Version: 1.0\n"
            "Content-Type: text/html; charset=utf-8\n"
            "Content-Transfer-Encoding: 8bit\n"
            "Content-Base: " permalink "\n\n"
            "<html><head><base href=\"" base-url
            "/\"></head><body>\n" body "\n</body></html>\n")))

(provide 'nnextension-core)

;;; nnextension-core.el ends here
