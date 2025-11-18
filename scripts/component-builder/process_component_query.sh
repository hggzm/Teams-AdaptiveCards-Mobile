#!/bin/bash
# process_component_query.sh - Process a component build query using AI agent

set -e

QUERY_FILE="$1"

if [[ -z "$QUERY_FILE" ]] || [[ ! -f "$QUERY_FILE" ]]; then
    echo "❌ Usage: $0 <query_file.json>"
    exit 1
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date +%s)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Component Build Query Processor${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📄 Query file: $QUERY_FILE${NC}"
echo ""

# Parse query
QUERY_ID=$(jq -r '.id' "$QUERY_FILE")
COMPONENT_NAME=$(jq -r '.request.component_name' "$QUERY_FILE")
DESCRIPTION=$(jq -r '.request.description' "$QUERY_FILE")
PROCESSOR=$(jq -r '.processing.processor // "local-poller"' "$QUERY_FILE")

echo -e "${GREEN}🆔 Query ID: $QUERY_ID${NC}"
echo -e "${GREEN}📦 Component: $COMPONENT_NAME${NC}"
echo -e "${GREEN}📝 Description: $DESCRIPTION${NC}"
echo -e "${GREEN}⚙️  Processor: $PROCESSOR${NC}"
echo ""

# Validate processor
if [[ "$PROCESSOR" != "local-poller" ]]; then
    echo -e "${YELLOW}⏭️  Skipping: This query is for processor '$PROCESSOR'${NC}"
    exit 0
fi

# Paths
PACKAGE_DIR="$REPO_ROOT/source/ios/AdaptiveCards/AdaptiveCards/Packages/AdaptiveCardCustomElements"
SOURCES_DIR="$PACKAGE_DIR/Sources/AdaptiveCardCustomElements"
SAMPLES_DIR="$REPO_ROOT/samples"
RESPONSE_FILE="$REPO_ROOT/responses/response_$QUERY_ID.json"
OUTPUT_LOG="$REPO_ROOT/artifacts/test_outputs/build_${QUERY_ID}.txt"

mkdir -p "$(dirname "$OUTPUT_LOG")"
mkdir -p "$REPO_ROOT/responses"

echo -e "${YELLOW}🤖 Starting AI agent to build component...${NC}"
echo ""

# Create agent context file
CONTEXT_FILE="/tmp/component_context_${QUERY_ID}.md"

cat > "$CONTEXT_FILE" <<EOF
# Component Build Request

## Component Specification

**Component Name:** ${COMPONENT_NAME}
**Description:** ${DESCRIPTION}

**Properties:**
\`\`\`json
$(jq -r '.request.properties' "$QUERY_FILE")
\`\`\`

**Example JSON:**
\`\`\`json
$(jq -r '.request.example_json' "$QUERY_FILE")
\`\`\`

## Instructions

You are building a new SwiftUI custom element for the AdaptiveCardCustomElements package.

### Package Location
\`${PACKAGE_DIR}\`

### Files to Create

1. **${COMPONENT_NAME}Data.swift** in \`$SOURCES_DIR/\`
2. **${COMPONENT_NAME}View.swift** in \`$SOURCES_DIR/\`
3. **${COMPONENT_NAME}HostingView.swift** in \`$SOURCES_DIR/\`
4. **${COMPONENT_NAME}ElementParser.swift** in \`$SOURCES_DIR/\`
5. **CustomElementRegistry.swift** - ADD registration (don't replace)
6. **${COMPONENT_NAME,,}-test.json** in \`$SAMPLES_DIR/\`

### Reference Component (Badge)

Use the Badge component as a reference pattern. Files are in the same directory:
- BadgeData.swift
- BadgeView.swift
- BadgeHostingView.swift
- BadgeElementParser.swift

### Build Validation

After creating files, you MUST invoke the build tool to validate:

\`\`\`bash
$SCRIPT_DIR/build_component.sh "${COMPONENT_NAME}"
\`\`\`

If build fails, review errors and fix issues. You have up to 3 attempts.

### Success Criteria

- ✅ All 4 Swift files created
- ✅ Registry updated with new component
- ✅ Test JSON card created
- ✅ Package builds without errors
- ✅ Component follows Badge pattern

### Full Prompt Template

See: \`$REPO_ROOT/AI_AGENT_COMPONENT_PROMPT_TEMPLATE.md\` for detailed instructions.

EOF

echo -e "${GREEN}📋 Agent context created: $CONTEXT_FILE${NC}"
echo ""

# Create initial response
cat > "$RESPONSE_FILE" <<EOF
{
  "id": "$QUERY_ID",
  "query_id": "$QUERY_ID",
  "timestamp": "$TIMESTAMP",
  "status": "in_progress",
  "response": {
    "summary": "Building component: ${COMPONENT_NAME}",
    "component_name": "${COMPONENT_NAME}",
    "files_created": [],
    "files_modified": [],
    "test_card_created": "",
    "compilation": {
      "success": false,
      "errors": [],
      "warnings": 0,
      "build_time_seconds": 0
    },
    "agent_work_log": [
      "Started component build process"
    ]
  },
  "processing": {
    "started_at": "$TIMESTAMP",
    "processed_by": "local_poller_v1",
    "agent": "github_copilot"
  }
}
EOF

# TODO: Actual AI agent integration
# For now, this is a placeholder that will be replaced with actual MCP or API calls

echo -e "${YELLOW}⚠️  AI Agent Integration Not Yet Implemented${NC}"
echo -e "${YELLOW}📝 This is a placeholder. In production, this would:${NC}"
echo -e "   1. Spawn GitHub Copilot or Claude with full context"
echo -e "   2. Provide access to Badge reference files"
echo -e "   3. Monitor code generation progress"
echo -e "   4. Invoke build validation after each file"
echo -e "   5. Iterate on compilation errors (max 3 attempts)"
echo -e "   6. Create test JSON card"
echo -e "   7. Return success/failure status"
echo ""

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Update response with placeholder status
cat > "$RESPONSE_FILE" <<EOF
{
  "id": "$QUERY_ID",
  "query_id": "$QUERY_ID",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "pending_implementation",
  "response": {
    "summary": "Component build system ready, awaiting AI agent implementation",
    "component_name": "${COMPONENT_NAME}",
    "files_created": [],
    "files_modified": [],
    "test_card_created": "",
    "compilation": {
      "success": false,
      "errors": ["AI agent integration not yet implemented"],
      "warnings": 0,
      "build_time_seconds": 0
    },
    "agent_work_log": [
      "Started component build process",
      "Created agent context file",
      "⚠️ AI agent integration pending",
      "Next step: Integrate GitHub Copilot or Claude API"
    ]
  },
  "processing": {
    "started_at": "$TIMESTAMP",
    "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "duration_seconds": $DURATION,
    "processed_by": "local_poller_v1",
    "agent": "pending_integration"
  },
  "next_steps": {
    "implementation_required": true,
    "options": [
      "Integrate with MCP server for component generation",
      "Use GitHub Copilot API directly",
      "Use Claude API with file operations",
      "Manual component creation following template"
    ]
  }
}
EOF

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  Response created with pending status${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📄 Response file: $RESPONSE_FILE${NC}"
echo -e "${GREEN}⏱️  Duration: ${DURATION}s${NC}"
echo ""

# For now, return exit code 0 to test the flow
exit 0
