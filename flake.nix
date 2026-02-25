{
  description = "NCALayer application for digital signature";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # NCALayer derivation builder
      # Uses the bundled Java Runtime (includes JavaFX) instead of system Java
      # because NixOS does not ship JavaFX with Java 8
      mkNCALayer = pkgs: with pkgs;
        let
          version = "1.2.0";
          pname = "ncalayer";

          # Download the official ncalayer.zip from Kazakhstan PKI
          ncalayer-zip = fetchurl {
            url = "https://ncl.pki.gov.kz/images/NCALayer/ncalayer.zip";
            sha1 = "0341e0e0a6a983bb46cca454f75356d85f451be9";
          };
        in
        stdenv.mkDerivation {
          inherit pname version;
          src = ncalayer-zip;

          nativeBuildInputs = [ unzip makeWrapper autoPatchelfHook ];
          buildInputs = [
            nss.tools
            pcsclite
            stdenv.cc.cc.lib

            # X11 and graphics libraries for bundled JRE
            libx11
            libxext
            libxrender
            libxtst
            libxi
            libxxf86vm
            libGL

            # GTK libraries (both GTK2 and GTK3 for compatibility)
            glib
            gtk2
            gtk3
            gdk-pixbuf
            cairo
            pango
            atk

            # Audio library
            alsa-lib

            # Additional libraries for JavaFX
            freetype
            fontconfig
          ];

          unpackPhase = ''
            runHook preUnpack
            unzip -q $src
            runHook postUnpack
          '';

          # Ignore missing old ffmpeg libraries (not critical for main functionality)
          autoPatchelfIgnoreMissingDeps = [
            "libavcodec.so.54"
            "libavcodec.so.55"
            "libavcodec.so.56"
            "libavcodec.so.57"
            "libavcodec.so.58"
            "libavcodec.so.59"
            "libavcodec.so.60"
            "libavcodec-ffmpeg.so.56"
            "libavformat.so.54"
            "libavformat.so.55"
            "libavformat.so.56"
            "libavformat.so.57"
            "libavformat.so.58"
            "libavformat.so.59"
            "libavformat.so.60"
            "libavformat-ffmpeg.so.56"
            "libgmodule-2.0.so.0"
            "libgthread-2.0.so.0"
          ];

          buildPhase = ''
            runHook preBuild

            # Extract JAR from ncalayer.sh (JAR is embedded after the shell script)
            echo "Extracting JAR from ncalayer.sh..."
            JAR_OFFSET=$(grep -abo "^PK" ncalayer.sh | head -1 | cut -d: -f1)
            if [ -z "$JAR_OFFSET" ]; then
              echo "Error: Could not find JAR signature in ncalayer.sh"
              exit 1
            fi
            tail -c +$JAR_OFFSET ncalayer.sh > ncalayer.jar

            # Embed certificates in install-certs.sh
            ROOT_B64=$(base64 -w 0 additions/cert/root_rsa.cer)
            NCA_B64=$(base64 -w 0 additions/cert/nca_rsa.cer)
            sed -e "s|@@ROOT_CERT_BASE64@@|$ROOT_B64|g" \
                -e "s|@@NCA_CERT_BASE64@@|$NCA_B64|g" \
                ${./install-certs.sh.template} > install-certs.sh

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            # Install bundled JRE (includes JavaFX)
            mkdir -p $out/lib
            cp -r additions/jre8_ncalayer $out/lib/jre

            # Install JAR and certificates
            install -Dm644 ncalayer.jar $out/share/${pname}/ncalayer.jar
            install -Dm644 additions/cert/root_rsa.cer $out/share/${pname}/cert/root_rsa.cer
            install -Dm644 additions/cert/nca_rsa.cer $out/share/${pname}/cert/nca_rsa.cer

            # Install certificate installer with wrapper
            install -Dm755 install-certs.sh $out/libexec/${pname}-install-certs-unwrapped
            makeWrapper $out/libexec/${pname}-install-certs-unwrapped $out/bin/${pname}-install-certs \
              --prefix PATH : ${lib.makeBinPath [ nss.tools ]}

            # Create launcher script using bundled JRE
            # - Runs in background (&) to return control to terminal
            # - Forces X11 backend for Wayland compatibility
            # - Redirects stderr to suppress GTK warnings
            # Find the compiled GSettings schema dir inside gtk3's store path at build time
            GTK3_GSCHEMA_DIR=$(find ${gtk3}/share/gsettings-schemas -name "gschemas.compiled" -exec dirname {} \; | head -1)

            cat > $out/bin/${pname} << EOF
#!/bin/bash
export PATH="${lib.makeBinPath [ nss.tools ]}:\$PATH"
export LD_LIBRARY_PATH="${lib.makeLibraryPath [ gtk3 gtk2 gdk-pixbuf cairo pango atk glib libGL libx11 ]}:\$LD_LIBRARY_PATH"
export GTK_PATH="${gtk3}/lib/gtk-3.0"
export GDK_PIXBUF_MODULE_FILE="${gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
export GDK_BACKEND=x11
export GSETTINGS_BACKEND=memory
export GSETTINGS_SCHEMA_DIR="$GTK3_GSCHEMA_DIR"
unset WAYLAND_DISPLAY

exec $out/lib/jre/bin/java \\
  -Dsun.security.smartcardio.library=${pcsclite}/lib/libpcsclite.so.1 \\
  -jar $out/share/${pname}/ncalayer.jar "\$@" 2>/dev/null &
EOF
            chmod +x $out/bin/${pname}

            # Install desktop entry with absolute path to binary
            mkdir -p $out/share/applications
            sed "s|Exec=ncalayer|Exec=$out/bin/${pname}|" \
              ${./ncalayer.desktop.template} > $out/share/applications/${pname}.desktop

            # Install icon
            install -Dm644 additions/ncalayer.png $out/share/icons/hicolor/256x256/apps/${pname}.png

            runHook postInstall
          '';

          meta = {
            description = "NCALayer application for digital signature";
            homepage = "https://github.com/ZhymabekRoman/NCALayer-Linux";
            license = lib.licenses.mit;
            mainProgram = pname;
            platforms = [ "x86_64-linux" ];
          };
        };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ncalayer = mkNCALayer pkgs;
      in
      {
        packages = {
          default = ncalayer;
          inherit ncalayer;
        };

        apps.default = {
          type = "app";
          program = "${ncalayer}/bin/ncalayer";
        };
      }
    ) // {
      # NixOS module
      nixosModules.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.programs.ncalayer;
        in
        {
          options.programs.ncalayer = {
            enable = mkEnableOption "NCALayer application for digital signature";
            package = mkOption {
              type = types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.ncalayer;
              description = "The NCALayer package to use";
            };
            installCerts = mkOption {
              type = types.bool;
              default = false;
              description = "Automatically installs certificates for active users";
            };
            enableSmartCards = mkOption {
              type = types.bool;
              default = false;
              description = "Enable PC/SC daemon for smart card support";
            };
          };

          config = mkMerge [
            (mkIf cfg.enable {
              environment.systemPackages = [ cfg.package ];

              # Enable PC/SC daemon for smart card support
              services.pcscd.enable = mkIf cfg.enableSmartCards true;

              # Install certificates for all active users during system activation (only once)
              system.activationScripts.ncalayer-install-certs = mkIf cfg.installCerts ''
                echo "Checking NCALayer certificate installation for active users..."
                for user_runtime in /run/user/*; do
                  if [ -d "$user_runtime" ]; then
                    uid=$(basename "$user_runtime")
                    username=$(${pkgs.coreutils}/bin/id -nu "$uid" 2>/dev/null || echo "")
                    if [ -n "$username" ]; then
                      home_dir=$(eval echo "~$username")
                      config_dir="$home_dir/.config/NCALayer"
                      marker_file="$config_dir/certs-installed"

                      if [ -n "$home_dir" ] && [ ! -f "$marker_file" ]; then
                        echo "  Installing certificates for user: $username (first time)"
                        if ${pkgs.su}/bin/su -l "$username" -c "${cfg.package}/bin/ncalayer-install-certs"; then
                          # Create config directory and marker file after successful installation
                          ${pkgs.coreutils}/bin/mkdir -p "$config_dir"
                          ${pkgs.coreutils}/bin/chown "$username" "$config_dir"
                          ${pkgs.coreutils}/bin/install -o "$username" -m 644 /dev/null "$marker_file"
                        fi
                      else
                        echo "  Certificates already installed for user: $username (skipping)"
                      fi
                    fi
                  fi
                done
              '';
            })

            # Cleanup NCALayer config directory when ncalayer is disabled to prevent system clutter
            (mkIf (!cfg.enable) {
              system.activationScripts.ncalayer-cleanup = ''
                echo "Cleaning up NCALayer configuration..."
                for user_home in /home/*; do
                  if [ -d "$user_home" ]; then
                    config_dir="$user_home/.config/NCALayer"
                    if [ -d "$config_dir" ]; then
                      username=$(basename "$user_home")
                      echo "  Removing configuration for user: $username"
                      rm -rf "$config_dir" 2>/dev/null || true
                    fi
                  fi
                done
              '';
            })
          ];
        };

      # Overlay
      overlays.default = final: prev: {
        ncalayer = mkNCALayer final;
      };
    };
}
