#!/bin/bash
# send_to_copilot.sh - Send prompts to Copilot using HTTP proxy

PROXY_URL="http://localhost:8765"

# Check if reading from stdin or argument
if [ -t 0 ]; then
    # Terminal input (argument)
    if [ $# -eq 0 ]; then
        echo "Usage: $0 'your prompt here'"
        echo "   or: echo 'prompt' | $0"
        exit 1
    fi
    PROMPT="$*"
else
    # Stdin
    PROMPT=$(cat)
fi

# Check if proxy is running
if ! curl -s "$PROXY_URL/status" > /dev/null 2>&1; then
    echo "❌ Query Proxy is not running!"
    echo ""
    echo "Please start it in VS Code:"
    echo "  1. Press Cmd+Shift+P"
    echo "  2. Run 'Query Proxy: Start Server'"
    echo ""
    echo "Or check if the extension is installed:"
    echo "  code --list-extensions | grep query-proxy"
    exit 1
fi

# Send the query
echo "📤 Sending query to Copilot Chat via HTTP proxy..."

RESPONSE=$(curl -X POST "$PROXY_URL/query" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg q "$PROMPT" '{query: $q}')" \
  --silent)

if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    echo "✅ Query sent successfully!"
    echo "$RESPONSE" | jq -r '.message // "Prompt delivered to Copilot"'
else
    echo "❌ Error sending query:"
    echo "$RESPONSE" | jq -r '.error // "Unknown error"'
    exit 1
fi
