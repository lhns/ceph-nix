{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ceph-nix-builder;
  user = "ceph-nix-runner";
  runnerNames = builtins.genList (i: "ceph-nix-${toString (i + 1)}") cfg.runner.count;

  # The runner user is trusted by the daemon if listed directly or via a group.
  trusted = config.nix.settings.trusted-users or [ ];
  isTrusted = lib.any (
    e:
    e == user
    || (lib.hasPrefix "@" e && lib.elem user (config.users.groups.${lib.removePrefix "@" e}.members or [ ]))
    || e == "@${user}"
  ) trusted;
in
{
  options.services.ceph-nix-builder = {
    enable = lib.mkEnableOption "ceph-nix builder: ephemeral GitHub runners and a signed Nix binary cache";

    runner = {
      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File with a fine-grained PAT (self-hosted runners read/write) or a registration token,
          one line, no trailing newline.
        '';
        example = "/run/secrets/ceph-nix-runner-token";
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/lhns/ceph-nix";
        description = "Repository or organization the runners register with.";
      };
      count = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "Number of ephemeral runner services.";
      };
    };

    cache = {
      signingKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Secret key for signing the cache, from `nix key generate-secret`.";
        example = "/var/lib/secrets/ceph-nix-cache-1.secret";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
        description = "TCP port harmonia listens on.";
      };
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open `cache.port` in the firewall.";
      };
    };

    gcRoots = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Store paths kept alive across garbage collection (e.g. released images).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !isTrusted;
        message = ''
          services.ceph-nix-builder: user "${user}" runs untrusted CI code and must not be in
          nix.settings.trusted-users.
        '';
      }
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      extraGroups = [ "kvm" ];
    };
    users.groups.${user} = { };

    services.github-runners = lib.genAttrs runnerNames (name: {
      enable = true;
      inherit (cfg.runner) url tokenFile;
      ephemeral = true;
      replace = true;
      extraLabels = [ "nix-builder" ];
      inherit user;
      group = user;
      extraPackages = with pkgs; [
        config.nix.package
        git
        gh
        zstd
      ];
      # /dev/kvm must be visible, and group membership must not be remapped away.
      serviceOverrides = {
        PrivateDevices = false;
        PrivateUsers = false;
      };
    });

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      system-features = [
        "nixos-test"
        "benchmark"
        "big-parallel"
        "kvm"
      ];
      sandbox = true;
      max-jobs = lib.mkDefault "auto";
      cores = lib.mkDefault 0;
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/ceph-nix 0755 root root -"
    ]
    ++ map (p: "L+ /nix/var/nix/gcroots/ceph-nix/${builtins.baseNameOf (toString p)} - - - - ${p}") cfg.gcRoots;

    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ cfg.cache.signingKeyFile ];
      settings.bind = "[::]:${toString cfg.cache.port}";
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.cache.openFirewall cfg.cache.port;
  };
}
