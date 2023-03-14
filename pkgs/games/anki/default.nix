{ lib
, stdenv
, buildEnv
, fetchFromGitHub
, fetchYarnDeps
, fixup_yarn_lock
, installShellFiles
, lame
, mpv-unwrapped
, ninja
, nodejs
, nodejs-slim
, protobuf
, python3
, qt6
, rsync
, rustPlatform
, writeShellScriptBin
, yarn
, CoreAudio
}:

let
  pname = "anki";
  version = "2.1.60";
  rev = "76d8807315fcc2675e7fa44d9ddf3d4608efc487";

  src = fetchFromGitHub {
    owner = "ankitects";
    repo = "anki";
    rev = version;
    hash = "sha256-hNrf6asxF7r7QK2XO150yiRjyHAYKN8OFCFYX0SAiwA=";
    fetchSubmodules = true;
  };


  cargoDeps = rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "csv-1.1.6" = "sha256-w728ffOVkI+IfK6FbmkGhr0CjuyqgJnPB1kutMJIUYg=";
      "linkcheck-0.4.1-alpha.0" = "sha256-Fiom8oHW9y7vV2RLXW0ClzHOdIlBq3Z9jLP+p6Sk4GI=";
    };
  };

  anki-build-python = python3.withPackages (ps: with ps; [
    pip
    mypy-protobuf
  ]);

  # anki shells out to git to check its revision, and also to update submodules
  # We don't actually need the submodules, so we stub that out
  fakeGit = writeShellScriptBin "git" ''
    case "$*" in
      "rev-parse --short=8 HEAD")
        echo ${builtins.substring 0 8 rev}
      ;;
      *"submodule update "*)
        exit 0
      ;;
      *)
        echo "Unrecognized git: $@"
        exit 1
      ;;
    esac
  '';

  # We don't want to run pip-sync, it does network-io
  fakePipSync = writeShellScriptBin "pip-sync" ''
    exit 0
  '';

  offlineYarn = writeShellScriptBin "yarn" ''
    [[ "$1" == "install" ]] && exit 0
    exec ${yarn}/bin/yarn --offline "$@"
  '';

  pyEnv = buildEnv {
    name = "anki-pyenv-${version}";
    paths = with python3.pkgs; [
      pip
      fakePipSync
      anki-build-python
    ];
    pathsToLink = [ "/bin" ];
  };

  yarnOfflineCache = fetchYarnDeps {
    yarnLock = "${src}/yarn.lock";
    hash = "sha256-bAtmMGWi5ETIidFFnG3jzJg2mSBnH5ONO2/Lr9A3PpQ=";
  };

  # https://discourse.nixos.org/t/mkyarnpackage-lockfile-has-incorrect-entry/21586/3
  anki-nodemodules = stdenv.mkDerivation {
    pname = "anki-nodemodules";
    inherit version src yarnOfflineCache;

    nativeBuildInputs = [
      fixup_yarn_lock
      yarn
      nodejs-slim
    ];

    configurePhase = ''
      export HOME=$NIX_BUILD_TOP
      yarn config --offline set yarn-offline-mirror $yarnOfflineCache
      fixup_yarn_lock yarn.lock
      yarn install --offline --frozen-lockfile --ignore-scripts --no-progress --non-interactive
      patchShebangs node_modules/
      yarn run postinstall --offline
    '';

    installPhase = ''
      mv node_modules $out
    '';
  };
in
python3.pkgs.buildPythonApplication {
  inherit pname version src;

  outputs = [ "out" "doc" "man" ];

  patches = [
    ./patches/gl-fixup.patch
    ./patches/no-update-check.patch
    # Upstreamed in https://github.com/ankitects/anki/pull/2446
    # We can drop these once we update to an anki version that includes them
    # already
    ./patches/0001-Don-t-download-nodejs-if-NODE_BINARY-is-set.patch
    ./patches/0002-Allow-setting-YARN_BINARY-for-the-build-system.patch
    # Not upstreamed
    ./patches/0003-Skip-formatting-python-code.patch
  ];

  inherit cargoDeps;

  nativeBuildInputs = [
    fakeGit
    fixup_yarn_lock
    offlineYarn

    installShellFiles
    rustPlatform.rust.cargo
    rustPlatform.cargoSetupHook
    ninja
    qt6.wrapQtAppsHook
    rsync
  ];
  nativeCheckInputs = with python3.pkgs; [ pytest mock astroid  ];

  buildInputs = [
    qt6.qtbase
  ];
  propagatedBuildInputs = with python3.pkgs; [
    # This rather long list came from running:
    #    grep --no-filename -oE "^[^ =]*" python/{requirements.base.txt,requirements.bundle.txt,requirements.qt6_4.txt} | \
    #      sort | uniq | grep -v "^#$"
    # in their repo at the git tag for this version
    # There's probably a more elegant way, but the above extracted all the
    # names, without version numbers, of their python dependencies. The hope is
    # that nixpkgs versions are "close enough"
    # I then removed the ones the check phase failed on (pythonCatchConflictsPhase)
    beautifulsoup4
    certifi
    charset-normalizer
    click
    colorama
    decorator
    distro
    flask
    flask-cors
    idna
    importlib-metadata
    itsdangerous
    jinja2
    jsonschema
    markdown
    markupsafe
    orjson
    pep517
    python3.pkgs.protobuf
    pyparsing
    pyqt6
    pyqt6-sip
    pyqt6-webengine
    pyrsistent
    pysocks
    requests
    send2trash
    six
    soupsieve
    urllib3
    waitress
    werkzeug
    zipp
  ] ++ lib.optionals stdenv.isDarwin [ CoreAudio ];

  # Activate optimizations
  RELEASE = true;

  PROTOC_BINARY = lib.getExe protobuf;
  NODE_BINARY = lib.getExe nodejs;
  YARN_BINARY = lib.getExe offlineYarn;
  PYTHON_BINARY = lib.getExe python3;

  inherit yarnOfflineCache;
  dontUseNinjaInstall = false;

  buildPhase = ''
    export RUST_BACKTRACE=1
    export RUST_LOG=debug

    mkdir -p out/pylib/anki \
             .git

    echo ${builtins.substring 0 8 rev} > out/buildhash
    touch out/env
    touch .git/HEAD

    ln -vsf ${pyEnv} ./out/pyenv
    ln -vsf ${pyEnv} ./out/pyenv-qt5
    rsync --chmod +w -avP ${anki-nodemodules}/ out/node_modules/
    ln -vsf out/node_modules node_modules

    export HOME=$NIX_BUILD_TOP
    yarn config --offline set yarn-offline-mirror $yarnOfflineCache
    fixup_yarn_lock yarn.lock

    patchShebangs ./ninja
    PIP_USER=1 ./ninja build wheels
  '';

  # tests fail with to many open files
  # TODO: verify if this is still true (I can't, no mac)
  doCheck = !stdenv.isDarwin;
  # mimic https://github.com/ankitects/anki/blob/76d8807315fcc2675e7fa44d9ddf3d4608efc487/build/ninja_gen/src/python.rs#L232-L250
  checkPhase = ''
    HOME=$TMP ANKI_TEST_MODE=1 PYTHONPATH=$PYTHONPATH:$PWD/out/pylib \
      pytest -p no:cacheprovider pylib/tests
    HOME=$TMP ANKI_TEST_MODE=1 PYTHONPATH=$PYTHONPATH:$PWD/out/pylib:$PWD/pylib:$PWD/out/qt \
      pytest -p no:cacheprovider qt/tests
  '';

  preInstall = ''
    mkdir dist
    mv out/wheels/* dist
  '';

  postInstall = ''
    install -D -t $out/share/applications qt/bundle/lin/anki.desktop
    install -D -t $doc/share/doc/anki README* LICENSE*
    install -D -t $out/share/mime/packages qt/bundle/lin/anki.xml
    install -D -t $out/share/pixmaps qt/bundle/lin/anki.{png,xpm}
    installManPage qt/bundle/lin/anki.1
  '';

  dontWrapQtApps = true;
  preFixup = ''
    makeWrapperArgs+=(
      "''${qtWrapperArgs[@]}"
      --prefix PATH ':' "${lame}/bin:${mpv-unwrapped}/bin"
    )
  '';

  meta = with lib; {
    homepage = "https://apps.ankiweb.net/";
    description = "Spaced repetition flashcard program";
    longDescription = ''
      Anki is a program which makes remembering things easy. Because it is a lot
      more efficient than traditional study methods, you can either greatly
      decrease your time spent studying, or greatly increase the amount you learn.

      Anyone who needs to remember things in their daily life can benefit from
      Anki. Since it is content-agnostic and supports images, audio, videos and
      scientific markup (via LaTeX), the possibilities are endless. For example:
      learning a language, studying for medical and law exams, memorizing
      people's names and faces, brushing up on geography, mastering long poems,
      or even practicing guitar chords!
    '';
    license = licenses.agpl3Plus;
    platforms = platforms.mesaPlatforms;
    maintainers = with maintainers; [ oxij Profpatsch euank ];
  };
}
