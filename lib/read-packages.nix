# Read a newline-separated package list and resolve each name to a package.
#
# The list file holds one attribute name per line. Blank lines are ignored,
# "#" starts a comment (whole-line or trailing), and dotted paths such as
# "kdePackages.konsole" are resolved through the attribute set.
#
# Used by home.nix (packages.txt) and configuration.nix (system-packages.txt).
# The `nix-addpkg` script appends to those files; this turns them into packages.
{ lib, pkgs, file }:

let
  lines = lib.splitString "\n" (builtins.readFile file);

  # Strip trailing comments and surrounding whitespace, drop what's left empty.
  names = lib.filter (s: s != "") (
    map (l: lib.trim (lib.head (lib.splitString "#" l))) lines
  );

  resolve = name:
    let path = lib.splitString "." name;
    in lib.attrByPath path
      (throw "read-packages: no such package '${name}' (from ${toString file})")
      pkgs;
in
map resolve names
