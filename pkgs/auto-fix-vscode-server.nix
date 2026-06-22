{
  lib,
  buildFHSEnv,
  runtimeShell,
  writeShellScript,
  writeShellApplication,
  coreutils,
  findutils,
  inotify-tools,
  psmisc,
  gnugrep,
  patchelf,
  stdenv,
  curl,
  icu,
  libunwind,
  libuuid,
  lttng-ust,
  openssl,
  zlib,
  krb5,
  enableFHS ? false,
  nodejsPackage ? null,
  extraRuntimeDependencies ? [ ],
  installPath ? [ "$HOME/.vscode-server" ],
  postPatch ? "",
}: let
  inherit (lib) makeBinPath makeLibraryPath optionalString;

  # Based on: https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/applications/editors/vscode/generic.nix
  runtimeDependencies =
    [
      stdenv.cc.libc
      stdenv.cc.cc

      # dotnet
      curl
      icu
      libunwind
      libuuid
      lttng-ust
      openssl
      zlib

      # mono
      krb5
    ]
    ++ extraRuntimeDependencies;

  nodejs = nodejsPackage;
  nodejsFHS = buildFHSEnv {
    name = "node";
    targetPkgs = _: runtimeDependencies;
    extraBuildCommands = ''
      if [[ -d /usr/lib/wsl ]]; then
        # Recursively symlink the lib files necessary for WSL
        # to properly function under the FHS compatible environment.
        # The -s stands for symbolic link.
        cp -rsHf /usr/lib/wsl usr/lib/wsl
      fi
    '';
    runScript = "${nodejs}/bin/node";
    meta = {
      description = ''
        Wrapped variant of Node.js which launches in an FHS compatible envrionment,
        which should allow for easy usage of extensions without Nix-specific modifications.
      '';
    };
  };

  patchELFScript = writeShellApplication {
    name = "patchelf-vscode-server";
    runtimeInputs = [ coreutils findutils patchelf ];
    text = ''
      set -e

      bin_dir="$1"
      patched_file="$bin_dir/.nixos-patched"

      # NOTE: We don't log here because it won't show up in the output of the user service.

      # Check if the installation is already full patched.
      if [[ ! -e $patched_file ]] || (( $(< "$patched_file") )); then
        exit 0
      fi

      ${optionalString (!enableFHS) ''
        INTERP=$(< ${stdenv.cc}/nix-support/dynamic-linker)
        RPATH=${makeLibraryPath runtimeDependencies}

        patch_elf () {
          local elf=$1 interp

          # Check if binary is patchable, e.g. not a statically-linked or non-ELF binary.
          if ! interp=$(patchelf --print-interpreter "$elf" 2>/dev/null); then
            return
          fi

          # Check if it is not already patched for Nix.
          if [[ $interp == "$INTERP" ]]; then
            return
          fi

          # Patch the binary based on the binary of Node.js,
          # which should include all dependencies they might need.
          patchelf --set-interpreter "$INTERP" --set-rpath "$RPATH" "$elf"

          # The actual dependencies are probably less than that of Node.js,
          # so shrink the RPATH to only keep those that are actually needed.
          patchelf --shrink-rpath "$elf"
        }

        while read -rd ''' elf; do
          patch_elf "$elf"
        done < <(find "$bin_dir" -type f -perm -100 -printf '%p\0')

        # Refer to https://github.com/NixOS/nixpkgs/issues/405528.
        # For whatever reason, libssl is required but absent from DT_NEEDED.
        vsce_sign_bin="$bin_dir/node_modules/@vscode/vsce-sign/bin/vsce-sign"
        if [[ -f "$vsce_sign_bin" ]]; then
          patchelf \
            --add-needed ${lib.getLib openssl}/lib/libssl.so \
            "$vsce_sign_bin"
        fi
      ''}

      # Mark the bin directory as being fully patched.
      echo 1 > "$patched_file"

      ${optionalString (postPatch != "") ''${writeShellScript "post-patchelf-vscode-server" postPatch} "$bin_dir"''}
    '';
  };

  autoFixScript = writeShellApplication {
    name = "auto-fix-vscode-server";
    runtimeInputs = [ coreutils findutils inotify-tools psmisc gnugrep ];
    text = ''
      set -e

      # Convert installPath list to an array
      IFS=':' read -r -a installPaths <<< "${lib.concatStringsSep ":" installPath}"

      # Returns 0 (success) when "$1" is already one of our replacements for the
      # node binary, i.e. a symlink (FHS mode) or a shell wrapper script (its
      # first bytes are the '#!' shebang). A raw, dynamically-linked ELF — the
      # binary VS Code ships — returns non-zero.
      is_patched_node () {
        local node="$1"
        [[ -e $node ]] || return 1
        [[ -L $node ]] && return 0
        [[ "$(head -c2 "$node" 2>/dev/null)" == '#!' ]]
      }

      patch_bin () {
        local actual_dir="$1"
        local current_install_path="$2"
        local patched_file="$actual_dir/.nixos-patched"
        local node="$actual_dir/node"

        # Nothing to patch (yet) if node hasn't been extracted.
        [[ -e $node ]] || return 0

        # IMPORTANT: We deliberately do NOT trust the .nixos-patched marker as
        # proof that node is patched. With the new cli/servers/<id>.staging/
        # layout, VS Code's installer re-extracts the server several times
        # (extract -> run node -> fails on NixOS -> delete dir -> re-extract),
        # and each extraction overwrites our wrapper at "node" with a fresh ELF
        # while the marker file (which is not part of VS Code's tarball)
        # survives. A write-once marker check would skip every retry after the
        # first, leaving node as an unrunnable raw ELF. Instead we inspect the
        # actual node binary on every event and re-patch whenever it has
        # reverted to a raw ELF, so we re-enter the race until our wrapper is
        # the binary VS Code finally launches.
        if is_patched_node "$node"; then
          return 0
        fi

        echo "Patching Node.js of VS Code server installation in $actual_dir..." >&2

        mv "$node" "$actual_dir/node.patched"

        ${optionalString (enableFHS) ''
        ln -sfT ${nodejsFHS}/bin/node "$actual_dir/node"
      ''}

        ${optionalString (!enableFHS || postPatch != "") ''
        cat <<EOF > "$actual_dir/node"
        #!${runtimeShell}

        # The core utilities are missing in the case of WSL, but required by Node.js.
        PATH="\''${PATH:+\''${PATH}:}${makeBinPath [ coreutils ]}"

        # We leave the rest up to the Bash script
        # to keep having to deal with 'sh' compatibility to a minimum.
        ${patchELFScript}/bin/patchelf-vscode-server \$(dirname "\$0")

        # Let Node.js take over as if this script never existed.
        ${
          let nodePath = (if (nodejs != null)
          then "${if enableFHS then nodejsFHS else nodejs}/bin/node"
          else ''\$(dirname "\$0")/node.patched'');
          in ''exec "${nodePath}" "\$@"''
        }
        EOF
        chmod +x "$actual_dir/node"
      ''}

        # Mark the bin directory as being patched.
        echo 0 > "$patched_file"
      }

      # Initialize arrays
      bins_dirs=()

      # Populate bins_dirs based on installPaths
      for current_install_path in "''${installPaths[@]}"; do
        bins_dirs+=("$current_install_path/bin" "$current_install_path/bin" "$current_install_path/cli/servers")
        for arch in arm64 x64 armhf; do
          bins_dirs+=("$current_install_path/bin/linux-$arch")
        done
      done

      # Create directories and patch existing bins
      for bins_dir in "''${bins_dirs[@]}"; do
        mkdir -p "$bins_dir"
        while read -r node_bin; do
          bin=$(dirname "$node_bin")
          patch_bin "$bin" "$(dirname "$(dirname "$bin")")"
        done < <(find "$bins_dir" -maxdepth 4 -type f -name node -executable -not -path "*/node_modules/*" -print)
      done

      # Watch for new installations
      while IFS=: read -r bins_dir bin event; do
        # A new version of the VS Code Server is being created.
        if [[ $event == 'CREATE,ISDIR' ]]; then
          # Check for the directory to satisfy a pattern in `bin` so we won't be waiting on, e.g., creation of `bin/multiplex-server`.
          parent_dir=$(basename "$bins_dir")
          if [ "$parent_dir" = "bin" ] && ! echo "$bin" | grep -Eq '^[a-z0-9]+$'; then
            continue
          fi
          actual_dir="$bins_dir$bin"
          echo "VS Code server is being installed in $actual_dir..." >&2
          # Wait for the node file to get created.
          while true; do
            node_bin=$(find "$actual_dir" -maxdepth 4 -type f -name node -executable -not -path "*/node_modules/*" | head -n1)
            if [ -n "$node_bin" ]; then
              break
            fi
            sleep 0.1
          done
          while [ -n "$(fuser "$node_bin")" ]; do
            sleep 0.1
          done
          bin=$(dirname "$node_bin")
          patch_bin "$bin" "$(dirname "$(dirname "$bin")")"
        # The monitored directory is deleted, e.g. when "Uninstall VS Code Server from Host" has been run.
        elif [[ $event == DELETE_SELF ]]; then
          # See the comments above Restart in the service config.
          exit 0
        fi
      done < <(inotifywait -q -m -e CREATE,ISDIR -e DELETE_SELF --format '%w:%f:%e' "''${bins_dirs[@]}")
    '';
  };
in
autoFixScript
