#!/usr/bin/env bash
# gitlab-manager.sh — Secure GitLab API TUI for Debian/Ubuntu/Kali
# - Token in system keyring (libsecret via secret-tool) — no env/plaintext
# - HTTPS-only API calls with retries & robust error handling
# - Interactive menus (Groups, Projects, Settings)
# - Default clone dir: ~/.glab-repos (0700); new projects auto-cloned there
# - Works with GitLab.com and self-managed instances
# - Caching (TTL), apt prompt for missing deps
#
# Usage:
#   chmod +x gitlab-manager.sh
#   ./gitlab-manager.sh

set -Eeuo pipefail
set -o errtrace
IFS=$'\n\t'
umask 077

VERSION="1.2.3"

# ---------- UI helpers ----------
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then ncolors=$(tput colors); else ncolors=0; fi
if [ "$ncolors" -ge 8 ]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4)
  BOLD=$(tput bold); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

die(){ echo -e "${RED}Error:${RESET} $*" >&2; exit 1; }
ok(){ echo -e "${GREEN}✓${RESET} $*"; }
warn(){ echo -e "${YELLOW}!${RESET} $*"; }
info(){ echo -e "${BLUE}i${RESET} $*"; }

_err_trap(){ local ec=$?; die "Unexpected error (line $1): ${2:-unknown}. Exit code $ec."; }
trap '_err_trap $LINENO "$BASH_COMMAND"' ERR

press_enter(){ echo; read -r -p "Press Enter to continue..." _ || true; }
ask_confirm(){ read -r -p "$1 [y/N]: " a || true; case "${a:-}" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac; }
prompt_nonempty(){ local prompt="$1" var; while :; do read -r -p "$prompt" var || true; [ -n "${var// /}" ] && { printf '%s\n' "$var"; return 0; }; warn "Value cannot be empty."; done; }
prompt_path(){ local prompt="$1" p; while :; do read -r -p "$prompt (lowercase letters, numbers, _ . -): " p || true; [[ "$p" =~ ^[a-z0-9._-]+$ ]] && { printf '%s\n' "$p"; return 0; }; warn "Invalid path. Allowed: a-z 0-9 . _ -"; done; }

# ---------- Required tools (Debian/Ubuntu/Kali) ----------
declare -a REQ_CMDS=(curl jq git secret-tool)
declare -A PKG_MAP=([curl]=curl [jq]=jq [git]=git [secret-tool]=libsecret-tools)

install_missing_with_apt() {
  local pkgs=("$@")
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found. Install manually: sudo apt-get install -y ${pkgs[*]}"; exit 1
  fi
  echo
  read -r -p "Install missing packages with apt now? [Y/n]: " ans
  case "${ans:-Y}" in [nN]*) die "Cannot proceed without required tools."; esac

  local SUDO=""; [ "$EUID" -ne 0 ] && { command -v sudo >/dev/null 2>&1 || die "Please run as root or install sudo."; SUDO="sudo"; }

  set +e
  $SUDO apt-get update
  if ! DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${pkgs[@]}"; then
    set -e; die "Failed to install required packages: ${pkgs[*]}"
  fi
  set -e
}

check_requirements() {
  local missing_cmds=() missing_pkgs=()
  for c in "${REQ_CMDS[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_cmds+=("$c"); done
  if [ ${#missing_cmds[@]} -gt 0 ]; then
    warn "Missing required tools: ${missing_cmds[*]}"
    for c in "${missing_cmds[@]}"; do missing_pkgs+=("${PKG_MAP[$c]}"); done
    install_missing_with_apt "${missing_pkgs[@]}"
    for c in "${REQ_CMDS[@]}"; do command -v "$c" >/dev/null 2>&1 || die "Tool still missing: $c"; done
    ok "All required tools are now installed."
  fi
}
check_requirements

# ---------- Config, cache, clone root ----------
CONFIG_FILE="./.gitlab_manager_config.json"
CACHE_DIR="./.gitlab_manager_cache"; mkdir -p "$CACHE_DIR"

CLONE_ROOT="${HOME}/.glab-repos"
ensure_clone_root(){ mkdir -p -m 700 "$CLONE_ROOT"; [ -w "$CLONE_ROOT" ] || die "Clone root '$CLONE_ROOT' is not writable."; }

DEFAULT_INSTANCE_URL="https://gitlab.com"
CACHE_TTL_SECONDS=300

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    if ! INSTANCE_URL=$(jq -r '.instance_url // empty' "$CONFIG_FILE" 2>/dev/null); then
      INSTANCE_URL="$DEFAULT_INSTANCE_URL"; printf '{"instance_url":"%s"}\n' "$INSTANCE_URL" > "$CONFIG_FILE"
    fi
  else
    INSTANCE_URL="$DEFAULT_INSTANCE_URL"; printf '{"instance_url":"%s"}\n' "$INSTANCE_URL" > "$CONFIG_FILE"
  fi
  if [ -z "${INSTANCE_URL:-}" ]; then INSTANCE_URL="$DEFAULT_INSTANCE_URL"; fi
}
save_config(){ jq --arg url "$INSTANCE_URL" '.instance_url=$url' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"; }
validate_https_url(){ case "$1" in https://*) return 0;; *) return 1;; esac; }

# ---------- Keyring (secret-tool) ----------
KEYRING_SERVICE="gitlab-manager"
KEYRING_ACCOUNT="access-token"

keyring_get_token(){ secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" instance "$INSTANCE_URL" 2>/dev/null || true; }
keyring_store_token(){ local token="$1"; printf '%s' "$token" | secret-tool store --label="GitLab PAT ($INSTANCE_URL)" service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" instance "$INSTANCE_URL"; }
prompt_token_if_missing(){
  TOKEN="$(keyring_get_token || true)"
  if [ -z "${TOKEN:-}" ]; then
    echo -n "Enter GitLab Access Token (stored securely in your keyring): "; IFS= read -r -s TOKEN; echo
    [ -z "$TOKEN" ] && die "Token cannot be empty."; keyring_store_token "$TOKEN"; ok "Token saved to keyring."
  fi
}

# ---------- HTTP / API ----------
BASE_URL=""; refresh_base(){ BASE_URL="${INSTANCE_URL%/}/api/v4"; }
urlencode(){ jq -nr --arg v "$1" '$v|@uri'; }

TMPDIR="$(mktemp -d)"; cleanup(){ rm -rf "$TMPDIR"; }; trap cleanup EXIT

_api_curl() {
  local method="$1"; shift
  local path="$1"; shift
  local payload="${1:-}"
  local url="${BASE_URL}${path}"
  local out="$TMPDIR/out.json"
  local code args curl_rc

  args=(--silent --show-error --location
        --proto "=https" --tlsv1.2
        --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1
        --header "PRIVATE-TOKEN: ${TOKEN}"
        --header "Accept: application/json"
        --request "$method" "$url"
        -o "$out" -w "%{http_code}")

  [ -n "$payload" ] && args+=(--header "Content-Type: application/json" --data-binary "$payload")

  set +e; code=$(curl "${args[@]}"); curl_rc=$?; set -e
  API_LAST_STATUS="$code"; API_LAST_BODY_FILE="$out"
  if [ $curl_rc -ne 0 ]; then return 2; fi
  [[ "$code" =~ ^2[0-9][0-9]$ ]] && return 0 || return 1
}
api_get(){ _api_curl "GET" "$1"; }
api_post(){ _api_curl "POST" "$1" "$2"; }
api_put(){ _api_curl "PUT" "$1" "$2"; }
api_delete(){ _api_curl "DELETE" "$1"; }

api_get_paginated() {
  local path="$1" page=1 acc_file="$TMPDIR/acc.json"
  printf '[]' > "$acc_file"
  while :; do
    local ppath hdr out code rc next
    if [[ "$path" == *\?* ]]; then ppath="${path}&page=${page}"; else ppath="${path}?page=${page}"; fi
    hdr="$TMPDIR/hdr.$page"; out="$TMPDIR/page.$page.json"

    set +e
    code=$(curl --silent --show-error --location \
      --proto "=https" --tlsv1.2 \
      --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 \
      --header "PRIVATE-TOKEN: ${TOKEN}" --header "Accept: application/json" \
      --request GET "${BASE_URL}${ppath}" -D "$hdr" -o "$out" -w "%{http_code}")
    rc=$?; set -e
    if [ $rc -ne 0 ]; then API_LAST_STATUS="$code"; API_LAST_BODY_FILE="$out"; return 2; fi
    [[ "$code" =~ ^2[0-9][0-9]$ ]] || { API_LAST_STATUS="$code"; API_LAST_BODY_FILE="$out"; return 1; }

    jq -s '.[0] + .[1]' "$acc_file" "$out" > "$acc_file.tmp" && mv "$acc_file.tmp" "$acc_file"

    next=$(awk -F': ' '/^X-Next-Page:/ {gsub(/\r/,""); print $2}' "$hdr")
    if [ -z "$next" ]; then break; fi
    page="$next"
  done
  API_LAST_STATUS=200; API_LAST_BODY_FILE="$acc_file"; return 0
}

# ---------- Cache helpers (TTL) ----------
cache_put(){ local key="$1"; local file="$2"; cp "$file" "$CACHE_DIR/${key}.json"; }
cache_get(){
  local key f now ts
  key="$1"
  f="$CACHE_DIR/${key}.json"
  if [ -f "$f" ]; then
    now=$(date +%s)
    ts=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
    if [ $(( now - ts )) -lt "$CACHE_TTL_SECONDS" ]; then echo "$f"; fi
  fi
}
clear_cache(){ rm -f "$CACHE_DIR"/*.json 2>/dev/null || true; }

# ---------- Selection UI ----------
select_from_json() {
  local file="$1" filter="$2" count choice
  count=$(jq 'length' "$file")
  if [ "$count" -eq 0 ]; then warn "No items found."; return 1; fi
  if command -v column >/dev/null 2>&1; then
    jq -r "to_entries[] | \"\(.key+1)) \(.value | ${filter})\"" "$file" | column -t -s$'\t'
  else
    jq -r "to_entries[] | \"\(.key+1)) \(.value | ${filter})\"" "$file"
  fi
  while :; do
    read -r -p "Select number (1-$count), or 0 to cancel: " choice || true
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -le "$count" ]; then
      [ "$choice" -eq 0 ] && return 2
      SELECTED_INDEX=$((choice-1))
      SELECTED_ITEM=$(jq -c ".[$SELECTED_INDEX]" "$file")
      SELECTED_ID=$(jq -r ".[$SELECTED_INDEX].id" "$file")
      return 0
    fi
    warn "Invalid selection."
  done
}

# ---------- Clone helpers ----------
ensure_clone_root
_clone_into(){
  local url="$1" ns_path="$2" dest
  dest="${CLONE_ROOT}/${ns_path}"
  mkdir -p "$(dirname "$dest")"
  if [ -d "$dest/.git" ]; then
    info "Repository exists at '$dest'. Pulling latest..."
    git -C "$dest" fetch --all --prune || die "git fetch failed in $dest"
    git -C "$dest" pull --ff-only || die "git pull failed in $dest"
    ok "Updated $dest"
  else
    info "Cloning into '$dest'"
    git clone --progress "$url" "$dest" || die "git clone failed"
    ok "Cloned to $dest"
  fi
}

# Pull fresh URLs for a project (handles eventual consistency just after creation)
# Sets: PROJECT_CLONE_URL (ssh or http), PROJECT_NS_PATH
get_project_urls() {
  local pid="$1" tries=0 max=5
  PROJECT_CLONE_URL=""; PROJECT_NS_PATH=""
  while [ $tries -lt $max ]; do
    if api_get "/projects/$pid"; then
      local ssh http ns
      ssh=$(jq -r '.ssh_url_to_repo // empty' "$API_LAST_BODY_FILE")
      http=$(jq -r '.http_url_to_repo // empty' "$API_LAST_BODY_FILE")
      ns=$(jq -r '.path_with_namespace // empty' "$API_LAST_BODY_FILE")
      if [ -n "$ssh" ] || [ -n "$http" ]; then
        PROJECT_CLONE_URL="$ssh"; [ -z "$PROJECT_CLONE_URL" ] && PROJECT_CLONE_URL="$http"
        PROJECT_NS_PATH="$ns"
        return 0
      fi
    fi
    tries=$((tries+1))
    sleep 1
  done
  return 1
}

# ---------- Groups ----------
list_groups() {
  local cache_file
  cache_file=$(cache_get "groups") || true
  if [ -n "${cache_file:-}" ]; then
    cp "$cache_file" "$TMPDIR/groups.json"
  else
    if ! api_get_paginated "/groups?per_page=100&min_access_level=10&with_shared=false"; then
      die "Failed to fetch groups (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
    fi
    cp "$API_LAST_BODY_FILE" "$TMPDIR/groups.json"
    cache_put "groups" "$TMPDIR/groups.json"
  fi
  jq -r '.[] | "\(.id)\t\(.full_path)\t\(.name)"' "$TMPDIR/groups.json" | column -t -s$'\t'
}
create_group() {
  local name path parent_id payload
  name=$(prompt_nonempty "Group name: ")
  path=$(prompt_path "Group path (slug)")
  read -r -p "Parent group ID (optional, Enter for top-level): " parent_id || true
  if [ -n "${parent_id:-}" ]; then
    payload=$(jq -n --arg name "$name" --arg path "$path" --argjson parent_id "$parent_id" '{name:$name, path:$path, parent_id:$parent_id}')
  else
    payload=$(jq -n --arg name "$name" --arg path "$path" '{name:$name, path:$path}')
  fi
  if api_post "/groups" "$payload"; then
    ok "Group created: $(jq -r '.full_path' "$API_LAST_BODY_FILE") (id $(jq -r '.id' "$API_LAST_BODY_FILE"))"
    clear_cache
  else
    die "Create group failed (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
  fi
}
rename_group() {
  if ! api_get_paginated "/groups?per_page=100&min_access_level=10"; then
    die "Failed to list groups (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
  fi
  local list="$API_LAST_BODY_FILE"
  select_from_json "$list" '.full_path + " (id " + (.id|tostring) + ")"' || { [ $? -eq 2 ] && return 0 || return 1; }
  local new_name payload gid="$SELECTED_ID"
  new_name=$(prompt_nonempty "New group name: ")
  payload=$(jq -n --arg name "$new_name" '{name:$name}')
  if api_put "/groups/$gid" "$payload"; then ok "Group renamed to $(jq -r '.name' "$API_LAST_BODY_FILE")"; clear_cache
  else die "Rename failed (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"; fi
}
delete_group() {
  if ! api_get_paginated "/groups?per_page=100&min_access_level=10"; then
    die "Failed to list groups (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
  fi
  local list="$API_LAST_BODY_FILE"
  select_from_json "$list" '.full_path + " (id " + (.id|tostring) + ")"' || { [ $? -eq 2 ] && return 0 || return 1; }
  local gid="$SELECTED_ID" name
  name=$(jq -r '.full_path' <<<"$SELECTED_ITEM")
  if ask_confirm "Really delete group '$name' (id $gid)? This cannot be undone."; then
    if api_delete "/groups/$gid"; then ok "Group deleted."; clear_cache
    else die "Delete failed (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
    fi
  else info "Cancelled."; fi
}

# ---------- Projects ----------
list_projects() {
  local cache_file
  cache_file=$(cache_get "projects") || true
  if [ -n "${cache_file:-}" ]; then
    cp "$cache_file" "$TMPDIR/projects.json"
  else
    if ! api_get_paginated "/projects?membership=true&order_by=last_activity_at&sort=desc&per_page=100"; then
      die "Failed to fetch projects (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
    fi
    cp "$API_LAST_BODY_FILE" "$TMPDIR/projects.json"
    cache_put "projects" "$TMPDIR/projects.json"
  fi
  jq -r '.[] | "\(.id)\t\(.path_with_namespace)\t\(.last_activity_at)"' "$TMPDIR/projects.json" | column -t -s$'\t'
}
create_project() {
  local name payload ns_id
  name=$(prompt_nonempty "Project name: ")
  read -r -p "Create under a group? [y/N]: " yn || true
  if [[ "${yn:-}" =~ ^[yY] ]]; then
    if ! api_get_paginated "/groups?per_page=100&min_access_level=30"; then
      die "Failed to list groups: $(cat "$API_LAST_BODY_FILE")"
    fi
    local list="$API_LAST_BODY_FILE"
    select_from_json "$list" '.full_path + " (id " + (.id|tostring) + ")"' || { [ $? -eq 2 ] && return 0 || return 1; }
    ns_id="$SELECTED_ID"
    payload=$(jq -n --arg name "$name" --argjson ns "$ns_id" '{name:$name, namespace_id:$ns, initialize_with_readme:true, visibility:"private"}')
  else
    payload=$(jq -n --arg name "$name" '{name:$name, initialize_with_readme:true, visibility:"private"}')
  fi
  if api_post "/projects" "$payload"; then
    local proj_json="$API_LAST_BODY_FILE"
    local pid branch ns_path
    pid=$(jq -r '.id' "$proj_json")
    branch=$(jq -r '.default_branch // "main"' "$proj_json")
    ns_path=$(jq -r '.path_with_namespace // empty' "$proj_json")
    ok "Project created (id $pid). Adding template files on branch '$branch'..."
    add_template_files "$pid" "$name" "$branch"

    # Always refetch to get stable clone URLs
    if get_project_urls "$pid"; then
      [ -z "$PROJECT_NS_PATH" ] && PROJECT_NS_PATH="$ns_path"
      _clone_into "$PROJECT_CLONE_URL" "$PROJECT_NS_PATH"
    else
      [ -z "$ns_path" ] && ns_path="$(jq -r '.path_with_namespace' "$proj_json")"
      local fallback_url="${INSTANCE_URL%/}/${ns_path}.git"
      warn "Clone URL missing from API response; falling back to: $fallback_url"
      _clone_into "$fallback_url" "$ns_path"
    fi

    clear_cache
  else
    die "Project creation failed (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
  fi
}
add_template_files() {
  local pid="$1" title="${2:-Project}" branch="$3"

  # README.md with real newlines (title is expanded)
  local readme_content
  readme_content=$(cat <<EOF
# ${title}

Basic project scaffold created by GitLab TUI.
EOF
)
  upsert_file "$pid" "README.md" "$readme_content" "$branch" "Initialize README"

  # .gitlab-ci.yml with correct YAML and literal ${SHARED_CONFIGURATION}
  # (single-quoted heredoc prevents shell expansion)
  local ci_content
  ci_content=$(cat <<'YAML'
variables:
  PUSH_TO_GITHUB: "true"
  GITHUB_REPO_PRIVATE: "false"

include:
  - project: '${SHARED_CONFIGURATION}'
    file: 'github-deploy.yml'
YAML
)
  upsert_file "$pid" ".gitlab-ci.yml" "$ci_content" "$branch" "Add CI template"
}

upsert_file() {
  local pid="$1" fpath="$2" content="$3" branch="$4" message="$5"
  local enc; enc=$(urlencode "$fpath")
  if api_get "/projects/$pid/repository/files/$enc?ref=$branch"; then
    local payload; payload=$(jq -n --arg branch "$branch" --arg content "$content" --arg msg "$message" '{branch:$branch, content:$content, commit_message:$msg}')
    if api_put "/projects/$pid/repository/files/$enc" "$payload"; then ok "Updated $fpath"
    else die "Failed to update $fpath (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"; fi
  else
    if [ "$API_LAST_STATUS" = "404" ]; then
      local payload; payload=$(jq -n --arg branch "$branch" --arg content "$content" --arg msg "$message" '{branch:$branch, content:$content, commit_message:$msg}')
      if api_post "/projects/$pid/repository/files/$enc" "$payload"; then ok "Created $fpath"
      else die "Failed to create $fpath (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"; fi
    else
      die "Failed to check file $fpath (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"
    fi
  fi
}
rename_project() {
  if ! api_get_paginated "/projects?membership=true&order_by=last_activity_at&sort=desc&per_page=100"; then
    die "Failed to list projects: $(cat "$API_LAST_BODY_FILE")"
  fi
  local list="$API_LAST_BODY_FILE"
  select_from_json "$list" '.path_with_namespace + " (id " + (.id|tostring) + ")"' || { [ $? -eq 2 ] && return 0 || return 1; }
  local pid="$SELECTED_ID" new_name payload
  new_name=$(prompt_nonempty "New project name: ")
  payload=$(jq -n --arg name "$new_name" '{name:$name}')
  if api_put "/projects/$pid" "$payload"; then ok "Project renamed to $(jq -r '.name' "$API_LAST_BODY_FILE")"; clear_cache
  else die "Rename failed (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"; fi
}
delete_project() {
  if ! api_get_paginated "/projects?membership=true&order_by=last_activity_at&sort=desc&per_page=100"; then
    die "Failed to list projects: $(cat "$API_LAST_BODY_FILE")"
  fi
  local list="$API_LAST_BODY_FILE"
  select_from_json "$list" '.path_with_namespace + " (id " + (.id|tostring) + ")"' || { [ $? -eq 2 ] && return 0 || return 1; }
  local pid="$SELECTED_ID" name
  name=$(jq -r '.path_with_namespace' <<<"$SELECTED_ITEM")
  if ask_confirm "Really delete project '$name' (id $pid)? This cannot be undone."; then
    if api_delete "/projects/$pid"; then ok "Project deleted."; clear_cache
    else die "Delete failed (HTTP $API_LAST_STATUS): $(cat "$API_LAST_BODY_FILE")"; fi
  else info "Cancelled."; fi
}
clone_project() {
  if ! api_get_paginated "/projects?membership=true&order_by=last_activity_at&sort=desc&per_page=100"; then
    die "Failed to list projects: $(cat "$API_LAST_BODY_FILE")"
  fi
  local list="$API_LAST_BODY_FILE" ns_path url
  select_from_json "$list" '.path_with_namespace + " (id " + (.id|tostring) + ")"' || { [ $? -eq 2 ] && return 0 || return 1; }
  ns_path=$(jq -r '.path_with_namespace' <<<"$SELECTED_ITEM")
  url=$(jq -r '(.ssh_url_to_repo // .http_url_to_repo // empty)' <<<"$SELECTED_ITEM")
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    # Refetch single project to get full representation
    if api_get "/projects/$SELECTED_ID"; then
      url=$(jq -r '(.ssh_url_to_repo // .http_url_to_repo // empty)' "$API_LAST_BODY_FILE")
      ns_path=$(jq -r '.path_with_namespace // empty' "$API_LAST_BODY_FILE")
    fi
  fi
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    local fallback_url="${INSTANCE_URL%/}/${ns_path}.git"
    warn "Clone URL not present in list response; falling back to: $fallback_url"
    url="$fallback_url"
  fi   # <-- fixed: was 'end'
  _clone_into "$url" "$ns_path"
}

# ---------- Settings ----------
settings_menu() {
  while :; do
    clear
    echo "${BOLD}Settings (instance: $INSTANCE_URL)${RESET}"
    cat <<EOF
1) Update GitLab token
2) Set GitLab instance URL
3) Clear cached data
4) Back
5) Quit
EOF
    read -r -p "Choose: " ans || true
    case "$ans" in
      1)
        echo -n "Enter new GitLab token: "; IFS= read -r -s ntok; echo
        if [ -z "${ntok:-}" ]; then warn "Token unchanged."; else keyring_store_token "$ntok"; TOKEN="$ntok"; ok "Token updated."; fi
        press_enter;;
      2)
        local url; url=$(prompt_nonempty "Instance URL (must start with https://): ")
        validate_https_url "$url" || die "Only HTTPS instance URLs are allowed."
        INSTANCE_URL="$url"; save_config; refresh_base; TOKEN=""; prompt_token_if_missing; press_enter;;
      3) clear_cache; ok "Cache cleared."; press_enter;;
      4) return 0;;
      5) exit 0;;
      *) warn "Invalid choice."; sleep 1;;
    esac
  done
}

# ---------- Menus ----------
groups_menu() {
  while :; do
    clear
    echo "${BOLD}Groups${RESET}"
    cat <<'EOF'
1) New Group
2) Rename Group
3) List Groups
4) Delete Group
5) Back
6) Quit
EOF
    read -r -p "Choose: " ans || true
    case "$ans" in
      1) create_group; press_enter;;
      2) rename_group; press_enter;;
      3) list_groups; press_enter;;
      4) delete_group; press_enter;;
      5) return 0;;
      6) exit 0;;
      *) warn "Invalid choice."; sleep 1;;
    esac
  done
}
projects_menu() {
  while :; do
    clear
    echo "${BOLD}Projects${RESET}"
    cat <<'EOF'
1) Clone Project
2) Create Project
3) Rename Project
4) List Projects
5) Delete Project
6) Back
7) Quit
EOF
    read -r -p "Choose: " ans || true
    case "$ans" in
      1) clone_project; press_enter;;
      2) create_project; press_enter;;
      3) rename_project; press_enter;;
      4) list_projects; press_enter;;
      5) delete_project; press_enter;;
      6) return 0;;
      7) exit 0;;
      *) warn "Invalid choice."; sleep 1;;
    esac
  done
}
main_menu() {
  while :; do
    clear
    echo "${BOLD}GitLab TUI (v$VERSION)${RESET}"
    cat <<'EOF'
Main Menu:
1) Groups
2) Projects
3) Settings
4) Quit
EOF
    read -r -p "Choose: " ans || true
    case "$ans" in
      1) groups_menu;;
      2) projects_menu;;
      3) settings_menu;;
      4) exit 0;;
      *) warn "Invalid choice."; sleep 1;;
    esac
  done
}

# ---------- Bootstrap ----------
load_config
[ -z "${INSTANCE_URL:-}" ] && INSTANCE_URL="$DEFAULT_INSTANCE_URL"
validate_https_url "$INSTANCE_URL" || die "INSTANCE_URL must start with https://"
refresh_base
prompt_token_if_missing
ensure_clone_root
main_menu
