require 'colors'
async = require 'async'
log = require('printit')
    prefix: 'application'
spawn = require('child_process').spawn
path = require 'path'
request = require 'request'

fs = require 'fs'
helpers = require './helpers'

Client = require("request-json").JsonClient
Client::configure = (url, password, callback) ->
    @host = url
    @post "login", password: password, (err, res, body) ->
        if err? or res.statusCode isnt 200
            log.error "Cannot get authenticated".red
        else
            callback()

class exports.ApplicationManager

    client: new Client ""

    checkError: (err, res, body, code, msg, callback) ->
        if err or res.statusCode isnt code
            log.error err.red if err?
            log.info msg
            if body?
                if body.msg?
                    log.info body.msg
                else
                    log.info body
        else
            callback()

    updateApp: (app, url, password, callback) ->
        log.info "Update #{app}..."
        @client.configure url, password, =>
            path = "api/applications/#{app}/update"
            @client.put path, {}, (err, res, body) =>
                output = 'Update failed.'.red
                @checkError err, res, body, 200, output, callback

    installApp: (app, url, repoUrl, password, callback) ->
        log.info "Install started for #{app}..."
        @client.configure url, password, =>
            app_descriptor =
                name: app
                git: repoUrl

            path = "api/applications/install"
            @client.post path, app_descriptor, (err, res, body) =>
                output = 'Install failed.'.red
                @checkError err, res, body, 201, output, callback

    uninstallApp: (app, url, password, callback) ->
        log.info "Uninstall started for #{app}..."
        @client.configure url, password, =>
            path = "api/applications/#{app}/uninstall"
            @client.del path, (err, res, body) =>
                output = 'Uninstall failed.'.red
                @checkError err, res, body, 200, output, callback

    stopApp: (app, callback) ->
        cmds = []
        cmds.push
            name: 'vagrant'
            args: ['ssh', '-c', "cozy-monitor stop #{app}"]
            opts:
                'cwd': path.join __dirname, '..'
        helpers.spawnUntilEmpty cmds, callback

    startApp: (app, callback) ->
        cmds = []
        cmds.push
            name: 'vagrant'
            args: ['ssh', '-c', "cozy-monitor start #{app}"]
            opts:
                'cwd': path.join __dirname, '..'
        helpers.spawnUntilEmpty cmds, callback

    checkStatus: (url, password, callback) ->
        checkApp = (app) =>
            (next) =>
                if app isnt "home" and app isnt "proxy"
                    path = "apps/#{app}/"
                else path = ""

                @client.get path, (err, res) ->
                    if err? or res.statusCode isnt 200
                        log.error "#{app}: " + "down".red
                    else
                        log.info "#{app}: " + "up".green
                    next()

        checkStatus = =>
            async.series [
                checkApp "home"
                checkApp "proxy", "routes"
            ], =>
                @client.get "api/applications/", (err, res, apps) ->
                    if err?
                        log.error err.red
                    else
                        funcs = []
                        if apps? and typeof apps == "object"
                            funcs.push checkApp(app.name) for app in apps.rows
                            async.series funcs, callback

        @client.configure url, password, checkStatus

    isInstalled: (app, url, password, callback) =>
        @client.configure url, password, =>
            @client.get "apps/#{app.toLowerCase()}/", (err, res, body) ->
                if body is "app unknown"
                    callback null, false
                else if err
                    callback err, false
                else
                    callback null, true

    stackVersions: (callback) ->
        dsClient = new Client 'http://localhost:9101'
        dsClient.post 'request/stackapplication/all/', {}, (err, res, body) ->
            async.eachSeries body, (app, cb) ->
                app = app.value
                if app.lastVersion
                    if app.version < app.lastVersion
                        log.warn "#{app.name} : #{app.version} -> #{app.lastVersion}"
                    else
                        log.info "#{app.name} : #{app.version} -> #{app.lastVersion}"
                    cb()
                else
                    request.get "https://raw.github.com/cozy/cozy-#{app.name}/master/package.json", (err, res, data) ->
                        data = JSON.parse data
                        if app.version < data.version
                            log.warn "#{app.name} : #{app.version} -> #{data.version}"
                        else
                            log.info "#{app.name} : #{app.version} -> #{data.version}"
                        cb()
            , (err) ->
                console.log err if err?

    addInDatabase: (manifest, callback) ->
        dsClient = new Client 'http://localhost:9101'
        dsClient.post 'data/', manifest, (err, res, body) ->
            callback err

    resetProxy: (callback) ->
        proxyClient = new Client 'http://localhost:9104'
        proxyClient.get 'routes/reset', (err, res, body) ->
            callback err

    removeFromDatabase: (manifest, callback) ->
        dsClient = new Client 'http://localhost:9101'
        dsClient.post 'request/application/byslug/', {key: manifest.slug}, (err, res, body) ->
            app = body[0].value
            port = app.port
            name = app.name
            dsClient.del "data/#{app._id}/", (err, res, body) ->
                callback err

    addPortForwarding: (name, port, callback) ->
        options=
            detached: true
            stdio: ['ignore', 'ignore', 'ignore']
        filePath = path.join(__dirname, '..', '.vagrant', 'machines', 'default', 'virtualbox', 'private_key')
        command = 'ssh'
        args = ['-N', 'vagrant@127.0.0.1']
        args = args.concat ['-R', "#{port}:localhost:#{port}"]
        args = args.concat ['-p', '2222']
        args = args.concat ['-o', "IdentityFile=#{filePath}"]
        args = args.concat ['-o','UserKnownHostsFile=/dev/null']
        args = args.concat ['-o', 'StrictHostKeyChecking=no']
        args = args.concat ['-o', 'PasswordAuthentication=no']
        args = args.concat ['-o', 'IdentitiesOnly=yes']
        child = spawn command, args, options
        pid = child.pid
        child.unref()
        fs.open path.join(__dirname, '..', "#{name}.pid"), 'w', (err) ->
            return callback err if err?
            fs.writeFile path.join(__dirname, '..', "#{name}.pid"), pid, callback

    removePortForwarding: (name, port, callback) ->
        pid = fs.readFileSync path.join(__dirname, '..', "#{name}.pid"), 'utf8'
        process.kill(pid)
        callback()