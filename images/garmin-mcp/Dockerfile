# Garmin Connect MCP server (Taxuspt/garmin_mcp, stdio) bridged to
# streamable HTTP by mcp-proxy so it can be used as a remote MCP connector.
#
# Build & push (OKE nodes are aarch64; OCIR creds in Vault at kv/oci/ocir):
#   docker build --platform linux/arm64 -t syd.ocir.io/sdajdczqv0qo/garmin-mcp:0.2.2 images/garmin-mcp
#   docker push syd.ocir.io/sdajdczqv0qo/garmin-mcp:0.2.2
FROM python:3.14-slim@sha256:a2b82f3c48559aa0a8446d9af49826b6e2b2016f4cd2afabfe6013ec53729170

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && pip install --no-cache-dir \
       mcp-proxy==0.12.0 \
       "mcp==1.27.2" \
       "garmin-mcp @ git+https://github.com/Taxuspt/garmin_mcp@7af73ebf9b4073cf3b1ad1cb42d351f38e7ef47c" \
    # garmin_mcp pins garminconnect==0.3.2, whose email one-time-code login is
    # broken (fixed 0.3.6-0.3.9); Garmin emails a code on new sign-ins even
    # without MFA. Override the pin.
    && pip install --no-cache-dir garminconnect==0.3.17 \
    && apt-get purge -y git && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# Token dir; refreshed in place by garminconnect, re-minted from credentials by
# the launcher when Garmin rejects the refresh token.
ENV GARMINTOKENS=/data/garmintokens

COPY garmin_mcp_launcher.py /app/garmin_mcp_launcher.py

EXPOSE 8080
# Streamable HTTP served at /mcp (also /sse for legacy clients).
CMD ["mcp-proxy", "--port=8080", "--host=0.0.0.0", "--stateless", "--pass-environment", "python", "/app/garmin_mcp_launcher.py"]
