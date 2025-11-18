#!/bin/bash
# poll.sh - Continuously poll AdaptiveCards-Mobile for component build requests

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="$REPO_ROOT/artifacts/logs/component_builder_poller.log"
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB
POLL_INTERVAL=30  # seconds
CLEANUP_INTERVAL=5  # Run cleanup every N poll iterations

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Setup logging
mkdir -p "$(dirname "$LOG_FILE")"

# Rotate log if too large
if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" > "$LOG_FILE"
fi

# Logging function
log_and_echo() {
    local message="$1"
    echo -e "$message"
    echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Component Builder Polling Service${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📁 Repository: $REPO_ROOT${NC}"
echo -e "${GREEN}⏱️  Poll interval: ${POLL_INTERVAL}s${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Function to pull latest changes
pull_changes() {
    cd "$REPO_ROOT"
    log_and_echo "${YELLOW}🔄 Fetching all branches...${NC}"
    
    # Fetch all branches including new ones
    git fetch --all --prune
    
    if git pull origin $(git branch --show-current) 2>&1 | grep -q "Already up to date"; then
        return 1  # No changes
    else
        log_and_echo "${GREEN}✅ New changes detected${NC}"
        return 0
    fi
}

# Function to check for component build branches
check_component_build_branches() {
    cd "$REPO_ROOT"
    
    # Find remote component-build-* branches
    local build_branches=$(git branch -r | grep "hggzm/component-build-" | sed 's/hggzm\///' | sed 's/^[[:space:]]*//' | xargs)
    
    if [[ -n "$build_branches" ]]; then
        log_and_echo "${GREEN}📋 Found component build branches:${NC}"
        for branch in $build_branches; do
            log_and_echo "  ${BLUE}→ $branch${NC}"
            
            # Check if branch has pending query
            if git ls-tree -r "hggzm/$branch" --name-only | grep -q "queries/.*\.json$"; then
                log_and_echo "    ${GREEN}✅ Has pending query${NC}"
                process_component_build "$branch"
            fi
        done
    fi
}

# Function to cleanup branches for closed/deleted PRs
cleanup_closed_prs() {
    cd "$REPO_ROOT"
    
    log_and_echo "${YELLOW}🧹 Checking for closed PRs to clean up...${NC}"
    
    # Get all component-build-* branches
    local build_branches=$(git branch -r | grep "hggzm/component-build-" | sed 's/hggzm\///' | sed 's/^[[:space:]]*//' || true)
    
    if [[ -z "$build_branches" ]]; then
        log_and_echo "${BLUE}ℹ️  No component build branches to check${NC}"
        return 0
    fi
    
    local cleanup_count=0
    
    for branch in $build_branches; do
        # Check if PR exists for this branch
        local pr_info=$(gh pr list --head "$branch" --state all --json state,number --jq '.[0]' 2>/dev/null || echo "{}")
        local pr_state=$(echo "$pr_info" | jq -r '.state // "NOT_FOUND"' 2>/dev/null || echo "NOT_FOUND")
        local pr_number=$(echo "$pr_info" | jq -r '.number // ""' 2>/dev/null || echo "")
        
        if [[ "$pr_state" == "NOT_FOUND" ]] || [[ "$pr_state" == "CLOSED" ]] || [[ "$pr_state" == "MERGED" ]] || [[ -z "$pr_state" ]] || [[ "$pr_state" == "null" ]]; then
            log_and_echo "${RED}🗑️  PR #${pr_number} for branch '$branch' is $pr_state${NC}"
            
            # Extract query ID from branch name (component-build-ComponentName-timestamp)
            local query_id=$(echo "$branch" | sed 's/component-build-//')
            
            # Archive files if they exist
            local current_branch=$(git branch --show-current)
            git checkout "$branch" 2>/dev/null || continue
            
            # Create archive directory
            mkdir -p "$REPO_ROOT/artifacts/archived_queries"
            
            # Archive query file
            if [[ -f "queries/component_${query_id}.json" ]]; then
                cp "queries/component_${query_id}.json" "$REPO_ROOT/artifacts/archived_queries/component_${query_id}_query.json"
                log_and_echo "${BLUE}📦 Archived query: component_${query_id}${NC}"
            fi
            
            # Archive response file
            if [[ -f "responses/response_component_${query_id}.json" ]]; then
                cp "responses/response_component_${query_id}.json" "$REPO_ROOT/artifacts/archived_queries/component_${query_id}_response.json"
                log_and_echo "${BLUE}📦 Archived response: component_${query_id}${NC}"
            fi
            
            # Return to previous branch
            git checkout "$current_branch" 2>/dev/null || git checkout main
            
            # Delete the remote branch
            log_and_echo "${RED}🗑️  Deleting remote branch: $branch${NC}"
            git push hggzm --delete "$branch" 2>/dev/null || log_and_echo "${YELLOW}⚠️  Failed to delete remote branch${NC}"
            
            # Prune local references
            git fetch --prune
            
            cleanup_count=$((cleanup_count + 1))
        fi
    done
    
    if [[ $cleanup_count -gt 0 ]]; then
        log_and_echo "${GREEN}✅ Cleaned up $cleanup_count closed PR(s)${NC}"
    else
        log_and_echo "${BLUE}ℹ️  No closed PRs to clean up${NC}"
    fi
}

# Function to process a component build request
process_component_build() {
    local branch="$1"
    
    cd "$REPO_ROOT"
    
    log_and_echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_and_echo "${BLUE}  Processing Branch: $branch${NC}"
    log_and_echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Checkout the branch
    log_and_echo "${YELLOW}🔀 Checking out branch: $branch${NC}"
    git checkout "$branch" || {
        log_and_echo "${RED}❌ Failed to checkout branch${NC}"
        return 1
    }
    
    # Pull latest changes
    git pull hggzm "$branch"
    
    # Find query file
    local query_file=$(find queries -name "component_*.json" -type f | head -1)
    
    if [[ -z "$query_file" ]]; then
        log_and_echo "${RED}❌ No query file found in branch${NC}"
        return 1
    fi
    
    log_and_echo "${GREEN}📄 Found query: $query_file${NC}"
    
    # Check if already processed
    local query_id=$(basename "$query_file" .json | sed 's/^component_//')
    local response_file="responses/response_component_${query_id}.json"
    
    if [[ -f "$response_file" ]]; then
        log_and_echo "${YELLOW}⚠️  Response already exists, skipping${NC}"
        return 0
    fi
    
    # Check processor type
    local processor=$(jq -r '.processing.processor // "local-poller"' "$query_file")
    
    if [[ "$processor" != "local-poller" ]]; then
        log_and_echo "${YELLOW}⏭️  Skipping: processor is '$processor', not 'local-poller'${NC}"
        return 0
    fi
    
    # Process the query
    log_and_echo "${GREEN}🚀 Processing component build request...${NC}"
    
    "$SCRIPT_DIR/process_component_query.sh" "$query_file"
    
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_and_echo "${GREEN}✅ Component build completed successfully${NC}"
        
        # Push response back to branch
        log_and_echo "${YELLOW}📤 Pushing response to branch...${NC}"
        git add -f responses/
        git add source/ios/AdaptiveCards/AdaptiveCards/Packages/AdaptiveCardCustomElements/ 2>/dev/null || true
        git add samples/ 2>/dev/null || true
        git commit -m "🤖 Component build response for $(jq -r '.request.component_name' "$query_file")" || true
        git push hggzm "$branch"
        
        log_and_echo "${GREEN}✅ Response pushed successfully${NC}"
    else
        log_and_echo "${RED}❌ Component build failed with exit code: $exit_code${NC}"
    fi
}

# Main polling loop
iteration=0
while true; do
    iteration=$((iteration + 1))
    
    log_and_echo ""
    log_and_echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_and_echo "${BLUE}  Poll Iteration #$iteration - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    log_and_echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Run cleanup every N iterations
    if (( iteration % CLEANUP_INTERVAL == 0 )); then
        cleanup_closed_prs
    fi
    
    # Check for new branches with queries
    check_component_build_branches
    
    # Return to main/feature branch
    cd "$REPO_ROOT"
    git checkout main 2>/dev/null || git checkout feature/dynamic_swiftui_builder 2>/dev/null || true
    
    log_and_echo "${BLUE}⏱️  Waiting ${POLL_INTERVAL}s before next poll...${NC}"
    sleep "$POLL_INTERVAL"
done
