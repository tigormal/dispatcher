import std/[monotimes, times, locks, options, heapqueue]
import pkg/[cps]

type DispatchMode* = uint8

const
  DispatchUnset* = 0b0000.DispatchMode
  DispatchMain* = 0b0001.DispatchMode
  DispatchParallel* = 0b0010.DispatchMode
  DispatchTimer* = 0b0100.DispatchMode
  DispatchImmediate* = 0b1000.DispatchMode
    # Don't wait for the time tag to synchronize in all run loops

type
  Dispatcher* = ref object
    now*: TimeTag
    mainLoop*: RunLoop
    timerLoop*: RunLoop
    threads*: seq[RunLoopThread]
    maxThreads*: Positive = 1
    immediate*: bool = false

  LoopState* = enum
    Running
    Paused
    Finished
    Crashed

  RunLoopThread* = ref object
    rl*: RunLoop
    th*: Thread[RunLoopThread]
    id*: int = -1

  TimeTag* = object ## Superdense time
    time*: MonoTime
    step*: Natural

  Waiter* = object
    tag*: TimeTag
    task*: Task

  RunLoop* = ref object # can run without events (event loop) hence the name
    lock*: Lock
    tasks*: seq[Continuation]
      # we use common continuations as tasks' cancel/deadline/completion handlers might be those
    waiters*: HeapQueue[Waiter]
    mode*: DispatchMode = DispatchUnset
    until*: MonoTime = high(MonoTime)
    finishWaitTime*: Duration = initDuration(seconds = 1)
    halt*: bool = false
    interrupt*: bool = false
    currentTask*: Continuation
    nextTag*: TimeTag

  Task* = ref object of Continuation
    suspended*: Task
    deadline*: Option[TimeInterval]
    onCancel*: Continuation
    onDeadline*: Continuation
    onComplete*: Continuation
    dependsOn*: seq[Task]
    rl*: RunLoop

var dispatcher*: Dispatcher

func contains*(a, b: DispatchMode): bool {.inline.} =
  (a and b) == b

func `<`*(a, b: TimeTag): bool =
  a.time < b.time and a.step < b.step

func `<`*(a, b: Waiter): bool =
  a.tag < b.tag
