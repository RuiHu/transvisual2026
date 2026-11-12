FROM ruby:3.3-slim

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential libpq-dev curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mkdir -p tmp/pids log

COPY Gemfile ./
RUN bundle install --jobs 4 --retry 3

COPY . .

RUN chmod +x bin/* || true

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
