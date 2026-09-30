{
  description = "K230 Linux SDK build environment (replaces: sudo make toolchain_and_depend)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # =====================================================================
      # 1. The XuanTie toolchain
      #
      # install_toolchain_and_depend.sh downloads this into /opt/toolchain.
      # It is a prebuilt x86_64 glibc binary, so it needs
      # /lib64/ld-linux-x86-64.so.2 -- which is the reason this flake uses an
      # FHS environment instead of a plain devShell. Nothing is patchelf'd.
      #
      # The vendor tarball's top-level directory name is preserved, because
      # buildroot's defconfig hard-codes the full path:
      #   BR2_TOOLCHAIN_EXTERNAL_PATH="/opt/toolchain/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2/"
      #
      # =====================================================================

      gccFile = "Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2-20250410";
      gccDir = "Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2";

      xuantieToolchain = pkgs.stdenvNoCC.mkDerivation {
        pname = "xuantie-900-gcc-linux";
        version = "6.6.0-glibc-V3.0.2-20250410";

        src = pkgs.fetchurl {
          url = "https://download.kendryte.com/k230/downloads/dl/gcc/${gccFile}.tar.gz";
          hash = "sha256-IhXh/+G5uSd7H1ry9hEC6DlzFjQE8psE2nCX/a+p4bc=";
        };

        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true; # do NOT strip or patchelf; the FHS env supplies the loader

        installPhase = ''
          mkdir -p $out
          tar -xf $src -C $out
        '';
      };

   
      fakeSudo = pkgs.writeShellScriptBin "sudo" ''
        exec "$@"
      '';


      fakeAptGet = pkgs.writeShellScriptBin "apt-get" ''
        echo "[flake] ignoring: apt-get $*" >&2
        echo "[flake] (parted and curl are provided by flake.nix)" >&2
        exit 0
      '';

      # =====================================================================
      # Host dependencies
      #
      # install_dependes() apt-gets a list that relies on Debian pulling in
      # transitive -dev packages. Nix makes those explicit, so this list is
      # longer than the original. Grouped by why each is here.
      # =====================================================================
      sdkDeps = ps: with ps; [
        # ---- verbatim from install_dependes() ----------------------------
        git gnused gnumake binutils diffutils gcc bash patch gzip bzip2 perl
        gnutar cpio unzip rsync file bc findutils wget ncurses openssl gawk
        cmake bison flex bash-completion parted curl xz
        (python3.withPackages (pp: with pp; [ pcpp setuptools ]))

        # ---- headers Debian supplies transitively via build-essential ----
        glibc.dev # errno.h, stdio.h ... -> /usr/include; perl Errno_pm.PL needs it
        linuxHeaders # linux/*.h, asm/*.h
        libxcrypt # crypt.h, -lcrypt  -> host-mkpasswd
        ncurses.dev # menuconfig
        openssl.dev # kernel module signing, host tools
        zlib zlib.dev
        util-linux util-linux.dev # blkid.h, mount.h
        libuuid # uuid/uuid.h
        expat expat.dev
        libxml2 libxml2.dev
        glib glib.dev
        acl attr libcap
        gmp mpfr libmpc # anything host-gcc-adjacent
        readline

        # ---- kernel 6.6 build --------------------------------------------
        elfutils # libelf
        pahole # needed if CONFIG_DEBUG_INFO_BTF is set
        kmod
        ubootTools # mkimage
        dtc # device tree compiler
        openssl

        # ---- build systems buildroot packages use ------------------------
        autoconf automake libtool m4 pkg-config gettext
        meson ninja
        texinfo help2man gperf swig
        which coreutils

        # ---- utilities Debian marks Essential, so install_dependes()
        #      never had to name them ---------------------------------------
        gnugrep # grep was not in the apt list either: Essential on Debian
        hostname # post-build.sh calls it (target-finalize died on this)
        glibc.bin # ldd, locale, getconf
        getent # its own package in nixpkgs, not part of glibc.bin
        procps # ps, free
        iproute2 # ip
        nettools # ifconfig, route
        time
        psmisc # killall, fuser

        # ---- image assembly (distribution.sh, buildroot fs images) -------
        e2fsprogs # mkfs.ext4 -d
        dosfstools mtools
        squashfsTools genext2fs
        fakeroot
        fakeSudo
        fakeAptGet

        # ---- compression ------------------------------------------------
        zstd lz4 lzop p7zip zip
        gnupg # signature checks on some downloads

        # ---- Debian/Ubuntu rootfs step ----------------------------------
        debootstrap
        qemu-user # only needed by the debian_rootfs target, not by `debian`
        dpkg

        # ---- handy while debugging the build ----------------------------
        strace
      ];

      fhs = pkgs.buildFHSEnv {
        name = "k230-sdk";
        targetPkgs = sdkDeps;

        # Put the toolchain exactly where BR2_TOOLCHAIN_EXTERNAL_PATH points.
        # /opt inside the sandbox is a read-only store bind, so bwrap cannot
        # create a mountpoint under it -- shadow /opt with a writable tmpfs
        # first, then bind the toolchain into that. Order of args matters.
        extraBwrapArgs = [
          "--tmpfs" "/opt"
          "--ro-bind" "${xuantieToolchain}" "/opt/toolchain"
        ];

        profile = ''
          export K230_SDK_FHS=1
          export LC_ALL=C

          echo "k230-sdk FHS shell"
          echo "  toolchain : /opt/toolchain/${gccDir}"
          echo ""
          echo "  1. make CONF=k230_canmv_defconfig     # full build"
          echo "  2. unshare -rm make debian            # rootless Debian image"
          echo ""
          echo "  Do NOT run step 1 or 3 under unshare: buildroot refuses to run as root."
        '';

        runScript = "bash";
      };
    in
    {
      packages.${system} = {
        inherit xuantieToolchain;
        default = fhs;
      };

      devShells.${system}.default = fhs.env;
    };
}
