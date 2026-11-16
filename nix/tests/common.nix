# Pieces shared by the VM tests of the ceph image and the cephadm host.
{ pkgs }:
let
  # The pinned Umbrella release, from the one place CI and the VM tests share: image, tag and the multi-arch digest.
  pins = builtins.fromJSON (builtins.readFile ../../tests/upstream-images.json);
  m = builtins.match "([^:@]+(:[0-9]+)?/[^:@]+):([^@]+)@(sha256:[0-9a-f]{64})" pins.umbrella.ref;
  imageInfo =
    if m == null then
      throw "tests/upstream-images.json: umbrella.ref is not image:tag@sha256:..."
    else
      {
        image = builtins.elemAt m 0;
        tag = builtins.elemAt m 2;
        digest = builtins.elemAt m 3;
      };
in
{
  inherit imageInfo;

  # A strictly v2 CPU: qemu's host model minus everything x86-64-v3 adds (AVX/AVX2/AVX512, BMI1/2, FMA, F16C, MOVBE,
  # LZCNT, which qemu calls abm). glibc checks these for its x86-64-v3 code paths.
  maskedCpu = "host,-avx,-avx2,-bmi1,-bmi2,-fma,-f16c,-avx512f,-movbe,-abm";

  # A streamed image as a file for `podman load -i`. The stream script tars tens of thousands of small files from the
  # VM's 9p store, which took over an hour for the Umbrella image; reading one big file is fast. It costs the image's
  # size in the store, so the Tentacle tests on CI runners keep streaming.
  imageTar = image: pkgs.runCommand "${image.name}.tar" { } "${image} > $out";

  # docker-archive of the pinned upstream release (needs a v3 CPU).
  upstreamImage = pkgs.dockerTools.pullImage {
    imageName = imageInfo.image;
    imageDigest = imageInfo.digest;
    # fixed-output hash of the amd64 pull; nixPullHash beside the ref in tests/upstream-images.json
    hash = pins.umbrella.nixPullHash;
    finalImageName = imageInfo.image;
    finalImageTag = imageInfo.tag;
    os = "linux";
    arch = "amd64";
  };
}
