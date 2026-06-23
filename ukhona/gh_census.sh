#!/usr/bin/env bash
# gh_census.sh — Scan 11 specific GitHub accounts for all repos and DOCX hits
set -euo pipefail

BOLD="\033[1m"; RESET="\033[0m"; CYAN="\033[36m"; DIM="\033[2m"; GREEN="\033[32m"

ACCOUNTS=(
  "ukubona-llc" "jhurepos" "abikesa" "muzaale" 
  "jhustata" "pairs-jh" "jhufena" "eplnm" 
  "ukb-pyro" "cryo-pyro" "ukb-dt"
)

echo -e "${BOLD}GitHub Ecosystem Census (11 Accounts)${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"
echo "Enter Personal Access Tokens (press Enter to skip for public-only repos):"

# Collect tokens into a temporary JSON file for Python to consume safely
SECRETS_FILE=$(mktemp /tmp/gh_secrets_XXXXXX.json)
trap 'rm -f "$SECRETS_FILE"' EXIT

echo "{" > "$SECRETS_FILE"
for idx in "${!ACCOUNTS[@]}"; do
    acct="${ACCOUNTS[$idx]}"
    printf "  ${CYAN}${BOLD}%-15s${RESET} PAT: " "$acct"
    read -rs token
    echo ""
    
    # Append to JSON
    echo "  \"$acct\": \"$token\"" >> "$SECRETS_FILE"
    if [ $idx -lt $((${#ACCOUNTS[@]}-1)) ]; then 
        sed -i '' '$ s/$/,/' "$SECRETS_FILE" # Add comma to previous line (macOS sed)
    fi
done
echo "}" >> "$SECRETS_FILE"

echo -e "\n${DIM}Starting census scan. This will take a few minutes...${RESET}\n"

# Python engine handles pagination, tree fetching, and formatting the final output
python3 - "$SECRETS_FILE" <<'PYEOF'
import sys, json, time, urllib.request, urllib.error, urllib.parse

secrets_path = sys.argv[1]
with open(secrets_path) as f:
    accounts = json.load(f)

def api_get(url, token, retries=3):
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    if token:
        req.add_header("Authorization", f"token {token}")
    
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                remaining = r.headers.get("X-RateLimit-Remaining", "60")
                if remaining and int(remaining) < 5:
                    reset_ts = int(r.headers.get("X-RateLimit-Reset", time.time() + 60))
                    wait = max(0, reset_ts - int(time.time())) + 2
                    print(f"  ⚠ Rate limit low — waiting {wait}s...", flush=True)
                    time.sleep(wait)
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 403:
                time.sleep(5)
                continue
            if e.code in (404, 409, 451): # 409 = empty repo
                return None
            raise
        except Exception:
            time.sleep(2 ** attempt)
    return None

final_ledger = {}
total_repos = 0

for acct, token in accounts.items():
    print(f"\033[1mScanning {acct}...\033[0m")
    all_repos = []
    page = 1
    
    # Paginate through all repos for the account
    while True:
        url = f"https://api.github.com/users/{acct}/repos?per_page=100&page={page}&sort=updated&direction=desc"
        if token:
            url = f"https://api.github.com/user/repos?per_page=100&page={page}&sort=updated&direction=desc"
        
        try:
            batch = api_get(url, token)
            if not batch: break
            
            # If using a PAT, the API returns ALL repos the token can see. 
            # We must filter to only keep the ones explicitly owned by 'acct'
            batch = [r for r in batch if r["owner"]["login"].lower() == acct.lower()]
            if not batch and token: # Reached the end of relevant repos
                break
                
            all_repos.extend(batch)
            page += 1
        except Exception as e:
            print(f"  Error fetching repos for {acct}: {e}")
            break

    print(f"  Found {len(all_repos)} repos. Checking trees...")
    total_repos += len(all_repos)
    acct_results = []

    for idx, repo in enumerate(all_repos):
        repo_name = repo["name"]
        default_br = repo.get("default_branch", "main")
        
        # Fetch the git tree
        tree_url = f"https://api.github.com/repos/{acct}/{repo_name}/git/trees/{urllib.parse.quote(default_br)}?recursive=1"
        tree_data = api_get(tree_url, token)

        if tree_data is None or "tree" not in tree_data:
            acct_results.append(f"{repo_name}:S") # S = Skipped / Empty
        else:
            docx_count = sum(1 for i in tree_data["tree"] if i.get("type") == "blob" and i.get("path", "").lower().endswith(".docx"))
            acct_results.append(f"{repo_name}:{docx_count}")
        
        if (idx + 1) % 50 == 0:
            print(f"    ... {idx + 1}/{len(all_repos)} processed")

    # Combine into the compressed string format
    final_ledger[acct] = ",".join(acct_results)

# Write out the exact JS object needed for the HTML file
output_file = "/tmp/repo_ledger_data.json"
with open(output_file, "w") as f:
    json.dump(final_ledger, f, indent=2)

print(f"\n\033[32m\033[1mSuccess!\033[0m Scanned {total_repos} total repos.")
print(f"The compressed dictionary has been saved to: \033[36m{output_file}\033[0m")
print("You can copy the contents of that file directly into the 'rawRepos' variable in your HTML artifact.")
PYEOF