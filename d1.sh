curl -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/processors" \
  -d "{
    \"displayName\": \"$PROCESSOR_NAME\",
    \"type\": \"FORM_PARSER_PROCESSOR\"
  }"
