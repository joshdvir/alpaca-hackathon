# syntax=docker/dockerfile:1
# check=error=true

FROM ruby:4.0.6-slim

# System deps for pg gem + building native extensions.
# - zlib1g-dev: required by the `zlib` gem (transitive dep of faraday-gzip).
#   Without it, `bundle install` fails with `deflateReset(NULL) in -lz... no`
#   because the zlib native extension can't link against the system zlib.
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  libpq-dev \
  postgresql-client \
  libyaml-dev \
  zlib1g-dev \
  git \
  curl \
  procps \
  htop \
  && rm -rf /var/lib/apt/lists/*

# Install bundler
RUN gem install bundler --no-document

WORKDIR /app

# Runtime env defaults — docker-compose can override any of these
ENV BUNDLE_DEPLOYMENT="1" \
  BUNDLE_PATH="/usr/local/bundle" \
  RUBY_YJIT_ENABLE="1"

# Install gems first (cache layer)
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

# Copy app source
COPY . .

# Precompile bootsnap for faster boot (no-op if bootsnap isn't loaded)
RUN bundle exec bootsnap precompile -j 1 app/ lib/ || true

EXPOSE 3000

# Default to bash. docker-compose.yml overrides with `foreman start` for the
# default service, or use `docker compose run --rm api <cmd>` for ad-hoc tasks.
CMD ["bash"]
