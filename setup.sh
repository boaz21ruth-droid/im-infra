#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env
if [ ! -f "$DIR/.env" ]; then
  echo "Error: $DIR/.env not found"
  exit 1
fi
source "$DIR/.env"

if [ -z "$HOST_IP" ]; then
  echo "Error: HOST_IP not set in .env"
  exit 1
fi

echo "HOST_IP = $HOST_IP"

# 1. openim-server-config/minio.yml
sed "s|\${HOST_IP}|${HOST_IP}|g" \
  "$DIR/openim-server-config/minio.yml.template" \
  > "$DIR/openim-server-config/minio.yml"
echo "✓ openim-server-config/minio.yml"

# 2. Flutter env.json (for --dart-define-from-file)
cat > "$DIR/env.json" <<EOF
{
  "HOST_IP": "${HOST_IP}"
}
EOF
echo "✓ env.json"

# 3. Restart openim-server
docker restart openim-server
echo "✓ openim-server restarted"

echo ""
echo "Run Flutter:"
echo "  fvm flutter run --dart-define-from-file=$DIR/env.json -d <device-id>"
