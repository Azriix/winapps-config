# winapps-config

[WinApps](https://github.com/winapps-org/winapps) sur Ubuntu : Office dans une VM Windows 11 LTSC ([dockur/windows](https://github.com/dockur/windows)), avec deux changements.

- **Client Wayland natif** : `sdl-freerdp` au lieu de `xfreerdp`. Fluide, bonne échelle, collage aux bords, multi-écran.
- **Presse-papiers** : les captures (Flameshot, GNOME) se collent dans Word.

Testé : Ubuntu 26.04, GNOME 50, FreeRDP 3.32.2, WinApps `42c7e83`.

## Installation

### 1. Prérequis

- Virtualisation activée (`/dev/kvm` présent).
- [Docker Engine](https://docs.docker.com/engine/install/ubuntu/) avec Compose.
- ISO Windows 11 Entreprise LTSC 2024.
- 75 Go de disque, 4 Go de RAM.

```bash
sudo usermod -aG docker,kvm "$USER"   # puis rouvrir la session
sudo apt install -y curl dialog freerdp3-sdl git iproute2 libnotify-bin netcat-openbsd gcc libc6-dev python3-gi gir1.2-gtk-4.0 gir1.2-gdkpixbuf-2.0
```

### 2. Déployer

```bash
git clone git@github.com:Azriix/winapps-config.git
cd winapps-config
./install.sh
```

Le script demande le mot de passe Windows, le compte, les ressources et le chemin de l'ISO. Il déploie tout dans `~/.config/winapps`.

Sans ISO, dockur télécharge la version d'évaluation (90 jours).

### 3. Installer Windows

```bash
docker compose --file ~/.config/winapps/compose.yaml up -d
```

Suivre sur <http://127.0.0.1:8006>. Automatique, environ 30 minutes. Activer Windows ensuite.

### 4. Installer Office

Dans <http://127.0.0.1:8006> : installer Office, lancer Word une fois, puis **se déconnecter de Windows**.

### 5. Installer WinApps

```bash
~/.local/bin/winapps-src/setup.sh --user
```

Les lanceurs apparaissent dans le menu des applications.

## Fonctionnement

| Fichier | Rôle |
| --- | --- |
| `install.sh` | Déploie le dépôt dans `~/.config/winapps`. |
| `config/compose.yaml` | VM Windows. |
| `config/winapps.conf` | Configuration WinApps. |
| `scripts/winapps-askpass` | Fournit le mot de passe à FreeRDP depuis `.env`. |
| `scripts/winapps-freerdp` | Lance `sdl-freerdp` avec les correctifs du presse-papiers. |
| `scripts/winapps-clipboard-bridge.py` | Ajoute une variante BMP aux images copiées. |
| `src/freerdp-clipboard-fix.c` | Corrige les images déformées dans Word. |

`install.sh` crée aussi `~/.config/winapps/.env` (compte, mot de passe, ISO, ressources). Il n'est jamais versionné.

**Mettre à jour FreeRDP et WinApps** : `./install.sh --update`. Le correctif du presse-papiers est recompilé. En cas de régression de WinApps : `git -C ~/.local/bin/winapps-src checkout 42c7e83`.

**Modifier** : éditer dans le dépôt, relancer `./install.sh`. Un `winapps.conf` modifié sur place est sauvegardé en `.bak-<date>`.

## Réglages

Dans `config/winapps.conf` :

| Variable | Défaut | Effet |
| --- | --- | --- |
| `FREERDP_COMMAND` | `winapps-freerdp` | `""` = client choisi par WinApps, sans correctifs. |
| `AUTOPAUSE_TIME` | `300` | Pause de la VM après 5 minutes sans application. |

Dans `~/.config/winapps/.env` : `WIN_RAM_SIZE`, `WIN_CPU_CORES`. Appliquer avec `docker compose --file ~/.config/winapps/compose.yaml up -d`.

Les autres valeurs de `.env` ne servent qu'à l'installation de Windows.

## Dépannage

| Symptôme | Action |
| --- | --- |
| Connexion refusée | `docker compose --file ~/.config/winapps/compose.yaml unpause` (ou `start`). |
| Aucune application ne se lance | Même commande avec `restart`. Fermer la session ouverte sur le port 8006. |
| Écran bleu de connexion qui reste | Redémarrer la VM : même commande avec `restart`. |
| Image non collable | Relancer `./install.sh`. Diagnostic : `WINAPPS_BRIDGE_DEBUG=1 ~/.config/winapps/winapps-clipboard-bridge.py`. |
| Mot de passe refusé | Mettre `WIN_PASSWORD` à jour dans `~/.config/winapps/.env`. |

## À savoir

- Le RemoteApp de `sdl-freerdp` est expérimental. Bugs connus : le double clic sur la barre de titre n'agrandit pas la fenêtre ; `/multimon` gèle l'application ; icône générique dans le dock.
- Ne pas tuer un client `sdl-freerdp` en cours : Windows peut rester bloqué à l'ouverture de session jusqu'au redémarrage de la VM.
- L'ISO peut être supprimée après l'installation. Ne pas la remplacer par une autre : dockur réinstallerait Windows.
- Tout effacer : `docker compose --file ~/.config/winapps/compose.yaml down --volumes`. Le disque Windows est perdu.
