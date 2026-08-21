;;; nnextension-core-test.el --- Tests for nnextension-core  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'nnextension-core)

(defun nnextension-core-test--http-buffer (status body)
  "Return a URL response buffer with STATUS and BODY."
  (let ((buffer (generate-new-buffer " *nnextension HTTP test*")))
    (with-current-buffer buffer
      (set-buffer-multibyte t)
      (insert (format "HTTP/1.1 %d Test\r\nContent-Type: application/json\r\n\r\n"
                      status))
      (setq-local url-http-response-status status)
      (setq-local url-http-end-of-headers (copy-marker (point)))
      (insert body))
    buffer))

(ert-deftest nnextension-core-test-json-request-and-utf8 ()
  (let (request-data request-headers)
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (setq request-data url-request-data
                       request-headers url-request-extra-headers)
                 (nnextension-core-test--http-buffer
                  200 "{\"ok\":true,\"items\":[1,2]}"))))
      (should
       (equal
        (nnextension-core-json-request
         "POST" "https://example.test/items"
         :data '(:body "中文")
         :headers '(("X-Test" . "héader")))
        '(:ok t :items (1 2))))
      (should-not (multibyte-string-p request-data))
      (should
       (equal
        (plist-get
         (json-parse-string
          (decode-coding-string request-data 'utf-8)
          :object-type 'plist)
         :body)
        "中文"))
      (dolist (header request-headers)
        (should-not (multibyte-string-p (car header)))
        (should-not (multibyte-string-p (cdr header)))))))

(ert-deftest nnextension-core-test-json-errors-and-redaction ()
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _)
               (nnextension-core-test--http-buffer
                422 "{\"message\":\"bad query\"}"))))
    (let ((error
           (should-error
            (nnextension-core-json-request
             "GET" "https://example.test/bad"
             :error-message-function
             (lambda (data fallback)
               (or (plist-get data :message) fallback)))
            :type 'nnextension-core-http-error)))
      (should (= (nth 1 error) 422))
      (should (equal (nth 2 error) "bad query"))))
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _)
               (error "transport failed with secret-value\nprivate body"))))
    (let* ((error
            (should-error
             (nnextension-core-json-request
              "GET" "https://example.test/private"
              :sensitive-values '("secret-value")
              :request-target "/private")
             :type 'nnextension-core-http-error))
           (message (nth 2 error)))
      (should (string-match-p "<redacted>" message))
      (should-not (string-match-p "secret-value" message))
      (should-not (string-match-p "private body" message)))))

(ert-deftest nnextension-core-test-sqlite-support ()
  (let ((database (sqlite-open)))
    (unwind-protect
        (progn
          (nnextension-core-initialize-metadata database)
          (nnextension-core-metadata-set database "cursor" 42)
          (should
           (equal (nnextension-core-metadata-get database "cursor") "42")))
      (sqlite-close database))))

(ert-deftest nnextension-core-test-text-and-mail-helpers ()
  (should
   (equal
    (nnextension-core-sanitize-header "safe\r\ninjected")
    "safe injected"))
  (should
   (equal
    (nnextension-core-html-to-text
     "<aside class=\"quote\">old</aside><p>Hello <b>world</b></p>"
     '("quote"))
    "Hello world"))
  (should
   (equal
    (nnextension-core-mail-from "alice" "example.test" "Alice \"A\"")
    "\"Alice \\\"A\\\"\" <alice@example.test>"))
  (should
   (equal
    (nnextension-core-database-file "/tmp/example" "server")
    (file-name-concat
     "/tmp/example" (concat (secure-hash 'sha256 "server") ".sqlite")))))

(provide 'nnextension-core-test)

;;; nnextension-core-test.el ends here
