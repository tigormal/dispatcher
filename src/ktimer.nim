import std/[posix, times, monotimes, with, os, bitops]
import sys/private/syscall/bsd/kqueue
import sys/private/errors

# Constants for timer flags
const
  NSec* = 0x00000001.FilterFlag
  NMillisec* = 0x00000000.FilterFlag
  NMicrosec* = 0x00000002.FilterFlag
  NNanosec* = 0x00000004.FilterFlag
  NAbsolute* = 0x00000008.FilterFlag

type TimerImpl* = ref object
  st: byte ## State tracking byte
  kq: FD ## Kqueue file descriptor
  kevp: array[1, Kevent] ## Periodic timer KEvent
  kevo: array[1, Kevent] ## Oneshot timer KEvent
  checkProc: proc(t: var TimerImpl, timeout: Duration): bool ## Event check function

func getDurationResolution(d: Duration): (FilterFlag, FilterData) =
  ## Returns the lowest unit of time that can be represented by the given duration
  if d.inNanoseconds mod 1000 == 0:
    if d.inMicroseconds mod 1000 == 0:
      if d.inMilliseconds mod 1000 == 0:
        result = (NSec, d.inSeconds.FilterData)
      else:
        result = (NMillisec, d.inMilliseconds.FilterData)
    else:
      result = (NMicrosec, d.inMicroseconds.FilterData)
  else:
    result = (NNanosec, d.inNanoseconds.FilterData)
  debugEcho result

proc `$`*(kev: Kevent): string =
  ## Convert `kev` into a string
  result =
    "Kevent(ident: " & $kev.ident.int & ", filter: " & $kev.filter.int & ", flags: " &
    $kev.flags.int & ", fflags: " & $kev.fflags & ", data: " & $kev.data & ", udata: " &
    $kev.udata.int & ")"

template durFromKevent(x: untyped) {.dirty.} =
  case x.fflags and 0x00000001
  of NSec:
    result = initDuration(seconds = x.data)
  of NMillisec:
    result = initDuration(milliseconds = x.data)
  of NMicrosec:
    result = initDuration(microseconds = x.data)
  of NNanosec:
    result = initDuration(nanoseconds = x.data)
  else:
    result = DurationZero

func period*(t: TimerImpl): Duration =
  ## Get the period of the timer
  durFromKevent t.kevp[0]

func offset*(t: TimerImpl): Duration =
  ## Get the offset or oneshot of the timer
  durFromKevent t.kevo[0]

# === Timer state flags ===
# for clarity hence inline procs
# 0bXXXX_XXX0: Unintitialized (not added to kqueue)
# 0bXXXX_XXX1: Intitialized (added to kqueue)
# 0bXXXX_XX1X: Oneshot Kevent added and enabled
# 0bXXXX_X1XX: Offset reached
# 0bXXXX_1XXX: Periodic timer started
proc didInit(t: TimerImpl): bool {.inline.} =
  t.st.testBit(0)

proc `didInit=`(t: TimerImpl, val: bool) {.inline.} =
  if val:
    t.st.setBit(0)
  else:
    t.st.clearBit(0)

proc didReachOffset(t: TimerImpl): bool {.inline.} =
  t.st.testBit(2)

proc `didReachOffset=`(t: TimerImpl, val: bool) {.inline.} =
  if val:
    t.st.setBit(2)
  else:
    t.st.clearBit(2)

proc `didStartPeriodic=`(t: TimerImpl, val: bool) {.inline.} =
  if val:
    t.st.setBit(3)
  else:
    t.st.clearBit(3)

proc didStartPeriodic*(t: TimerImpl): bool {.inline.} =
  t.st.testBit(3)

proc didStartOneshot(t: TimerImpl): bool {.inline.} =
  t.st.testBit(1)

proc `didStartOneshot=`(t: TimerImpl, val: bool) {.inline.} =
  if val:
    t.st.setBit(1)
  else:
    t.st.clearBit(1)

proc hasOneshot(t: TimerImpl): bool {.inline.} =
  t.kevo[0].data > 0

proc hasPeriodic(t: TimerImpl): bool {.inline.} =
  t.kevp[0].data > 0

# ===============

func toTimespec(d: Duration): Timespec =
  ## Convert a Duration to Timespec
  Timespec(
    tv_sec: posix.Time(d.inSeconds),
    tv_nsec: int(d.inNanoseconds - convert(Seconds, Nanoseconds, d.inSeconds)),
  )

template startTimer(t: var TimerImpl, kev: typed, name: untyped): untyped =
  var ret: cint
  ret = t.kq.kevent(changeList = kev)
  posixChk ret, "Failed to enable timer (" & name & ")"
  # Clear EvAdd flag as it has been added to the queue
  # kev[0].flags = kev[0].flags and not EvAdd
  debugEcho "Timer enabled (", name, "): ", ret

proc enable*(t: var TimerImpl) =
  ## Enable the timer, depending on offset and oneshot
  if (t.hasOneshot and not t.didReachOffset) or not t.hasPeriodic:
    startTimer(t, t.kevo, "oneshot")
    t.didStartOneshot = true
  else:
    startTimer(t, t.kevp, "periodic")
    t.didStartPeriodic = true

template modifyTimer(t: TimerImpl, flag: typed, errMsg: string): untyped =
  var tempEvent: array[1, KEvent]
  if t.hasOneshot: # Check if oneshot or offset
    tempEvent = t.kevo
  else:
    tempEvent = t.kevp
  tempEvent[0].flags = tempEvent[0].flags or flag
  let ret = t.kq.kevent(changeList = tempEvent)
  posixChk ret, errMsg

proc pause*(t: var TimerImpl) =
  ## Temporarily disable the timer without removing it from the queue
  modifyTimer t, EvDisable, "Failed to pause timer"

proc disable*(t: var TimerImpl) =
  ## Remove the timer from the queue
  modifyTimer t, EvDelete, "Failed to stop timer"

proc checkPeriod(t: var TimerImpl, timeout: Duration = DurationZero): bool =
  # stdout.write "p "
  let ret = t.kq.kevent(eventList = t.kevp, timeout = timeout.toTimespec)
  posixChk ret, "Failed to check timer"
  result = ret > 0

proc checkOneshot(t: var TimerImpl, timeout: Duration = DurationZero): bool =
  # stdout.write "o "
  if not t.didReachOffset:
    # stdout.write "-"
    let ret = t.kq.kevent(eventList = t.kevo, timeout = timeout.toTimespec)
    posixChk ret, "Failed to check timer"
    result = ret > 0
    if result:
      # stdout.write "+"
      t.didReachOffset = true
      if t.hasPeriodic:
        t.checkProc = checkPeriod
        startTimer(t, t.kevp, "periodic")

proc check*(t: var TimerImpl, timeout: Duration = DurationZero): bool {.inline.} =
  t.checkProc(t, timeout)

proc check*(t: var TimerImpl, timeout: TimeInterval): bool {.inline.} =
  check(
    t,
    initDuration(
      timeout.nanoseconds, timeout.microseconds, timeout.milliseconds, timeout.seconds,
      timeout.minutes, timeout.hours, timeout.days, timeout.weeks,
    ),
  )

proc init(
    t: TimerImpl,
    p: Duration = DurationZero,
    offset: Duration = DurationZero,
    oneshot: bool = false,
) =
  debugEcho "Initializing timer... Oneshot: ", oneshot
  if p != DurationZero:
    debugEcho "Setting period of ", p
    let (pFlag, pTime) = getDurationResolution(p)
    t.kevp = [KEvent()]
    with t.kevp[0]:
      ident = 1.Ident # TODO: Change to retrieve available id from Event Queue
      filter = FilterTimer
      flags = EvAdd or EvEnable
      fflags = pFlag
      data = pTime
      udata = 0.UserData
    t.checkProc = checkPeriod
  if offset != DurationZero or oneshot:
    debugEcho "Setting oneshot/offset of ", offset
    let (oFlag, oTime) = getDurationResolution(offset)
    t.kevo = [KEvent()]
    with t.kevo[0]:
      ident = 1.Ident # TODO: Change to retrieve available id from Event Queue
      filter = FilterTimer
      flags = EvAdd or EvEnable or EvOneshot
      fflags = oFlag
      data = oTime
      udata = 0.UserData
    t.checkProc = checkOneshot
  debugEcho t.kevp[0], " ", t.kevo[0]

proc init*(t: TimerImpl, p: TimeInterval, offset: TimeInterval = 0.seconds) =
  ## Initialize the timer with a period and offset
  init(
    t,
    initDuration(
      p.nanoseconds, p.microseconds, p.milliseconds, p.seconds, p.minutes, p.hours,
      p.days, p.weeks,
    ),
    initDuration(
      offset.nanoseconds, offset.microseconds, offset.milliseconds, offset.seconds,
      offset.minutes, offset.hours, offset.days, offset.weeks,
    ),
    false,
  )

proc init*(t: TimerImpl, p: TimeInterval, oneshot: bool) =
  ## Initialize the timer with a period and optionally flag it as oneshot
  init(
    t,
    DurationZero,
    initDuration(
      p.nanoseconds, p.microseconds, p.milliseconds, p.seconds, p.minutes, p.hours,
      p.days, p.weeks,
    ),
    oneshot,
  )

proc main() =
  let kq = kqueue()
  var timer1 = new TimerImpl
  var timer2 = new TimerImpl
  var timer3 = new TimerImpl
  timer1.kq = kq
  timer2.kq = kq
  timer3.kq = kq
  timer1.init(1.seconds)
  timer2.init(200.milliseconds, oneshot = true)
  timer3.init(5000.milliseconds, offset = 2.seconds)

  timer1.enable()
  for i in 0 .. 4:
    echo "Waiting for timer1..."
    while not timer1.check():
      discard
    echo "Timer fired!"
  timer2.enable()
  for i in 0 .. 0:
    echo "Waiting for timer2..."
    while not timer2.check():
      discard
    echo "Timer fired!"

  timer3.enable()
  for i in 0 .. 2:
    debugEcho getMonoTime(), " Waiting for timer3..."
    while not timer3.check():
      discard
    debugEcho getMonoTime(), " Timer fired! Pausing..."
    timer3.pause()
    var i = 0
    while i < 3:
      sleep(1000)
      inc i
      debugEcho i
    debugEcho getMonoTime(), " Resuming..."
    timer3.enable()

  timer1.disable()
  kq.close()

when isMainModule:
  main()
