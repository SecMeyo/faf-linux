#!/bin/bash
# Main setup script
set -eE
trap 'echo; echo "Script error! The installation has failed. Please report this to the author."' ERR

PROTON_VERSION="- Experimental"
# winetricks has its own self-updater
WINETRICKS_URL="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
STEAM_GAME_ID="9420"

basedir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
cd "$basedir"

source ./common.sh

# if you are using nonstandard paths, please add it here
# if you've installed steam from an official or distribution package but it was
# not found, please file an issue
STEAM_SEARCH_PATHS=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
)
# note: ~/.steam/steam exists even if steam is installed to ~/.local/share/Steam
# for what appears to be compatibility reasons.

if [[ "$BYPASS_STEAM" != "1" ]]; then
    echo "looking for Steam..."
    for f in "${STEAM_SEARCH_PATHS[@]}"; do
        if [[ -f "$f/steamapps/libraryfolders.vdf" ]]; then
            echo "found Steam: $f"
            STEAM_PATH="$f"
            break
        else
            echo "not found: $f"
        fi
    done

    if [[ -z "$STEAM_PATH" ]]; then
        echo
        echo "Could not find Steam. If Steam is installed at a different location, please modify the STEAM_SEARCH_PATHS variable to match." >&2
        exit 1
    fi

    # parse libraryfolders.vdf
    libraryfolders=()
    while IFS='' read -u 10 f; do
        if [[ -d "$f" ]]; then
            echo "found steam library folder: $f"
            libraryfolders+=("$f")
        fi
    done 10<<< "$( \
        # cursed parse
        grep -Po '"path"\s+".+"$' "$STEAM_PATH/steamapps/libraryfolders.vdf" | \
            cut -sd $'\t' -f 3 | \
            cut -sd '"' -f 2)"

    if [[ "${#libraryfolders[@]}" = "0" ]]; then
        echo "warning: failed to parse library folders"
        libraryfolders+=("$STEAM_PATH")
    fi

    # search every known library folder for app name
    rv=''
    function find-app() {
        for f in "${libraryfolders[@]}"; do
            local try_path="$f/steamapps/common/$1"
            if [[ -d "$try_path" ]]; then
                echo "found $1 at $try_path"
                rv="$try_path"
                return 0
            fi
        done
        return 1
    }
    
    # find game and proton install path
    if ! find-app "Proton $PROTON_VERSION"; then
        echo "Could not find Proton $PROTON_VERSION." >&2
        echo "Please run the game from Steam at least once with the selected Proton version." >&2
        exit 1
    fi
    PROTON_PATH="$rv"

    if ! find-app "Supreme Commander Forged Alliance"; then
        echo "Could not find Forged Alliance." >&2
        echo "Please ensure Supreme Commander: Forged Alliance is installed on Steam." >&2
        exit 1
    fi
    GAME_PATH="$rv"
else
    if [[ -z "$GAME_PATH" ]]; then
        echo "error: need GAME_PATH if not using Steam" >&2
        exit 1
    fi
    if [[ -z "$PROTON_PATH" ]] && [[ -z "$WINE_PATH" ]]; then
        echo "error: need PROTON_PATH or WINE_PATH set if not using Steam" >&2
        exit 1
    fi
fi

proton_wine_subdir="files" # this changes sometimes, for some reason
if [[ ! -z "$PROTON_PATH" ]]; then 
    ensure-path "$PROTON_PATH/$proton_wine_subdir" "Proton $PROTON_VERSION does not appear to be extracted. Please run Proton at least once."
    WINE_PATH="$PROTON_PATH/$proton_wine_subdir"
fi
# ensure paths are valid, especially if the user passed them manually
ensure-path "$WINE_PATH" "error: wine not found!"
ensure-path "$GAME_PATH" "error: SC:FA not found!"

GAME_DATA_PATH="AppData/Local/Gas Powered Games/Supreme Commander Forged Alliance"

# required programs: wget jq cabextract
ensure-bin wget --version
ensure-bin jq --version
ensure-bin cabextract --version
ensure-bin patch --version

# required libs
block-print "Checking libraries"
echo "Found the following libraries:"
ensure-lib libXrandr libpulse libvulkan libXfixes libXcursor libXi libXcomposite libfreetype
ensure-lib64 libXcomposite libgstreamer

# initialize environment file
cat <<EOF > "$basedir/common-env"
# This file is automatically generated by setup.sh and will be overwritten
# when the script is run.

EOF

wineprefix="$basedir/prefix"
write-env "wineprefix" "$wineprefix"
[[ ! -z "$STEAM_PATH" ]] && write-env "steam_path" "$STEAM_PATH"
[[ ! -z "$PROTON_PATH" ]] && write-env "proton_path" "$PROTON_PATH"
write-env "steam_game_id" "$STEAM_GAME_ID"
write-env "game_path" "$GAME_PATH"
write-env "game_data_path" "$wineprefix/drive_c/users/steamuser/$GAME_DATA_PATH"
write-env "dxvk_hud" "compiler" # sane defaults, probably
write-env "dxvk_config_file" "$basedir/dxvk.conf"
# unfortunately the steam overlay seems to crash the game sometimes
# enable at your own risk
write-env "enable_steam_integration" "0"
write-env "ice_adapter_debug" "1"
write-env "wine_path" "$WINE_PATH"
write-env "use_gamescope" "0"

dxvk_cache_dir="$basedir/dxvk-cache"
mkdir -p "$dxvk_cache_dir"
write-env "dxvk_cache_dir" "$dxvk_cache_dir"

block-print "Downloading winetricks"
wget -O winetricks "$WINETRICKS_URL"
chmod a+x winetricks

# ensure we are actually using the wine version we want
wine_expected="$(readlink -f "$WINE_PATH/bin/wine")"
wine_actual="$(readlink -f "$("$basedir/launchwrapper-env" which wine)")"
if [[ "$wine_expected" != "$wine_actual" ]]; then
    echo "error: wrong wine on path!"
    echo "expected: $wine_expected"
    echo "actual: $wine_actual"
    exit 1
fi

# load target versions
. ./versions

"$basedir/update-component.sh" faf-client "$dfc_version_target"

"$basedir/update-component.sh" java "$java_download_url_target"

block-print "Wineboot"
"$basedir/launchwrapper-env" wine wineboot -u
block-print "Running winetricks"
"$basedir/launchwrapper-env" "$basedir/winetricks" d3dx9 xact
# install dxvk into prefix
"$basedir/update-component.sh" dxvk "$dxvk_version_target"

# prompt user to log in
echo
echo "Setup complete. Please log in to the FAF client."
echo "If, at this point, you have not yet read the README, please do so now:"
echo "  https://github.com/FAForever/faf-linux/blob/master/README.md"
echo "Additional configuration needs to be set in order to launch the game properly."
echo "When you are done logging in, please close the client and run './set-client-paths.sh'."
