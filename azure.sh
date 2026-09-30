#!/bin/bash
set -e

# ==================== Configuration ====================
TARGET_LOCATIONS=(
  "eastus2"
)

# Base models deployed in every target region. Leave empty if none are needed.
BASE_MODELS=(
)

# Extra models deployed only in eastus2 (includes gpt-image-2 and the rest of the list)
# Format: "model-name|version|SKU|capacity"
EASTUS2_EXTRA_MODELS=(
  "gpt-image-2|2026-04-21|GlobalStandard|2"
  "gpt-6-astra|2026-09-03|GlobalStandard|1000"
  "gpt-6-sol|2026-09-22|GlobalStandard|1000"
  "gpt-6-luna|2026-09-22|GlobalStandard|1000"
  "gpt-4o|2024-11-20|GlobalStandard|450"
  "gpt-5.6-sol|2026-07-09|GlobalStandard|1000"
  "gpt-5.6-luna|2026-07-09|GlobalStandard|1000"
  "gpt-5.6-terra|2026-07-09|GlobalStandard|1000"
  "gpt-5.5|2026-04-24|GlobalStandard|1000"
  "gpt-5.4|2026-03-05|GlobalStandard|1000"
  "gpt-5.4-mini|2026-03-17|GlobalStandard|1000"
  "gpt-5-mini|2025-08-07|GlobalStandard|1000"
  "gpt-image-2.5-flare|2026-09-08|GlobalStandard|2"
  "gpt-image-2.5-sunburst|2026-09-08|GlobalStandard|2"
)

# Azure built-in default content safety policy (Default V2, includes Jailbreak, cannot be relaxed)
DEFAULT_RAI_POLICY="Microsoft.DefaultV2"
# Legacy custom loose policy left by the old script. Deleted after deployments are rebound to the default policy.
LEGACY_LOOSE_POLICY="custom-lowest-filter"
# ================================================

# Models that failed to deploy, keyed by region
declare -A FAILED_MODELS

# Generate a 12-character random lowercase string (parent resource account name)
gen_random_str() {
  tr -dc 'a-z' < /dev/urandom 2>/dev/null | head -c 12 || echo "az$(date +%s | tail -c 8)"
}

# After deployments are rebound to the default policy, delete the old custom-lowest-filter (skip if missing)
remove_legacy_loose_filter() {
  local ACC_NAME="$1"
  local RG="$2"

  local API_URL="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${ACC_NAME}/raiPolicies/${LEGACY_LOOSE_POLICY}?api-version=2024-10-01"

  if ! az rest --method get --uri "$API_URL" -o none 2>/dev/null; then
    echo "[✔] Account [${ACC_NAME}] has no leftover policy [${LEGACY_LOOSE_POLICY}]"
    return 0
  fi

  echo "[*] Deleting leftover policy [${LEGACY_LOOSE_POLICY}]..."
  if az rest --method delete --uri "$API_URL" -o none 2>/dev/null; then
    echo "[✔] Deleted [${LEGACY_LOOSE_POLICY}]. Deployments use the Azure default policy [${DEFAULT_RAI_POLICY}]"
  else
    echo "[!] Failed to delete [${LEGACY_LOOSE_POLICY}]. If deployments still reference it, confirm they are rebound to [${DEFAULT_RAI_POLICY}] first."
  fi
}

# Deploy a model. If it already exists, rebind it to the Azure default content safety policy.
deploy_model_if_not_exists() {
  local ACC_NAME="$1"
  local RG="$2"
  local M_NAME="$3"
  local M_VER="$4"
  local SKU="$5"
  local CAP="$6"
  local REGION_KEY="$7"

  # List existing deployment names on the account
  EXISTING_DEPLOYMENTS=$(az cognitiveservices account deployment list \
    --name "$ACC_NAME" \
    --resource-group "$RG" \
    --subscription "$SUB_ID" \
    --query "[].name" -o tsv 2>/dev/null || echo "")

  # Rebind when a deployment with the same name already exists
  if echo "$EXISTING_DEPLOYMENTS" | grep -qw "$M_NAME"; then
    echo "[➔] Model [${M_NAME}] already exists on account [${ACC_NAME}]. Rebinding to the Azure default policy [${DEFAULT_RAI_POLICY}]..."

    local UPDATE_URL="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${ACC_NAME}/deployments/${M_NAME}?api-version=2024-10-01"
    local UPDATE_BODY="{
      \"sku\": { \"name\": \"${SKU}\", \"capacity\": ${CAP} },
      \"properties\": {
        \"model\": { \"format\": \"OpenAI\", \"name\": \"${M_NAME}\", \"version\": \"${M_VER}\" },
        \"raiPolicyName\": \"${DEFAULT_RAI_POLICY}\"
      }
    }"
    if ! az rest --method put --uri "$UPDATE_URL" --body "$UPDATE_BODY" -o none 2>/dev/null; then
      echo "[!] Failed to rebind model [${M_NAME}] to the default policy."
      if [ -z "${FAILED_MODELS[$REGION_KEY]}" ]; then
        FAILED_MODELS["$REGION_KEY"]="$M_NAME"
      else
        FAILED_MODELS["$REGION_KEY"]="${FAILED_MODELS[$REGION_KEY]}, $M_NAME"
      fi
    fi
  else
    echo "[*] Deploying new model [${M_NAME}] (version: ${M_VER}, capacity: ${CAP})..."

    local DEPLOY_URL="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${ACC_NAME}/deployments/${M_NAME}?api-version=2024-10-01"

    local DEPLOY_BODY="{
      \"sku\": { \"name\": \"${SKU}\", \"capacity\": ${CAP} },
      \"properties\": {
        \"model\": {
          \"format\": \"OpenAI\",
          \"name\": \"${M_NAME}\",
          \"version\": \"${M_VER}\"
        },
        \"raiPolicyName\": \"${DEFAULT_RAI_POLICY}\"
      }
    }"

    if az rest --method put --uri "$DEPLOY_URL" --body "$DEPLOY_BODY" -o none 2>/dev/null; then
      echo "[✔] Model [${M_NAME}] deployed and using the Azure default policy [${DEFAULT_RAI_POLICY}]"
    else
      echo "[!] REST deployment failed. Trying the generic CLI deployment..."
      if ! az cognitiveservices account deployment create \
        --name "$ACC_NAME" \
        --resource-group "$RG" \
        --subscription "$SUB_ID" \
        --deployment-name "$M_NAME" \
        --model-name "$M_NAME" \
        --model-format OpenAI \
        --model-version "$M_VER" \
        --sku-name "$SKU" \
        --sku-capacity "$CAP" \
        -o table 2>&1; then

        echo "[✘] Warning: deployment of model [${M_NAME}] was blocked."
        if [ -z "${FAILED_MODELS[$REGION_KEY]}" ]; then
          FAILED_MODELS["$REGION_KEY"]="$M_NAME"
        else
          FAILED_MODELS["$REGION_KEY"]="${FAILED_MODELS[$REGION_KEY]}, $M_NAME"
        fi
      fi
    fi
  fi
}

usage() {
  echo "Usage: $0 <subscriptionId>"
  echo "Example: $0 00000000-0000-0000-0000-000000000000"
  exit 1
}

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "[✘] Error: a target subscription ID is required. With multiple subscriptions, do not rely on the az default subscription."
  usage
fi

SUB_ID="$1"

if ! [[ "$SUB_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
  echo "[✘] Error: invalid subscription ID format: ${SUB_ID}"
  usage
fi

echo "=========================================="
echo " Target subscription: ${SUB_ID}"
echo " Looking up AI / OpenAI resource groups in this subscription..."
echo "=========================================="

if ! az account show --subscription "$SUB_ID" --query "{id:id, name:name}" -o table; then
  echo "[✘] Error: cannot access subscription [${SUB_ID}]. Confirm that az login succeeded and this subscription is available to the current account."
  exit 1
fi

RG_NAME=$(az cognitiveservices account list --subscription "$SUB_ID" --query "[?kind=='OpenAI' || kind=='AIServices'].resourceGroup | [0]" -o tsv)

if [ -z "$RG_NAME" ] || [ "$RG_NAME" == "null" ]; then
    RG_NAME=$(az group list --subscription "$SUB_ID" --query "[0].name" -o tsv)
fi

if [ -z "$RG_NAME" ] || [ "$RG_NAME" == "null" ]; then
    echo "[✘] Error: no existing resource group was found in this subscription."
    exit 1
fi

echo "[✔] Target resource group: [ ${RG_NAME} ]"

# Load existing accounts
EXISTING_ACCOUNTS_JSON=$(az cognitiveservices account list \
  --resource-group "${RG_NAME}" \
  --subscription "$SUB_ID" \
  --query "[?kind=='OpenAI' || kind=='AIServices'].{name:name, location:location}" -o json)

declare -A DEPLOYED_ACCOUNTS

for TARGET in "${TARGET_LOCATIONS[@]}"; do
  TARGET_CLEAN=$(echo "$TARGET" | tr -d ' -' | tr '[:upper:]' '[:lower:]')
  
  MATCHED_ACCOUNT=$(echo "$EXISTING_ACCOUNTS_JSON" | jq -r ".[] | select((.location | ascii_downcase | gsub(\"[ -]\"; \"\")) == \"${TARGET_CLEAN}\") | .name" | head -n 1)

  echo -e "\n------------------------------------------"
  CURRENT_ACC=""

  if [ -n "$MATCHED_ACCOUNT" ] && [ "$MATCHED_ACCOUNT" != "null" ]; then
    echo "[✔] Region [${TARGET}] already has account: ${MATCHED_ACCOUNT}"
    CURRENT_ACC="$MATCHED_ACCOUNT"
  else
    RANDOM_ACCOUNT_NAME=$(gen_random_str)
    echo "[*] Region [${TARGET}] has no account. Creating parent resource: ${RANDOM_ACCOUNT_NAME}..."
    
    az cognitiveservices account create \
      --name "${RANDOM_ACCOUNT_NAME}" \
      --resource-group "${RG_NAME}" \
      --subscription "$SUB_ID" \
      --location "${TARGET}" \
      --kind OpenAI \
      --sku S0 \
      --custom-domain "${RANDOM_ACCOUNT_NAME}" \
      -o table

    CURRENT_ACC="$RANDOM_ACCOUNT_NAME"
  fi

  DEPLOYED_ACCOUNTS["$TARGET"]="$CURRENT_ACC"

  # 1. Deploy the base model list
  if [ ${#BASE_MODELS[@]} -gt 0 ]; then
    echo "[*] Deploying the base model group..."
    for ITEM in "${BASE_MODELS[@]}"; do
      IFS='|' read -r M_NAME M_VER M_SKU M_CAP <<< "$ITEM"
      deploy_model_if_not_exists "$CURRENT_ACC" "$RG_NAME" "$M_NAME" "$M_VER" "$M_SKU" "$M_CAP" "$TARGET"
    done
  fi

  # 2. In eastus2, also deploy the region-specific model group
  if [ "$TARGET_CLEAN" == "eastus2" ]; then
    echo -e "\n[★] eastus2 detected. Deploying the region-specific model group..."
    for ITEM in "${EASTUS2_EXTRA_MODELS[@]}"; do
      IFS='|' read -r M_NAME M_VER M_SKU M_CAP <<< "$ITEM"
      deploy_model_if_not_exists "$CURRENT_ACC" "$RG_NAME" "$M_NAME" "$M_VER" "$M_SKU" "$M_CAP" "$TARGET"
    done
  fi

  # After rebinding to the default policy, delete the old custom loose policy
  remove_legacy_loose_filter "$CURRENT_ACC" "$RG_NAME"
done

# ==================== Summary: keys and endpoints ====================
echo -e "\n=========================================================================================="
echo "                        Deployment complete - KEY & URL summary                            "
echo " Subscription: ${SUB_ID}"
echo "=========================================================================================="

for TARGET in "${TARGET_LOCATIONS[@]}"; do
  ACC_NAME="${DEPLOYED_ACCOUNTS[$TARGET]}"
  
  if [ -n "$ACC_NAME" ]; then
    ENDPOINT=$(az cognitiveservices account show \
      --name "$ACC_NAME" \
      --resource-group "$RG_NAME" \
      --subscription "$SUB_ID" \
      --query "properties.endpoint" -o tsv 2>/dev/null | sed 's/\/$//')
    
    if [ -n "$ENDPOINT" ]; then
      URL="${ENDPOINT}"
      KEY=$(az cognitiveservices account keys list \
        --name "$ACC_NAME" \
        --resource-group "$RG_NAME" \
        --subscription "$SUB_ID" \
        --query "key1" -o tsv 2>/dev/null)

      echo "[Region: ${TARGET}]"
      echo "  Account Name : ${ACC_NAME}"
      echo "  URL          : ${URL}"
      echo "  Key          : ${KEY}"
      echo "${URL}|${KEY}"
      
      # Note any models that failed to deploy
      if [ -n "${FAILED_MODELS[$TARGET]}" ]; then
        echo "  Failed models: ${FAILED_MODELS[$TARGET]}"
      else
        echo "  Model status : all deployed"
      fi
      echo "------------------------------------------------------------------------------------------"
    fi
  fi
done
