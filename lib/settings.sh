# shellcheck shell=bash
# settings.json: validated against tabby-omarchy/lib/settings-schema.json, the
# single source of truth shared with the Tabby plugin and the bar widget.

# Effective settings (defaults + valid stored values) as JSON.
settings_json() {
  local stored='{}'
  if [[ -f $OT_SETTINGS ]]; then
    stored="$(jq -c 'if type == "object" then . else {} end' "$OT_SETTINGS" 2>/dev/null || echo '{}')"
  fi
  jq -c --argjson stored "$stored" '
    to_entries | map(
      .key as $k | .value as $spec | $stored[$k] as $v |
      { key: $k, value: (
          if $spec.type == "boolean" and ($v | type) == "boolean" then $v
          elif $spec.type == "enum" and ($v | type) == "string" and ($spec.options | index($v)) then $v
          else $spec.default end) }
    ) | from_entries' "$OT_SCHEMA"
}

setting() {
  settings_json | jq -r --arg k "$1" '.[$k] | if . == null then empty else tostring end'
}

# settings_set KEY VALUE (VALUE as text: true/false or an enum option)
settings_set() {
  local key="$1" raw="$2" spec value current
  spec="$(jq -c --arg k "$key" '.[$k] // empty' "$OT_SCHEMA")"
  [[ -n $spec ]] || die "unknown setting '$key' (see: omarchy-tabby settings list)"
  case "$(jq -r .type <<<"$spec")" in
  boolean)
    case "$raw" in
    true | on | yes | 1) value=true ;;
    false | off | no | 0) value=false ;;
    *) die "$key expects true or false" ;;
    esac
    ;;
  enum)
    jq -e --arg v "$raw" '.options | index($v)' <<<"$spec" >/dev/null ||
      die "$key expects one of: $(jq -r '.options | join(", ")' <<<"$spec")"
    value="$(jq -n --arg v "$raw" '$v')"
    ;;
  esac

  mkdir -p -- "$OT_CONFIG_DIR" || die "cannot create $OT_CONFIG_DIR"
  (
    flock -w 5 9 || die "settings are locked"
    current='{}'
    if [[ -f $OT_SETTINGS ]]; then
      current="$(jq -c 'if type == "object" then . else {} end' "$OT_SETTINGS" 2>/dev/null || echo '{}')"
    fi
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' <<<"$current" | write_atomic "$OT_SETTINGS" 644
  ) 9>"$OT_CONFIG_DIR/.settings.lock"
}

settings_toggle() {
  local key="$1" type
  type="$(jq -r --arg k "$key" '.[$k].type // empty' "$OT_SCHEMA")"
  [[ $type == boolean ]] || die "$key is not a boolean setting"
  if [[ "$(setting "$key")" == true ]]; then
    settings_set "$key" false
  else
    settings_set "$key" true
  fi
}

cmd_settings() {
  local sub="${1:-list}"
  shift || true
  case "$sub" in
  list)
    if [[ ${1:-} == --json ]]; then
      jq -c --argjson s "$(settings_json)" 'to_entries | map(.value + {key: .key, value: $s[.key]})' "$OT_SCHEMA"
    else
      settings_json | jq -r 'to_entries[] | "\(.key)\t\(.value)"'
    fi
    ;;
  get)
    [[ $# -eq 1 ]] || die "usage: omarchy-tabby settings get KEY"
    jq -e --arg k "$1" 'has($k)' "$OT_SCHEMA" >/dev/null || die "unknown setting '$1'"
    setting "$1"
    ;;
  set)
    [[ $# -eq 2 ]] || die "usage: omarchy-tabby settings set KEY VALUE"
    settings_set "$1" "$2"
    ;;
  toggle)
    [[ $# -eq 1 ]] || die "usage: omarchy-tabby settings toggle KEY"
    settings_toggle "$1"
    ;;
  reset)
    rm -f -- "$OT_SETTINGS"
    ;;
  *) die "usage: omarchy-tabby settings [list [--json] | get KEY | set KEY VALUE | toggle KEY | reset]" ;;
  esac
}
