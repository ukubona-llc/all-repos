#!/usr/bin/env bash
# gh_census.sh — Ecosystem Census for 11 GitHub accounts
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

echo -e "\n${DIM}Starting census scan...${RESET}\n"

# Python engine handles pagination, fetching, and aggregating ecosystem stats
python3 - "$SECRETS_FILE" <<'PYEOF'
import sys, json, time, urllib.request, urllib.error
from collections import Counter

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
total_repos_across_orgs = 0

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
            
            # Filter to explicit ownership
            batch = [r for r in batch if r["owner"]["login"].lower() == acct.lower()]
            if not batch and token: 
                break
                
            all_repos.extend(batch)
            page += 1
        except Exception as e:
            print(f"  Error fetching repos for {acct}: {e}")
            break

    total_repos_across_orgs += len(all_repos)
    
    # Process Census Statistics
    acct_results = []
    priv_count = 0
    pub_count = 0
    languages = Counter()

    for repo in all_repos:
        is_priv = repo.get("private", False)
        if is_priv: priv_count += 1
        else: pub_count += 1
        
        lang = repo.get("language")
        if lang: languages[lang] += 1

        acct_results.append({
            "name": repo["name"],
            "private": is_priv,
            "is_fork": repo.get("fork", False),
            "created_at": repo.get("created_at"),
            "last_pushed": repo.get("pushed_at"),
            "language": lang,
            "stars": repo.get("stargazers_count", 0),
            "size_kb": repo.get("size", 0),
            "open_issues": repo.get("open_issues_count", 0)
        })

    # Sort array by last active date
    acct_results.sort(key=lambda x: x["last_pushed"] or "", reverse=True)
    final_ledger[acct] = acct_results

    # Print summary to terminal
    top_lang = languages.most_common(1)[0][0] if languages else "None"
    print(f"  ↳ Repos: \033[36m{len(all_repos)}\033[0m | Public: {pub_count} | Private: {priv_count} | Top Lang: {top_lang}")

# Write out the deep JSON artifact
output_file = "/tmp/github_ecosystem_census.json"
with open(output_file, "w") as f:
    json.dump(final_ledger, f, indent=2)

print(f"\n\033[32m\033[1mSuccess!\033[0m Scanned {total_repos_across_orgs} total repos.")
print(f"The detailed JSON census has been saved to: \033[36m{output_file}\033[0m")
PYEOF