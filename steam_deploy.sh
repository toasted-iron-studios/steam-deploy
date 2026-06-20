#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# steamcmd runs natively on the (kata microVM) runner — no Docker/dind needed.

# Handle absolute or relative rootPath
if [[ "$rootPath" = /* ]]; then
  contentroot="$rootPath"
else
  contentroot="$(pwd)/$rootPath"
fi

# Use a deploy workspace under the content root (shared volume accessible by DinD)
deploydir="$contentroot/.deploy"
mkdir -p "$deploydir/BuildOutput"
mkdir -p "$deploydir/steam/config"
manifest_path="$deploydir/manifest.vdf"

# Clean up deploy workspace on exit (all files created by the runner user).
cleanup() { rm -rf "$deploydir" 2>/dev/null || true; }
trap cleanup EXIT

echo ""
echo "#################################"
echo "#   Generating Depot Manifests  #"
echo "#################################"
echo ""

if [ -n "$firstDepotIdOverride" ]; then
  firstDepotId=$firstDepotIdOverride
else
  firstDepotId=$((appId + 1))
fi

i=1;
export DEPOTS="\n  "
until [ $i -gt 9 ]; do
  eval "currentDepotPath=\$depot${i}Path"
  eval "currentDepotInstallScriptPath=\$depot${i}InstallScriptPath"
  if [ -n "$currentDepotPath" ]; then
    currentDepot=$((firstDepotId + i - 1))

    if [ -n "${currentDepotInstallScriptPath:-}" ]; then
      echo ""
      echo "Adding install script for depot ${currentDepot}..."
      echo ""
      installScriptDirective="\"InstallScript\" \"${currentDepotInstallScriptPath}\""
    else
      installScriptDirective=""
    fi
    if [ "${debugBranch}" = "true" ]; then
      debugExcludes=""
    else
      debugExcludes='"FileExclusion" "*.pdb"\n  "FileExclusion" "**/*_BurstDebugInformation_DoNotShip*"\n  "FileExclusion" "**/*_BackUpThisFolder_ButDontShipItWithYourGame*"'
    fi

    echo ""
    echo "Adding depot${currentDepot}.vdf ..."
    echo ""
    export DEPOTS="$DEPOTS  \"$currentDepot\" \"depot${currentDepot}.vdf\"\n  "

    cat << EOF > "$deploydir/depot${currentDepot}.vdf"
"DepotBuildConfig"
{
  "DepotID" "$currentDepot"
  "FileMapping"
  {
    "LocalPath" "./$currentDepotPath/*"
    "DepotPath" "."
    "recursive" "1"
  }
  $(echo "$debugExcludes" |sed 's/\\n/\
/g')

  $installScriptDirective
}
EOF

  cat "$deploydir/depot${currentDepot}.vdf"
  echo ""
  fi;

  i=$((i+1))
done

echo ""
echo "#################################"
echo "#    Generating App Manifest    #"
echo "#################################"
echo ""

cat << EOF > "$manifest_path"
"appbuild"
{
  "appid" "$appId"
  "desc" "$buildDescription"
  "buildoutput" "$deploydir/BuildOutput"
  "contentroot" "$contentroot"
  "setlive" "$releaseBranch"

  "depots"
  {$(echo "$DEPOTS" | sed 's/\\n/\
/g')}
}
EOF

cat "$manifest_path"
echo ""

if [ -n "$steam_totp" ]; then
  echo ""
  echo "#################################"
  echo "#     Using SteamGuard TOTP     #"
  echo "#################################"
  echo ""
elif [ -n "$configVdf" ]; then
  echo ""
  echo "#################################"
  echo "#    Copying SteamGuard Files   #"
  echo "#################################"
  echo ""

  echo "Steam config at: $deploydir/steam"

  echo "Copying config.vdf..."
  echo "$configVdf" | base64 -d > "$deploydir/steam/config/config.vdf"
  chmod 777 "$deploydir/steam/config/config.vdf"

  echo "Finished Copying SteamGuard Files!"
  echo ""
else
  echo "Error: Either 'totp' or 'configVdf' must be provided."
  exit 1
fi

# Run steamcmd NATIVELY (no Docker). The deploy job runs inside a kata-containers
# microVM (its own ARC runner) — that gives the 32-bit Steam client a virtualized
# CPU plus a guest kernel with IA32 emulation + COMPAT_32BIT_TIME, without which
# the client segfaults / aborts on showboat's bare metal. dind does not work
# inside a kata microVM (privileged device passthrough is blocked), so we install
# and invoke steamcmd directly on the runner here.
# steamcmd ignores a HOME override and always uses the invoking account's
# real $HOME/.local/share/Steam — so we place config.vdf there and DO NOT override
# HOME when running it. STEAMCMD_DIR is just where the steamcmd binary is installed.
STEAMCMD_DIR="$deploydir/steamcmd"
STEAM_DATA="${HOME:-/root}/.local/share/Steam"

setup_steamcmd() {
  echo "Setting up native steamcmd..."
  # steamcmd is a 32-bit binary; ensure i386 runtime libs (runner has sudo).
  if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q i386; then
    sudo dpkg --add-architecture i386
    sudo apt-get update -qq
  fi
  sudo apt-get install -y -qq lib32gcc-s1 libc6:i386 ca-certificates curl >/dev/null 2>&1 \
    || sudo apt-get install -y -qq lib32gcc1 libc6:i386 ca-certificates curl >/dev/null 2>&1 || true
  mkdir -p "$STEAMCMD_DIR"
  if [ ! -f "$STEAMCMD_DIR/steamcmd.sh" ]; then
    curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
      | tar zxf - -C "$STEAMCMD_DIR"
  fi
  # Place config.vdf where steamcmd ACTUALLY reads it: the invoking account's real
  # $HOME/.local/share/Steam/config/. steamcmd IGNORES a HOME override and resolves
  # the account home itself, so placing the vdf under a custom HOME ($deploydir/...)
  # leaves it unread — steamcmd then reports "Logging in using username/password"
  # and fails "Invalid Password". At the real XDG path it reports "Logging in using
  # cached credentials" and the vdf authenticates with no password / no 2FA.
  if [ -f "$deploydir/steam/config/config.vdf" ]; then
    # steamcmd's data dir varies by build/image: tarball steamcmd run as root uses
    # $HOME/Steam (confirmed: logging dir /root/Steam/logs), while the steamcmd
    # Docker image uses the XDG $HOME/.local/share/Steam. Place the vdf at ALL
    # candidates under both the real $HOME and /root so the one steamcmd actually
    # reads is always populated → "Logging in using cached credentials".
    for d in "${HOME:-/root}/Steam" "${HOME:-/root}/.local/share/Steam" /root/Steam /root/.local/share/Steam; do
      mkdir -p "$d/config" "$d/logs"
      cp "$deploydir/steam/config/config.vdf" "$d/config/config.vdf"
      chmod 600 "$d/config/config.vdf"
    done
    echo "config.vdf placed at: ${HOME:-/root}/Steam/config, .local/share/Steam/config, /root/... (all candidates)"
  else
    echo "No config.vdf (TOTP auth mode)"
  fi
}

run_steamcmd() {
  # stdin from /dev/null: on a login failure steamcmd otherwise drops to its
  # interactive "Steam>" prompt and hangs forever waiting for input. EOF makes
  # it quit immediately so the job fails fast instead of stalling for hours.
  # SIGTERM at STEAMCMD_TIMEOUT (default 20m for a real upload), SIGKILL 30s
  # later. An auth-failed steamcmd that ignores EOF then dies in minutes, not the
  # job ceiling — preventing a wedged runner.
  local t="${STEAMCMD_TIMEOUT:-1200}"
  timeout -k 30 "$t" "$STEAMCMD_DIR/steamcmd.sh" "$@" </dev/null
  ret=$?
  if [ $ret -ne 0 ]; then
    echo ""
    echo "=== Steam logs ==="
    for f in "${HOME:-/root}"/Steam/logs/* /root/Steam/logs/* "${HOME:-/root}"/.local/share/Steam/logs/* "$STEAMCMD_DIR"/logs/*; do
      [ -e "$f" ] && echo "######## $f" && cat "$f" && echo
    done
    echo "=================="
  fi
  return $ret
}

echo ""
echo "#################################"
echo "#   Login + Upload (single run) #"
echo "#################################"
echo ""

setup_steamcmd

# Build steamcmd arguments based on auth method
if [ -n "$steam_totp" ]; then
  # TOTP auth: guard code + username/password
  steamcmd_args="+set_steam_guard_code $steam_totp +login $steam_username $steam_password +run_app_build $manifest_path +quit"
elif [ -n "${steam_password:-}" ]; then
  # configVdf + password: config.vdf bypasses Steam Guard, password handles auth
  steamcmd_args="+login $steam_username $steam_password +run_app_build $manifest_path +quit"
else
  # configVdf only: cached credentials from config.vdf handle both login and Steam Guard
  steamcmd_args="+login $steam_username +run_app_build $manifest_path +quit"
fi

# Capture output to detect login failures (steamcmd exits 0 with +quit even on error)
deploy_log="$deploydir/deploy_output.log"
set +e
run_steamcmd "$steamcmd_args" 2>&1 | tee "$deploy_log"
ret=${PIPESTATUS[0]}
set -e

# Check for success/failure in output (steamcmd exits 0 with +quit even on error).
# Look for the definitive success message first, then check for fatal errors.
if grep -q "Successfully finished" "$deploy_log"; then
    echo ""
    echo "#################################"
    echo "#     Build Succeeded!          #"
    echo "#################################"
    echo ""
elif [ $ret -ne 0 ] || grep -qE "ERROR \(|FAILED!|Login Failure" "$deploy_log"; then
    echo ""
    echo "#################################"
    echo "#             Errors            #"
    echo "#################################"
    echo ""
    if grep -qE "ERROR \(|FAILED!|Login Failure" "$deploy_log"; then
      echo "Detected error in steamcmd output:"
      grep -E "ERROR \(|FAILED!|Login Failure" "$deploy_log"
      echo ""
    fi
    echo "Listing content root:"
    ls -alh "$contentroot" || true
    echo ""
    echo "Listing build output:"
    ls -Ralph "$deploydir/BuildOutput" || true

    for f in "$deploydir"/BuildOutput/*.log; do
      if [ -e "$f" ]; then
        echo "######## $f"
        cat "$f"
        echo
      fi
    done

    exit 1
fi

echo "manifest=${manifest_path}" >> $GITHUB_OUTPUT

# Clean up deploy workspace (the EXIT trap also covers failure paths).
rm -rf "$deploydir"
