#!/usr/bin/env bash

TABLE_NAME="YOUR_TABLE_NAME"
REGION="us-gov-east-1"
PK_NAME="PK"

STAGE="$1"
OUTPUT_FILE="dynamodb-${STAGE}.json"

echo "[" > "$OUTPUT_FILE"

FIRST=true

while IFS= read -r PK_VALUE; do

  [ -z "$PK_VALUE" ] && continue

  echo "Querying: $PK_VALUE"

  RESULT=$(aws dynamodb get-item \
    --region "$REGION" \
    --table-name "$TABLE_NAME" \
    --key "{\"$PK_NAME\":{\"S\":\"$PK_VALUE\"}}" \
    --output json)

  if [ "$FIRST" = false ]; then
    echo "," >> "$OUTPUT_FILE"
  fi

  FIRST=false

  echo "$RESULT" >> "$OUTPUT_FILE"

done < pks.txt

echo "]" >> "$OUTPUT_FILE"

echo
echo "Saved to $OUTPUT_FILE"