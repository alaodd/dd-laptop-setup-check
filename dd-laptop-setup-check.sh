#!/usr/bin/env bash
#
# dd-laptop-setup-check.sh
#
# Audits a Datadog work laptop against the "Datadog Laptop Setup Guide":
#   https://datadoghq.atlassian.net/wiki/spaces/ISEC/pages/6965658495/Datadog+Laptop+Setup+Guide
#
# For every item in the guide the script prints one of:
#   [OK]        already installed / already configured  -> nothing to do
#   [INSTALLED] was missing, this script installed it
#   [FAILED]    was missing, install was attempted and failed
#   [MANUAL]    cannot be automated (GUI app, Chrome extension, interactive login)
#   [SKIPPED]   install skipped by you or by --check-only / --dry-run
#   [WARN]      present but not in the state the guide expects
#
# Usage:
#   ./dd-laptop-setup-check.sh                 # audit, then prompt before each install
#   ./dd-laptop-setup-check.sh --yes           # audit and install without prompting
#   ./dd-laptop-setup-check.sh --check-only    # audit only, never install
#   ./dd-laptop-setup-check.sh --dry-run       # audit, print install commands, run nothing
#   ./dd-laptop-setup-check.sh --email a.b@datadoghq.com
#                                              # used for git identity + username checks
#   ./dd-laptop-setup-check.sh --no-network    # skip checks that hit the network
#   ./dd-laptop-setup-check.sh --sudo-interactive
#                                              # also run a real `sudo ls` (will prompt for
#                                              # your Mac password); the default probe is
#                                              # non-interactive and never prompts
#
# Safe to re-run. Nothing here is destructive.
#
# Note: any sudo probe causes the Privileges app to grant just-in-time admin
# (typically 20 minutes). That is the documented Datadog behaviour, not a change
# this script makes permanently.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration / flags
# ---------------------------------------------------------------------------

ASSUME_YES=0
CHECK_ONLY=0
DRY_RUN=0
NO_NETWORK=0
SUDO_INTERACTIVE=0
DD_EMAIL=""

BREW_PREFIX_ARM="/opt/homebrew"
BREW_PREFIX_INTEL="/usr/local"
NODE_MIN_MAJOR=18
GUIDE_URL="https://datadoghq.atlassian.net/wiki/spaces/ISEC/pages/6965658495/Datadog+Laptop+Setup+Guide"
DOGGO_EXT_ID="hcdoigpbdkefpiejgenmfgkfglmhacbk"

# Internal hosts that only resolve/respond when the AppGate tunnel is up.
INTERNAL_HOSTS="gitlab.ddbuild.io binaries.ddbuild.io vault.us1.ddbuild.io"
# The two GitHub orgs from Step 3.1, and the team from Step 1.2.
GITHUB_ORGS="DataDog ddoghq"
GITHUB_TEAM_SLUG="dev"
# Private repo used as a direct read-access probe (Step 1.2 of the guide).
GITHUB_PROBE_REPO="DataDog/dogweb"
# GitLab group from Step 1.5 / 3.5.
GITLAB_HOST="gitlab.ddbuild.io"
GITLAB_GROUP="DataDog"
# dda install instructions are read live from here, never hardcoded.
DDA_DOCS_URL="https://datadoghq.dev/datadog-agent-dev/install/"

usage() {
  sed -n '/^# Usage:/,/^# this script makes permanently\./p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)           ASSUME_YES=1 ;;
    -c|--check-only)    CHECK_ONLY=1 ;;
    -n|--dry-run)       DRY_RUN=1 ;;
    --no-network)       NO_NETWORK=1 ;;
    --sudo-interactive) SUDO_INTERACTIVE=1 ;;
    --email)            DD_EMAIL="${2:-}"; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Output plumbing: colored to the terminal, plain text to the log file
# ---------------------------------------------------------------------------

LOG_FILE="${HOME}/dd-laptop-setup-check-$(date +%Y%m%d-%H%M%S).log"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
fi

: > "$LOG_FILE"

# Writes a colored line to the terminal and the same line, stripped, to the log.
emit() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" \
    | sed -E $'s/\033\\[[0-9;]*m//g' >> "$LOG_FILE"
}

N_OK=0; N_INSTALLED=0; N_FAILED=0; N_MANUAL=0; N_SKIPPED=0; N_WARN=0
RESULTS=()

record() { # record <STATUS> <item> <detail>
  RESULTS+=("$1|$2|$3")
  case "$1" in
    OK)        N_OK=$((N_OK+1)) ;;
    INSTALLED) N_INSTALLED=$((N_INSTALLED+1)) ;;
    FAILED)    N_FAILED=$((N_FAILED+1)) ;;
    MANUAL)    N_MANUAL=$((N_MANUAL+1)) ;;
    SKIPPED)   N_SKIPPED=$((N_SKIPPED+1)) ;;
    WARN)      N_WARN=$((N_WARN+1)) ;;
  esac
}

ok()        { emit "  ${C_GREEN}[OK]${C_RESET}        $1 — ${C_DIM}already installed${C_RESET}${2:+ ($2)}"; record OK "$1" "${2:-already installed}"; }
ok_cfg()    { emit "  ${C_GREEN}[OK]${C_RESET}        $1 — ${C_DIM}already configured${C_RESET}${2:+ ($2)}"; record OK "$1" "${2:-already configured}"; }
installed() { emit "  ${C_CYAN}[INSTALLED]${C_RESET} $1${2:+ — $2}"; record INSTALLED "$1" "${2:-installed by this script}"; }
failed()    { emit "  ${C_RED}[FAILED]${C_RESET}    $1${2:+ — $2}"; record FAILED "$1" "${2:-install failed}"; }
manual()    { emit "  ${C_MAGENTA}[MANUAL]${C_RESET}    $1${2:+ — $2}"; record MANUAL "$1" "${2:-needs a human}"; }
skipped()   { emit "  ${C_YELLOW}[SKIPPED]${C_RESET}   $1${2:+ — $2}"; record SKIPPED "$1" "${2:-skipped}"; }
warn()      { emit "  ${C_YELLOW}[WARN]${C_RESET}      $1${2:+ — $2}"; record WARN "$1" "${2:-unexpected state}"; }
info()      { emit "              ${C_DIM}$1${C_RESET}"; }
hdr()       { emit ""; emit "${C_BOLD}${C_BLUE}=== $1 ===${C_RESET}"; }
checking()  { emit "  ${C_DIM}checking:${C_RESET} $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Poor-man's timeout: macOS has no coreutils `timeout` by default.
run_timeout() { # run_timeout <seconds> <cmd...>
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return $rc
}

confirm() { # confirm "<prompt>"  -> 0 yes, 1 no
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ ! -t 0 ] && return 1
  local reply=""
  printf '  %s[?]%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$1"
  read -r reply
  printf '  [?] %s -> %s\n' "$1" "${reply:-N}" >> "$LOG_FILE"
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# install_step <item label> <install command string>
# Honours --check-only / --dry-run, prompts unless --yes, logs the outcome.
install_step() {
  local item="$1" cmd="$2"
  info "install command: $cmd"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    skipped "$item" "not installed (--check-only)"; return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    skipped "$item" "would run: $cmd (--dry-run)"; return 1
  fi
  if ! confirm "Install $item now?"; then
    skipped "$item" "declined at prompt"; return 1
  fi
  emit "  ${C_DIM}running:${C_RESET} $cmd"
  if bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

emit "${C_BOLD}Datadog Laptop Setup Guide — installed-state check${C_RESET}"
emit "${C_DIM}Guide: ${GUIDE_URL}${C_RESET}"
emit "${C_DIM}Log:   ${LOG_FILE}${C_RESET}"
emit "${C_DIM}Host:  $(scutil --get ComputerName 2>/dev/null || hostname) | macOS $(sw_vers -productVersion 2>/dev/null) | $(uname -m)${C_RESET}"
mode_desc="install missing items (prompting)"
[ "$ASSUME_YES" -eq 1 ] && mode_desc="install missing items (no prompts)"
[ "$DRY_RUN" -eq 1 ]    && mode_desc="dry run — report only, print install commands"
[ "$CHECK_ONLY" -eq 1 ] && mode_desc="check only — report, never install"
emit "${C_DIM}Mode:  ${mode_desc}${C_RESET}"

if [ -z "$DD_EMAIL" ]; then
  DD_EMAIL="$(git config --global user.email 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Step 1 — Preflight checks
# ---------------------------------------------------------------------------

hdr "Step 1 — Preflight checks"

# 1.1 Slack + Self Service + AppGate are IT/Self-Service installs, not scriptable.
check_app() { # check_app "<App Name>" "</Applications/X.app>" "<how to get it>"
  checking "$1 ($2)"
  if [ -d "$2" ]; then
    local v
    v="$(defaults read "$2/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    ok "$1" "${v:+version $v}"
  else
    manual "$1" "not found at $2 — $3"
  fi
}

check_app "Slack" "/Applications/Slack.app" \
  "install from Self Service, or request via Freshservice https://datadog.freshservice.com/support/catalog/items/488"
check_app "AppGate SDP" "/Applications/AppGate SDP.app" \
  "install from Self Service — required for GitLab, Vault and internal services"
check_app "Self Service" "/Applications/Self Service.app" \
  "Day 1 IT install — ask in #onboarding-help if missing"
check_app "Google Chrome" "/Applications/Google Chrome.app" \
  "needed for the Doggo extension in Step 5.1"

# 1.3 git + Apple command line tools
checking "Apple command line tools (xcode-select -p)"
if xcode-select -p >/dev/null 2>&1; then
  ok "Apple command line tools" "$(xcode-select -p)"
else
  info "The guide: run 'xcode-select --install', or install Command Line Tools from Self Service."
  if install_step "Apple command line tools" "xcode-select --install"; then
    installed "Apple command line tools" "GUI installer launched — finish it, then re-run this script"
  else
    : # install_step already recorded SKIPPED
  fi
fi

checking "git (command -v git)"
if have git; then
  ok "git" "$(git --version 2>/dev/null)"
else
  failed "git" "missing — install Apple command line tools above, then re-run"
fi

# 1.3 git identity
checking "git global user.email"
gh_email="$(git config --global user.email 2>/dev/null || true)"
if [ -z "$gh_email" ]; then
  if [ -n "$DD_EMAIL" ] && [ "$DD_EMAIL" != "$gh_email" ]; then
    if install_step "git user.email" "git config --global user.email \"$DD_EMAIL\""; then
      installed "git user.email" "set to $DD_EMAIL"
    fi
  else
    manual "git user.email" "unset — run: git config --global user.email \"your.name@datadoghq.com\" (or re-run with --email)"
  fi
elif [[ "$gh_email" == *"@datadoghq.com" ]]; then
  ok_cfg "git user.email" "$gh_email"
else
  warn "git user.email" "$gh_email is not an @datadoghq.com address"
fi

checking "git global user.name"
gh_name="$(git config --global user.name 2>/dev/null || true)"
if [ -n "$gh_name" ]; then
  ok_cfg "git user.name" "$gh_name"
else
  manual "git user.name" "unset — run: git config --global user.name \"Your Name\""
fi

# 1.4 Mac username, $USER, and the home folder must all match the Google
#     Workspace account name (the local part of the Datadog email).
checking "username consistency (whoami / \$USER / home folder / Workspace account)"
mac_user="$(whoami)"
env_user="${USER:-<unset>}"
home_base="$(basename "$HOME")"
info "whoami=$mac_user  \$USER=$env_user  home folder=$home_base  HOME=$HOME"

user_mismatch=""
[ "$mac_user" != "$env_user" ]  && user_mismatch="${user_mismatch} whoami!=\$USER"
[ "$mac_user" != "$home_base" ] && user_mismatch="${user_mismatch} whoami!=home-folder"

# Only trust the email for this comparison if it is actually a Datadog address;
# a personal address in git config would produce a bogus mismatch.
workspace_user=""
case "$DD_EMAIL" in
  *@datadoghq.com) workspace_user="${DD_EMAIL%@*}" ;;
esac

if [ -n "$user_mismatch" ]; then
  warn "Username consistency" "mismatch:${user_mismatch} — see https://support.apple.com/en-us/HT201548"
elif [ -n "$workspace_user" ]; then
  if [ "$mac_user" = "$workspace_user" ]; then
    ok_cfg "Username consistency" "whoami, \$USER, home folder and Workspace account all '$mac_user'"
  else
    warn "Username consistency" "whoami/\$USER/home folder are '$mac_user' but Workspace account is '$workspace_user' — see https://support.apple.com/en-us/HT201548"
  fi
else
  ok_cfg "Username consistency" "whoami, \$USER and home folder all '$mac_user'"
  info "No @datadoghq.com address known, so the Workspace account name was not compared. Re-run with: --email first.last@datadoghq.com"
fi

# 1.6 Admin access. Datadog laptops grant admin just-in-time through the
#     Privileges app, so group membership alone is not the answer. The default
#     probe below is non-interactive: it never asks for your password.
#
#     Side effect worth knowing: invoking sudo at all is what triggers the
#     Privileges grant, so this check may itself start a ~20 minute admin window.
checking "admin rights (Privileges JIT admin / sudo)"
sudo_out="$(run_timeout 25 sudo -nv 2>&1)"
printf '%s\n' "$sudo_out" >> "$LOG_FILE"

in_admin_group=1
id -Gn "$mac_user" 2>/dev/null | tr ' ' '\n' | grep -qx admin && in_admin_group=0

if printf '%s' "$sudo_out" | grep -qiE 'not in the sudoers file|not allowed to run sudo|may not run sudo'; then
  warn "Admin rights" "$mac_user cannot run sudo at all — contact IT; setup scripts fail in confusing ways without it"
elif printf '%s' "$sudo_out" | grep -qiE 'now has administrator privileges|already has the requested privileges|privileges expire'; then
  ok_cfg "Admin rights" "Privileges JIT admin granted — $(printf '%s' "$sudo_out" | grep -iE 'administrator privileges|privileges expire' | head -1)"
elif [ "$in_admin_group" -eq 0 ]; then
  ok_cfg "Admin rights" "$mac_user is in the 'admin' group"
elif printf '%s' "$sudo_out" | grep -qi 'a password is required'; then
  ok_cfg "Admin rights" "sudo is available and will prompt for your password (expected)"
else
  warn "Admin rights" "could not confirm — sudo said: $(printf '%s' "$sudo_out" | head -1)"
  info "Open the Privileges app, grant yourself temporary admin, then re-run."
fi

# The guide's literal check is `sudo ls`. Only run it when asked, because it
# prompts for your Mac password and this script is otherwise non-interactive.
if [ "$SUDO_INTERACTIVE" -eq 1 ]; then
  checking "sudo ls (interactive — will prompt for your Mac password)"
  if sudo ls >/dev/null 2>>"$LOG_FILE"; then
    ok_cfg "sudo ls" "succeeded"
  else
    warn "sudo ls" "failed — grant admin via the Privileges app, or contact IT"
  fi
else
  info "Skipping the literal 'sudo ls' password prompt. Re-run with --sudo-interactive to include it."
fi

# 1.5 / 4.1 AppGate: installed is not the same as connected. Check the client
#           and driver processes, the tunnel interface, internal DNS, and an
#           actual HTTPS response from internal-only hosts.
hdr "Step 1.5 / 4.1 — AppGate tunnel and internal network"

checking "AppGate client and driver processes"
ag_client=1; ag_driver=1
pgrep -f '/Applications/AppGate SDP.app/Contents/MacOS/Appgate SDP' >/dev/null 2>&1 && ag_client=0
pgrep -f 'Appgate Driver' >/dev/null 2>&1 && ag_driver=0
if [ "$ag_client" -eq 0 ] && [ "$ag_driver" -eq 0 ]; then
  ok_cfg "AppGate processes" "client and driver both running"
elif [ "$ag_driver" -eq 0 ]; then
  warn "AppGate processes" "driver running but the AppGate SDP client is not — open AppGate SDP and Sign in with Provider"
else
  warn "AppGate processes" "AppGate SDP is not running — open it and Sign in with Provider"
fi

checking "tunnel interface (utun)"
utun_list="$(ifconfig 2>/dev/null | grep -oE '^utun[0-9]+' | tr '\n' ' ')"
if [ -n "$utun_list" ]; then
  ok_cfg "Tunnel interface" "present: $utun_list"
else
  warn "Tunnel interface" "no utun interface — AppGate is not connected"
fi

if [ "$NO_NETWORK" -eq 1 ]; then
  skipped "Internal DNS resolution" "--no-network"
  skipped "Internal HTTPS reachability" "--no-network"
  skipped "Okta SSO on internal services" "--no-network"
else
  checking "internal DNS resolution ($INTERNAL_HOSTS)"
  dns_ok=0; dns_bad=""
  for h in $INTERNAL_HOSTS; do
    ip="$(dscacheutil -q host -a name "$h" 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    if [ -n "$ip" ]; then
      info "$h -> $ip"
      dns_ok=$((dns_ok+1))
    else
      info "$h -> (no answer)"
      dns_bad="${dns_bad} $h"
    fi
  done
  if [ -z "$dns_bad" ]; then
    ok_cfg "Internal DNS resolution" "all $dns_ok internal hosts resolve"
  elif [ "$dns_ok" -gt 0 ]; then
    warn "Internal DNS resolution" "partial — no answer for:${dns_bad}"
  else
    warn "Internal DNS resolution" "no internal host resolves — AppGate is not connected (look for the green checkmark in AppGate SDP)"
  fi

  checking "internal HTTPS reachability"
  reach_bad=""
  for h in $INTERNAL_HOSTS; do
    code="$(run_timeout 18 curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$h/" 2>/dev/null)"
    if [ -n "${code:-}" ] && [ "$code" != "000" ]; then
      info "https://$h/ -> HTTP $code"
    else
      info "https://$h/ -> no response"
      reach_bad="${reach_bad} $h"
    fi
  done
  if [ -z "$reach_bad" ]; then
    ok_cfg "Internal HTTPS reachability" "all internal hosts responded"
  else
    warn "Internal HTTPS reachability" "no response from:${reach_bad} — reconnect AppGate and re-run"
  fi

  # SSO: an unauthenticated request to GitLab should land on a sign-in flow.
  # A connection failure means the tunnel is down; an HTML sign-in page means
  # the identity layer is reachable and ready to take your Okta login.
  checking "Okta SSO reachable on internal services (gitlab sign-in flow)"
  sso_body="$(run_timeout 20 curl -sL --max-time 15 -o - -w '\n__HTTP_CODE__%{http_code}' "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null)"
  sso_code="$(printf '%s' "$sso_body" | sed -n 's/.*__HTTP_CODE__//p' | tail -1)"
  if [ -z "${sso_code:-}" ] || [ "$sso_code" = "000" ]; then
    warn "Okta SSO reachability" "could not reach the GitLab sign-in page — AppGate tunnel is down"
  elif [ "$sso_code" = "200" ]; then
    if printf '%s' "$sso_body" | grep -qiE 'okta|saml|oauth|sign in|sign_in'; then
      ok_cfg "Okta SSO reachability" "GitLab sign-in flow reachable (HTTP 200)"
    else
      warn "Okta SSO reachability" "HTTP 200 but the page does not look like a sign-in flow"
    fi
  else
    warn "Okta SSO reachability" "GitLab sign-in page returned HTTP $sso_code"
  fi
  info "Whether your Okta session is actually valid is proven by the authenticated checks below (GitHub, GitLab token, Vault)."
fi

# ---------------------------------------------------------------------------
# Step 1.2 — GitHub org and team access
# ---------------------------------------------------------------------------

hdr "Step 1.2 / 3.1 — GitHub org and team access"

checking "GitHub CLI (gh)"
if have gh; then
  ok "GitHub CLI" "$(gh --version 2>/dev/null | head -1)"
elif have brew; then
  if install_step "GitHub CLI" "brew install gh"; then
    have gh && installed "GitHub CLI" "$(gh --version 2>/dev/null | head -1)" \
            || failed "GitHub CLI" "brew install ran but gh is not on PATH"
  fi
else
  failed "GitHub CLI" "missing and Homebrew is unavailable"
fi

gh_login=""
ssh_login=""

if [ "$NO_NETWORK" -eq 1 ]; then
  skipped "GitHub org membership" "--no-network"
  skipped "GitHub Dev team membership" "--no-network"
elif ! have gh; then
  manual "GitHub org membership" "install gh, run 'gh auth login', then re-run to check $GITHUB_ORGS"
else
  checking "gh authentication"
  gh_auth="$(run_timeout 30 gh auth status 2>&1)"
  printf '%s\n' "$gh_auth" >> "$LOG_FILE"
  gh_login="$(run_timeout 25 gh api user --jq .login 2>/dev/null)"
  gh_scopes="$(printf '%s' "$gh_auth" | sed -n "s/.*Token scopes: //p" | head -1)"
  if [ -n "$gh_login" ]; then
    ok_cfg "gh authentication" "logged in as '$gh_login'${gh_scopes:+, scopes: $gh_scopes}"
  else
    warn "gh authentication" "not logged in — run: gh auth login"
  fi

  if ! printf '%s' "$gh_scopes" | grep -q 'read:org'; then
    warn "gh token scopes" "missing 'read:org' — org and team checks will be incomplete. Fix: gh auth refresh -h github.com -s read:org"
  fi

  if [ -n "$gh_login" ]; then
    # Org membership, via the authenticated user's own org list (needs read:org).
    checking "GitHub org membership ($GITHUB_ORGS)"
    gh_orgs="$(run_timeout 40 gh api 'user/orgs?per_page=100' --jq '.[].login' 2>/dev/null)"
    printf 'user/orgs:\n%s\n' "$gh_orgs" >> "$LOG_FILE"
    orgs_missing=""
    for o in $GITHUB_ORGS; do
      if printf '%s\n' "$gh_orgs" | grep -qix "$o"; then
        info "$o: member"
      else
        info "$o: NOT a member (as '$gh_login')"
        orgs_missing="${orgs_missing} $o"
      fi
    done
    if [ -z "$orgs_missing" ]; then
      ok_cfg "GitHub org membership" "'$gh_login' is in both $GITHUB_ORGS"
    else
      warn "GitHub org membership" "'$gh_login' is not in:${orgs_missing} — accept the org invite, or request via https://datadog.freshservice.com/support/catalog/items/502"
    fi

    # "Dev" team membership in each org (needs read:org).
    checking "GitHub '$GITHUB_TEAM_SLUG' team membership in $GITHUB_ORGS"
    gh_teams="$(run_timeout 60 gh api 'user/teams?per_page=100' --paginate --jq '.[] | .organization.login + "/" + .slug' 2>/dev/null)"
    printf 'user/teams:\n%s\n' "$gh_teams" >> "$LOG_FILE"
    teams_missing=""
    for o in $GITHUB_ORGS; do
      if printf '%s\n' "$gh_teams" | grep -qix "$o/$GITHUB_TEAM_SLUG"; then
        info "$o/$GITHUB_TEAM_SLUG: member"
      else
        info "$o/$GITHUB_TEAM_SLUG: NOT a member"
        teams_missing="${teams_missing} $o/$GITHUB_TEAM_SLUG"
      fi
    done
    if [ -z "$teams_missing" ]; then
      ok_cfg "GitHub Dev team membership" "member of both $GITHUB_ORGS teams"
    else
      warn "GitHub Dev team membership" "not in:${teams_missing} — request via https://datadog.freshservice.com/support/catalog/items/502 (team page: https://github.com/orgs/DataDog/teams/dev/members)"
    fi

    # Direct read test against a private repo named in the guide.
    checking "private repo read access ($GITHUB_PROBE_REPO)"
    if run_timeout 30 gh api "repos/$GITHUB_PROBE_REPO" --jq .full_name >/dev/null 2>&1; then
      ok_cfg "Private repo access" "can read $GITHUB_PROBE_REPO"
    else
      warn "Private repo access" "cannot read $GITHUB_PROBE_REPO as '$gh_login' — this is the guide's Step 1.2 verification"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Laptop baseline
# ---------------------------------------------------------------------------

hdr "Step 2 — Install the laptop baseline"

# 2.1 Homebrew
checking "Homebrew (brew --version)"
if ! have brew; then
  for p in "$BREW_PREFIX_ARM" "$BREW_PREFIX_INTEL"; do
    if [ -x "$p/bin/brew" ]; then
      info "brew found at $p/bin/brew but not on PATH — loading shellenv for this run"
      eval "$("$p/bin/brew" shellenv)"
      break
    fi
  done
fi

if have brew; then
  ok "Homebrew" "$(brew --version 2>/dev/null | head -1)"
else
  if install_step "Homebrew" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; then
    for p in "$BREW_PREFIX_ARM" "$BREW_PREFIX_INTEL"; do
      [ -x "$p/bin/brew" ] && eval "$("$p/bin/brew" shellenv)" && break
    done
    if have brew; then
      installed "Homebrew" "$(brew --version 2>/dev/null | head -1)"
      info "Add this to ~/.zshrc so brew stays on PATH: eval \"\$($(command -v brew) shellenv)\""
    else
      failed "Homebrew" "installer ran but brew is still not on PATH"
    fi
  fi
fi

# 2.2 Node.js >= 18
checking "Node.js >= ${NODE_MIN_MAJOR} (node --version)"
if have node; then
  node_ver="$(node --version 2>/dev/null)"
  node_major="$(printf '%s' "${node_ver#v}" | cut -d. -f1)"
  if [ -n "$node_major" ] && [ "$node_major" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null; then
    ok "Node.js" "$node_ver"
  else
    warn "Node.js" "$node_ver is older than v${NODE_MIN_MAJOR} — Claude Code and related tools need v${NODE_MIN_MAJOR}+"
    if have brew; then
      if install_step "Node.js upgrade" "brew upgrade node || brew install node"; then
        installed "Node.js upgrade" "$(node --version 2>/dev/null)"
      fi
    fi
  fi
else
  if have brew; then
    if install_step "Node.js" "brew install node"; then
      installed "Node.js" "$(node --version 2>/dev/null)"
    else
      :
    fi
  else
    failed "Node.js" "missing and Homebrew is unavailable — install Homebrew first"
  fi
fi

# 2.3 Datadog engineering setup script
checking "Datadog engineering setup script (laptop-setup.sh)"
setup_script=""
for candidate in "$HOME/Downloads/laptop-setup.sh" "$HOME/laptop-setup.sh"; do
  [ -f "$candidate" ] && setup_script="$candidate" && break
done
if [ -n "$setup_script" ]; then
  ok "laptop-setup.sh" "present at $setup_script"
  manual "laptop-setup.sh run" "cannot verify it completed — re-run manually if unsure: /bin/bash $setup_script (safe to re-run, can take hours)"
else
  info "Source: https://github.com/DataDog/devtools/raw/master/laptop-ansible/laptop-setup.sh (requires GitHub access + AppGate)"
  if install_step "laptop-setup.sh download" \
      "curl -fsSL -o \"$HOME/Downloads/laptop-setup.sh\" https://github.com/DataDog/devtools/raw/master/laptop-ansible/laptop-setup.sh"; then
    if [ -s "$HOME/Downloads/laptop-setup.sh" ]; then
      installed "laptop-setup.sh download" "saved to ~/Downloads/laptop-setup.sh"
      manual "laptop-setup.sh run" "not run by this script (interactive, hours long) — run: cd ~/Downloads && /bin/bash laptop-setup.sh"
    else
      failed "laptop-setup.sh download" "downloaded file is empty — check GitHub access and AppGate"
    fi
  fi
fi

# 2.4 Shell config permissions
checking "~/.zshrc permissions"
if [ -f "$HOME/.zshrc" ]; then
  zshrc_mode="$(stat -f '%OLp' "$HOME/.zshrc" 2>/dev/null)"
  if [ "$zshrc_mode" = "600" ]; then
    ok_cfg "~/.zshrc permissions" "mode $zshrc_mode"
  elif printf '%s' "$zshrc_mode" | grep -qE '^[0-7][2367][0-7]$|^[0-7][0-7][2367]$'; then
    warn "~/.zshrc permissions" "mode $zshrc_mode is group- or world-writable"
    if install_step "~/.zshrc permission fix" "chmod 600 \"$HOME/.zshrc\""; then
      installed "~/.zshrc permission fix" "now mode $(stat -f '%OLp' "$HOME/.zshrc" 2>/dev/null) — restart Terminal"
    fi
  else
    ok_cfg "~/.zshrc permissions" "mode $zshrc_mode (not 600, but not writable by others — the guide's chmod 600 is only needed if your shell complains)"
  fi
else
  warn "~/.zshrc" "file does not exist"
fi

# ---------------------------------------------------------------------------
# Step 3 — git, SSH, source control
# ---------------------------------------------------------------------------

hdr "Step 3 — Configure git, SSH, and source control access"

# 3.2 git-config-tool
checking "git-config-tool"
gct=""
if have git-config-tool; then
  gct="$(command -v git-config-tool)"
elif [ -x "$HOME/.local/bin/git-config-tool" ]; then
  gct="$HOME/.local/bin/git-config-tool"
  info "found at $gct but not on PATH — add ~/.local/bin to PATH in ~/.zshrc"
fi

if [ -n "$gct" ]; then
  ok "git-config-tool" "$gct"
else
  info "Installer requires AppGate connectivity (binaries.ddbuild.io)."
  if install_step "git-config-tool" "curl -fsSL https://binaries.ddbuild.io/devtools/apps/git-config-tool/install.sh | sh"; then
    if have git-config-tool; then gct="$(command -v git-config-tool)"
    elif [ -x "$HOME/.local/bin/git-config-tool" ]; then gct="$HOME/.local/bin/git-config-tool"; fi
    if [ -n "$gct" ]; then
      installed "git-config-tool" "$gct"
    else
      failed "git-config-tool" "installer ran but the binary was not found"
    fi
  fi
fi

# 3.3 / 3.4 setup is interactive; doctor is a read-only validation
if [ -n "$gct" ]; then
  if [ "$NO_NETWORK" -eq 1 ]; then
    skipped "git-config-tool doctor" "--no-network"
  else
    checking "git-config-tool doctor"
    gct_out="$(run_timeout 60 "$gct" doctor 2>&1)"
    gct_rc=$?
    printf '%s\n' "$gct_out" >> "$LOG_FILE"
    if [ $gct_rc -eq 0 ]; then
      ok_cfg "git-config-tool doctor" "all checks passing"
    else
      warn "git-config-tool doctor" "exit $gct_rc — SSH keys / signing not fully configured"
      info "Fix interactively (this script will not run it for you): $gct setup"
      printf '%s\n' "$gct_out" | tail -20 | while IFS= read -r line; do info "$line"; done
    fi
  fi
else
  manual "git-config-tool setup" "install git-config-tool first, then run: git-config-tool setup"
fi

# SSH keys on disk
checking "SSH keys (~/.ssh)"
ssh_keys="$(ls -1 "$HOME"/.ssh/id_* 2>/dev/null | grep -v '\.pub$' | tr '\n' ' ')"
if [ -n "$ssh_keys" ]; then
  ok_cfg "SSH keys" "found: $ssh_keys"
else
  manual "SSH keys" "none in ~/.ssh — created by: git-config-tool setup"
fi

# GitHub SSH authentication
if [ "$NO_NETWORK" -eq 1 ]; then
  skipped "GitHub SSH auth" "--no-network"
else
  checking "GitHub SSH auth (ssh -T git@github.com)"
  gh_ssh="$(run_timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)"
  printf '%s\n' "$gh_ssh" >> "$LOG_FILE"
  if printf '%s' "$gh_ssh" | grep -q 'successfully authenticated'; then
    ssh_login="$(printf '%s' "$gh_ssh" | sed -n 's/^Hi \([^!]*\)!.*/\1/p' | head -1)"
    ok_cfg "GitHub SSH auth" "authenticated as '${ssh_login:-unknown}'"
  else
    warn "GitHub SSH auth" "not authenticated — $(printf '%s' "$gh_ssh" | head -1)"
    info "Accept the DataDog org invite and run: git-config-tool setup"
  fi
fi

# git over SSH and the gh CLI must be the same GitHub account, or org access
# will look broken in one of them while working in the other.
if [ -n "$ssh_login" ] && [ -n "$gh_login" ]; then
  checking "GitHub identity consistency (ssh vs gh CLI)"
  if [ "$ssh_login" = "$gh_login" ]; then
    ok_cfg "GitHub identity consistency" "both are '$gh_login'"
  else
    warn "GitHub identity consistency" "ssh authenticates as '$ssh_login' but gh CLI is logged in as '$gh_login' — org and team checks above reflect '$gh_login'"
    info "Point gh at the work account: gh auth login  (or: gh auth switch)"
  fi
fi

# 3.5 ddtool (also used in Step 4)
checking "ddtool"
if have ddtool; then
  ok "ddtool" "$(run_timeout 15 ddtool version 2>/dev/null | head -1 || echo 'version unknown')"
  if have brew; then
    info "Guide recommends keeping it current: brew update && brew upgrade ddtool"
  fi
else
  if have brew; then
    if install_step "ddtool" "brew update && brew install ddtool"; then
      if have ddtool; then
        installed "ddtool" "$(run_timeout 15 ddtool version 2>/dev/null | head -1)"
      else
        failed "ddtool" "brew install ran but ddtool is not on PATH — it may require the internal Datadog tap (run laptop-setup.sh first)"
      fi
    fi
  else
    failed "ddtool" "missing and Homebrew is unavailable"
  fi
fi

# 3.5 / 1.5 GitLab: token-based auth plus access to the DataDog group.
if [ "$NO_NETWORK" -eq 1 ]; then
  skipped "GitLab authentication" "--no-network"
  skipped "GitLab $GITLAB_GROUP group access" "--no-network"
else
  checking "GitLab token (ddtool auth gitlab token / \$GITLAB_TOKEN)"
  gl_token=""
  gl_token_source=""
  gl_auth_header=""
  if have ddtool; then
    # Exits 0 with empty output and an explanatory stderr line when not logged in,
    # so this never opens a browser or blocks on a prompt.
    gl_token="$(run_timeout 25 ddtool auth gitlab token </dev/null 2>>"$LOG_FILE" | tr -d '[:space:]')"
    [ -n "$gl_token" ] && gl_token_source="ddtool" && gl_auth_header="Authorization: Bearer $gl_token"
  fi
  if [ -z "$gl_token" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
    gl_token="$GITLAB_TOKEN"
    gl_token_source="\$GITLAB_TOKEN"
    gl_auth_header="PRIVATE-TOKEN: $gl_token"
  fi

  if [ -z "$gl_token" ]; then
    warn "GitLab authentication" "no token available — run: ddtool auth gitlab login && ddtool auth gitlab token"
    skipped "GitLab $GITLAB_GROUP group access" "no GitLab token to test with"
  else
    gl_user="$(run_timeout 25 curl -s --max-time 20 --header "$gl_auth_header" "https://${GITLAB_HOST}/api/v4/user" 2>/dev/null)"
    printf 'gitlab /api/v4/user: %s\n' "$gl_user" >> "$LOG_FILE"
    gl_username="$(printf '%s' "$gl_user" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$gl_username" ]; then
      ok_cfg "GitLab authentication" "authenticated as '$gl_username' (token from $gl_token_source)"
    else
      warn "GitLab authentication" "token from $gl_token_source did not authenticate — run: ddtool auth gitlab login"
    fi

    checking "GitLab $GITLAB_GROUP group access (/api/v4/groups/$GITLAB_GROUP)"
    gl_grp_code="$(run_timeout 25 curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
      --header "$gl_auth_header" "https://${GITLAB_HOST}/api/v4/groups/${GITLAB_GROUP}" 2>/dev/null)"
    case "${gl_grp_code:-000}" in
      200)
        ok_cfg "GitLab $GITLAB_GROUP group access" "HTTP 200 — group is visible to you"
        ;;
      403|404)
        warn "GitLab $GITLAB_GROUP group access" "HTTP $gl_grp_code — no access yet; open https://${GITLAB_HOST}/${GITLAB_GROUP} and use the page menu to Request Access"
        ;;
      401)
        warn "GitLab $GITLAB_GROUP group access" "HTTP 401 — token rejected; run: ddtool auth gitlab login"
        ;;
      *)
        warn "GitLab $GITLAB_GROUP group access" "unexpected response (HTTP ${gl_grp_code:-none}) — check AppGate and re-run"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 — Datadog internal access
# ---------------------------------------------------------------------------

hdr "Step 4 — Verify Datadog internal access"

# 4.2 Vault CLI
checking "Vault CLI (vault --version)"
if have vault; then
  ok "Vault CLI" "$(vault --version 2>/dev/null | head -1)"
else
  if have brew; then
    if install_step "Vault CLI" "brew install vault || { brew tap hashicorp/tap && brew install hashicorp/tap/vault; }"; then
      if have vault; then
        installed "Vault CLI" "$(vault --version 2>/dev/null | head -1)"
      else
        failed "Vault CLI" "brew install ran but vault is not on PATH"
      fi
    fi
  else
    failed "Vault CLI" "missing and Homebrew is unavailable"
  fi
fi

# Vault token state — read-only, never triggers a login
if have vault; then
  if [ "$NO_NETWORK" -eq 1 ]; then
    skipped "Vault token" "--no-network"
  else
    checking "Vault token (vault token lookup)"
    export VAULT_ADDR="${VAULT_ADDR:-https://vault.us1.ddbuild.io}"
    info "VAULT_ADDR=$VAULT_ADDR"
    vt_out="$(run_timeout 25 vault token lookup 2>&1)"
    vt_rc=$?
    printf '%s\n' "$vt_out" >> "$LOG_FILE"
    if [ $vt_rc -eq 0 ]; then
      ok_cfg "Vault token" "valid token present"
    elif printf '%s' "$vt_out" | grep -q 'removed GODEBUG'; then
      # Older vault binaries set GODEBUG=x509sha1=1 for themselves. That value is
      # inherited by the token helper, and Go toolchains that removed the setting
      # abort at startup. The fix is upgrading vault, not changing your shell.
      warn "Vault token" "vault's token helper aborts on an inherited GODEBUG setting that current Go removed — not an actual missing token"
      info "This vault build: $(vault --version 2>/dev/null | head -1)"
      info "Fix: brew upgrade vault   (or use 'ddtool auth login --datacenter us1.ddbuild.io', which does not go through the vault binary)"
    else
      warn "Vault token" "no valid token — $(printf '%s' "$vt_out" | head -1)"
      info "Log in with: ddtool auth login --datacenter us1.ddbuild.io  (or: vault login -method=oidc)"
    fi
  fi
fi

manual "ddtool auth login" "interactive SSO not run by this script — run: ddtool auth login --datacenter us1.ddbuild.io"

# ---------------------------------------------------------------------------
# Step 5 — Optional but recommended tools
# ---------------------------------------------------------------------------

hdr "Step 5 — Optional but recommended tools"

# 5.1 Doggo Chrome extension
checking "Doggo Chrome extension (id ${DOGGO_EXT_ID})"
doggo_found=0
for prof in "$HOME/Library/Application Support/Google/Chrome"/*/Extensions; do
  [ -d "$prof/$DOGGO_EXT_ID" ] && doggo_found=1 && break
done
if [ "$doggo_found" -eq 1 ]; then
  ok "Doggo Chrome extension" "installed in a Chrome profile"
else
  manual "Doggo Chrome extension" "install from https://chromewebstore.google.com/detail/doggo-datadog-companion/${DOGGO_EXT_ID} (if 'dd' is taken, rename the other shortcut in chrome://settings/searchEngines)"
fi

# 5.2 Claude Code CLI
checking "Claude Code (claude --version)"
if have claude; then
  ok "Claude Code" "$(run_timeout 20 claude --version 2>/dev/null | head -1)"
elif [ -x "$HOME/.local/bin/claude" ]; then
  ok "Claude Code" "$HOME/.local/bin/claude (not on PATH — add ~/.local/bin to PATH in ~/.zshrc)"
else
  info "Prereqs per the guide: ddtool, AppGate, Node.js and Vault access working first."
  info "Access request: https://app.datadoghq.com/app-builder/apps/b2f6473e-2298-453e-8571-f83ecc9939cf"
  if install_step "Claude Code" "curl -fsSL https://claude.ai/install.sh | bash"; then
    if have claude || [ -x "$HOME/.local/bin/claude" ]; then
      installed "Claude Code" "run 'claude' and choose 'Anthropic Console account' at the login prompt"
    else
      failed "Claude Code" "installer ran but 'claude' was not found — see https://code.claude.com/docs/en/quickstart"
    fi
  fi
fi

# 5.3 Claude Desktop
check_app "Claude Desktop" "/Applications/Claude.app" \
  "install from Self Service (search 'Claude'), sign in with your Datadog work email; if SSO fails in Safari, make Chrome the default browser for the first login"

# ---------------------------------------------------------------------------
# Engineering track extras — not in the laptop guide's numbered steps, but
# required before the backend, Agent, and Terraform provider tracks will build.
# ---------------------------------------------------------------------------

hdr "Engineering track extras — Go toolchain and dda"

# Go toolchain
checking "Go toolchain (go version)"
if have go; then
  ok "Go toolchain" "$(go version 2>/dev/null)"
else
  if have brew; then
    if install_step "Go toolchain" "brew install go"; then
      have go && installed "Go toolchain" "$(go version 2>/dev/null)" \
              || failed "Go toolchain" "brew install ran but go is not on PATH"
    fi
  else
    failed "Go toolchain" "missing and Homebrew is unavailable"
  fi
fi

if have go; then
  checking "GOPATH / GOBIN"
  go_path="$(go env GOPATH 2>/dev/null)"
  go_bin="$(go env GOBIN 2>/dev/null)"
  [ -z "$go_bin" ] && go_bin="${go_path:+$go_path/bin}"
  info "GOPATH=${go_path:-<unset>}  GOBIN=${go_bin:-<unset>}"

  if [ -z "$go_path" ]; then
    warn "GOPATH" "go env GOPATH is empty"
  elif [ -d "$go_path" ]; then
    ok_cfg "GOPATH" "$go_path exists"
  else
    warn "GOPATH" "$go_path does not exist yet"
    if install_step "GOPATH directory" "mkdir -p \"$go_path/bin\" \"$go_path/src\" \"$go_path/pkg\""; then
      installed "GOPATH directory" "created $go_path"
    fi
  fi

  checking "\$GOPATH/bin on PATH"
  if [ -n "$go_bin" ]; then
    case ":$PATH:" in
      *":$go_bin:"*) ok_cfg "GOPATH bin on PATH" "$go_bin" ;;
      *)
        warn "GOPATH bin on PATH" "$go_bin is not on PATH — go-installed tools will not be found"
        info "Add to ~/.zshrc: export PATH=\"\$PATH:$go_bin\""
        ;;
    esac
  fi

  # A stale GODEBUG pinned to a setting newer Go toolchains removed will make
  # Go binaries abort at startup — this is what breaks `vault token lookup`.
  checking "GODEBUG for removed settings"
  if [ -n "${GODEBUG:-}" ]; then
    info "GODEBUG=$GODEBUG"
    if printf '%s' "$GODEBUG" | grep -q 'x509sha1'; then
      warn "GODEBUG" "contains x509sha1, which current Go toolchains removed — Go binaries will abort with 'fatal error: removed GODEBUG'. Unset it in your shell rc."
    else
      ok_cfg "GODEBUG" "set, no removed settings detected"
    fi
  else
    ok_cfg "GODEBUG" "not set in this shell"
  fi
fi

# dda CLI — install instructions are read live from the docs, not hardcoded.
checking "dda CLI (dda --version)"
if have dda; then
  ok "dda CLI" "$(run_timeout 25 dda --version 2>/dev/null | head -1 || echo 'version unknown')"
else
  if [ "$NO_NETWORK" -eq 1 ]; then
    skipped "dda CLI" "--no-network, cannot read the live install command"
  else
    info "Reading the current install command from $DDA_DOCS_URL"
    dda_page="$(run_timeout 35 curl -fsSL --max-time 30 "$DDA_DOCS_URL" 2>/dev/null \
      | sed -e 's/<[^>]*>/ /g' -e 's/&quot;/"/g' -e 's/&amp;/\&/g' \
            -e 's/&lt;/</g' -e 's/&gt;/>/g' -e "s/&#39;/'/g")"
    if [ -z "$dda_page" ]; then
      manual "dda CLI" "could not read $DDA_DOCS_URL (AppGate or network) — follow the install page manually"
    else
      # Generic patterns: the package name and URLs come from the page itself.
      dda_cmd="$(printf '%s' "$dda_page" | grep -oE 'brew install --cask [A-Za-z0-9@._+-]+' | head -1)"
      if [ -n "$dda_cmd" ]; then
        info "found on the docs page: $dda_cmd"
        if install_step "dda CLI" "$dda_cmd"; then
          have dda && installed "dda CLI" "$(run_timeout 25 dda --version 2>/dev/null | head -1)" \
                   || failed "dda CLI" "'$dda_cmd' ran but dda is not on PATH"
        fi
      else
        dda_pkg_url="$(printf '%s' "$dda_page" | grep -oE 'https://github.com/[^ ]+/dda-universal\.pkg' | head -1)"
        if [ -n "$dda_pkg_url" ]; then
          manual "dda CLI" "docs show no Homebrew cask; the .pkg path needs sudo — run manually: curl -Lo dda-universal.pkg $dda_pkg_url && sudo installer -pkg ./dda-universal.pkg -target /"
        else
          manual "dda CLI" "no install command recognised on $DDA_DOCS_URL — open the page and follow it manually"
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Quick validation checklist (from the guide)
# ---------------------------------------------------------------------------

hdr "Quick validation checklist"

checklist() { # checklist <0|1> <text>
  if [ "$1" -eq 0 ]; then
    emit "  ${C_GREEN}[x]${C_RESET} $2"
  else
    emit "  ${C_YELLOW}[ ]${C_RESET} $2"
  fi
}

have git  && checklist 0 "git works in Terminal"              || checklist 1 "git works in Terminal"
have brew && checklist 0 "brew works in Terminal"             || checklist 1 "brew works in Terminal"
have node && checklist 0 "node works in Terminal"             || checklist 1 "node works in Terminal"
have go   && checklist 0 "go works in Terminal"               || checklist 1 "go works in Terminal"
[ -d "/Applications/AppGate SDP.app" ] && checklist 0 "AppGate SDP installed" || checklist 1 "AppGate SDP installed"
[ -n "${utun_list:-}" ] && checklist 0 "AppGate tunnel is up (utun interface present)" || checklist 1 "AppGate tunnel is up (utun interface present)"
[ -n "${gct:-}" ] && checklist 0 "git-config-tool installed"  || checklist 1 "git-config-tool installed"
[ -n "${gh_login:-}" ] && checklist 0 "gh CLI authenticated"  || checklist 1 "gh CLI authenticated"
[ -z "${orgs_missing:-}" ] && [ -n "${gh_login:-}" ] && checklist 0 "GitHub org membership: $GITHUB_ORGS" || checklist 1 "GitHub org membership: $GITHUB_ORGS"
[ -z "${teams_missing:-}" ] && [ -n "${gh_login:-}" ] && checklist 0 "GitHub '$GITHUB_TEAM_SLUG' team in both orgs" || checklist 1 "GitHub '$GITHUB_TEAM_SLUG' team in both orgs"
have ddtool && checklist 0 "ddtool installed"                 || checklist 1 "ddtool installed"
have vault  && checklist 0 "vault CLI installed"              || checklist 1 "vault CLI installed"
have dda    && checklist 0 "dda CLI installed"                || checklist 1 "dda CLI installed"
( have claude || [ -x "$HOME/.local/bin/claude" ] ) && checklist 0 "claude --version works" || checklist 1 "claude --version works"
emit "  ${C_DIM}Not machine-checkable: Gmail/Slack sign-in and Datadog app invites.${C_RESET}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

hdr "Summary"

for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
  status="${row%%|*}"; rest="${row#*|}"
  item="${rest%%|*}"; detail="${rest#*|}"
  # Collapse real and escaped newlines, then cap the row so stack traces
  # (which are already in the per-step output and the log) stay readable here.
  detail="$(printf '%s' "$detail" | tr '\n' ' ' | sed -e 's/\\n/ /g' -e 's/  */ /g')"
  if [ "${#detail}" -gt 110 ]; then
    detail="${detail:0:107}..."
  fi
  case "$status" in
    OK)        color="$C_GREEN" ;;
    INSTALLED) color="$C_CYAN" ;;
    FAILED)    color="$C_RED" ;;
    MANUAL)    color="$C_MAGENTA" ;;
    *)         color="$C_YELLOW" ;;
  esac
  emit "$(printf '  %s%-11s%s %-32s %s' "$color" "[$status]" "$C_RESET" "$item" "${C_DIM}${detail}${C_RESET}")"
done

emit ""
emit "  ${C_GREEN}OK: ${N_OK}${C_RESET}  ${C_CYAN}installed: ${N_INSTALLED}${C_RESET}  ${C_YELLOW}warn: ${N_WARN}${C_RESET}  ${C_YELLOW}skipped: ${N_SKIPPED}${C_RESET}  ${C_MAGENTA}manual: ${N_MANUAL}${C_RESET}  ${C_RED}failed: ${N_FAILED}${C_RESET}"
emit ""
emit "  ${C_DIM}Full log: ${LOG_FILE}${C_RESET}"
emit "  ${C_DIM}Blocked? Ask in #onboarding-help: https://dd.enterprise.slack.com/archives/CP357324T${C_RESET}"

if [ $((N_FAILED + N_MANUAL + N_WARN)) -gt 0 ]; then
  exit 1
fi
exit 0
