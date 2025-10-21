#!/bin/bash

set -euo pipefail

# Check dependencies
for cmd in curl yq fzf; do
  command -v $cmd >/dev/null 2>&1 || {
    echo >&2 "Required command '$cmd' is not installed."; exit 1;
  }
done

SHOW_JSON=false
SHOW_CONDITION_KEYS=false
SHOW_RESOURCE_DETAILS=false
SHOW_ALL_RESOURCE_DETAILS=false
SERVICE_NAME_INPUT=""

export SHOW_JSON
export SHOW_CONDITION_KEYS
export SHOW_RESOURCE_DETAILS
export SHOW_ALL_RESOURCE_DETAILS
export SERVICE_NAME_INPUT

function json_pprint() {
  # Build JSON array string manually
  JSON_ARRAY="["
  first=true
  while IFS= read -r action; do
    # skip empty lines
    [ -z "$action" ] && continue
    # prepend service name
    item="\"${SERVICE_NAME_INPUT}:${action}\""
    if $first; then
      JSON_ARRAY+=$item
      first=false
    else
      JSON_ARRAY+=",$item"
    fi
  done <<< "$1"
  JSON_ARRAY+="]"

  # Pretty print JSON array with yq
  echo "$JSON_ARRAY" | yq -o json eval --prettyPrint -
}

# Parse flags and positional args
for arg in "$@"; do
  if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    echo "Usage: $0 [options] [service-name]"
    echo ""
    echo "Options:"
    echo "  -h, --help                 Show this help message and exit"
    echo "  -j, --json                 Output results in JSON format"
    echo "      --condition-keys       List condition keys for the specified service"
    echo "      --resource-details     Show details for the selected resource type"
    echo "      --all-resource-details Show details for all resource types"
    echo "Service Name:"
    echo "  You can provide the AWS service name as a positional argument."
    echo "  If not provided, an interactive fuzzy search will be launched."
    exit 0
  elif [ "$arg" = "--json" ] || [ "$arg" = "-j" ]; then
    SHOW_JSON=true
  elif [ "$arg" = "--condition-keys" ]; then
    SHOW_CONDITION_KEYS=true
  elif [ "$arg" = "--resource-details" ]; then
    SHOW_RESOURCE_DETAILS=true
  elif [ "$arg" = "--all-resource-details" ]; then
    SHOW_ALL_RESOURCE_DETAILS=true
  else
    SERVICE_NAME_INPUT=$(echo "$arg" | tr '[:upper:]' '[:lower:]')
  fi
done

SERVICE_LIST=$(curl -s "https://servicereference.us-east-1.amazonaws.com/v1/service-list.json")

# If no service name is provided launch fuzzy search
if [ "$SERVICE_NAME_INPUT" == "" ]; then
  SERVICE_NAME_INPUT=$(echo "$SERVICE_LIST" | \
    yq -r '.[] | .service' | \
    sort | \
    fzf --prompt="Select AWS service: ")

  if [ -z "$SERVICE_NAME_INPUT" ]; then
    echo "No service selected. Exiting."
    exit 1
  fi
fi

SERVICE_URL=$(echo "$SERVICE_LIST" | \
  yq -r '.[] | select(.service == env(SERVICE_NAME_INPUT)) | .url')

if [ -z "$SERVICE_URL" ]; then
  echo "Service '$SERVICE_NAME_INPUT' not found."
  exit 1
fi

SERVICE_JSON=$(curl -s "$SERVICE_URL")

if $SHOW_CONDITION_KEYS; then
  CONDITION_KEYS=$(echo "$SERVICE_JSON" | \
    yq -r '.ConditionKeys[]?.Name' 2>/dev/null | sort -u)

  if [ -z "$CONDITION_KEYS" ]; then
    echo "No condition keys found for service '$SERVICE_NAME_INPUT'."
    exit 0
  fi

  if $SHOW_JSON; then
    for k in $CONDITION_KEYS; do
      echo "\"$k\""
    done | jq -s '.'
  else
    echo "$CONDITION_KEYS"
  fi
  exit 0
fi

RESOURCE_TYPES=$(echo "$SERVICE_JSON" | \
  yq -r '.Actions[].Resources[].Name' 2>/dev/null | \
  sort -u)

if $SHOW_ALL_RESOURCE_DETAILS; then
  if [ -z "$RESOURCE_TYPES" ]; then
    echo "Service has no resource types."
    exit 1
  fi
  RESOURCE_DETAILS=$(echo "$SERVICE_JSON" | yq -r '.Resources' 2>/dev/null)

  if $SHOW_JSON; then
    echo "$RESOURCE_DETAILS" | yq -ojson
  else
    echo "$RESOURCE_DETAILS" | yq -p json -o yaml
  fi
  exit 0
fi

# If no resource types found for the service preselect the ALL option
if [ -z "$RESOURCE_TYPES" ]; then
  SELECTED_RESOURCE="[ All ]"
else
  RESOURCE_TYPES_WITH_ALL=$(echo -e "[ All ]\n$RESOURCE_TYPES")
  SELECTED_RESOURCE=$(echo "$RESOURCE_TYPES_WITH_ALL" | \
    fzf --prompt="Select resource type to filter actions: ")

  if [ -z "$SELECTED_RESOURCE" ]; then
    echo "No resource type selected. Exiting."
    exit 1
  fi
fi
export SELECTED_RESOURCE

if $SHOW_RESOURCE_DETAILS; then
  if [ -z "$RESOURCE_TYPES" ]; then
    echo "Service has no resource types."
    exit 1
  fi
  RESOURCE_DETAILS=$(echo "$SERVICE_JSON" | \
    yq -r '[.Resources[] | select(.Name == env(SELECTED_RESOURCE))]' 2>/dev/null)

  if $SHOW_JSON; then
    echo "$RESOURCE_DETAILS" | yq -ojson
  else
    echo "$RESOURCE_DETAILS"
  fi
  exit 0
fi

if [ "$SELECTED_RESOURCE" = "[ All ]" ]; then
  FILTERED_ACTIONS=$(echo "$SERVICE_JSON" | yq -r '.Actions')
else
  FILTERED_ACTIONS=$(echo "$SERVICE_JSON" | yq -r '[.Actions[] | 
    select(.Resources[].Name == env(SELECTED_RESOURCE))]
  ')
fi

# Now collect all capabilities from these filtered actions
CAPABILITIES=$(echo "$FILTERED_ACTIONS" | \
  yq -r '.[]?.Annotations?.Properties | to_entries[] | select(.value == true) | .key' 2>/dev/null | sort -u)

# Check if IsReadOnly is needed
HAS_READ_ONLY=$(echo "$FILTERED_ACTIONS" | \
  yq -r '
    .[] | select(
      (.Annotations.Properties // {} | to_entries | map(.value) | all_c(. == false))
    ) | .Name
  ' | awk 'NR > 0 { found=1; exit } END { print (found ? "yes" : "no") }' || true)

# Add synthetic capability if needed
if [ "$HAS_READ_ONLY" = "yes" ]; then
  CAPABILITIES=$(echo -e "IsReadOnly\n$CAPABILITIES" | sort -u)
fi

CAPABILITY_COUNT=$(echo "$CAPABILITIES" | grep -c '^')

if [ "$CAPABILITY_COUNT" -eq 1 ]; then
  SELECTED_CAPABILITY="$CAPABILITIES"
else
  CAPABILITIES_WITH_ALL=$(echo -e "[ All ]\n$CAPABILITIES")
  SELECTED_CAPABILITY=$(echo "$CAPABILITIES_WITH_ALL" | \
    fzf --prompt="Select capability to filter actions: ")

  if [ -z "$SELECTED_CAPABILITY" ]; then
    echo "No capability selected. Exiting."
    exit 1
  fi
fi
export SELECTED_CAPABILITY

if [ "$SELECTED_RESOURCE" = "[ All ]" ] && [ "$SELECTED_CAPABILITY" = "[ All ]" ]; then
  QUERY=".Actions[].Name"

elif [ "$SELECTED_RESOURCE" = "[ All ]" ]; then
  if [ "$SELECTED_CAPABILITY" = "IsReadOnly" ]; then
    QUERY='.Actions[] |
      select(
        (.Annotations.Properties | to_entries | map(select(.value == true)) | length) == 0
      ) |
      .Name'
  else
    QUERY=".Actions[] |
      select(.Annotations.Properties[env(SELECTED_CAPABILITY)] == true) |
      .Name"
  fi

elif [ "$SELECTED_CAPABILITY" = "[ All ]" ]; then
  QUERY=".Actions[] |
    select(.Resources[].Name == env(SELECTED_RESOURCE)) |
    .Name"

else
  if [ "$SELECTED_CAPABILITY" = "IsReadOnly" ]; then
    QUERY='.Actions[] |
      select(.Resources[].Name == env(SELECTED_RESOURCE)) |
      select(
        (.Annotations.Properties | to_entries | map(select(.value == true)) | length) == 0
      ) |
      .Name'
  else
    QUERY=".Actions[] |
      select(.Annotations.Properties[env(SELECTED_CAPABILITY)] == true) |
      select(.Resources[].Name == env(SELECTED_RESOURCE)) |
      .Name"
  fi
fi

ACTIONS=$(echo "$SERVICE_JSON" | yq -r "$QUERY")

ACTIONS=$(echo "$SERVICE_JSON" | yq -r "$QUERY")

if $SHOW_JSON; then
  json_pprint "$ACTIONS"
else
  echo "$ACTIONS"
fi
