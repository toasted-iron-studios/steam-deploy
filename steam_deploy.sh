#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

STEAMCMD_IMAGE="${STEAMCMD_IMAGE:-cm2network/steamcmd:root}"

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

# Run steamcmd via Docker (x86 image, works on arm64 via QEMU binfmt).
# All files are under $contentroot which is a shared hostPath volume,
# so both the runner and DinD-spawned containers can access them.
run_steamcmd() {
  docker run --rm \
    --platform linux/amd64 \
    -v "$contentroot":"$contentroot" \
    -v "$deploydir/steam":/root/Steam \
    -w "$deploydir" \
    "$STEAMCMD_IMAGE" \
    bash -c "/home/steam/steamcmd/steamcmd.sh $*"
}

echo ""
echo "#################################"
echo "#        Test login             #"
echo "#################################"
echo ""

run_steamcmd "+set_steam_guard_code $steam_totp +login $steam_username $steam_password +quit"

ret=$?
if [ $ret -eq 0 ]; then
    echo ""
    echo "#################################"
    echo "#        Successful login       #"
    echo "#################################"
    echo ""
else
      echo ""
      echo "#################################"
      echo "#        FAILED login           #"
      echo "#################################"
      echo ""
      echo "Exit code: $ret"

      exit $ret
fi

echo ""
echo "#################################"
echo "#        Uploading build        #"
echo "#################################"
echo ""

run_steamcmd "+login $steam_username +run_app_build $manifest_path +quit" || (
    echo ""
    echo "#################################"
    echo "#             Errors            #"
    echo "#################################"
    echo ""
    echo "Listing current folder and rootpath"
    echo ""
    ls -alh "$deploydir"
    echo ""
    ls -alh "$contentroot" || true
    echo ""
    echo "Listing logs folder:"
    echo ""
    ls -Ralph "$deploydir/steam/logs/" || true

    for f in "$deploydir"/steam/logs/*; do
      if [ -e "$f" ]; then
        echo "######## $f"
        cat "$f"
        echo
      fi
    done

    echo ""
    echo "#################################"
    echo "#             Output            #"
    echo "#################################"
    echo ""
    ls -Ralph "$deploydir/BuildOutput" || true

    for f in "$deploydir"/BuildOutput/*.log; do
      if [ -e "$f" ]; then
        echo "######## $f"
        cat "$f"
        echo
      fi
    done

    exit 1
  )

echo "manifest=${manifest_path}" >> $GITHUB_OUTPUT

# Clean up deploy workspace
rm -rf "$deploydir"
