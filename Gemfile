# frozen_string_literal: true

source "https://rubygems.org"

gem "jekyll-theme-chirpy", "~> 7.6"

gem "html-proofer", "~> 5.0", group: :test

# Only needed for tools/migrate-mt-to-jekyll.rb. Not installed by a plain
# `bundle install`; opt in with `bundle install --with migration`.
group :migration, optional: true do
  gem "mysql2", "~> 0.5"
  gem "tzinfo", ">= 1", "< 3"
end
