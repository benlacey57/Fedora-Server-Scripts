#!/usr/bin/env bash
# ==============================================================================
# Script: cloudflare-setup.sh
# Description: Cleans existing DNS records and provisions fresh records & wildcard setup
# ==============================================================================
set -euo pipefail

ENV_FILE="../.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    if [ -f "../.env" ]; then
        source ".env"
    else
        echo "ERROR: .env file not found." >&2
        exit 1
    fi
fi

if [ -z "${CF_API_TOKEN:-}" ] || [ "$CF_API_TOKEN" = "your_cloudflare_api_token_here" ]; then
    echo "ERROR: CF_API_TOKEN is not configured in your .env file." >&2
    exit 1
fi

API_BASE="https://api.cloudflare.com/client/v4"

echo "=== 1. Verifying Cloudflare API Token & Connection ==="
VERIFY_RES=$(curl -s -X GET "$API_BASE/user/tokens/verify" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")

if [ "$(echo "$VERIFY_RES" | jq -r '.success')" = "true" ]; then
    echo "[PASS] Cloudflare API token is valid and active."
else
    echo "[FAIL] Token verification failed:"
    echo "$VERIFY_RES" | jq '.errors'
    exit 1
fi

echo "=== 2. Fetching Zone ID for domain (${DOMAIN}) ==="
ZONE_RES=$(curl -s -X GET "$API_BASE/zones?name=${DOMAIN}" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RES" | jq -r '.result[0].id // empty')

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
    echo "[FAIL] Could not resolve Zone ID for domain ${DOMAIN}."
    exit 1
else
    echo "[PASS] Resolved Zone ID: $ZONE_ID"
fi

echo "=== 3. Purging Existing DNS Records for ${DOMAIN} ==="
RECORDS_RES=$(curl -s -X GET "$API_BASE/zones/${ZONE_ID}/dns_records?per_page=100" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")

RECORD_IDS=$(echo "$RECORDS_RES" | jq -r '.result[].id')

for rec_id in $RECORD_IDS; do
    if [ -n "$rec_id" ] && [ "$rec_id" != "null" ]; then
        echo "Deleting DNS record ID: $rec_id..."
        curl -s -X DELETE "$API_BASE/zones/${ZONE_ID}/dns_records/$rec_id" \
             -H "Authorization: Bearer $CF_API_TOKEN" \
             -H "Content-Type: application/json" >/dev/null
    fi
done
echo "[PASS] Existing DNS records cleared successfully."

echo "=== 4. Provisioning Fresh DNS Records ==="
# Wildcard A Record (*.laceynet.co.uk -> LOCAL_IP)
echo "Creating wildcard A record (*.${DOMAIN} -> ${LOCAL_IP})..."
curl -s -X POST "$API_BASE/zones/${ZONE_ID}/dns_records" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"*.'${DOMAIN}'","content":"'${LOCAL_IP}'","ttl":1,"proxied":true}' >/dev/null

# Root A Record (laceynet.co.uk -> LOCAL_IP)
echo "Creating root A record (${DOMAIN} -> ${LOCAL_IP})..."
curl -s -X POST "$API_BASE/zones/${ZONE_ID}/dns_records" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"'${DOMAIN}'","content":"'${LOCAL_IP}'","ttl":1,"proxied":true}' >/dev/null

echo "✅ Cloudflare DNS reset and provisioning completed successfully."
