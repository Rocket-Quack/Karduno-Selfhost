#!/usr/bin/env bash
# Karduno Self-Hosted: configure, check domain routing, and start on Unix hosts.
set -Eeuo pipefail
[[ ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Error: Bash 4 or newer is required.\n' >&2; exit 1; }
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
non_interactive=false
skip_dependencies=false
prepare_only=false
for arg in "$@"; do
    case "$arg" in
        --prepare-only) prepare_only=true ;;
        --non-interactive) non_interactive=true ;;
        --skip-dependencies) skip_dependencies=true ;;
        --help|-h)
            printf '%s\n' 'Karduno Self-Hosted' \
                '  bash easy-install.sh                    Configure, check domains, pull images, and start' \
                '  bash easy-install.sh --prepare-only     Prepare configuration without starting' \
                '  bash easy-install.sh --non-interactive  Use an existing .env without prompts' \
                '  bash easy-install.sh --skip-dependencies  Do not install missing packages' \
                'Missing Docker dependencies can be installed on Ubuntu, Debian, and Fedora.' \
                'Default setup checks TCP 80/443 through all three domains, then verifies HTTPS.'
            exit 0 ;;
        *) fail "Unknown option: $arg (see --help)" ;;
    esac
done

[[ -r .env.example && -r docker-compose.yml && -r scripts/start-app.sh && -r scripts/check-deployment.py ]] || fail 'Installation files are missing. Download the complete repository.'

as_root() {
    if [[ $EUID -eq 0 ]]; then "$@"
    elif command -v sudo >/dev/null; then sudo "$@"
    else fail 'Installing dependencies requires root or sudo. Install Docker manually or rerun with suitable permissions.'
    fi
}
install_dependencies() {
    [[ "$skip_dependencies" == false ]] || fail 'Docker with Compose v2 is required. Dependency installation was disabled.'
    [[ -r /etc/os-release ]] || fail 'Install Docker and Compose manually on this operating system, then rerun.'
    # This system-owned file identifies the distribution and repository codename.
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian)
            if command -v docker >/dev/null; then
                printf 'Installing the missing Compose plugin; keeping the existing Docker engine.\n'
                as_root apt-get update
                if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
                    as_root apt-get install -y docker-compose-plugin
                else
                    as_root apt-get install -y docker-compose-v2
                fi
            else
                printf 'Installing Docker Engine and Compose from the official Docker repository.\n'
                as_root apt-get update
                as_root apt-get install -y ca-certificates curl
                as_root install -m 0755 -d /etc/apt/keyrings
                curl -fsSL "https://download.docker.com/linux/$ID/gpg" | as_root tee /etc/apt/keyrings/docker.asc >/dev/null
                as_root chmod a+r /etc/apt/keyrings/docker.asc
                printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
                    "$ID" "${UBUNTU_CODENAME:-${VERSION_CODENAME:?Missing distribution codename}}" "$(dpkg --print-architecture)" \
                    | as_root tee /etc/apt/sources.list.d/docker.sources >/dev/null
                as_root apt-get update
                as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            fi ;;
        fedora)
            if command -v docker >/dev/null; then
                printf 'Installing Compose; keeping the existing Docker engine.\n'
                if ! as_root dnf install -y docker-compose-plugin; then
                    as_root dnf install -y docker-compose
                fi
            else
                printf 'Installing Docker Engine and Compose from the official Docker repository.\n'
                as_root dnf install -y ca-certificates curl
                curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo \
                    | as_root tee /etc/yum.repos.d/docker-ce.repo >/dev/null
                as_root dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            fi ;;
        *) fail 'Automatic dependency installation supports Ubuntu, Debian, and Fedora. Install Docker with Compose v2 manually on this system.' ;;
    esac
}
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    install_dependencies
fi
docker compose version >/dev/null || fail 'Docker Compose is still unavailable. Check package installation and reopen your terminal if needed.'

# Keep daemon permissions local to this invocation; never modify user groups.
docker_binary=$(command -v docker)
docker_command=("$docker_binary")
docker() { "${docker_command[@]}" "$@"; }
if [[ "$prepare_only" == false ]] && ! docker info >/dev/null 2>&1; then
    if command -v sudo >/dev/null && sudo "$docker_binary" info >/dev/null 2>&1; then
        docker_command=(sudo "$docker_binary")
    else
        command -v systemctl >/dev/null || fail 'Docker is not running. Start Docker and rerun the installer.'
        as_root systemctl start docker
        if ! docker info >/dev/null 2>&1; then
            if command -v sudo >/dev/null && sudo "$docker_binary" info >/dev/null 2>&1; then
                docker_command=(sudo "$docker_binary")
            else fail 'Docker is still unavailable. Check the service and your Docker permissions.'
            fi
        fi
    fi
fi

mkdir .easy-install.lock 2>/dev/null || fail 'Another installer is running. After an interrupted run, remove the empty .easy-install.lock directory if needed.'
env_tmp=''
secret_tmp=''
cleanup() {
    [[ -z "$env_tmp" ]] || rm -f -- "$env_tmp"
    [[ -z "$secret_tmp" ]] || rm -f -- "$secret_tmp"
    rmdir .easy-install.lock 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ask() {
    local label=$1 default=${2:-} value
    if [[ -n "$default" ]]; then label+=" [$default]"; fi
    read -r -p "$label: " value || fail 'Input was interrupted.'
    REPLY=${value:-$default}
}
valid_domain() {
    local domain=$1 label
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *. ]] || return 1
    [[ "$domain" != *[!a-zA-Z0-9.-]* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
}
valid_email() { [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
ask_domain() {
    while true; do
        ask "$1"
        valid_domain "$REPLY" && return
        printf 'Enter a full DNS name without https://, a port, or a path.\n'
    done
}
ask_email() {
    while true; do
        ask "$1" "${2:-}"
        valid_email "$REPLY" && return
        printf 'Enter a valid email address.\n'
    done
}
# Quote Compose dotenv values without ever executing user input as shell code.
write_env() {
    local value=$2
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//\$/\$\$}
    local next
    next=$(mktemp .env.tmp.XXXXXX)
    KARDUNO_ENV_LINE="$1=\"$value\"" awk -v key="$1" '
        BEGIN { found = 0 }
        $0 ~ "^" key "=" { print ENVIRON["KARDUNO_ENV_LINE"]; found = 1; next }
        { print }
        END { if (!found) print ENVIRON["KARDUNO_ENV_LINE"] }
    ' "$env_tmp" > "$next"
    mv -- "$next" "$env_tmp"
}

printf '\nKarduno Self-Hosted - Easy Install\n\n'
new_config=false
if [[ ! -e .env ]]; then
    [[ "$non_interactive" == false && -t 0 ]] || fail 'No .env found. Run interactively first, or copy .env.example to .env and fill it in.'
    printf 'All three domains must point to this server. TCP ports 80 and 443 must be available.\n\n'
    ask_domain 'Customer portal domain'; portal=$REPLY
    while true; do
        ask_domain 'Administration domain'; admin=$REPLY
        [[ "${portal,,}" != "${admin,,}" ]] && break
        printf 'Portal and administration require different domains.\n'
    done
    while true; do
        ask_domain 'API domain (app and POS systems)'; api=$REPLY
        [[ "${api,,}" != "${portal,,}" && "${api,,}" != "${admin,,}" ]] && break
        printf 'The API domain must differ from the portal and administration domains.\n'
    done
    ask_email 'Initial administrator email'; admin_email=$REPLY
    while true; do
        read -r -s -p 'Administrator password (at least 12 characters): ' admin_password || fail 'Input was interrupted.'
        printf '\n'
        [[ ${#admin_password} -ge 12 ]] || { printf 'The password is too short.\n'; continue; }
        read -r -s -p 'Confirm password: ' confirmation || fail 'Input was interrupted.'
        printf '\n'
        [[ "$admin_password" == "$confirmation" ]] && break
        printf 'The passwords do not match.\n'
    done
    ask_email 'Contact email for HTTPS certificates' "$admin_email"; acme_email=$REPLY
    env_tmp=$(mktemp .env.tmp.XXXXXX)
    # Copy the template, retaining its comments and any additional settings.
    tr -d '\r' < .env.example > "$env_tmp"
    write_env PORTAL_DOMAIN "$portal"
    write_env ADMIN_DOMAIN "$admin"
    write_env API_DOMAIN "$api"
    write_env ACME_EMAIL "$acme_email"
    write_env INITIAL_ADMIN_EMAIL "$admin_email"
    write_env INITIAL_ADMIN_PASSWORD "$admin_password"
    mv -- "$env_tmp" .env
    env_tmp=''
    new_config=true
    unset admin_password confirmation
    printf '\n.env has been created.\n'
else
    [[ -f .env && ! -L .env ]] || fail '.env must be a regular file.'
    printf 'Keeping the existing .env.\n'
fi
chmod 600 .env

if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(POSTGRES_PASSWORD|JWT_SECRET)[[:space:]]*=' .env; then
    fail 'Legacy secrets found in .env. Preserve the existing values in secrets/postgres_password and secrets/jwt_secret first, then remove the old variables from .env.'
fi

docker compose config --quiet || fail 'The .env is incomplete or invalid.'
resolved_environment=$(docker compose config --environment) || fail 'Could not read the Compose settings.'
portal='' admin='' api='' admin_email='' admin_password='' project=''
while IFS='=' read -r key value; do
    case "$key" in
        PORTAL_DOMAIN) portal=$value ;;
        ADMIN_DOMAIN) admin=$value ;;
        API_DOMAIN) api=$value ;;
        ACME_EMAIL) acme_email=$value ;;
        INITIAL_ADMIN_EMAIL) admin_email=$value ;;
        INITIAL_ADMIN_PASSWORD) admin_password=$value ;;
        COMPOSE_PROJECT_NAME) project=$value ;;
    esac
done <<< "$resolved_environment"
unset resolved_environment
valid_domain "$portal" && valid_domain "$admin" && valid_domain "$api" || fail 'PORTAL_DOMAIN, ADMIN_DOMAIN, and API_DOMAIN must be full DNS names without a protocol, port, or path.'
[[ "${portal,,}" != "${admin,,}" ]] || fail 'Portal and administration require different domains.'
[[ "${api,,}" != "${portal,,}" && "${api,,}" != "${admin,,}" ]] || fail 'The API domain must differ from the portal and administration domains.'
[[ "$portal" != *.example.com && "$admin" != *.example.com && "$api" != *.example.com ]] || fail 'Replace the example.com placeholders with your own domains.'
valid_email "${acme_email:-}" || fail 'ACME_EMAIL is not a valid email address.'
[[ -n "$project" ]] || fail 'Could not determine the Compose project name.'
existing_database=''
if docker info >/dev/null 2>&1; then
    existing_database=$(docker volume ls --filter "label=com.docker.compose.project=$project" \
        --filter 'label=com.docker.compose.volume=postgres_data' --format '{{.Name}}') || fail 'Could not check existing database volumes.'
elif [[ "$new_config" == false && ( ! -s secrets/postgres_password || ! -s secrets/jwt_secret ) ]]; then
    fail 'Docker is unavailable and an existing .env has missing secrets. Start Docker to check for an existing database before generating anything.'
else
    printf 'Docker is not running or is not accessible. Preparing files only; start Docker before running the application.\n'
fi
if [[ -z "$existing_database" ]]; then
    valid_email "$admin_email" && [[ ${#admin_password} -ge 12 ]] || fail 'Before the first start, set INITIAL_ADMIN_EMAIL and an administrator password with at least 12 characters.'
fi
unset admin_password

[[ ! -L secrets ]] || fail 'secrets/ must not be a symbolic link.'
if [[ -n "$existing_database" && ( ! -s secrets/postgres_password || ! -s secrets/jwt_secret ) ]]; then
    fail 'An existing database was found but secret files are missing. Restore the original values from your backup; new secrets will not be generated.'
fi
mkdir -p secrets
chmod 700 secrets
for secret in postgres_password jwt_secret; do
    path="secrets/$secret"
    [[ ! -L "$path" ]] || fail "$path must not be a symbolic link."
    if [[ -e "$path" ]]; then
        [[ -f "$path" && -s "$path" ]] || fail "$path is not a valid secret file. Restore the original value."
        [[ "$secret" != jwt_secret || $(wc -c < "$path") -ge 32 ]] || fail 'The JWT secret must contain at least 32 characters.'
        printf 'Keeping %s unchanged.\n' "$path"
    else
        secret_tmp=$(mktemp "secrets/.$secret.XXXXXX")
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$secret_tmp"
        [[ $(wc -c < "$secret_tmp") -eq 64 ]] || fail 'Could not generate a random secret.'
        mv -- "$secret_tmp" "$path"
        secret_tmp=''
        printf 'Created %s.\n' "$path"
    fi
    chmod 600 "$path"
done
if command -v getenforce >/dev/null && [[ $(getenforce) != Disabled ]]; then
    # Compose file secrets have no :z option; label only this dedicated directory.
    command -v chcon >/dev/null || fail 'SELinux is enabled but chcon is missing. Install coreutils and rerun.'
    as_root chcon -R -t container_file_t -- "$PWD/secrets"
fi
printf '\nEmail delivery is configured in the administration interface.\n'
printf '\nInclude .env and secrets/ in your encrypted backup.\n'
if [[ "$prepare_only" == true ]]; then
    printf '\nConfiguration is ready. No application containers have been started.\n'
    printf 'To check domains and start, rerun without --prepare-only.\n'
    exit 0
fi
running_services=$(docker compose ps --status running --services) || fail 'Could not inspect the existing installation.'
printf '\nPreparing domain checks (downloads the API image if needed)...\n'
if [[ $'\n'"$running_services"$'\n' == *$'\ncaddy\n'* ]]; then
    printf 'Checking the existing installation through all three domains...\n'
    docker compose run --rm --no-deps -T setup-check /venv/bin/python /run/karduno/check-deployment.py verify --timeout 0 --existing \
        || fail 'The existing domain routes failed verification. Existing services were left running.'
else
    printf 'Checking DNS and routing to this host on TCP ports 80 and 443...\n'
    docker compose run --rm --no-deps -T --service-ports setup-check \
        || fail 'Domain/port checks failed. Check DNS, TCP 80/443, firewall rules, and conflicting web servers before retrying.'
fi
printf '\nDownloading application and infrastructure images...\n'
docker compose pull postgres redis api worker admin portal caddy || fail 'Image download failed. Check registry availability, network access, and supported architecture. Nothing has been stopped.'
if [[ $'\n'"$running_services"$'\n' == *$'\nworker\n'* ]]; then
    docker compose stop worker || fail 'Could not pause the existing worker before database migrations.'
fi
docker compose up -d --wait --wait-timeout 300 postgres redis api worker admin portal caddy \
    || fail 'Startup failed. Check docker compose ps and docker compose logs --tail 100. Existing data and secrets are preserved.'
docker compose run --rm --no-deps -T setup-check /venv/bin/python /run/karduno/check-deployment.py verify \
    || fail 'Containers started, but public-domain HTTPS/readiness checks failed. Check Caddy logs, DNS, and firewall settings. The stack was left running for diagnosis.'
printf '\nKarduno is running and domain checks passed from this server.\n'
printf 'Portal: https://%s\nAdministration: https://%s\nAPI: https://%s/api/v1\n' "$portal" "$admin" "$api"
printf 'Also test browser sign-in and email delivery, and check access from another network.\n'
