# Garmin Connect MCP server (Taxuspt/garmin_mcp, stdio) bridged to
# streamable HTTP by mcp-proxy so it can be used as a remote MCP connector.
#
# Build & push (OKE nodes are aarch64; OCIR creds in Vault at kv/oci/ocir):
#   docker build --platform linux/arm64 -t syd.ocir.io/sdajdczqv0qo/garmin-mcp:0.1.0 images/garmin-mcp
#   docker push syd.ocir.io/sdajdczqv0qo/garmin-mcp:0.1.0
FROM python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && pip install --no-cache-dir \
       mcp-proxy==0.12.0 \
       "garmin-mcp @ git+https://github.com/Taxuspt/garmin_mcp@7af73ebf9b4073cf3b1ad1cb42d351f38e7ef47c" \
    && apt-get purge -y git && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# Token dir; seeded from Vault via init container, refreshed in place by garminconnect.
ENV GARMINTOKENS=/data/garmintokens

EXPOSE 8080
# Streamable HTTP served at /mcp (also /sse for legacy clients).
CMD ["mcp-proxy", "--port=8080", "--host=0.0.0.0", "--stateless", "--pass-environment", "garmin-mcp"]
