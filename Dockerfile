FROM kong/kong-gateway:3.8

LABEL org.opencontainers.image.title="Next Moca Runtime Defense for AI Agents"
LABEL org.opencontainers.image.description="Thin Kong Gateway plugin that calls the hosted Next Moca Runtime Defense API."
LABEL org.opencontainers.image.source="https://github.com/nextmoca/kong-runtime-defense"
LABEL org.opencontainers.image.licenses="Apache-2.0"

USER root
COPY kong/plugins/nextmoca-runtime-defense /usr/local/share/lua/5.1/kong/plugins/nextmoca-runtime-defense
USER kong

ENV KONG_PLUGINS="bundled,nextmoca-runtime-defense"
