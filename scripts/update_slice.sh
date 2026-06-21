#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Configuration
CONTAINER_NAME="open5gs_5gc"
DB_NAME="open5gs"

# Function to display usage instructions
usage() {
    echo "Usage: $0 <sst> <sd>"
    echo "Example: $0 1 111111"
    exit 1
}

# Check if exactly two arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Error: Invalid number of arguments."
    usage
fi

# Assign arguments to variables
SST=$1
SD=$2

# Validate that SST is a number
if ! [[ "$SST" =~ ^[0-9]+$ ]]; then
    echo "Error: SST must be a numeric value (e.g., 1)."
    exit 1
fi

# Validate that SD is a 6-digit hex string (remove 0x prefix if provided)
SD="${SD#0x}" # strips '0x' if user typed 0x111111
if ! [[ "$SD" =~ ^[0-9a-fA-F]{6}$ ]]; then
    echo "Error: SD must be a 6-character hex value (e.g., 111111 or ffffff)."
    exit 1
fi

echo "Updating all subscribers in container '$CONTAINER_NAME'..."
echo "Setting target slice to -> SST: $SST, SD: 0x$SD"

# Construct the MongoDB query string
# This updates ALL documents ({}) by setting the first element in the slice array
MONGO_CMD="db.subscribers.updateMany({}, { \$set: { 'slice.0.sst': $SST, 'slice.0.sd': '$SD' } })"

# Execute the command inside the docker container
# Checks for mongosh first, falls back to legacy mongo shell if needed
if docker exec "$CONTAINER_NAME" which mongosh > /dev/null 2>&1; then
    docker exec -i "$CONTAINER_NAME" mongosh "$DB_NAME" --eval "$MONGO_CMD"
else
    docker exec -i "$CONTAINER_NAME" mongo "$DB_NAME" --eval "$MONGO_CMD"
fi

echo "Successfully triggered slice update for all subscribers."