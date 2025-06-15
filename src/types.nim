import std/[monotimes, times, locks, options, heapqueue, tables]
import pkg/[cps]
import sys/private/ioqueue_bsd {.all.}
import sys/private/syscall/bsd/kqueue
import timer

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

  Sleeper* = object
    tag*: TimeTag
    task*: Task

  RunLoop* = ref object # can run without events (event loop) hence the name
    lock*: Lock
    tasks*: seq[Task] # every common Continuation will be turned into Task
    sleepers*: HeapQueue[Sleeper]
    waiters*: Table[FD, Waiter]
    timers*: seq[Timer] # only for the timer loop
    mode*: DispatchMode = DispatchUnset
    until*: MonoTime = high(MonoTime)
    finishWaitTime*: Duration = initDuration(seconds = 1)
    halt*: bool = false
    interrupt*: bool = false
    nextTag*: TimeTag
    when defined(bsd):
      kq*: FD
      lastId*: int # kqueue event id

  Task* = ref object of Continuation
    suspended*: Task # TODO: what is this used for?
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

func `<`*(a, b: Sleeper): bool =
  a.tag < b.tag
