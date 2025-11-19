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
6. **$(echo ${COMPONENT_NAME} | tr '[:upper:]' '[:lower:]')-test.json** in \`$SAMPLES_DIR/\`

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

# ============================================================================
# AI AGENT INTEGRATION - GitHub Copilot via HTTP Proxy
# ============================================================================

echo -e "${BLUE}🤖 Invoking AI Agent (GitHub Copilot)${NC}"
echo ""

# Build the prompt for Copilot
AI_PROMPT="I need you to build a new SwiftUI custom element for AdaptiveCards.

# Component Specification

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

# Instructions

Create a new SwiftUI component following the exact pattern of the Badge component.

## Package Location
\`${PACKAGE_DIR}\`

## Files to Create

You MUST create these 6 files:

1. **${COMPONENT_NAME}Data.swift** in \`$SOURCES_DIR/\`
   - Define properties from JSON spec above
   - Implement Codable, Equatable, Hashable
   - Follow BadgeData.swift pattern exactly

2. **${COMPONENT_NAME}View.swift** in \`$SOURCES_DIR/\`
   - SwiftUI View rendering the component
   - Use properties from ${COMPONENT_NAME}Data
   - Follow BadgeView.swift pattern exactly

3. **${COMPONENT_NAME}HostingView.swift** in \`$SOURCES_DIR/\`
   - UIKit wrapper for SwiftUI view
   - Follow BadgeHostingView.swift pattern exactly

4. **${COMPONENT_NAME}ElementParser.swift** in \`$SOURCES_DIR/\`
   - Parse JSON to ${COMPONENT_NAME}Data
   - Follow BadgeElementParser.swift pattern exactly

5. **CustomElementRegistry.swift** - UPDATE (don't replace entire file)
   - Add registration in registerDefaultElements():
   \`\`\`swift
   registry.register(typeName: \"${COMPONENT_NAME}\", parser: ${COMPONENT_NAME}ElementParser.self)
   \`\`\`

6. **$(echo ${COMPONENT_NAME} | tr '[:upper:]' '[:lower:]')-test.json** in \`$SAMPLES_DIR/\`
   - Test card using the example JSON above

## Reference Files

Examine these Badge component files as your template:
- $SOURCES_DIR/BadgeData.swift
- $SOURCES_DIR/BadgeView.swift
- $SOURCES_DIR/BadgeHostingView.swift
- $SOURCES_DIR/BadgeElementParser.swift

## Build Validation

After creating all files, you MUST run:
\`\`\`bash
$SCRIPT_DIR/build_component.sh \"${COMPONENT_NAME}\"
\`\`\`

If build fails, fix errors and try again (max 3 attempts).

## Critical Requirements

- ✅ Follow Badge pattern EXACTLY
- ✅ All properties from JSON spec must be in ${COMPONENT_NAME}Data
- ✅ Proper Swift naming conventions (UpperCamelCase for types)
- ✅ Complete Codable implementation
- ✅ Registry registration added (not replaced)
- ✅ Test JSON card created
- ✅ Package builds successfully

**START NOW** - Create all 6 files and validate the build."

# Send to Copilot
echo "$AI_PROMPT" | "$SCRIPT_DIR/send_to_copilot.sh"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Prompt sent to Copilot successfully${NC}"
    echo ""
    echo -e "${YELLOW}⏳ Waiting for Copilot to complete the work...${NC}"
    echo -e "${YELLOW}   The component builder will monitor for file changes${NC}"
    echo ""
    
    # Wait for Copilot to create files (give it time to work)
    echo -e "${BLUE}⏱️  Monitoring for file creation (timeout: 5 minutes)${NC}"
    
    WAIT_START=$(date +%s)
    TIMEOUT=300  # 5 minutes
    FILES_EXPECTED=6
    FILES_FOUND=0
    
    while [ $FILES_FOUND -lt $FILES_EXPECTED ]; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - WAIT_START))
        
        if [ $ELAPSED -gt $TIMEOUT ]; then
            echo -e "${YELLOW}⚠️  Timeout waiting for files (5 minutes)${NC}"
            break
        fi
        
        # Check for created files
        FILES_FOUND=0
        [ -f "$SOURCES_DIR/${COMPONENT_NAME}Data.swift" ] && FILES_FOUND=$((FILES_FOUND + 1))
        [ -f "$SOURCES_DIR/${COMPONENT_NAME}View.swift" ] && FILES_FOUND=$((FILES_FOUND + 1))
        [ -f "$SOURCES_DIR/${COMPONENT_NAME}HostingView.swift" ] && FILES_FOUND=$((FILES_FOUND + 1))
        [ -f "$SOURCES_DIR/${COMPONENT_NAME}ElementParser.swift" ] && FILES_FOUND=$((FILES_FOUND + 1))
        [ -f "$SAMPLES_DIR/$(echo ${COMPONENT_NAME} | tr '[:upper:]' '[:lower:]')-test.json" ] && FILES_FOUND=$((FILES_FOUND + 1))
        
        # Check if registry was updated (look for component registration)
        if grep -q "${COMPONENT_NAME}ElementParser" "$SOURCES_DIR/CustomElementRegistry.swift" 2>/dev/null; then
            FILES_FOUND=$((FILES_FOUND + 1))
        fi
        
        if [ $FILES_FOUND -gt 0 ]; then
            echo -e "${BLUE}📁 Files detected: $FILES_FOUND/$FILES_EXPECTED${NC}"
        fi
        
        sleep 10  # Check every 10 seconds
    done
    
    echo ""
    echo -e "${BLUE}🏗️  Validating component build...${NC}"
    
    # Run build validation
    if "$SCRIPT_DIR/build_component.sh" "${COMPONENT_NAME}" > "$OUTPUT_LOG" 2>&1; then
        BUILD_SUCCESS=true
        BUILD_STATUS="success"
        BUILD_ERRORS="[]"
        SUMMARY="Component '${COMPONENT_NAME}' built successfully"
    else
        BUILD_SUCCESS=false
        BUILD_STATUS="failed"
        BUILD_ERRORS=$(jq -n --arg err "$(tail -50 "$OUTPUT_LOG")" '[$err]')
        SUMMARY="Component build failed - see build log for details"
    fi
else
    echo -e "${RED}❌ Failed to send prompt to Copilot${NC}"
    BUILD_SUCCESS=false
    BUILD_STATUS="failed"
    BUILD_ERRORS='["Failed to communicate with Copilot proxy"]'
    SUMMARY="Failed to invoke AI agent"
fi

# Collect created files
CREATED_FILES=()
[ -f "$SOURCES_DIR/${COMPONENT_NAME}Data.swift" ] && CREATED_FILES+=("${COMPONENT_NAME}Data.swift")
[ -f "$SOURCES_DIR/${COMPONENT_NAME}View.swift" ] && CREATED_FILES+=("${COMPONENT_NAME}View.swift")
[ -f "$SOURCES_DIR/${COMPONENT_NAME}HostingView.swift" ] && CREATED_FILES+=("${COMPONENT_NAME}HostingView.swift")
[ -f "$SOURCES_DIR/${COMPONENT_NAME}ElementParser.swift" ] && CREATED_FILES+=("${COMPONENT_NAME}ElementParser.swift")

MODIFIED_FILES=()
if grep -q "${COMPONENT_NAME}ElementParser" "$SOURCES_DIR/CustomElementRegistry.swift" 2>/dev/null; then
    MODIFIED_FILES+=("CustomElementRegistry.swift")
fi

TEST_CARD=""
TEST_CARD_FILE="$SAMPLES_DIR/$(echo ${COMPONENT_NAME} | tr '[:upper:]' '[:lower:]')-test.json"
[ -f "$TEST_CARD_FILE" ] && TEST_CARD="$(basename "$TEST_CARD_FILE")"

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Create response
CREATED_FILES_JSON=$(printf '%s\n' "${CREATED_FILES[@]}" | jq -R . | jq -s .)
MODIFIED_FILES_JSON=$(printf '%s\n' "${MODIFIED_FILES[@]}" | jq -R . | jq -s .)

cat > "$RESPONSE_FILE" <<EOF
{
  "id": "$QUERY_ID",
  "query_id": "$QUERY_ID",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "$BUILD_STATUS",
  "response": {
    "summary": "$SUMMARY",
    "component_name": "${COMPONENT_NAME}",
    "files_created": $CREATED_FILES_JSON,
    "files_modified": $MODIFIED_FILES_JSON,
    "test_card_created": "$TEST_CARD",
    "compilation": {
      "success": $BUILD_SUCCESS,
      "errors": $BUILD_ERRORS,
      "build_time_seconds": $DURATION
    },
    "agent_work_log": [
      "Started component build process",
      "Created agent context file",
      "Sent prompt to GitHub Copilot via HTTP proxy",
      "Monitored for file creation",
      "Validated component build"
    ]
  },
  "processing": {
    "started_at": "$TIMESTAMP",
    "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "duration_seconds": $DURATION,
    "processed_by": "local_poller_v1",
    "agent": "github_copilot_http"
  }
}
EOF

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$BUILD_SUCCESS" = true ]; then
    echo -e "${GREEN}✅ Component build completed successfully!${NC}"
else
    echo -e "${YELLOW}⚠️  Component build completed with errors${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📄 Response file: $RESPONSE_FILE${NC}"
echo -e "${GREEN}⏱️  Duration: ${DURATION}s${NC}"
echo -e "${GREEN}📁 Files created: ${#CREATED_FILES[@]}${NC}"
echo -e "${GREEN}📝 Files modified: ${#MODIFIED_FILES[@]}${NC}"
echo ""

# Exit with appropriate code
if [ "$BUILD_SUCCESS" = true ]; then
    exit 0
else
    exit 1
fi
