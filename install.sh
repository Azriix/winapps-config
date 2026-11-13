#!/usr/bin/env bash
# Déploie ce dépôt dans ~/.config/winapps. Relançable : .env est conservé.
# --update : met aussi à jour FreeRDP (apt, sudo) et WinApps (git pull).

set -euo pipefail

update=0
case "${1:-}" in
    "") ;;
    --update) update=1 ;;
    *) echo "Usage : $0 [--update]" >&2; exit 2 ;;
esac

REPO=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
readonly REPO
readonly DIR="${HOME}/.config/winapps"
readonly WINAPPS_SRC="${HOME}/.local/bin/winapps-src"
readonly WINAPPS_REPO="https://github.com/winapps-org/winapps.git"
readonly PACKAGES=(
    curl dialog freerdp3-sdl git iproute2 libnotify-bin netcat-openbsd
    gcc libc6-dev
    python3-gi gir1.2-gtk-4.0 gir1.2-gdkpixbuf-2.0
)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mAttention :\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mErreur :\033[0m %s\n' "$*" >&2; exit 1; }

# --- Prérequis ---
info "Vérification des paquets"
missing=()
for package in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' ||
        missing+=("$package")
done
if ((${#missing[@]})); then
    die "paquets manquants : sudo apt install -y ${missing[*]}"
fi

if ((update)); then
    info "Mise à jour de FreeRDP"
    sudo apt-get update
    sudo apt-get install -y --only-upgrade freerdp3-sdl
fi

info "Vérification de Docker et de KVM"
command -v docker &>/dev/null ||
    die "Docker absent (README, étape 1)."
docker compose version &>/dev/null ||
    die "greffon « docker compose » absent (paquet docker-compose-plugin)."
docker info &>/dev/null ||
    die "Docker injoignable : sudo usermod -aG docker \"\$USER\", puis rouvrez la session."
[[ -r /dev/kvm && -w /dev/kvm ]] ||
    die "/dev/kvm inaccessible : activez la virtualisation, sudo usermod -aG kvm \"\$USER\", puis rouvrez la session."

# --- WinApps (compose.yaml monte son dossier oem/) ---
if [[ -d "$WINAPPS_SRC/.git" ]]; then
    if ((update)); then
        info "Mise à jour de WinApps"
        git -C "$WINAPPS_SRC" pull --ff-only --recurse-submodules ||
            warn "WinApps non mis à jour (modifications locales ou version figée ?)."
    fi
    info "WinApps déjà présent ($(git -C "$WINAPPS_SRC" log -1 --format='%h du %ad' --date=short))"
else
    info "Clonage de WinApps dans ${WINAPPS_SRC}"
    mkdir -p "$(dirname "$WINAPPS_SRC")"
    git clone --recurse-submodules --remote-submodules "$WINAPPS_REPO" "$WINAPPS_SRC"
fi
[[ -f "$WINAPPS_SRC/oem/install.bat" ]] ||
    die "${WINAPPS_SRC}/oem/install.bat introuvable : clone incomplet."

# --- Déploiement ---
info "Déploiement dans ${DIR}"
mkdir -p "$DIR"
chmod 700 "$DIR"

# Remplacement atomique : un client FreeRDP en cours n'est pas perturbé.
deploy() { # deploy <droits> <source> <nom>
    install -m "$1" "$2" "${DIR}/.$3.tmp"
    mv -f "${DIR}/.$3.tmp" "${DIR}/$3"
}

if [[ -e "${DIR}/winapps.conf" ]] && ! cmp -s "${REPO}/config/winapps.conf" "${DIR}/winapps.conf"; then
    backup="winapps.conf.bak-$(date +%Y-%m-%d-%H%M%S)"
    cp -p "${DIR}/winapps.conf" "${DIR}/${backup}"
    warn "winapps.conf modifié sur place : ancienne version gardée dans ${backup}."
fi
deploy 600 "${REPO}/config/winapps.conf" winapps.conf
for script in winapps-askpass winapps-freerdp winapps-clipboard-bridge.py; do
    deploy 755 "${REPO}/scripts/${script}" "$script"
done

info "Compilation de freerdp-clipboard-fix.so"
gcc -shared -fPIC -O2 -Wall -Wextra -o "${DIR}/.freerdp-clipboard-fix.so.tmp" \
    "${REPO}/src/freerdp-clipboard-fix.c" -ldl
mv -f "${DIR}/.freerdp-clipboard-fix.so.tmp" "${DIR}/freerdp-clipboard-fix.so"

# Anciens noms.
rm -f "${DIR}/xfreerdp-winapps" "${DIR}/xfreerdp-clipboard-fix.so" "${DIR}/winapps-geometry.py"

cd "$DIR"

# --- .env ---
# Valeur d'une variable du conteneur WinApps existant.
existing() {
    docker inspect WinApps --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
        sed -n "s/^$1=//p" | head -n1
}

ask() { # ask <question> <défaut> ; sans terminal : le défaut
    local answer=""
    [[ -t 0 ]] && read -r -p "$1 [$2] : " answer
    printf '%s' "${answer:-$2}"
}

if [[ ! -e .env ]]; then
    info "Création de .env (Entrée = valeur proposée)"
    if [[ -s .password ]]; then
        password=$(<.password) # Ancienne organisation : repris, puis supprimé.
    else
        [[ -t 0 ]] || die "pas de terminal pour saisir le mot de passe."
        while true; do
            read -r -s -p "Mot de passe Windows : " password; echo
            read -r -s -p "Encore une fois : " confirmation; echo
            if [[ -z "$password" ]]; then
                warn "mot de passe vide."
            elif [[ "$password" != "$confirmation" ]]; then
                warn "les deux saisies diffèrent."
            else
                break
            fi
        done
    fi
    [[ "$password" != *"'"* ]] ||
        die "pas d'apostrophe dans le mot de passe."

    while true; do
        default_username=$(existing USERNAME || true)
        username=$(ask "Compte Windows" "${default_username:-$USER}")
        [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] && break
        warn "lettres, chiffres, point, tiret et tiret bas uniquement."
    done
    default_version=$(existing VERSION || true)
    version=$(ask "Édition sans ISO (11l = LTSC évaluation, 11 = Pro)" "${default_version:-11l}")
    default_ram=$(existing RAM_SIZE || true)
    ram=$(ask "Mémoire" "${default_ram:-4G}")
    default_cpu=$(existing CPU_CORES || true)
    cpu=$(ask "Cœurs" "${default_cpu:-4}")
    default_disk=$(existing DISK_SIZE || true)
    disk=$(ask "Disque C:" "${default_disk:-64G}")

    iso=""
    if ! docker inspect WinApps &>/dev/null; then
        while true; do
            iso=$(ask "ISO Windows 11 LTSC (vide = téléchargement de l'évaluation)" "")
            iso=${iso/#\~/$HOME}
            [[ -z "$iso" ]] && break
            if [[ ! -f "$iso" ]]; then
                warn "fichier introuvable : ${iso}"
            elif [[ "$iso" == *"'"* ]]; then
                warn "pas d'apostrophe dans le chemin."
            else
                iso=$(readlink -f "$iso")
                break
            fi
        done
    fi

    (
        umask 077
        cat > .env <<EOF
# Créé par install.sh. Après modification : relancer install.sh.
# WIN_ISO vide : dockur télécharge WIN_VERSION.
WIN_USERNAME=${username}
WIN_PASSWORD='${password}'
WIN_ISO='${iso}'
WIN_VERSION=${version}
WIN_RAM_SIZE=${ram}
WIN_CPU_CORES=${cpu}
WIN_DISK_SIZE=${disk}
WIN_LANGUAGE=French
WIN_REGION=fr-FR
WIN_KEYBOARD=fr-FR
EOF
    )
    unset password confirmation
    if [[ -e .password ]]; then
        rm -f .password
        info ".password repris dans .env, puis supprimé"
    fi
else
    info ".env conservé"
fi
chmod 600 .env

# compose.yaml : la ligne /boot.iso n'est gardée que si l'ISO existe.
iso=$(sed -n "s/^WIN_ISO='\(.*\)'\$/\1/p" .env | head -n1)
if [[ -n "$iso" && -f "$iso" ]]; then
    info "ISO : ${iso}"
    deploy 644 "${REPO}/config/compose.yaml" compose.yaml
else
    if [[ -n "$iso" ]]; then
        warn "ISO introuvable (${iso}) : non montée. Sans importance si Windows est déjà installé."
    fi
    without_iso=$(mktemp)
    sed '/:\/boot\.iso$/d; /Ligne retirée par install\.sh/d' "${REPO}/config/compose.yaml" > "$without_iso"
    deploy 644 "$without_iso" compose.yaml
    rm -f "$without_iso"
fi

docker compose --file compose.yaml config --quiet ||
    die "compose.yaml ou .env invalide."

# --- Suite ---
info "Poste prêt."
if docker inspect WinApps &>/dev/null; then
    echo "VM « WinApps » déjà présente : rien d'autre à faire."
else
    [[ -n "$iso" && -f "$iso" ]] ||
        echo "Sans ISO : dockur téléchargera l'édition « $(sed -n 's/^WIN_VERSION=//p' .env) »."
    cat <<EOF
Suite (README) :
  4. docker compose --file ${DIR}/compose.yaml up -d   puis http://127.0.0.1:8006
  5. Installer Office dans Windows, se déconnecter.
  6. ${WINAPPS_SRC}/setup.sh --user
EOF
fi
