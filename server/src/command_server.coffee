# middleware to serve the results of shell commands
# Listens to POST /run/
{spawn} = require('child_process')
PerfCollector = require('./PerfCollector')

module.exports = (workingDir, useLoginShell) ->
  args = if useLoginShell then ['-l'] else []
  # the Connect middleware
  (req, res, next) ->
    return next() unless req.method == 'POST' and req.url == '/run/'
    startTime = Date.now()
    bytesOut = 0
    commandStr = ''
    widgetId = req.headers['x-widget-id'] or null
    shell = spawn 'bash', args, cwd: workingDir

    req.on 'data', (chunk) ->
      commandStr += chunk.toString() if commandStr.length < 200
      shell.stdin.write chunk

    req.on 'end', ->
      setStatusOnce = (status) ->
        res.writeHead status
        setStatusOnce = ->

      shell.stderr.on 'data', (d) ->
        setStatusOnce 500
        res.write d

      shell.stdout.on 'data', (d) ->
        bytesOut += d.length
        setStatusOnce 200
        res.write d

      shell.on 'error', (err) ->
        setStatusOnce 500
        res.write err.message

      shell.on 'close', ->
        setStatusOnce 200
        res.end()
        PerfCollector.recordCommand({
          command: commandStr.trim()
          durationMs: Date.now() - startTime
          bytesOut: bytesOut
          widgetId: widgetId
        })

      shell.stdin.write '\n'
      shell.stdin.end()





