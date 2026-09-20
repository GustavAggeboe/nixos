{
  alsa-lib,
  autoPatchelfHook,
  fetchurl,
  fontconfig,
  freetype,
  lib,
  libgcc,
  stdenvNoCC,
  unzip,

  installStandalone ? true,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "locd";
  version = "1.0.5";

  src = fetchurl {
    url = "https://api.crql.works/download/locd/linux/${finalAttrs.version}";
    sha256 = "sha256-nO4LRZTgd9gEordswjeI3C4u2Lfv/xl4Cpaq0+in/MY=";

    # Will not fetch zipfile properly unless setting user agent.
    curlOpts = "-A Mozilla/5.0";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    unzip
  ];

  buildInputs = [
    alsa-lib
    fontconfig
    freetype
    libgcc.lib
  ];

  unpackPhase = ''
    unzip $src
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp -r CLAP $out/lib/clap
    cp -r VST3 $out/lib/vst3
  ''
  + lib.optionalString installStandalone ''
    mkdir -p $out/bin
    cp -r Standalone/* $out/bin/
  '';

  meta = {
    description = "Phase-Locked distortion plugin for MEGA crunchiness.";
    homepage = "https://crql.works/locd/";
    license = lib.licenses.unfreeRedistributable;
  }
  // lib.optionalAttrs installStandalone {
    mainProgram = "LOCD";
  };
})
