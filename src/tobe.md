1. Generic scheduling
```nim
var i = 0
proc whatI {.task.} =
  echo $i

schedule(RT):
  echo fmt"Hello {i}"
  inc i

schedule whatI
```

2. Pipes
```nim
let p = Pipe[int]()
schedule: # Main
  for i in 0..5: p.send(i)

for _ in 0..5: echo $p.receive
```

3. Timeout and cancelling
```nim
schedule(IO):
  {.deadline: 100.milliseconds.}:
    echo "oops! timeout"
  for i in 0..1000:
    echo "Sleeping..."
    sleep 20.milliseconds

let job: Task[string] = schedule:
  {.cancel.}:
    "cancelled"
  for i in 0..1000:
    echo "Sleeping..."
    sleep 20.milliseconds
  "Done"
job.cancel()
echo job.data
```
