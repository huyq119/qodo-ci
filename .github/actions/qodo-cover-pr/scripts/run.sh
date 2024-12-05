#!/bin/bash
set -e

BINARY_PATH="/tmp/bin/cover-agent-pro"
REPORT_DIR="/tmp"
REPORT_PATH="$REPORT_DIR/report.txt"
MODIFIED_FILES_JSON="/tmp/modified-files.json"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --pr-number) PR_NUMBER="$2"; shift ;;
        --pr-ref) PR_REF="$2"; shift ;;
        --project-language) PROJECT_LANGUAGE="$2"; shift ;;
        --project-root) PROJECT_ROOT="$2"; shift ;;
        --code-coverage-report-path) CODE_COVERAGE_REPORT_PATH="$2"; shift ;;
        --test-command) TEST_COMMAND="$2"; shift ;;
        --model) MODEL="$2"; shift ;;
        --max-iterations) MAX_ITERATIONS="$2"; shift ;;
        --desired-coverage) DESIRED_COVERAGE="$2"; shift ;;
        --action-path) ACTION_PATH="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Install system dependencies
if ! (command -v wget >/dev/null && command -v sqlite3 >/dev/null && command -v jq >/dev/null); then
    echo "Installing system dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq wget sqlite3 libsqlite3-dev jq >/dev/null
fi

# Install jinja2-cli if not installed
if ! pip show jinja2-cli >/dev/null; then
    echo "Installing jinja2-cli..."
    pip install jinja2-cli -q
fi

# Install jedi-language-server if project language is Python
if [ "$PROJECT_LANGUAGE" == "python" ]; then
    if ! pip show jedi-language-server >/dev/null; then
        echo "Installing jedi-language-server..."
        pip install jedi-language-server -q
    fi
fi

# Set up Git configuration
git config --global user.email "cover-bot@qodo.ai"
git config --global user.name "Qodo Cover"

# Download cover-agent-pro if not already downloaded
if [ ! -f "$BINARY_PATH" ]; then
    echo "Downloading cover-agent-pro ${ACTION_REF}..."
    mkdir -p /tmp/bin
    wget -q -P /tmp/bin "https://github.com/qodo-ai/qodo-ci/releases/download/${ACTION_REF}/cover-agent-pro" >/dev/null
    chmod +x "$BINARY_PATH"
fi

# Checkout the PR branch
git fetch origin "$PR_REF"
git checkout "$PR_REF"

# Get the repository root
REPO_ROOT=$(git rev-parse --show-toplevel)

# Generate the modified files JSON using gh pr view, including only added or modified files
echo "Generating modified files list..."
gh pr view "$PR_NUMBER" --json files --jq '.files[].path' | \
jq -R -s 'split("\n")[:-1] | map("'"$REPO_ROOT"'/" + .)' > "$MODIFIED_FILES_JSON"

# Check if modified-files.json is empty
if [ ! -s "$MODIFIED_FILES_JSON" ]; then
    echo "No added or modified files found in the PR. Exiting."
    exit 0
fi

# Run cover-agent-pro in pr mode with the provided arguments
"$BINARY_PATH" \
  --mode "pr" \
  --project-language "$PROJECT_LANGUAGE" \
  --project-root "$GITHUB_WORKSPACE/$PROJECT_ROOT" \
  --code-coverage-report-path "$GITHUB_WORKSPACE/$CODE_COVERAGE_REPORT_PATH" \
  --test-command "$TEST_COMMAND" \
  --model "$MODEL" \
  --max-iterations "$MAX_ITERATIONS" \
  --desired-coverage "$DESIRED_COVERAGE" \
  --report-dir "$REPORT_DIR" \
  --modified-files-json "$MODIFIED_FILES_JSON"

# Handle any changes made by cover-agent-pro
if [ -n "$(git status --porcelain)" ]; then
    TIMESTAMP=$(date +%s)
    BRANCH_NAME="qodo-cover-${PR_NUMBER}-${TIMESTAMP}"

    if [ ! -f "$REPORT_PATH" ]; then
        echo "Error: Report file not found at $REPORT_PATH"
        exit 1
    fi

    REPORT_TEXT=$(cat "$REPORT_PATH")
    PR_BODY=$(jinja2 "$ACTION_PATH/templates/pr_body_template.j2" -D pr_number="$PR_NUMBER" -D report="$REPORT_TEXT")
    
    git add .
    git commit -m "Add tests to improve coverage"
    git checkout -b "$BRANCH_NAME"
    git push origin "$BRANCH_NAME"
    
    gh pr create \
        --base "$PR_REF" \
        --head "$BRANCH_NAME" \
        --title "Qodo Cover Update: ${TIMESTAMP}" \
        --body "$PR_BODY"
fi
