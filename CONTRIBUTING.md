# Contributing to cms-api-ruby-flatfile

Thanks for taking a look. This is a build-in-public project at version 0.1.0, so it is still moving and contributions of every kind are welcome: bug reports, questions, ideas, and code.

## Ground rules

- Stay on the standard library. The point of this project is Ruby's core and standard library, so please do not add gems or a `Gemfile`.
- The conformance test suite is the contract. If you change behavior, change the tests in the same pull request and explain why. Keep them green.
- This is not production software, and the README says so. Please keep that framing.

## Getting started

```sh
git clone https://github.com/ericbinek/cms-api-ruby-flatfile.git
cd cms-api-ruby-flatfile
cp .env.example .env
```

Run it:

```sh
ruby src/server.rb
```

Run the tests:

```sh
ruby -e "Dir.glob('test/*_test.rb').sort.each { |f| require File.expand_path(f) }"
```

There is no `bundle install` and no virtual environment to manage: a standard Ruby install is all you need.

## Sending a change

1. For anything beyond a small fix, open an issue or discussion first so we do not duplicate work.
2. Keep each pull request focused on one thing.
3. Run the test suite locally and make sure it is green before you open the pull request.
4. Describe what changed and why.

## Style

Idiomatic Ruby on the standard library, no framework. Match the surrounding code.
