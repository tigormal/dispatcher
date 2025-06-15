## Busy waiting generic timer

import std/[times, monotimes, locks]
import pkg/[cps]
import ../../[types, timer]

type TimerImpl* = ref object
  period*: TimeInterval ## Time interval between timer events
  offset*: TimeInterval ## Time offset for the first timer event
  nextTime*: MonoTime ## Next time the timer should fire
  enabled*: bool ## Whether the timer is enabled
  lock: Lock
  cond*: Cond
    ## The event loop signals the timer to stop waiting when a new timer is added
  id*: int ## Timer ID, used for identification in the event loop
  task*: Task ## Continuation to run when the timer fires

template checkNoBlockImpl*() {.dirty.} =
  # (t: var TimerImpl)
  if t.enabled and (t.nextTime < currentMonoTime()):
    return true

template checkImpl*() {.dirty.} =
  # Wait until external thread signals the timer or the timer fires
  # (t: var TimerImpl)
  t.lock.acquire()
  wait t.cond, t.lock
  t.lock.release()
  if t.enabled and (t.nextTime < currentMonoTime()):
    return true

template enableImpl*() {.dirty.} =
  # (t: var TimerImpl)
  t.enabled = true
  t.nextTime = currentMonoTime() + t.period

template disableImpl*() {.dirty.} =
  # (t: var TimerImpl)
  t.enabled = false

template pauseImpl*() {.dirty.} =
  # (t: var TimerImpl)
  t.enabled = false
  t.nextTime = currentMonoTime() + t.offset

template signalImpl*() {.dirty.} =
  # (t: var TimerImpl)
  signal t.cond

template initWithOffsetImpl*() {.dirty.} =
  # (t: var TimerImpl, period: TimeInterval, offset: TimeInterval = 0.seconds)
  t.period = period
  t.offset = offset
  t.nextTime = currentMonoTime() + offset
  t.enabled = true # Timer is enabled by default
  t.cond = Cond()
  initCond t.cond
  t.id = -1 # Unset ID, to be set by the event loop
  t.task = nil

template initImpl*() {.dirty.} =
  # (t: var TimerImpl, period: TimeInterval, oneshot: bool)
  t.period = period
  t.offset = 0.seconds
  t.nextTime = currentMonoTime() + period
  t.enabled = true # Start enabled
  t.cond = Cond()
  initCond t.cond
  t.id = -1 # Unset ID, to be set by the event loop
  t.task = nil

template periodImpl*() {.dirty.} =
  # (t: TimerImpl): Duration
  t.period

template offsetImpl*() {.dirty.} =
  # (t: TimerImpl): Duration
  t.offset
