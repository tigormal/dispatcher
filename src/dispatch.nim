import threading/once
import loghelp
import types, runloop, debug, task, timetag
import std/[monotimes, times, locks, cpuinfo, options, macros, heapqueue, os]
import pkg/[cps]
import fusion/[matching, astdsl]

var didInitDispatcher = createOnce()

proc init*(
    T: typedesc[Dispatcher], maxThreads = countProcessors(), timerThread = DispatchMain
) =
  once(didInitDispatcher):
    debug "Dispatcher",
      "Init, maxThreads: ", maxThreads, " timerThread: ", dbgDModeName(timerThread)
    dispatcher = Dispatcher()
    dispatcher.maxThreads = maxThreads
    case timerThread
    of DispatchMain:
      dispatcher.mainLoop = newRunLoop(mode = DispatchMain or DispatchTimer)
      dispatcher.timerLoop = dispatcher.mainLoop # same ref
    of DispatchTimer:
      dispatcher.mainLoop = newRunLoop(mode = DispatchMain)
      dispatcher.timerLoop = newRunLoop(mode = DispatchTimer)
      dispatcher.threads.add(newRunLoopThread(rl = dispatcher.timerLoop))
    else:
      raise newException(ValueError, "Invalid watchdogThread value")

Dispatcher.init(timerThread = DispatchTimer)

proc getMostFreeThread(): Option[RunLoopThread] =
  if dispatcher.threads.len == 0:
    return none(RunLoopThread)
  var minTasks = dispatcher.threads[0].rl.tasks.len
  var minThread = dispatcher.threads[0]
  for t in dispatcher.threads:
    # skip timer thread
    if t.rl.mode.contains(DispatchTimer):
      continue
    if t.rl.tasks.len < minTasks:
      minTasks = t.rl.tasks.len
      minThread = t
  # don't return timer thread
  if minThread.rl.mode.contains(DispatchTimer):
    result = some minThread
  else:
    result = none(RunLoopThread)

proc scheduleNext*(task: Task, mode = DispatchMain, overrideTimeout = none(Duration)) =
  ## Schedules the task for execution one step later.
  var nextNow = dispatcher.now
  inc nextNow
  case mode
  of DispatchMain:
    dispatcher.mainLoop.waiters.push(Waiter(tag: nextNow, task: task))
  of DispatchParallel:
    # Parallel loops are always created on a separate thread
    # if no Parallel loops were created, create a new thread
    # if all threads are busy, inject continuation into the least busy thread
    # if a new thread cannot be created, inject continuation into the main thread run loop
    let canCreateThread = dispatcher.threads.len < dispatcher.maxThreads - 1
      # we don't count main thread
    var mostFreeTh = getMostFreeThread()
    if canCreateThread:
      # TODO: add persistent thread creation (not finish upon all tasks completion)
      var t = newRunLoopThread(newRunLoop(mode = DispatchParallel))
      t.rl.waiters.push(Waiter(tag: nextNow, task: task))
      createThread(t.th, threadFunc, t)
      dispatcher.threads.add t
    else:
      if mostFreeTh.isSome:
        mostFreeTh.get.rl.waiters.push(Waiter(tag: nextNow, task: task))
      else:
        dispatcher.mainLoop.waiters.push(Waiter(tag: nextNow, task: task))
  of DispatchTimer:
    raise newException(ValueError, "DispatchTimer mode is not supported yet")
  else:
    raise newException(ValueError, "Unknown mode value")

proc scheduleTask*(task: Task, mode = DispatchMain, overrideTimeout = none(Duration)) =
  # TODO: make this use `macrocache.CacheTable` with templates to
  # generate this if-else block in a modular way. This would allow
  # to support custom DispatchMode values and dispatch behaviour.
  case mode
  of DispatchMain:
    dispatcher.mainLoop.push task
  of DispatchParallel:
    # Parallel loops are always created on a separate thread
    # if no Parallel loops were created, create a new thread
    # if all threads are busy, inject continuation into the least busy thread
    # if a new thread cannot be created, inject continuation into the main thread run loop
    let canCreateThread = dispatcher.threads.len < dispatcher.maxThreads - 1
      # we don't count main thread
    var mostFreeTh = getMostFreeThread()
    if canCreateThread:
      # TODO: add persistent thread creation (not finish upon all tasks completion)
      var t = newRunLoopThread(newRunLoop(mode = DispatchParallel))
      t.rl.push task
      createThread(t.th, threadFunc, t)
      dispatcher.threads.add t
    else:
      if mostFreeTh.isSome:
        mostFreeTh.get.rl.push task
      else:
        dispatcher.mainLoop.push task
  of DispatchTimer:
    raise newException(ValueError, "DispatchTimer mode is not supported yet")
  else:
    raise newException(ValueError, "Unknown mode value")

proc updateTime*() =
  var result = dispatcher.now
  for th in dispatcher.threads:
    result = min(result, th.rl.currentTag)
      # TODO: check if this is correct. Isn't it max?
  result = min(result, dispatcher.mainLoop.currentTag)

proc start*(T: type Dispatcher, mode = DispatchUnset) =
  when mode.contains(DispatchAsync):
    dispatcher.immediate = true
    info "Dispatcher", "Starting in async mode"
  else:
    info "Dispatcher", "Starting in sync mode"
  dispatcher.now = initTimeTag(getMonoTime(), 0)
  # check if timer thread needs to be created
  if dispatcher.timerLoop != dispatcher.mainLoop:
    createThread(dispatcher.threads[0].th, threadFunc, dispatcher.threads[0])
  dispatcher.mainLoop.run()
  # Finish threads
  debug "Dispatcher", "Finishing " & $len(dispatcher.threads) & " threads"
  for rlth in dispatcher.threads:
    debug "Dispatcher", "--> ", rlth.repr
    if rlth.th.running:
      rlth.th.joinThread()
  info "Dispatcher", "Finished"

template schedule*(mode: DispatchMode, code: untyped): untyped =
  proc sched() {.gensym, task.} =
    # FIXME: this folds the proc body into another stmtlist, it probably can be avoided, but works for now
    code

  scheduleTask(asTask sched(), mode)

template schedule*(code: untyped): untyped =
  schedule(DispatchMain, code)

when isMainModule:
  # proc testProc2() {.task.} =
  #   echo "TEST2 CALLED"
  #   echo "beep boop"
  #   echo "TEST2 END"

  # proc testProc1(a: string) {.task.} =
  #   echo "TEST1 CALLED"
  #   echo a
  #   echo "TEST1 END"
  #   scheduleTask(asTask testProc2(), mode=DispatchParallel)

  # scheduleTask asTask testProc1("meh")

  # schedule(DispatchParallel):
  #   {.deadline: 1.seconds.}:
  #     echo "oops! cancelled"
  #   echo "Hello 1"
  var flag = false
  schedule:
    # echo "Entering loop"
    # while true:
    #   if flag:
    #     echo "Got flag, breaking"
    #     break
    #   jield() # TODO: check if yielding is done automatically
    # var i = 0
    # while i < 5:
    #   inc i
    echo "Hello again: ", dispatcher.now
    #   jield()
    #   os.sleep(200)

  schedule:
    echo "Hello before sleep: ", dispatcher.now
    sleep(initDuration(seconds = 1))
    flag = true
    echo "Hello after sleep: ", dispatcher.now

  Dispatcher.start()
