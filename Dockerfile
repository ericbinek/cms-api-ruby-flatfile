FROM ruby:3.4-alpine

RUN addgroup -S appuser && adduser -S appuser -G appuser

WORKDIR /app

COPY . .

RUN mkdir -p data && chown -R appuser:appuser /app
USER appuser

EXPOSE 3016

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:3016/health || exit 1

CMD ["ruby", "src/server.rb"]
