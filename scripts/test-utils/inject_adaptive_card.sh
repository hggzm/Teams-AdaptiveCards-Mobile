#!/bin/bash

# inject_adaptive_card.sh
# Injects an Adaptive Card JSON into the magic file for testing

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
MAGIC_FILE="${REPO_ROOT}/samples/InjectedCard.json"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 [card.json|--sample|--clear]"
    echo ""
    echo "Options:"
    echo "  card.json    Path to an Adaptive Card JSON file to inject"
    echo "  --sample     Inject a test sample card"
    echo "  --clear      Clear the magic file (restore default behavior)"
    echo "  --stdin      Read JSON from stdin"
    echo ""
    echo "Examples:"
    echo "  $0 my_card.json              # Inject from file"
    echo "  $0 --sample                  # Inject test card"
    echo "  $0 --clear                   # Clear and restore normal behavior"
    echo "  cat card.json | $0 --stdin   # Inject from stdin"
}

inject_sample_card() {
    cat > "$MAGIC_FILE" << 'EOF'
{
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "type": "AdaptiveCard",
  "version": "1.5",
  "body": [
    {
      "type": "TextBlock",
      "text": "🧪 Magic File Injection Test",
      "size": "Large",
      "weight": "Bolder",
      "horizontalAlignment": "Center"
    },
    {
      "type": "TextBlock",
      "text": "This card was injected via InjectedCard.json",
      "wrap": true,
      "horizontalAlignment": "Center"
    },
    {
      "type": "TextBlock",
      "text": "The Visualizer automatically loaded this card instead of showing the file browser.",
      "wrap": true,
      "spacing": "Medium",
      "isSubtle": true
    },
    {
      "type": "FactSet",
      "facts": [
        {
          "title": "Status:",
          "value": "✅ Working"
        },
        {
          "title": "File:",
          "value": "InjectedCard.json"
        },
        {
          "title": "Purpose:",
          "value": "CI/CD Visual Testing"
        }
      ]
    }
  ],
  "actions": [
    {
      "type": "Action.OpenUrl",
      "title": "View Documentation",
      "url": "https://adaptivecards.io"
    }
  ]
}
EOF
    echo -e "${GREEN}✅ Injected sample test card${NC}"
}

clear_magic_file() {
    echo "{}" > "$MAGIC_FILE"
    echo -e "${GREEN}✅ Cleared magic file - normal behavior restored${NC}"
}

inject_from_file() {
    local input_file="$1"
    
    if [ ! -f "$input_file" ]; then
        echo -e "${RED}❌ Error: File not found: $input_file${NC}"
        exit 1
    fi
    
    # Validate JSON
    if ! python3 -m json.tool "$input_file" > /dev/null 2>&1; then
        echo -e "${RED}❌ Error: Invalid JSON in $input_file${NC}"
        exit 1
    fi
    
    # Copy to magic file
    cp "$input_file" "$MAGIC_FILE"
    echo -e "${GREEN}✅ Injected card from: $input_file${NC}"
}

inject_from_stdin() {
    local temp_file=$(mktemp)
    cat > "$temp_file"
    
    # Validate JSON
    if ! python3 -m json.tool "$temp_file" > /dev/null 2>&1; then
        echo -e "${RED}❌ Error: Invalid JSON from stdin${NC}"
        rm -f "$temp_file"
        exit 1
    fi
    
    # Copy to magic file
    mv "$temp_file" "$MAGIC_FILE"
    echo -e "${GREEN}✅ Injected card from stdin${NC}"
}

show_status() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  📋 Magic File Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Location: ${CYAN}$MAGIC_FILE${NC}"
    
    if [ -f "$MAGIC_FILE" ]; then
        local file_size=$(stat -f%z "$MAGIC_FILE" 2>/dev/null || stat -c%s "$MAGIC_FILE" 2>/dev/null)
        local content=$(cat "$MAGIC_FILE")
        
        if [ "$content" = "{}" ] || [ "$file_size" -le 2 ]; then
            echo -e "Status:   ${YELLOW}Empty (Normal Behavior)${NC}"
        else
            echo -e "Status:   ${GREEN}Injected (Magic Mode Active)${NC}"
            echo -e "Size:     ${CYAN}${file_size} bytes${NC}"
            
            # Try to extract card title if present
            if command -v jq &> /dev/null; then
                local title=$(echo "$content" | jq -r '.body[0].text // "N/A"' 2>/dev/null)
                if [ "$title" != "N/A" ] && [ "$title" != "null" ]; then
                    echo -e "Title:    ${CYAN}${title}${NC}"
                fi
            fi
        fi
    else
        echo -e "Status:   ${RED}File not found${NC}"
    fi
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Main logic
CYAN='\033[0;36m'

case "${1:-}" in
    --sample)
        inject_sample_card
        show_status
        ;;
    --clear)
        clear_magic_file
        show_status
        ;;
    --stdin)
        inject_from_stdin
        show_status
        ;;
    --help|-h|"")
        print_usage
        show_status
        ;;
    *)
        inject_from_file "$1"
        show_status
        ;;
esac
