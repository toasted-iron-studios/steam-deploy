#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

STEAMCMD_IMAGE="${STEAMCMD_IMAGE:-sonroyaalmerol/steamcmd-arm64:root}"

# Wait for Docker daemon (DinD sidecar may still be starting)
if [ -n "${DOCKER_HOST:-}" ]; then
  echo "Waiting for Docker daemon at $DOCKER_HOST..."
  for i in $(seq 1 30); do
    if docker info &>/dev/null 2>&1; then
      echo "Docker is ready."
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "Error: Docker daemon not available after 30s"
      exit 1
    fi
    sleep 1
  done
fi

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
else
  if [ ! -n "$configVdf" ]; then
    echo "Config VDF input is missing or incomplete! Cannot proceed."
    exit 1
  fi

  steam_totp="INVALID"

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
fi

# Run steamcmd via Docker using Box86/Box64 for x86 emulation (native ARM64).
# The sonroyaalmerol/steamcmd-arm64:root image runs as root (HOME=/root).
# steamcmd stores data at $HOME/Steam/ => /root/Steam/.
# We mount config to /root/Steam so steamcmd finds config.vdf.
run_steamcmd() {
  docker run --rm --privileged \
    -v "$contentroot":"$contentroot" \
    -v "$deploydir/steam":/root/Steam \
    -w "$deploydir" \
    "$STEAMCMD_IMAGE" \
    bash -c '
      echo "=== Steam config debug ==="
      echo "HOME=$HOME"
      echo "Files in /root/Steam/config/:"
      ls -la /root/Steam/config/ 2>/dev/null || echo "  (directory not found)"
      if [ -f /root/Steam/config/config.vdf ]; then
        echo "config.vdf size: $(wc -c < /root/Steam/config/config.vdf) bytes"
        echo "config.vdf first line: $(head -1 /root/Steam/config/config.vdf)"
      else
        echo "WARNING: /root/Steam/config/config.vdf not found!"
      fi
      echo "========================="

      export LD_LIBRARY_PATH="/home/steam/steamcmd/linux32:${LD_LIBRARY_PATH:-}"
      while true; do
        box86 /home/steam/steamcmd/linux32/steamcmd '"$*"'
        ret=$?
        if [ $ret -ne 42 ]; then exit $ret; fi
        echo "steamcmd: restarting by request..."
      done
    '
}

echo ""
echo "#################################"
echo "#   Login + Upload (single run) #"
echo "#################################"
echo ""

# Build steamcmd arguments based on auth method
if [ -n "$steam_totp" ] && [ "$steam_totp" != "INVALID" ]; then
  # TOTP auth: guard code + username/password
  steamcmd_args="+set_steam_guard_code $steam_totp +login $steam_username $steam_password +run_app_build $manifest_path +quit"
elif [ -n "${steam_password:-}" ]; then
  # Password auth (no TOTP): username/password only
  steamcmd_args="+login $steam_username $steam_password +run_app_build $manifest_path +quit"
else
  # configVdf auth: username only (cached credentials from config.vdf)
  steamcmd_args="+login $steam_username +run_app_build $manifest_path +quit"
fi

# Capture output to detect login failures (steamcmd exits 0 with +quit even on error)
deploy_log="$deploydir/deploy_output.log"
set +e
run_steamcmd "$steamcmd_args" 2>&1 | tee "$deploy_log"
ret=${PIPESTATUS[0]}
set -e

# Check for errors in output (steamcmd may exit 0 despite failures)
if [ $ret -ne 0 ] || grep -qiE "ERROR|FAILED" "$deploy_log"; then
    echo ""
    echo "#################################"
    echo "#             Errors            #"
    echo "#################################"
    echo ""
    if grep -qiE "ERROR|FAILED" "$deploy_log"; then
      echo "Detected error in steamcmd output:"
      grep -iE "ERROR|FAILED" "$deploy_log"
      echo ""
    fi
    echo "Listing content root:"
    ls -alh "$contentroot" || true
    echo ""
    echo "Listing logs folder:"
    ls -Ralph "$deploydir/steam/logs/" || true

    for f in "$deploydir"/steam/logs/*; do
      if [ -e "$f" ]; then
        echo "######## $f"
        cat "$f"
        echo
      fi
    done

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

# Clean up deploy workspace (docker creates files as root)
docker run --rm -v "$contentroot":"$contentroot" alpine rm -rf "$deploydir"
