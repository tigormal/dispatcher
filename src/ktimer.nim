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

type
  PipeSignal = object
    readFd: cint ## Read end of the signal pipe
    writeFd: cint ## Write end of the signal pipe
    ident: Ident ## Identifier for the pipe event

  TimerImpl* = ref object
    st: byte ## State tracking byte
    kq: FD ## Kqueue file descriptor
    kevp: array[2, Kevent] ## Periodic timer KEvent and pipe event
    kevo: array[2, Kevent] ## Oneshot timer KEvent and pipe event
    pipe: PipeSignal ## Signal pipe for inter-thread communication
    checkProc: proc(t: var TimerImpl, timeout: Duration): bool ## Event check function
    isBlocking: bool ## Whether the timer is in blocking mode

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

proc `==`(a, b: Filter): bool {.borrow.}

proc hasOneshot(t: TimerImpl): bool {.inline.} =
  (t.kevo[0].data > 0) and (t.kevo[0].filter == FilterTimer)

proc hasPeriodic(t: TimerImpl): bool {.inline.} =
  (t.kevp[0].data > 0) and (t.kevp[0].filter == FilterTimer)

# ===============

func toTimespec(d: Duration): Timespec =
  ## Convert a Duration to Timespec
  Timespec(
    tv_sec: posix.Time(d.inSeconds),
    tv_nsec: int(d.inNanoseconds - convert(Seconds, Nanoseconds, d.inSeconds)),
  )

template startTimer(t: var TimerImpl, kev: typed, name: untyped): untyped =
  var tempEvent: array[1, KEvent]
  tempEvent[0] = kev[0] # Copy only the timer event, not the pipe event
  var ret: cint
  ret = t.kq.kevent(changeList = tempEvent)
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
    tempEvent[0] = t.kevo[0] # Copy only the timer event, not the pipe event
  else:
    tempEvent[0] = t.kevp[0] # Copy only the timer event, not the pipe event
  tempEvent[0].flags = tempEvent[0].flags or flag
  let ret = t.kq.kevent(changeList = tempEvent)
  posixChk ret, errMsg

proc pause*(t: var TimerImpl) =
  ## Temporarily disable the timer without removing it from the queue
  modifyTimer t, EvDisable, "Failed to pause timer"

proc disable*(t: var TimerImpl) =
  ## Remove the timer from the queue
  modifyTimer t, EvDelete, "Failed to stop timer"

# TODO: Change timeout to Option[Duration]. None would call a blocking wait
proc checkPeriod(t: var TimerImpl, timeout: Duration = DurationZero): bool =
  # stdout.write "p "
  var timeoutSpec: Timespec
  var pTimeoutSpec: ptr Timespec = nil

  if not t.isBlocking:
    # Use the provided timeout for non-blocking mode
    timeoutSpec = timeout.toTimespec
    pTimeoutSpec = addr timeoutSpec
  # For blocking mode, pTimeoutSpec remains nil which will block indefinitely

  # Make a local event list - we'll need to modify it
  var eventList = t.kevp
  # Reset the pipe event to watch for new events
  eventList[1].flags = eventList[1].flags or EvClear

  let ret = t.kq.kevent(eventList = eventList, timeout = pTimeoutSpec)
  posixChk ret, "Failed to check timer"

  if ret > 0:
    # Check if we received a pipe signal
    for i in 0 ..< ret:
      if eventList[i].filter == FilterRead and eventList[i].ident == t.pipe.ident:
        # Drain the pipe
        var buf: array[1, char]
        discard posix.read(t.pipe.readFd, addr buf[0], 1)
        return false

      # Check if we got a timer event
      if eventList[i].filter == FilterTimer:
        return true

  return false

proc checkOneshot(t: var TimerImpl, timeout: Duration = DurationZero): bool =
  # stdout.write "o "
  if not t.didReachOffset:
    # stdout.write "-"
    var timeoutSpec: Timespec
    var pTimeoutSpec: ptr Timespec = nil

    if not t.isBlocking:
      # Use the provided timeout for non-blocking mode
      timeoutSpec = timeout.toTimespec
      pTimeoutSpec = addr timeoutSpec
    # For blocking mode, pTimeoutSpec remains nil which will block indefinitely

    # Make a local event list - we'll need to modify it
    var eventList = t.kevo
    # Reset the pipe event to watch for new events
    eventList[1].flags = eventList[1].flags or EvClear

    let ret = t.kq.kevent(eventList = eventList, timeout = pTimeoutSpec)
    posixChk ret, "Failed to check timer"

    if ret > 0:
      # Check if we received a pipe signal
      for i in 0 ..< ret:
        if eventList[i].filter == FilterRead and eventList[i].ident == t.pipe.ident:
          # Drain the pipe
          var buf: array[1, char]
          discard posix.read(t.pipe.readFd, addr buf[0], 1)
          return false

        # Check if we got a timer event
        if eventList[i].filter == FilterTimer:
          t.didReachOffset = true
          if t.hasPeriodic:
            t.checkProc = checkPeriod
            startTimer(t, t.kevp, "periodic")
          return true

    return false
  return false

proc check*(t: var TimerImpl, timeout: Duration = DurationZero): bool {.inline.} =
  # If in blocking mode, timeouts are ignored by the checkProc functions
  t.checkProc(t, timeout)

proc setBlocking*(t: var TimerImpl, blocking: bool) =
  ## Set the timer to blocking mode (wait indefinitely until signal or timer)
  ## or non-blocking mode (wait only for the specified timeout)
  ##
  ## In blocking mode, the timeout passed to check() is ignored and the kqueue
  ## call will use NULL for the timeout parameter, causing it to block until
  ## an event occurs.
  t.isBlocking = blocking

proc check*(t: var TimerImpl, timeout: TimeInterval): bool {.inline.} =
  check(
    t,
    initDuration(
      timeout.nanoseconds, timeout.microseconds, timeout.milliseconds, timeout.seconds,
      timeout.minutes, timeout.hours, timeout.days, timeout.weeks,
    ),
  )

proc createSignalPipe(t: TimerImpl) =
  ## Create a pipe that can be used for signaling between threads
  var fds: array[2, cint]

  # Create the pipe
  if posix.pipe(fds) != 0:
    raiseOSError(osLastError(), "Failed to create pipe")

  # Set non-blocking mode for read end
  var flags = fcntl(fds[0], F_GETFL, 0)
  discard fcntl(fds[0], F_SETFL, flags or O_NONBLOCK)

  # Store the file descriptors
  t.pipe.readFd = fds[0]
  t.pipe.writeFd = fds[1]
  t.pipe.ident = t.pipe.readFd.Ident

  # Setup the pipe event for both kevp and kevo
  # For kevp
  t.kevp[1].ident = t.pipe.ident # Use read end of pipe as identifier
  t.kevp[1].filter = FilterRead # Monitor for read events
  t.kevp[1].flags = EvAdd or EvEnable or EvClear
  t.kevp[1].fflags = 0.FilterFlag
  t.kevp[1].data = 0.FilterData
  t.kevp[1].udata = 0.UserData

  # For kevo
  t.kevo[1].ident = t.pipe.ident # Use read end of pipe as identifier
  t.kevo[1].filter = FilterRead # Monitor for read events
  t.kevo[1].flags = EvAdd or EvEnable or EvClear
  t.kevo[1].fflags = 0.FilterFlag
  t.kevo[1].data = 0.FilterData
  t.kevo[1].udata = 0.UserData

  # Add the pipe event to kqueue
  var pipeEvent: array[1, Kevent]
  pipeEvent[0] = t.kevp[1]
  let ret = t.kq.kevent(changeList = pipeEvent)
  posixChk ret, "Failed to add pipe event to kqueue"

  # Don't need to add the pipe event to the queue twice, since they share the same descriptor
  # Just make sure both kevp and kevo have the pipe event in the second position
  t.kevo[1] = t.kevp[1]

  debugEcho "Signal pipe initialized: ", t.kevp[1]

proc init(
    t: TimerImpl,
    p: Duration = DurationZero,
    offset: Duration = DurationZero,
    oneshot: bool = false,
) =
  debugEcho "Initializing timer... Oneshot: ", oneshot

  # Initialize arrays to zero - important for clean state
  t.kevp = [Kevent(), Kevent()]
  t.kevo = [Kevent(), Kevent()]

  # Initialize state
  t.isBlocking = false
  t.st = 0
  t.pipe = PipeSignal() # Initialize pipe structure

  # Create the signal pipe
  createSignalPipe(t)

  if p != DurationZero:
    debugEcho "Setting period of ", p
    let (pFlag, pTime) = getDurationResolution(p)
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

proc signal*(t: TimerImpl) =
  ## Signal the timer via the pipe, which will unblock any blocking check() call
  var buf: array[1, char] = ['X']
  let writeResult = posix.write(t.pipe.writeFd, addr buf[0], 1)
  if writeResult != 1:
    var errStr = "Failed to signal timer: "
    if writeResult < 0:
      errStr.add($(osLastError().int))
    else:
      errStr.add("wrote only " & $writeResult & " bytes")
    debugEcho errStr

proc close*(t: var TimerImpl) =
  ## Close the timer's resources
  if t.pipe.readFd != 0:
    discard posix.close(t.pipe.readFd)
    t.pipe.readFd = 0

  if t.pipe.writeFd != 0:
    discard posix.close(t.pipe.writeFd)
    t.pipe.writeFd = 0

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

  # Example with blocking mode
  timer1.setBlocking(true)
  timer1.enable()

  # Simulate a thread that signals after 500ms
  proc signalThread() {.thread.} =
    sleep(500)
    echo "Signaling timer1..."
    timer1.signal()

  var signalT: Thread[void]
  createThread(signalT, signalThread)

  echo "Waiting for timer1 (blocking)..."
  # In blocking mode this will wait indefinitely (timeout is ignored) until
  # either the timer fires or a signal is received through the pipe
  discard timer1.check()
  echo "Woke up from blocking wait!"

  # Normal examples (non-blocking)
  timer1.setBlocking(false)
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
  timer1.close()
  timer2.close()
  timer3.close()
  kq.close()

when isMainModule:
  main()
