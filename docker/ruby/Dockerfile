FROM ruby:3.4.4-slim-bookworm AS base

RUN apt update && apt --fix-missing install -y build-essential pkg-config bash curl libssl-dev libyaml-dev \
     && rm -rf /var/lib/apt/lists/*

RUN echo 'gem: --no-document' >> ~/.gemrc

WORKDIR /app

COPY .ruby-version Gemfile Gemfile.lock /app/

RUN bundle install --jobs $(nproc) --retry=3 && \
    bundle clean --force && rm -rf /usr/local/bundle/cache/*

FROM ruby:3.4.4-slim-bookworm AS deploy
RUN apt update && apt install --fix-missing -y bash curl libssl-dev libyaml-0-2 \
     && rm -rf /var/lib/apt/lists/*

COPY --from=base /usr/local/bundle /usr/local/bundle
COPY . /app

ENV SERVER_ENV=production \
    RACK_ENV=production \
    BIND=0.0.0.0 \
    PORT=9293

EXPOSE $PORT
WORKDIR /app

HEALTHCHECK --interval=15s --timeout=2s --retries=3 CMD curl --fail http://127.0.0.1:$PORT/health || exit 1
CMD bundle exec rackup /app/tool-call-shim.ru -o 0.0.0.0 -p $PORT -s falcon
