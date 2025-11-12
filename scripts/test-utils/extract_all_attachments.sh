#!/bin/bash

# Extract all attachments from xcresult bundle by brute force
# Usage: ./extract_all_attachments.sh <xcresult_path> <output_dir>

XCRESULT="$1"
OUTPUT_DIR="${2:-extracted}"

if [ ! -d "$XCRESULT" ]; then
    echo "Error: xcresult not found: $XCRESULT"
    exit 1
fi

echo "🔍 Extracting all attachments from: $XCRESULT"
echo "📁 Output: $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR"

# Get all data file IDs
DATA_IDS=$(ls "$XCRESULT/Data/" | grep "^data\." | sed 's/^data\.//')

count=0
for id in $DATA_IDS; do
    temp_file=$(mktemp)
    
    # Try to export this data file
    xcrun xcresulttool export --legacy --type file \
        --path "$XCRESULT" \
        --id "$id" \
        --output-path "$temp_file" 2>/dev/null
    
    if [ -f "$temp_file" ]; then
        # Check if it's a PNG image
        file_type=$(file -b "$temp_file" | head -1)
        if [[ "$file_type" == *"PNG image"* ]]; then
            output_path="${OUTPUT_DIR}/attachment_${count}.png"
            mv "$temp_file" "$output_path"
            echo "✓ Extracted PNG: attachment_${count}.png"
            ((count++))
        else
            rm -f "$temp_file"
        fi
    else
        rm -f "$temp_file"
    fi
done

echo ""
if [ "$count" -gt 0 ]; then
    echo "✅ Extracted $count PNG attachment(s)"
else
    echo "⚠️  No PNG attachments found"
fi
