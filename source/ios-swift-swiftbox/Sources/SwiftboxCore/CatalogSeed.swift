import Foundation

/// Built-in catalog seed.
///
/// Two sources feed the default catalog:
///
/// 1. **Termux-derived recipes** — authored in the upstream `build.sh` format
///    using each package's real upstream metadata (version, homepage, license,
///    dependencies, source URL, checksum). These represent the porting backlog;
///    the host backend reports them `deferred` until they are cross-built /
///    ported for the iOS sandbox. Point ``PackageCatalog/ingestTermuxPackages``
///    at a full `termux-packages` clone to aggregate the complete set.
///
/// 2. **swiftbox-native recipes** — `interpreted` packages that ship pure
///    script/data/config artifacts and therefore build on any host today. These
///    prove the build → stage → install pipeline end to end.
public enum CatalogSeed {

    /// Real-metadata Termux recipes (a curated cross-section of the backlog).
    public static let termuxRecipes: [(name: String, script: String)] = [
        ("cowsay", """
        TERMUX_PKG_HOMEPAGE=https://cowsay.diamonds/
        TERMUX_PKG_DESCRIPTION="Program which generates ASCII pictures of a cow with a message"
        TERMUX_PKG_LICENSE="GPL-2.0"
        TERMUX_PKG_VERSION="3.8.4"
        TERMUX_PKG_SRCURL=https://github.com/cowsay-org/cowsay/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz
        TERMUX_PKG_SHA256=c15bc10712835d3a9bcda780dc9453362567bf48d1185905dc7ef2334d79aadd
        TERMUX_PKG_DEPENDS="perl"
        TERMUX_PKG_PLATFORM_INDEPENDENT=true
        """),
        ("figlet", """
        TERMUX_PKG_HOMEPAGE=http://www.figlet.org/
        TERMUX_PKG_DESCRIPTION="Program for making large letters out of ordinary text"
        TERMUX_PKG_LICENSE="BSD 3-Clause"
        TERMUX_PKG_VERSION=2.2.5
        TERMUX_PKG_REVISION=3
        TERMUX_PKG_SRCURL=ftp://ftp.figlet.org/pub/figlet/program/unix/figlet-${TERMUX_PKG_VERSION}.tar.gz
        TERMUX_PKG_SHA256=bf88c40fd0f077dab2712f54f8d39ac952e4e9f2e1882f1195be9e5e4257417d
        """),
        ("tree", """
        TERMUX_PKG_HOMEPAGE=http://mama.indstate.edu/users/ice/tree/
        TERMUX_PKG_DESCRIPTION="Recursive directory lister producing a depth indented listing of files"
        TERMUX_PKG_LICENSE="GPL-2.0"
        TERMUX_PKG_VERSION="2.3.2"
        TERMUX_PKG_DEPENDS="libandroid-support"
        TERMUX_PKG_BUILD_IN_SRC=true
        """),
        ("nano", """
        TERMUX_PKG_HOMEPAGE=https://www.nano-editor.org/
        TERMUX_PKG_DESCRIPTION="Small, friendly text editor inspired by Pico"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="8.2"
        TERMUX_PKG_DEPENDS="ncurses, libiconv"
        """),
        ("less", """
        TERMUX_PKG_HOMEPAGE=https://www.greenwoodsoftware.com/less/
        TERMUX_PKG_DESCRIPTION="Terminal pager program used to view the contents of a text file"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="668"
        TERMUX_PKG_DEPENDS="ncurses, libandroid-support"
        """),
        ("grep", """
        TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/grep/
        TERMUX_PKG_DESCRIPTION="Command which searches one or more input files for lines matching a pattern"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="3.11"
        TERMUX_PKG_DEPENDS="pcre2"
        """),
        ("jq", """
        TERMUX_PKG_HOMEPAGE=https://stedolan.github.io/jq/
        TERMUX_PKG_DESCRIPTION="Command-line JSON processor"
        TERMUX_PKG_LICENSE="MIT"
        TERMUX_PKG_VERSION="1.7.1"
        TERMUX_PKG_DEPENDS="oniguruma"
        """),
        ("git", """
        TERMUX_PKG_HOMEPAGE=https://git-scm.com/
        TERMUX_PKG_DESCRIPTION="Distributed version control system"
        TERMUX_PKG_LICENSE="GPL-2.0"
        TERMUX_PKG_VERSION="2.47.1"
        TERMUX_PKG_DEPENDS="curl, libcurl, pcre2, openssl, zlib"
        """),
        ("python", """
        TERMUX_PKG_HOMEPAGE=https://www.python.org/
        TERMUX_PKG_DESCRIPTION="Python programming language interpreter"
        TERMUX_PKG_LICENSE="PSF-2.0"
        TERMUX_PKG_VERSION="3.12.7"
        TERMUX_PKG_DEPENDS="libandroid-support, openssl, libffi, zlib, ncurses"
        """),
        ("perl", """
        TERMUX_PKG_HOMEPAGE=https://www.perl.org/
        TERMUX_PKG_DESCRIPTION="Larry Wall's Practical Extraction and Report Language"
        TERMUX_PKG_LICENSE="GPL-1.0, Artistic-1.0-Perl"
        TERMUX_PKG_VERSION="5.40.0"
        TERMUX_PKG_DEPENDS="libcrypt"
        """),
        ("busybox", """
        TERMUX_PKG_HOMEPAGE=https://busybox.net/
        TERMUX_PKG_DESCRIPTION="Tiny versions of many common UNIX utilities in a single small executable"
        TERMUX_PKG_LICENSE="GPL-2.0"
        TERMUX_PKG_VERSION="1.36.1"
        TERMUX_PKG_DEPENDS="libandroid-support"
        """),
        ("bash", """
        TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/bash/
        TERMUX_PKG_DESCRIPTION="Bourne Again SHell"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="5.2.37"
        TERMUX_PKG_DEPENDS="ncurses, libandroid-support, command-not-found"
        """),
        ("zsh", """
        TERMUX_PKG_HOMEPAGE=https://www.zsh.org/
        TERMUX_PKG_DESCRIPTION="UNIX shell with many improvements over Bourne shell"
        TERMUX_PKG_LICENSE="custom (MIT-like)"
        TERMUX_PKG_VERSION="5.9"
        TERMUX_PKG_DEPENDS="ncurses, libandroid-support, pcre2"
        """),
        ("vim", """
        TERMUX_PKG_HOMEPAGE=https://www.vim.org/
        TERMUX_PKG_DESCRIPTION="Vi IMproved - highly configurable, improved version of the vi text editor"
        TERMUX_PKG_LICENSE="custom (Vim License)"
        TERMUX_PKG_VERSION="9.1.0866"
        TERMUX_PKG_DEPENDS="ncurses, vim-runtime"
        """),
        ("neovim", """
        TERMUX_PKG_HOMEPAGE=https://neovim.io/
        TERMUX_PKG_DESCRIPTION="Ambitious Vim-fork focused on extensibility and usability"
        TERMUX_PKG_LICENSE="Apache-2.0, Vim"
        TERMUX_PKG_VERSION="0.10.2"
        TERMUX_PKG_DEPENDS="libandroid-support, libiconv, libluv, libmsgpack, libtermkey, libtree-sitter, libuv, libvterm, luajit, unibilium"
        """),
        ("tmux", """
        TERMUX_PKG_HOMEPAGE=https://tmux.github.io/
        TERMUX_PKG_DESCRIPTION="Terminal multiplexer"
        TERMUX_PKG_LICENSE="ISC"
        TERMUX_PKG_VERSION="3.5a"
        TERMUX_PKG_DEPENDS="libevent, ncurses, libandroid-support"
        """),
        ("htop", """
        TERMUX_PKG_HOMEPAGE=https://htop.dev/
        TERMUX_PKG_DESCRIPTION="Interactive process viewer"
        TERMUX_PKG_LICENSE="GPL-2.0"
        TERMUX_PKG_VERSION="3.3.0"
        TERMUX_PKG_DEPENDS="ncurses, libandroid-support"
        """),
        ("curl", """
        TERMUX_PKG_HOMEPAGE=https://curl.se/
        TERMUX_PKG_DESCRIPTION="Tool and library for transferring data with URL syntax"
        TERMUX_PKG_LICENSE="MIT"
        TERMUX_PKG_VERSION="8.11.0"
        TERMUX_PKG_DEPENDS="libcurl"
        """),
        ("wget", """
        TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/wget/
        TERMUX_PKG_DESCRIPTION="Network utility to retrieve files from the Web"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="1.25.0"
        TERMUX_PKG_DEPENDS="libandroid-support, libidn2, openssl, pcre2"
        """),
        ("openssh", """
        TERMUX_PKG_HOMEPAGE=https://www.openssh.com/
        TERMUX_PKG_DESCRIPTION="Connectivity tools for remote login with the SSH protocol"
        TERMUX_PKG_LICENSE="BSD"
        TERMUX_PKG_VERSION="9.9p1"
        TERMUX_PKG_DEPENDS="openssl, libandroid-support, ncurses, krb5, zlib, ldns"
        """),
        ("openssl", """
        TERMUX_PKG_HOMEPAGE=https://www.openssl.org/
        TERMUX_PKG_DESCRIPTION="Toolkit for the Transport Layer Security (TLS) protocols"
        TERMUX_PKG_LICENSE="Apache-2.0"
        TERMUX_PKG_VERSION="3.4.0"
        """),
        ("sqlite", """
        TERMUX_PKG_HOMEPAGE=https://sqlite.org/
        TERMUX_PKG_DESCRIPTION="Small, fast, self-contained, high-reliability, full-featured SQL database engine"
        TERMUX_PKG_LICENSE="public domain"
        TERMUX_PKG_VERSION="3.47.1"
        TERMUX_PKG_DEPENDS="ncurses, readline, libandroid-support"
        """),
        ("ncurses", """
        TERMUX_PKG_HOMEPAGE=https://invisible-island.net/ncurses/
        TERMUX_PKG_DESCRIPTION="Library for text-based user interfaces in a terminal-independent manner"
        TERMUX_PKG_LICENSE="MIT"
        TERMUX_PKG_VERSION="6.5"
        """),
        ("nodejs", """
        TERMUX_PKG_HOMEPAGE=https://nodejs.org/
        TERMUX_PKG_DESCRIPTION="Open Source, cross-platform JavaScript runtime environment"
        TERMUX_PKG_LICENSE="MIT, BSD, Artistic-2.0, ISC, Apache-2.0, X11"
        TERMUX_PKG_VERSION="23.3.0"
        TERMUX_PKG_DEPENDS="libc++, libicu, openssl, c-ares, libuv, zlib"
        """),
        ("clang", """
        TERMUX_PKG_HOMEPAGE=https://llvm.org/
        TERMUX_PKG_DESCRIPTION="C, C++, OpenCL, and Objective-C compiler frontend for the LLVM compiler"
        TERMUX_PKG_LICENSE="Apache-2.0, NCSA"
        TERMUX_PKG_VERSION="19.1.4"
        TERMUX_PKG_DEPENDS="libllvm, libc++, ndk-sysroot, liblzma"
        """),
        ("make", """
        TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/make/
        TERMUX_PKG_DESCRIPTION="Tool which controls the generation of executables and other non-source files"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="4.4.1"
        TERMUX_PKG_DEPENDS="libandroid-support"
        """),
        ("ripgrep", """
        TERMUX_PKG_HOMEPAGE=https://github.com/BurntSushi/ripgrep
        TERMUX_PKG_DESCRIPTION="Line-oriented search tool that recursively searches the current directory for a regex pattern"
        TERMUX_PKG_LICENSE="MIT, Unlicense"
        TERMUX_PKG_VERSION="14.1.1"
        """),
        ("fzf", """
        TERMUX_PKG_HOMEPAGE=https://github.com/junegunn/fzf
        TERMUX_PKG_DESCRIPTION="Command-line fuzzy finder"
        TERMUX_PKG_LICENSE="MIT"
        TERMUX_PKG_VERSION="0.56.3"
        """),
        ("tar", """
        TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/tar/
        TERMUX_PKG_DESCRIPTION="GNU tool to create and manipulate tar archives"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="1.35"
        TERMUX_PKG_DEPENDS="libandroid-support, libacl, liblzma, bzip2, libxz"
        """),
        ("gzip", """
        TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/gzip/
        TERMUX_PKG_DESCRIPTION="GNU compression utility (LZ77)"
        TERMUX_PKG_LICENSE="GPL-3.0"
        TERMUX_PKG_VERSION="1.13"
        TERMUX_PKG_DEPENDS="libandroid-support"
        """),
        ("openssl-tool", """
        TERMUX_PKG_HOMEPAGE=https://www.openssl.org/
        TERMUX_PKG_DESCRIPTION="The openssl command-line binary tool"
        TERMUX_PKG_LICENSE="Apache-2.0"
        TERMUX_PKG_VERSION="3.4.0"
        TERMUX_PKG_DEPENDS="openssl"
        """),
    ]

    /// swiftbox-native interpreted packages — built and staged on any host now.
    public static func nativeRecipes() -> [BuildRecipe] {
        [
            BuildRecipe(
                metadata: RecipeMetadata(
                    name: "swiftbox-base-files",
                    version: SemanticVersion(0, 1, 0),
                    rawVersion: "0.1.0",
                    summary: "Base filesystem layout, motd and login profile",
                    license: "GPL-3.0-or-later",
                    platformIndependent: true
                ),
                kind: .interpreted,
                artifacts: [
                    BuildArtifact(
                        path: "etc/motd",
                        contents: "Welcome to swiftbox - a Termux-style environment for the iOS sandbox.\nType 'help' for builtins, 'pkg catalog' to browse packages.\n"
                    ),
                    BuildArtifact(
                        path: "etc/profile",
                        contents: "# swiftbox login profile\nexport PS1='$ '\nexport EDITOR=ed\n"
                    ),
                ],
                origin: "swiftbox-native"
            ),
            BuildRecipe(
                metadata: RecipeMetadata(
                    name: "swiftbox-aliases",
                    version: SemanticVersion(0, 1, 0),
                    rawVersion: "0.1.0",
                    summary: "Common shell aliases shipped as a config fragment",
                    license: "GPL-3.0-or-later",
                    dependencies: ["swiftbox-base-files"],
                    platformIndependent: true
                ),
                kind: .interpreted,
                artifacts: [
                    BuildArtifact(
                        path: "etc/profile.d/aliases.sh",
                        contents: "alias ll='ls -l'\nalias la='ls -a'\nalias ..='cd ..'\n"
                    ),
                ],
                origin: "swiftbox-native"
            ),
            // A scripted build: the package's files are produced by build steps
            // run through the interpreter, not declared statically. This is the
            // swiftbox analogue of a Termux recipe with `termux_step_*` functions.
            BuildRecipe(
                metadata: RecipeMetadata(
                    name: "swiftbox-hello",
                    version: SemanticVersion(0, 1, 0),
                    rawVersion: "0.1.0",
                    summary: "A tiny scripted-build example that installs a greeter",
                    license: "GPL-3.0-or-later",
                    dependencies: ["swiftbox-base-files"],
                    platformIndependent: true
                ),
                kind: .interpreted,
                buildSteps: [
                    "mkdir -p $PREFIX/bin",
                    "write $BUILD_DIR/hello.txt building $PKG_NAME $PKG_VERSION",
                    "echo echo \"hello from swiftbox\" > $PREFIX/bin/hello",
                ],
                origin: "swiftbox-native"
            ),
            // The editor family. These are real, installable utilities backed by
            // the interpreted EdEditor engine, so `pkg install ed` / `pkg install
            // vi` deliver a working editor in the simulation today. (Full-screen
            // visual `vim`/`neovim` remain in the porting backlog as native ports.)
            BuildRecipe(
                metadata: RecipeMetadata(
                    name: "ed",
                    version: SemanticVersion(1, 22, 5),
                    rawVersion: "1.22.5",
                    summary: "Classic UNIX line editor (interpreted EdEditor engine)",
                    license: "GPL-3.0-or-later",
                    platformIndependent: true
                ),
                kind: .interpreted,
                artifacts: [
                    BuildArtifact(
                        path: "share/doc/ed/README",
                        contents: "ed - the standard line editor. Commands are read from stdin:\n  printf 'a\\nhello\\n.\\nw\\nq\\n' | ed notes.txt\n"
                    ),
                ],
                origin: "swiftbox-native"
            ),
            BuildRecipe(
                metadata: RecipeMetadata(
                    name: "vi",
                    version: SemanticVersion(1, 0, 0),
                    rawVersion: "1.0.0",
                    summary: "POSIX ex/vi line editor (interpreted; visual mode pending)",
                    license: "GPL-3.0-or-later",
                    dependencies: ["ed"],
                    platformIndependent: true
                ),
                kind: .interpreted,
                artifacts: [
                    BuildArtifact(
                        path: "share/doc/vi/README",
                        contents: "vi/ex - line (ex) mode editor. Run startup commands and edit files:\n  vi -c '%s/foo/bar/g' -c 'wq' notes.txt\n"
                    ),
                    BuildArtifact(
                        path: "etc/virc",
                        contents: "\" swiftbox default ex/vi config\nset autoindent\n"
                    ),
                ],
                origin: "swiftbox-native"
            ),
        ]
    }

    /// Build the default catalog: native recipes plus the Termux seed.
    public static func makeDefaultCatalog() -> PackageCatalog {
        let catalog = PackageCatalog()
        for recipe in nativeRecipes() { catalog.add(recipe) }
        for entry in termuxRecipes {
            _ = try? catalog.ingest(buildScript: entry.script, name: entry.name)
        }
        return catalog
    }
}
