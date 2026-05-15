FROM ghcr.io/berriai/litellm-database:main-stable

COPY config.yaml /app/config.yaml
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 4000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["--config", "/app/config.yaml", "--port", "4000"]
