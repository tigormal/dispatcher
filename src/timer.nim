## Timer dirty interface.
import std/[posix, times, monotimes, with, os, bitops, strformat]

# when defined(bsd):
#   import platform/bsd/ktimer
when defined(linux):
  import platform/linux/etimer
else:
  {.
    warning:
      "This module has not been ported to your operating system. Using fallback generic timer"
  .}
  import platform/generic/ctimer
type Timer* = TimerImpl

proc check*(t: var Timer): bool =
  checkImpl

proc enable*(t: var Timer) =
  enableImpl

proc disable*(t: var Timer) =
  disableImpl

proc pause*(t: var Timer) =
  pauseImpl

proc init*(t: Timer, period: TimeInterval, offset: TimeInterval = 0.seconds) =
  initWithOffsetImpl

proc init*(t: Timer, period: TimeInterval, oneshot: bool) =
  initImpl

func period*(t: Timer): Duration =
  periodImpl

func offset*(t: Timer): Duration =
  offsetImpl

proc signal*(t: Timer) =
  signalImpl

proc `$`*(t: Timer): string =
  fmt"Timer<P: {$t.period} , O: {$t.offset} at {cast[int](addr t)}>"
