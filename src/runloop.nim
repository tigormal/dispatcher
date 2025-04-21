import threading/once
import loghelp
import types, debug, timetag
import std/[monotimes, times, locks, sets, cpuinfo, options, macros, heapqueue]
import pkg/[cps]

proc isEmpty*(loop: RunLoop): bool {.inline.} =
  loop.tasks.len == 0 and loop.waiters.len == 0

proc state*(rl: RunLoop): LoopState =
  if rl.halt:
    result = Paused
  elif rl.isEmpty and rl.until >= getMonoTime():
    result = Finished
  else:
    result = Running
  if rl.mode == DispatchUnset:
    result = Crashed

proc repr(rl: RunLoop): string =
  "Rl." & dbgDModeName(rl.mode)

proc `$`*(rl: RunLoop): string =
  rl.repr & " state: " & $rl.state & "finishWaitTime: " & $rl.finishWaitTime &
    "runUntil: " & $rl.until & " tasks: " & $rl.tasks.len

proc newRunLoop*(mode = DispatchMain): RunLoop =
  result = RunLoop()
  result.lock = Lock()
  result.lock.initLock()
  result.tasks = @[]
  result.mode = mode

proc push*(loop: RunLoop, cont: Continuation, silent = false) {.inline.} =
  if not silent:
    debug loop.repr, " Pushing cont [Thread ", $getThreadId(), "]"
  loop.lock.acquire()
  loop.tasks.add(cont)
  loop.lock.release()

proc push*(loop: RunLoop, task: Task, silent = false) {.inline.} =
  if not silent:
    debug loop.repr, " Pushing task [Thread ", $getThreadId(), "]"
  task.rl = loop
  loop.push(cont = task, silent = true)

# proc suspend*(c: Continuation, rl: RunLoop) =
#   if c != nil:
#     rl.push(c)
#     c.running = false
proc trampoline*[T: Continuation](loop: RunLoop, c: sink T): T {.discardable.} =
  var c: Continuation = move c
  while not c.isNil and not c.fn.isNil and not loop.interrupt:
    try:
      var y = c.fn
      var x = y(c)
      c = x
    except CatchableError:
      if not c.dismissed:
        writeStackFrames c
      raise
  if loop.interrupt:
    info loop.repr, "Reset Interrupt Flag"
    loop.interrupt = false
  result = T c

proc interrupt*(loop: RunLoop, cont: sink Continuation) =
  debug loop.repr, "Replacing task [Thread ", $getThreadId(), "]"
  # loop.lock.acquire()
  if cont != nil:
    # FIXME
    loop.tasks.insert(cont, 0)
    # loop.interrupt = true

  # loop.lock.release()

proc processWaiters(loop: RunLoop) =
  ## Check if any waiters need to be executed
  ## Put the in the loop if needed
  withLock loop.lock:
    # debug loop.repr, "Processing waiters: " & $loop.waiters.len
    if loop.waiters.len == 0:
      return
    let w = loop.waiters[0]
    # if w.tag.time <= getMonoTime():
    if w.tag.time <= dispatcher.now:
      loop.interrupt(w.task) # interrupt or schedule Next
      loop.waiters.del(0)

proc processGeneral(loop: RunLoop) =
  ## Just take a task/cont from the queue and trampoline
  loop.currentTask = loop.tasks.pop
  loop.trampoline(loop.currentTask)

proc timerJobIteration(timerLoop: RunLoop) {.cps: Continuation.} =
  assert timerLoop.mode.contains(DispatchTimer)
  dispatcher.mainLoop.processWaiters()
  for th in dispatcher.threads:
    th.rl.processWaiters()

proc allDone*(disp: Dispatcher): bool =
  result = true
  for th in disp.threads:
    result = result and th.rl.state == Finished
  result = result and disp.mainLoop.state == Finished

proc run*(loop: RunLoop) =
  debug loop.repr, "run"
  if loop.mode == DispatchUnset:
    raise newException(ValueError, "RunLoop mode is not set")
  while getMonoTime() < loop.until:
    # Do timer stuff if needed
    if loop.mode.contains(DispatchTimer):
      if not dispatcher.allDone:
        #     loop.push(whelp loop.timerJobIteration(), silent=true)
        loop.timerJobIteration()

    # Check if done
    loop.lock.acquire()
    if loop.isEmpty:
      let doneTime = getMonoTime()
      info loop.repr, "Done at ", $doneTime
      loop.lock.release()
      while getMonoTime() < doneTime + loop.finishWaitTime:
        if not loop.isEmpty:
          info loop.repr, "Got something to do"
          loop.lock.acquire()
          break
      if getMonoTime() >= doneTime + loop.finishWaitTime:
        info loop.repr, "and finished"
        return
    debug loop.repr, "Trampolining task"
    loop.currentTask = loop.tasks.pop
    loop.lock.release()
    loop.trampoline(loop.currentTask)

proc repr*(rlth: RunLoopThread): string =
  result = "RlThread " & $rlth.id
  if rlth.th.running:
    result &= " ℝ"
  else:
    result &= " 𝕊"
  case rlth.rl.state
  of LoopState.Running:
    result &= "❯ "
  of LoopState.Paused:
    result &= "⧗ "
  of LoopState.Finished:
    result &= "✔︎ "
  of LoopState.Crashed:
    result &= "✘ "

proc newRunLoopThread*(rl: RunLoop): RunLoopThread =
  result = RunLoopThread()
  result.rl = rl
  debug "RlThread", "New for mode: ", dbgDModeName(rl.mode)

proc setId(t: RunLoopThread, id: int) =
  t.id = id

proc threadFunc*(t: RunLoopThread) {.thread.} =
  t.setId(getThreadId()) # FIXME: crashes if not in a proc
  debug t.repr, "Started"
  t.rl.run()
