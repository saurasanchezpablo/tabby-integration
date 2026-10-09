# shellcheck shell=bash
# setup / uninstall: thin entry points to install.sh, which ships next to the
# CLI both in ~/.local/share/omarchy-tabby and in the Omarchy plugin folder.

cmd_setup() {
  [[ -f $OT_ROOT/install.sh ]] || die "install.sh is missing from $OT_ROOT"
  exec bash "$OT_ROOT/install.sh" "$@"
}

cmd_uninstall() {
  [[ -f $OT_ROOT/install.sh ]] || die "install.sh is missing from $OT_ROOT"
  exec bash "$OT_ROOT/install.sh" --uninstall "$@"
}
