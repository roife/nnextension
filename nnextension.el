;;; nnextension.el --- Gnus backends for web communities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nnextension contributors

;; Author: nnextension contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.0"))
;; Keywords: news, hypermedia
;; URL: https://github.com/roife/nnextension
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; nnextension packages the nndiscourse and nnhackernews Gnus backends.

;;; Code:

(require 'nnextension-core)
(require 'nndiscourse)
(require 'nnhackernews)

(provide 'nnextension)

;;; nnextension.el ends here
