import threading/once
import loghelp
import types, debug, timetag, timer
import std/[monotimes, times, locks, tables, sets, cpuinfo, options, macros, heapqueue]
import pkg/[cps]

proc isEmpty*(loop: RunLoop): bool {.inline.} =
  loop.tasks.len == 0 and loop.waiters.len == 0 and loop.sleepers.len == 0 and
    loop.timers.len == 0

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

proc addTimer*(timerLoop: var RunLoop, timer: Timer) =
  ## Add a timer to the run loop
  assert timerLoop.mode.contains(DispatchTimer)
  if timerLoop.timers.len > 0:
    # Signal the existing timer to stop waiting
    let waitingTimer = timerLoop.timers[0]
    waitingTimer.signal()
  timerLoop.timers.add(timer)

proc push*(loop: RunLoop, cont: Continuation, silent = false) {.inline.} =
  if not silent:
    debug loop.repr, " Pushing cont [Thread ", $getThreadId(), "]"
  loop.lock.acquire()
  loop.tasks.add(Task cont)
  loop.lock.release()

proc push*(loop: RunLoop, task: Task, silent = false) {.inline.} =
  if not silent:
    debug loop.repr, " Pushing task [Thread ", $getThreadId(), "]"
  task.rl = loop
  # Create a timer if task has a deadline
  if task.deadline.isSome:
    debugEcho "Task has deadline: ", $task.deadline
    if loop.mode.contains(DispatchMain):
      # Main loop creates Sleepers instead
      var sleeper = Sleeper()
      sleeper.task = task
      sleeper.tag = TimeTag(currentMonoTime() + task.deadline.get, 0)
      loop.sleepers.add(sleeper)
      loop.push(cont = task, silent = true)
      return
    var deadlineTimer = new Timer
    deadlineTimer.init(task.deadline.get, oneshot = true)
    deadlineTimer.task = Task task.onDeadline
    deadlineTimer.task.rl = loop
    # FIXME: set the timer ID
    loop.push(cont = task, silent = true)
    dispatcher.timerLoop.addTimer(deadlineTimer) # Timer is added already enabled
  else:
    # Add the task to the end of the queue
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

proc interruptWith*(loop: RunLoop, cont: sink Continuation) =
  ## Interrupt the run loop with a continuation
  debug loop.repr, "Replacing task [Thread ", $getThreadId(), "]"
  # loop.lock.acquire()
  if cont != nil:
    # FIXME
    loop.tasks.insert(Task cont, 0)
    loop.interrupt = true
  # loop.lock.release()
  #

proc interruptWith*(loop: RunLoop, task: sink Task) =
  ## Interrupt the run loop with a continuation
  debug loop.repr, "Replacing task [Thread ", $getThreadId(), "]"
  # loop.lock.acquire()
  if task != nil:
    # FIXME
    loop.tasks.insert(task, 0)
    loop.interrupt = true
  # loop.lock.release()

proc processSleepers(loop: RunLoop) =
  ## Check if any sleepers need to be executed
  ## Put the in the loop if needed
  withLock loop.lock:
    # debug loop.repr, "Processing waiters: " & $loop.waiters.len
    if loop.sleepers.len == 0:
      return
    let sleeper = loop.sleepers[0]
    # if waiter.tag.time <= getMonoTime():
    if sleeper.tag.time <= dispatcher.now:
      loop.interruptWith(sleeper.task) # interrupt or schedule Next
      loop.sleepers.del(0)

proc processGeneral(loop: RunLoop) =
  ## Just take a task/cont from the queue and trampoline
  loop.trampoline(loop.tasks.pop)

proc processTimers(timerLoop: RunLoop) =
  ## Process timers (single iteration)
  assert timerLoop.mode.contains(DispatchTimer)
  # dispatcher.mainLoop.processSleepers()
  # for th in dispatcher.threads:
  #   th.rl.processSleepers()
  var timer = timerLoop.timers[0]
  # Wait for the timer to fire
  if timer.check():
    # Trampoline the continuation
    timer.task.rl.interruptWith(timer.task)

proc allDone*(disp: Dispatcher): bool =
  ## Check if all run loops in the dispatcher are done
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
        #     loop.push(whelp loop.processTimers(), silent=true)
        loop.processTimers()

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
    let currentTask = loop.tasks.pop()
    loop.lock.release()
    loop.trampoline(currentTask)

#
# === RunLoopThread ===
#
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

proc setId(th: RunLoopThread, id: int) =
  th.id = id

proc threadFunc*(th: RunLoopThread) {.thread.} =
  th.setId(getThreadId()) # FIXME: crashes if not in a proc
  debug th.repr, "Started"
  th.rl.run()
