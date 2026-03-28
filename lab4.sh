#!/bin/bash
clear

echo "Starting Execution..."

# Step 1: Set environment variables
echo "Setting environment variables..."
export PROCESSOR_NAME=form-processor
export PROJECT_ID=$(gcloud config get-value core/project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export REGION=$(gcloud compute project-info describe \
--format="value(commonInstanceMetadata.items[google-compute-default-region])")

export GEO_CODE_REQUEST_PUBSUB_TOPIC=geocode_request
export BUCKET_LOCATION=$REGION

# Step 2: Create GCS buckets
echo "Creating GCS buckets..."
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-input-invoices || true
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-output-invoices || true
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-archived-invoices || true

# 🔥 Ensure GCS service account exists
echo "Ensuring GCS service account exists..."
gsutil ls > /dev/null 2>&1
sleep 10

# Step 3: Enable required services
echo "Enabling required services..."
gcloud services enable documentai.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  geocoding-backend.googleapis.com

# Step 4: Create API key
echo "Creating API key..."
gcloud alpha services api-keys create --display-name="awesome" || true

# Step 5: Get API key
echo "Fetching API key..."
KEY_NAME=$(gcloud alpha services api-keys list \
  --format="value(name)" --filter "displayName=awesome" | head -n 1)

API_KEY=$(gcloud alpha services api-keys get-key-string $KEY_NAME \
  --format="value(keyString)")

# Step 6: Restrict API key
echo "Restricting API key..."
curl -X PATCH \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{
    "restrictions": {
      "apiTargets": [
        {
          "service": "geocoding-backend.googleapis.com"
        }
      ]
    }
  }' \
  "https://apikeys.googleapis.com/v2/$KEY_NAME?updateMask=restrictions"

# Step 7: Copy demo assets
echo "Copying demo assets..."
mkdir -p ~/documentai-pipeline-demo
gcloud storage cp -r gs://spls/gsp927/documentai-pipeline-demo/* \
  ~/documentai-pipeline-demo/

# Step 8: Create Document AI Processor
echo "Creating Document AI Processor..."
curl -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d "{
    \"display_name\": \"$PROCESSOR_NAME\",
    \"type\": \"FORM_PARSER_PROCESSOR\"
  }" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors"

# Step 9: BigQuery setup
echo "Creating BigQuery dataset..."
bq --location=US mk -d ${PROJECT_ID}:invoice_parser_results || true

cd ~/documentai-pipeline-demo/scripts/table-schema/
bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json || true
bq mk --table invoice_parser_results.geocode_details geocode_details.json || true

# Step 10: Pub/Sub topic
echo "Creating Pub/Sub topic..."
gcloud pubsub topics create ${GEO_CODE_REQUEST_PUBSUB_TOPIC} || true

# Step 11: IAM bindings (FIXED ✅)
echo "Assigning IAM roles..."
GCS_SA="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${GCS_SA}" \
  --role="roles/pubsub.publisher" || true

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${GCS_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" || true

# Step 12: Deploy functions
cd ~/documentai-pipeline-demo/scripts
export CLOUD_FUNCTION_LOCATION=$REGION

deploy_function() {
  NAME=$1
  SOURCE=$2
  ENTRY=$3
  TRIGGER=$4

  while true; do
    echo "Deploying $NAME..."

    gcloud functions deploy $NAME \
      --no-gen2 \
      --region=$CLOUD_FUNCTION_LOCATION \
      --runtime=python311 \
      --entry-point=$ENTRY \
      --source=$SOURCE \
      --timeout=400 \
      $TRIGGER

    if [ $? -eq 0 ]; then
      echo "$NAME deployed successfully!"
      break
    else
      echo "Retrying $NAME..."
      sleep 20
    fi
  done
}

# Deploy process-invoices
deploy_function "process-invoices" \
  "cloud-functions/process-invoices" \
  "process_invoice" \
  "--trigger-resource=gs://${PROJECT_ID}-input-invoices --trigger-event=google.storage.object.finalize"

# Deploy geocode-addresses
deploy_function "geocode-addresses" \
  "cloud-functions/geocode-addresses" \
  "process_address" \
  "--trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC}"

# Step 13: Get processor ID
echo "Fetching Processor ID..."
PROCESSOR_ID=$(curl -s -X GET \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" \
  | grep '"name":' | head -1 | sed -E 's/.*processors\/([^"]+)".*/\1/')

# Step 14: Update functions with env vars
echo "Updating functions..."

gcloud functions deploy process-invoices \
  --no-gen2 \
  --region=$CLOUD_FUNCTION_LOCATION \
  --runtime=python311 \
  --entry-point=process_invoice \
  --source=cloud-functions/process-invoices \
  --update-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=us,GCP_PROJECT=${PROJECT_ID} \
  --trigger-resource=gs://${PROJECT_ID}-input-invoices \
  --trigger-event=google.storage.object.finalize

gcloud functions deploy geocode-addresses \
  --no-gen2 \
  --region=$CLOUD_FUNCTION_LOCATION \
  --runtime=python311 \
  --entry-point=process_address \
  --source=cloud-functions/geocode-addresses \
  --update-env-vars=API_key=${API_KEY} \
  --trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC}

# Step 15: Upload sample files
echo "Uploading sample files..."
gsutil cp gs://spls/gsp927/documentai-pipeline-demo/sample-files/* \
  gs://${PROJECT_ID}-input-invoices/

echo "🎉 Lab Completed Successfully!"