import types

func dbgDModeName*(x: DispatchMode): string =
  result = ""
  template bar() =
    if result.len > 0:
      result &= "|"

  if x.contains(DispatchMain):
    bar
    result &= "Main"
  if x.contains(DispatchParallel):
    bar
    result &= "Parallel"
  if x.contains(DispatchTimer):
    bar
    result &= "Timer"
  if result == "":
    result = "Unknown"
