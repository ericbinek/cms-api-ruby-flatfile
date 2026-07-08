# schema.org aligned CMS API (Ruby)

[![Tests](https://github.com/ericbinek/cms-api-ruby-flatfile/actions/workflows/test.yml/badge.svg)](https://github.com/ericbinek/cms-api-ruby-flatfile/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-0.1.1-blue.svg)
![Status](https://img.shields.io/badge/status-work_in_progress-orange.svg)
![Build in public](https://img.shields.io/badge/build-in_public-ff69b4.svg)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)
![Ruby 3.4](https://img.shields.io/badge/Ruby-3.4-red.svg)

A standalone, schema.org aligned CMS API written in plain Ruby 3.4.

There is no `Gemfile` to install and no bundler step. It runs on Ruby's core and standard library: a hand-written HTTP/1.1 layer over `socket`/`TCPServer` to serve, `json` and `securerandom` for the model, and `minitest` to test. WEBrick is deliberately avoided — it is a separately versioned default gem, and building the HTTP layer from `socket` is the point of the vanilla target.

It exposes CRUD endpoints for 14 schema.org entity types such as BlogPosting, Person, and Organization, backed by flat-file JSON storage, with validation, pagination, filtering, sorting, ETag caching, and reference embedding.

A conformance test suite defines the HTTP contract.

## Status: work in progress (v0.1.1)

This is an ongoing build-in-public project, shared only for community and communication purposes. Do not deploy it in production. Do not rely on its interfaces or data format remaining stable.

## No bundler

There is no `Gemfile` and nothing to `bundle install`. The whole thing is Ruby's core and standard library: `socket`, `json`, `securerandom`, `digest`, `openssl`, `minitest`. Run it with the system `ruby`.

## Requirements

- Ruby 3.4 or newer

## Installation

```sh
git clone https://github.com/ericbinek/cms-api-ruby-flatfile.git
cd cms-api-ruby-flatfile
cp .env.example .env
```

## Running

```sh
ruby src/server.rb
```

The server listens on `PORT` (default 3016).

## Usage

```sh
curl http://localhost:3016/blog-postings
```

All list endpoints return `{ items, total }`. See per-entity routes below.

## Authentication

Reads are public; every write requires a session. Roles (admin, editor, author, viewer) gate access per entity and operation, authors may only change their own records, and a publication workflow governs status changes.

On first start, when the account store is empty and `ADMIN_USER` and `ADMIN_PASSWORD` are set, an admin account is created. There is no self-registration.

```sh
# log in to obtain a session token
curl -sX POST http://localhost:3016/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"change-me"}'

# use the token on writes
curl -X POST http://localhost:3016/blog-postings \
  -H "Authorization: Bearer <token>" \
  -H 'Content-Type: application/json' \
  -d '{ ... }'
```

## Entities

- `BlogPosting`
- `Person`
- `Organization`
- `WebPage`
- `ImageObject`
- `VideoObject`
- `AudioObject`
- `CategoryCode`
- `CategoryCodeSet`
- `DefinedTerm`
- `DefinedTermSet`
- `Comment`
- `WebSite`
- `SiteNavigationElement`

## Testing

```sh
ruby -e "Dir.glob('test/*_test.rb').sort.each { |f| require File.expand_path(f) }"
```

## Contributing

Contributions are welcome. This is a build-in-public project, so issues, questions, and ideas count as much as pull requests. If you send code, keep it on Ruby's core and standard library with no new dependencies, and keep the conformance suite green, since the tests are the contract.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guidelines.

## License

MIT. See [LICENSE](LICENSE).
