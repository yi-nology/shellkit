#!/usr/bin/env bash
#
# 国际化。msgid 一律英文，译文进 locale/<lang>/LC_MESSAGES/shellkit.po。
# 找不到 gettext 时降级为原样输出 msgid（即英文），不失败。

if [ "${SHELLKIT_NO_GETTEXT:-0}" = "1" ]; then
  SK_GETTEXT=""
else
  SK_GETTEXT=$(command -v gettext 2>/dev/null) || SK_GETTEXT=""
fi
export SK_GETTEXT

# _t MSG
#
# gettext 把以 - 开头的参数当选项，所以 msgid 以短横开头时（像
# '--set expects KEY=VALUE'）必须在前面加一个 -- 让它停止解析选项。
# 只有真的要传短横开头时才加：多加会让 gettext 把 -- 当成 msgid 本身。
_t() {
  if [ -n "${SK_GETTEXT:-}" ]; then
    case "${1:-}" in
      -*) "$SK_GETTEXT" -- "$@" ;;
      *) "$SK_GETTEXT" "$@" ;;
    esac
  else
    printf '%s' "${1:-}"
  fi
}

# _tn SINGULAR PLURAL N
_tn() {
  if [ "${3:-0}" = "1" ]; then
    _t "$1"
    return 0
  fi
  # 复数文案也必须经过 gettext，否则 .po 里写了的译文永远用不上
  _t "${2:-}"
}
