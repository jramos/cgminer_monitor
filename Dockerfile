# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM ruby:3.4-slim AS builder

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile cgminer_monitor.gemspec ./
COPY lib/cgminer_monitor/version.rb lib/cgminer_monitor/version.rb

RUN bundle config set --local without 'development' && \
    bundle install --jobs 4 && \
    bundle binstubs cgminer_monitor --force --path /usr/local/bundle/bin

COPY . .

# ---- Runtime stage ----
FROM ruby:3.4-slim

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app /app

# Default miners config location — mount or override via env
RUN mkdir -p config

EXPOSE 9292

ENTRYPOINT ["bundle", "exec", "cgminer_monitor"]
CMD ["run"]
