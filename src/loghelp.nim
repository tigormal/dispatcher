import std/[terminal, os, tables]

let clr = @{"DBG": fgCyan, "INF": fgGreen, "WRN": fgYellow, "ERR": fgRed}.toTable

template log*(lvl: string, writer: string, x: varargs[string]) =
  stdout.styledWrite(clr[lvl], lvl, " ")
  stdout.write('[')
  stdout.write(writer)
  stdout.write("] ")
  for el in x:
    stdout.write(el)
  stdout.write('\n')

template debug*(writer: string, x: varargs[string, `$`]) =
  log "DBG", writer, x

template info*(writer: string, x: varargs[string, `$`]) =
  log "INF", writer, x
