#!/usr/bin/env bash
# Funciones de utilidad compartidas por todos los scripts

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
log_fatal()   { log_error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || log_fatal "Este script debe ejecutarse como root."
}

confirm() {
    local prompt="${1:-¿Continuar?} [s/N] "
    read -rp "$prompt" answer
    [[ "${answer,,}" == "s" ]]
}

dry_run_guard() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warn "[DRY-RUN] Se ejecutaría: $*"
        return 0
    fi
    "$@"
}

check_command() {
    command -v "$1" &>/dev/null || log_fatal "Comando requerido no encontrado: $1"
}

is_debian_based() {
    [[ -f /etc/debian_version ]]
}

debian_version() {
    grep -oP '\d+' /etc/debian_version | head -1
}
