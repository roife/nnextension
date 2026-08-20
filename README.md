# nnextension

`nnextension` packages Gnus backends for web communities:

- `nndiscourse` presents Discourse categories and posts through Gnus and
  supports the existing authenticated write operations;
- `nnhackernews` presents Hacker News stories and comments as a strictly
  read-only backend.

The package targets Emacs 31 and uses only built-in Emacs libraries for Gnus,
URL, JSON, SQLite, MIME, `auth-source`, and HTML rendering. Browser-based
Discourse User API Key authorization also requires the `openssl` executable.

## Installation

Clone the repository and add it to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/nnextension")
(require 'nnextension)
```

`nnextension` loads both backends. Existing configurations may continue to
load either backend independently with `(require 'nndiscourse)` or
`(require 'nnhackernews)`.

## Hacker News

Add the read-only server to an existing Gnus configuration:

```elisp
(add-to-list 'gnus-secondary-select-methods '(nnhackernews ""))
```

Run `M-x gnus`, show the server buffer with `^`, browse the nnhackernews
server, and subscribe to any of these groups:

| Group | Contents |
| --- | --- |
| `news` | New stories other than Ask HN, Show HN, and jobs |
| `ask` | Ask HN stories |
| `show` | Show HN stories |
| `job` | Job stories |

The initial scan retains the latest 100 roots from each feed by default.
Customize `nnhackernews-feed-limit` to change that window. Article-number
mappings are persistent and never change when scores, comment counts, or
feed positions change.

Opening a story for the first time downloads its complete comment tree and
reselects the current Gnus summary so the comments appear as threaded
articles. Normal Gnus refreshes update story roots but deliberately do not
poll previously opened comment trees. Use `C-c C-r` in a nnhackernews summary
or article buffer to refresh the current thread manually.

Root articles show the Hacker News self text, score, comment count, permalink,
and original article link. External pages are not downloaded into Emacs.
There is no authentication and no support for submissions, replies, votes,
editing, deletion, or expiry.

The backend uses the official
[Hacker News Firebase API](https://github.com/HackerNews/API) for feed
membership, the [Algolia HN API](https://hn.algolia.com/api) for batched story
metadata and recursive comment trees, and the official item endpoint when a
new root has not reached Algolia yet. Its implementation is new, with the
original [dickmao/nnhackernews](https://github.com/dickmao/nnhackernews)
serving as a behavioral reference.

## Discourse

A `use-package` setup for a forum looks like this:

```elisp
(use-package nnextension
  :load-path "/path/to/nnextension"
  :config
  (add-to-list
   'gnus-secondary-select-methods
   '(nndiscourse "meta"
     (nndiscourse-base-url "https://meta.discourse.org")
     (nndiscourse-auth-type auto))))
```

The first string is a Gnus virtual-server name. It does not have to match the
hostname. When `nndiscourse-base-url` is omitted, the virtual-server name is
treated as an HTTPS hostname.

Public forums can be read without credentials. Authenticated operations use
the HTTP authentication schemes supported by the
[Discourse API](https://docs.discourse.org/). Store credentials in an
`auth-source` backend, preferably `~/.authinfo.gpg`:

```text
machine forum.example port discourse login alice password API_KEY
```

The available `nndiscourse-auth-type` values are:

- `auto` (default): read anonymously without an entry; infer the credential
  type when an entry is present;
- `anonymous`: never consult `auth-source`;
- `api-key`: send `Api-Username` and `Api-Key`;
- `user-api-key`: read the `user-api-key` login and send `User-Api-Key`.

For a normal Discourse account, configure `user-api-key` and run
`M-x nndiscourse-authorize`. The command opens the forum authorization page,
verifies the returned payload, and stores the key in
`nndiscourse-auth-source-file`.

Normal Gnus commands create topics, reply, edit, and delete when the account
has permission. `nndiscourse-mode` additionally provides:

| Command | Action |
| --- | --- |
| `C-c C-l` | Like or unlike the current post |
| `C-c C-n` | Change the topic notification level |
| `C-c C-o` | Fetch one or more older pages |

The nnextension refactor preserves the existing `nndiscourse-*` public
variables, commands, backend method, SQLite location, authentication behavior,
and persistent article numbers.

## Storage

Each backend keeps its own SQLite databases beneath the corresponding Gnus
directory:

- `nndiscourse-directory` continues to default to
  `gnus-directory/nndiscourse`;
- `nnhackernews-directory` defaults to `gnus-directory/nnhackernews`.

The databases contain public remote content, synchronization metadata, and
stable local article mappings. Authentication secrets are never stored in
SQLite or included in diagnostics.

## Development

Run byte compilation, deterministic ERT tests, and Checkdoc with:

```sh
make check
```

The ERT suites use in-memory SQLite databases and mocked HTTP responses.
Optional read-only network smoke tests are available:

```sh
make smoke-discourse URL=https://meta.discourse.org
make smoke-hackernews
```

Maintainers with `package-lint` installed can also run:

```sh
make package-lint
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
