# nndiscourse

`nndiscourse` is a Gnus backend for [Discourse](https://www.discourse.org/)
forums. It presents:

- Discourse categories as Gnus groups;
- posts as threaded articles;
- topic creation and replies through normal Gnus message composition;
- post editing and deletion;
- likes and topic notification levels.

The package targets Emacs 31. It uses the built-in Gnus, URL, JSON, SQLite,
MIME, and `auth-source` libraries. Browser-based User API Key authorization
also requires the `openssl` executable.

## Installation

Until the package is available from MELPA, clone the repository and add it
to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/nndiscourse")
(require 'nndiscourse)
```

A `use-package` setup for a forum looks like this:

```elisp
(use-package nndiscourse
  :load-path "/path/to/nndiscourse"
  :config
  (add-to-list
   'gnus-secondary-select-methods
   '(nndiscourse "meta"
     (nndiscourse-base-url "https://meta.discourse.org")
     (nndiscourse-auth-type auto))))
```

The first string is a Gnus virtual-server name. It does not have to match
the hostname. When `nndiscourse-base-url` is omitted, the virtual-server
name is treated as an HTTPS hostname:

```elisp
(add-to-list 'gnus-secondary-select-methods
             '(nndiscourse "forum.example"))
```

Run `M-x gnus`, show the server buffer with `^`, browse the nndiscourse
server, and subscribe to the desired `category.<id>` groups. Gnus shows
the corresponding category names alongside these stable internal names.

## Authentication

Public forums can be read without credentials. Authenticated operations use
the HTTP authentication schemes supported by the
[Discourse API](https://docs.discourse.org/).

Store credentials in an `auth-source` backend, preferably
`~/.authinfo.gpg`, rather than in Emacs configuration:

```text
machine forum.example port discourse login alice password API_KEY
```

The available `nndiscourse-auth-type` values are:

- `auto` (default): read anonymously without an entry; treat a
  `user-api-key` login as a User API Key and any other entry as
  `Api-Key` plus `Api-Username`;
- `anonymous`: never consult `auth-source`;
- `api-key`: use the entry's login and secret as `Api-Username` and
  `Api-Key`;
- `user-api-key`: find the `user-api-key` login in
  `nndiscourse-auth-source-file` and send its secret as `User-Api-Key`.

For a normal Discourse user account, configure `user-api-key` and run:

```text
M-x nndiscourse-authorize
```

The command opens the forum's authorization page. Log in through the browser,
approve the requested write access, click **Copy API Key**, then paste the
encrypted payload into Emacs. `nndiscourse` verifies and decrypts it, stores
the resulting key in `nndiscourse-auth-source-file` (default
`~/.authinfo.gpg`), and deletes the temporary RSA private key.

For a pre-provisioned User API Key, use this exact login:

```text
machine forum.example port discourse login user-api-key password USER_API_KEY
```

Then configure `(nndiscourse-auth-type user-api-key)`.

Secrets are neither written to the SQLite cache nor included in diagnostic
messages.

## Gnus usage

Normal Gnus commands perform the core operations:

| Command | Action |
| --- | --- |
| `a` | Create a topic in the current category |
| `f` | Reply to the selected post |
| `F` | Reply and quote the selected post |
| `e` | Edit an editable post as raw Markdown |
| `E` | Mark a post as expirable |
| `B DEL` | Delete a post immediately |
| `M-g` | Synchronize new posts |

The `nndiscourse-mode` minor mode adds:

| Command | Action |
| --- | --- |
| `C-c C-l` | Like or unlike the current post |
| `C-c C-n` | Set muted, normal, tracking, or watching for the topic |
| `C-c C-o` | Fetch one older page; a numeric prefix fetches more pages |

Add `%uH` to `gnus-summary-line-format` and alias
`gnus-user-format-function-H` to `nndiscourse-summary-liked-mark` to display
`♥` on posts liked by the current user.  The mark updates immediately after
`C-c C-l`.  nndiscourse also observes Discourse's per-post `can_act` and
`can_undo` flags, so forbidden likes and expired unlike windows are reported
before a request is sent.

Gnus expiry behaves like a mail backend. A forced delete is immediate.
Routine expiry only deletes posts marked expirable and old enough under the
group's `expiry-wait` setting. Discourse permission checks still apply.

The initial synchronization downloads the latest 500 accessible posts by
default. Customize `nndiscourse-initial-sync-limit` before first opening a
server to change that window. Article-number mappings and synchronization
cursors are persistent, so restarts do not renumber articles.

Topic-starting posts use the Discourse topic title as their Gnus subject.
Replies use a compact, plain-text excerpt of their rendered body so that
individual responses remain identifiable in the summary buffer. Customize
`nndiscourse-reply-subject-length` to change the default 72-character limit.

## Current boundaries

This release does not implement private messages, uploads or attachments,
flags, bookmarks, moderation, tag/category administration, remote Discourse
read-state synchronization, or topic-title editing. Message composition
accepts a single plain-text Markdown part and rejects multipart messages.

## Development

Run the deterministic ERT suite and byte compilation with:

```sh
make check
```

The tests use in-memory SQLite databases and mocked HTTP responses. An
optional read-only smoke test can be run against a public forum:

```sh
make smoke URL=https://meta.discourse.org
```

Maintainers with `package-lint` installed can also run:

```sh
make package-lint
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
