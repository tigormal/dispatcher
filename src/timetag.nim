import types
import std/monotimes

proc initTimeTag*(time: MonoTime = low(MonoTime), step = 0): TimeTag =
  result = TimeTag()
  result.time = time
  result.step = step

proc inc*(tag: var TimeTag) =
  inc tag.step

proc `$`*(tag: TimeTag): string =
  $tag.time & "ˢ" & $tag.step

proc high(T: typedesc[TimeTag]): TimeTag =
  TimeTag(time: high(MonoTime), step: high(Natural))

converter toMonoTime*(tag: TimeTag): MonoTime =
  tag.time
