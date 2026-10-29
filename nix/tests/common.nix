# Pieces shared by the VM tests of the ceph image and the cephadm host.
{ pkgs }:
let
  imageInfo = builtins.fromJSON (builtins.readFile ../ceph-image.json);
in
{
  inherit imageInfo;

  # A v2-only CPU: qemu's host model minus what x86-64-v3 needs (glibc checks AVX2, BMI1/2, FMA, F16C ...).
  maskedCpu = "host,-avx2,-bmi1,-bmi2,-fma,-f16c,-avx512f";

  # docker-archive of the pinned upstream release (needs a v3 CPU).
  upstreamImage = pkgs.dockerTools.pullImage {
    imageName = imageInfo.image;
    imageDigest = imageInfo.digest;
    # fixed-output hash of the amd64 pull; update together with ceph-image.json
    hash = "sha256-l/1Eyay6CUxLYkj1NBFPGxHQh278U4w63csVZB3IQwM=";
    finalImageName = imageInfo.image;
    finalImageTag = imageInfo.tag;
    os = "linux";
    arch = "amd64";
  };
}
