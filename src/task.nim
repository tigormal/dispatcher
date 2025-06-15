import types, runloop, timetag
import pkg/[cps]
import std/[times, monotimes, options, macros, sugar, locks, heapqueue, macrocache]
import fusion/[matching, astdsl]

template resume*(t: Task) =
  discard trampoline(t)

proc suspendNext*(t: Task) =
  if t != nil:
    var nextNow = dispatcher.now
    inc nextNow
    t.rl.sleepers.push(Sleeper(tag: nextNow, task: t))

proc suspend(t: Task) =
  if t != nil:
    t.rl.push(t, silent = true) # Add this task last

proc jield*(t: Task): Task {.cpsMagic.} =
  t.suspendNext()
  nil

proc sleep*(task: Task, d: Duration): Task {.cpsMagic.} =
  assert task != nil
  assert task.rl != nil
  debugEcho "Sleeping for " & $d
  withLock task.rl.lock:
    let sleeper = Sleeper(tag: initTimeTag(time = (getMonoTime() + d)), task: task)
    task.rl.sleepers.push(sleeper)
  nil

template deadline*(d: TimeInterval, code: untyped) {.pragma.}
template cancel*(code: untyped) {.pragma.}
template complete*(code: untyped) {.pragma.}

# const noDispatchMsg = "Task is not called from a dispatcher."
const taskHandlerCache = CacheTable"taskCache"

macro task*(procDecl: untyped): untyped =
  ## Scans the proc for `.deadline.`, `.cancel.`, and `.complete.` pragma blocks and rewrites them as separate procs with `.cps:Task.` or `.cps:Continuation` applied.
  result = newStmtList()
  debugEcho "{.task.} Input:"
  debugEcho treeRepr(procDecl)
  assertMatch(procDecl):
    Ident(strVal: @name) | Postfix[_, Ident(strVal: @name)]
    _ # Term rewriting template
    _ # Generic params
    FormalParams:
      @returnType
      all @args
    @pragmas
    _ # Reserved
    @implementation
  debugEcho "Taskifying " & $name
  # var warnFlag = false
  # Unfold the proc body (`schedule` template workaround)
  if implementation[0].kind == nnkStmtList:
    debugEcho "Unfolding StmtList"
    implementation = implementation[0]
  # Find pragma blocks:
  for i in 0 ..< implementation.len:
    let node = implementation[i]
    # Check if those are what we seek
    if node.kind == nnkPragmaBlock:
      if node.matches(
        [
          Pragma[
            ExprColonExpr[Ident(strVal: @pragmaName), @pragmaValue] |
              Ident(strVal: @pragmaName)
          ],
          @code,
        ]
      ):
        # Check if deadline has time
        if pragmaName in ["deadline", "cancel", "complete"]:
          debugEcho "Found " & $pragmaName
          # warnFlag = true
          # Check if time is specified
          if pragmaName == "deadline" and not pragmaValue.isSome:
            error "Deadline block must have a time specified"

          # Check if pragma is already in cache and add it if not
          if not taskHandlerCache.hasKey(name & pragmaName):
            taskHandlerCache[name & pragmaName] =
              if pragmaName == "deadline":
                pragmaValue.get # Time for deadline
              else:
                newEmptyNode() # Empty for cancel and complete

          # Insert cps:Continuation pragma
          let cpsPragma = buildAst:
            ExprColonExpr:
              ident"cps"
              ident"Continuation"
          var auxProc = newProc(
            name = ident(name & pragmaName),
            params = @[returnType] & args,
            body = code,
            pragmas = pragmas,
          )
          auxProc.addPragma(cpsPragma)
          result &= auxProc
          # debugEcho treeRepr(result)
          implementation[i] = newEmptyNode()

  # Add Task pragma and add to statement list
  let cpsPragma = buildAst:
    ExprColonExpr:
      ident"cps"
      ident"Task"
  procDecl.addPragma(cpsPragma)
  result &= procDecl
  # debugEcho treeRepr(result)

macro asTask*(call: untyped): untyped =
  ## Converts a proc call into a Task continuation object. Calls `cps.whelp`, but also assigns deadline, cancel and complete handlers if they exist.
  # debugEcho "asTask: "
  # debugEcho treeRepr(call)
  # Call
  #   Ident "myProc1"
  #   IntLit 0
  #   IntLit 123
  # ==================
  let procName = call[0]

  result = buildAst:
    BlockStmt:
      empty()
      StmtList:
        VarSection:
          IdentDefs:
            ident"res"
            empty()
            Command:
              ident"Task"
              Command:
                ident"whelp"
                call
        # Assign deadline handler
        if taskHandlerCache.hasKey($procName & "deadline"):
          let duration = taskHandlerCache[$procName & "deadline"]
          var callCopy = call.copy()
          callCopy[0] = ident($procName & "deadline")
          # if duration.kind == nnkEmpty:
          #   error "Deadline block must have a time specified"
          Asgn:
            DotExpr:
              ident"res"
              ident"onDeadline"
            Command:
              ident"whelp"
              callCopy
          # Assign time
          Asgn:
            DotExpr:
              ident"res"
              ident"deadline"
            Command:
              ident"some"
              duration
        # Assign cancel handler
        if taskHandlerCache.hasKey($procName & "cancel"):
          var callCopy = call.copy()
          callCopy[0] = ident($procName & "cancel")
          Asgn:
            DotExpr:
              ident"res"
              ident"onCancel"
            Command:
              ident"whelp"
              callCopy
        # Assign completion handler
        if taskHandlerCache.hasKey($procName & "complete"):
          var callCopy = call.copy()
          callCopy[0] = ident($procName & "complete")
          Asgn:
            DotExpr:
              ident"res"
              ident"onComplete"
            Command:
              ident"whelp"
              callCopy
        ident"res"
  # debugEcho treeRepr(result)

when isMainModule:
  # expandMacros:
  proc myProc1*(a, b: int) {.task.} =
    {.deadline: 5.seconds.}:
      echo "deadline", $a, $b
    {.cancel.}:
      echo "cancel", $a, $b
    echo("hello")

  # `let t = asTask myProc1(1, 2)` expands into:
  # dumpTree:
  # let t = block:
  #   var res = Task whelp myProc1(1, 2)
  #   # TODO: This value is taken from cache
  #   res.deadline = some 5.seconds # TODO: convert this to Duration to be added to getMonoTime() in dispatcher
  #   res.onDeadline = whelp myProc1deadline(1, 2)
  #   res.onCancel = whelp myProc1cancel(1, 2)
  #   res.onComplete = nil
  #   res
  myProc1(1, 2)
  let T = asTask myProc1(0, 123)
  discard trampoline T

  # ProcDef
  #   Postfix
  #     Ident "*"
  #     Ident "myProc1"
  #   Empty
  #   Empty
  #   FormalParams
  #     Ident "int"
  #     IdentDefs
  #       Ident "a"
  #       Ident "b"
  #       Ident "int"
  #       Empty
  #   Pragma
  #     Ident "myPragma"
  #   Empty
  #   StmtList
  #     PragmaBlock
  #       Pragma
  #         ExprColonExpr
  #           Ident "deadline"
  #           DotExpr
  #             IntLit 5
  #             Ident "seconds"
  #       StmtList
  #         DiscardStmt
  #           Empty
  #     PragmaBlock
  #       Pragma
  #         Ident "cancel"
  #       StmtList
  #         DiscardStmt
  #           Empty
  #     Call
  #       Ident "echo"
  #       StrLit "hello"

  # proc smth() {.cps:Task.} =
  #     Pragma
  #       ExprColonExpr
  #         Ident "cps"
  #         Ident "Task"

  #       BlockStmt
  #         Empty
  #         StmtList
  #           VarSection
  #             IdentDefs
  #               Ident "res"
  #               Empty
  #               Command
  #                 Ident "Task"
  #                 Command
  #                   Ident "whelp"
  #                   Call
  #                     Ident "myProc1"
  #                     IntLit 1
  #                     IntLit 2
  #           Asgn
  #             DotExpr
  #               Ident "res"
  #               Ident "deadline"
  #             Command
  #               Ident "some"
  #               DotExpr
  #                 IntLit 5
  #                 Ident "seconds"
  #           Asgn
  #             DotExpr
  #               Ident "res"
  #               Ident "onDeadline"
  #             Command
  #               Ident "whelp"
  #               Call
  #                 Ident "myProc1deadline"
  #                 IntLit 1
  #                 IntLit 2
  #           Asgn
  #             DotExpr
  #               Ident "res"
  #               Ident "onCancel"
  #             Command
  #               Ident "whelp"
  #               Call
  #                 Ident "myProc1cancel"
  #                 IntLit 1
  #                 IntLit 2
  #           Asgn
  #             DotExpr
  #               Ident "res"
  #               Ident "onComplete"
  #             NilLit
  #           Ident "res"
