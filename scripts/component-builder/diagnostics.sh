#!/bin/bash
# diagnostics.sh - Component Builder diagnostic tools

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

cd "$REPO_ROOT"

# Command functions
cmd_status() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Component Builder Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Count branches
    local branch_count=$(git branch -r | grep -c "origin/component-build-" || echo "0")
    echo -e "${GREEN}🌿 Active branches: $branch_count${NC}"
    
    # Count queries and responses
    local query_count=$(find queries -name "component_*.json" 2>/dev/null | wc -l | xargs)
    local response_count=$(find responses -name "response_component_*.json" 2>/dev/null | wc -l | xargs)
    echo -e "${GREEN}📥 Pending queries: $query_count${NC}"
    echo -e "${GREEN}📤 Responses: $response_count${NC}"
    
    # Check poller log
    if [[ -f "artifacts/logs/component_builder_poller.log" ]]; then
        local log_size=$(du -h artifacts/logs/component_builder_poller.log | cut -f1)
        local last_run=$(tail -1 artifacts/logs/component_builder_poller.log | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "Never")
        echo -e "${GREEN}📋 Poller log size: $log_size${NC}"
        echo -e "${GREEN}🕐 Last poll: $last_run${NC}"
    else
        echo -e "${YELLOW}⚠️  Poller log not found${NC}"
    fi
    
    echo ""
}

cmd_prs() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Component Build PRs${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    gh pr list --label "component-build" --json number,title,headRefName,state,labels --jq '.[] | 
        "\(.number): \(.title)\n  Branch: \(.headRefName)\n  State: \(.state)\n  Labels: \(.labels | map(.name) | join(", "))\n"'
}

cmd_branches() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Component Build Branches${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    git branch -r | grep "origin/component-build-" | while read -r branch; do
        branch=$(echo "$branch" | sed 's/origin\///' | xargs)
        echo -e "${GREEN}🌿 $branch${NC}"
        
        # Check for query
        if git ls-tree -r "origin/$branch" --name-only | grep -q "queries/component_.*\.json$"; then
            echo -e "   ${CYAN}📥 Has query${NC}"
        fi
        
        # Check for response
        if git ls-tree -r "origin/$branch" --name-only | grep -q "responses/response_component_.*\.json$"; then
            echo -e "   ${GREEN}📤 Has response${NC}"
        fi
        
        echo ""
    done
}

cmd_query() {
    local query_id="$1"
    
    if [[ -z "$query_id" ]]; then
        echo -e "${RED}❌ Usage: $0 query <query_id>${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Query: $query_id${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local query_file=$(find queries -name "component_${query_id}.json" 2>/dev/null | head -1)
    
    if [[ -z "$query_file" ]]; then
        echo -e "${RED}❌ Query not found: $query_id${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}📄 Query file: $query_file${NC}"
    echo ""
    cat "$query_file" | jq '.'
    echo ""
    
    # Check for response
    local response_file="responses/response_component_${query_id}.json"
    if [[ -f "$response_file" ]]; then
        echo -e "${GREEN}📤 Response exists: $response_file${NC}"
        echo ""
        cat "$response_file" | jq '.response.summary, .response.compilation.success'
    fi
}

cmd_archived() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Archived Component Builds${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ ! -d "artifacts/archived_queries" ]]; then
        echo -e "${YELLOW}⚠️  No archived queries directory${NC}"
        exit 0
    fi
    
    local archive_count=$(ls -1 artifacts/archived_queries/component_*_query.json 2>/dev/null | wc -l | xargs)
    
    if [[ "$archive_count" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  No archived component builds${NC}"
        exit 0
    fi
    
    echo -e "${GREEN}📦 Archived builds: $archive_count${NC}"
    echo ""
    
    for query_file in artifacts/archived_queries/component_*_query.json; do
        if [[ -f "$query_file" ]]; then
            local query_id=$(basename "$query_file" | sed 's/component_//' | sed 's/_query.json//')
            local component_name=$(jq -r '.request.component_name // "Unknown"' "$query_file" 2>/dev/null || echo "Unknown")
            local response_file="artifacts/archived_queries/component_${query_id}_response.json"
            
            if [[ -f "$response_file" ]]; then
                local build_success=$(jq -r '.response.compilation.success // false' "$response_file" 2>/dev/null || echo "false")
                if [[ "$build_success" == "true" ]]; then
                    echo -e "${GREEN}✅ $component_name (${query_id})${NC}"
                else
                    echo -e "${RED}❌ $component_name (${query_id})${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  $component_name (${query_id}) - no response${NC}"
            fi
        fi
    done
    
    echo ""
    echo -e "${BLUE}Storage: $(du -sh artifacts/archived_queries 2>/dev/null | cut -f1)${NC}"
}

cmd_logs() {
    local lines="${1:-50}"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Poller Logs (last $lines lines)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ -f "artifacts/logs/component_builder_poller.log" ]]; then
        tail -n "$lines" artifacts/logs/component_builder_poller.log
    else
        echo -e "${YELLOW}⚠️  Poller log not found${NC}"
    fi
}

cmd_help() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Component Builder Diagnostics${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status              Show component builder system status"
    echo "  prs                 List component build PRs"
    echo "  branches            Show component build branches"
    echo "  query <id>          Show details for a specific query"
    echo "  archived            Show archived component builds"
    echo "  logs [lines]        Show poller logs (default: 50 lines)"
    echo "  help                Show this help message"
    echo ""
}

# Main
COMMAND="${1:-help}"

case "$COMMAND" in
    status)
        cmd_status
        ;;
    prs)
        cmd_prs
        ;;
    branches)
        cmd_branches
        ;;
    query)
        cmd_query "$2"
        ;;
    archived)
        cmd_archived
        ;;
    logs)
        cmd_logs "$2"
        ;;
    help|*)
        cmd_help
        ;;
esac
