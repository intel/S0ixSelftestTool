{ pkgs ? import <nixpkgs> {} }:
  pkgs.mkShell {
    nativeBuildInputs = [
      pkgs.acpica-tools
      pkgs.linuxPackages.turbostat
      pkgs.xxd
      pkgs.powertop
      pkgs.gawk
    ];
  }
