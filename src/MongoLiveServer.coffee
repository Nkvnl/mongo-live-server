_                    = require "underscore"
async                = require "async"
debug                = (require "debug") "mongo-live-server"
http                 = require "http"
uuid                 = require "uuid"
qs                   = require "qs"
WebSocket            = require "ws"
MongoConnector       = require "mongo-changestream-connector"

{ defaultLogger }    = require "./lib"



class MongoLiveServer
	constructor: (args) ->
		{
			@port
			@httpServer
			log
			@mongo
			@watches
			Gauge
			metricLabel
			@getAllowed
			@aclHeaders = [
				"user-id"
				"company-id"
			]
		} = args

		@getAllowed or= ({ ids, aclHeaders }, cb) ->
			debug "Received ACL Headers but discarding them. ACl headers:", aclHeaders
			cb null, ids

		defaultLabel = "mongo-live-server"
		@log         = log or defaultLogger defaultLabel
		metricLabel  = metricLabel or (@log.label ? defaultLabel).replace /-/g, "_"

		@log.warn "Mongo Live Server running without `getAllowed` function!" unless @getAllowed

		debug "TN-log & prometheus metric label is: #{metricLabel}"

		# Config validation of @mongo happens in mongo-changestream-connector
		unless @mongo
			throw new Error "Mongo config must be provided to create Mongo Live Server"
		unless @port or @httpServer
			throw new Error "httpServer or port must be provided to create Mongo Live Server"

		@unControlledHTTP      = Boolean @httpServer
		@httpServer          or= http.createServer()
		@changeStreams         = {}
		@wsServers             = []
		@defaultOperationTypes = ["update", "insert"]

		# two more operation types
		# @defaultOperationTypes = ["update", "insert", "delete", "replace", "invalidate"]

		#######################################
		# Why two gauges?
		# Value of gauge streams and of gauge sockets should be identical!
		#######################################

		@gaugeStreams = if Gauge then new Gauge
			name:       "#{metricLabel}_change_stream_count"
			help:       "Counts the change streams of the of the Mongo Live Server"
			labelNames: [ "live_data_server_streams" ]

		@gaugeSockets = if Gauge then new Gauge
			name:       "#{metricLabel}_active_socket_count"
			help:       "Counts the connected sockets"
			labelNames: [ "identity" ]

		throw new Error "Should provide at least one watch configuration." unless @watches.length >= 1

		_.each @watches, (route) =>
			{ path, model, collection, blacklistFields } = route

			throw new Error "Watch configuration should have a path." unless path

			livePath                                     = "/#{path}/live"

			if @mongo.useMongoose and collection
				throw new Error "Each watch config object should have the `model` property (and not `collection`)"
			if not @mongo.useMongoose and model
				throw new Error "Each watch config object should have the `collection` property (and not `model`)"

			debug "Setting up web socket server for path: #{livePath}. Blacklist: #{blacklistFields?.join " "}"

		@mongoConnector = new MongoConnector _.extend {}, @mongo, log: @log
		@wsServer       = new WebSocket.Server server: @httpServer

		@wsServer.on "connection", @_handleConnection

	_updateGaugeStreams: =>
		mnt = (_.keys @changeStreams).length

		return unless @gaugeStreams

		debug "Updating amount of streams gauge: #{mnt}"

		@gaugeStreams.set mnt

	_updateGaugeSockets: =>
		mnt = @wsServer.clients.size

		return unless @gaugeSockets

		debug "Updating amount of sockets gauge: #{mnt}"

		@gaugeSockets.set mnt

	_setupStream: (payload, cb) =>
		{
			identityKey = "identity"
			ids
			model
			collection
			onChange
			onClose
			pipeline
			socket
			streamId
			aclHeaders
		} = payload

		@getAllowed { ids, aclHeaders }, (error, allowed = []) =>
			if error
				mssg = "Error getting allowed `#{model or collection}` documents: #{error}"
				return cb new Error mssg

			if [ WebSocket.CLOSED, WebSocket.CLOSING ].includes socket.readyState
				return cb new Error "Socket disconnected while getting allowed ids"

			pipeline[0].$match.$and or= []
			pipeline[0].$match.$and.push "fullDocument.#{identityKey}": $in: allowed if allowed.length

			onError = (error) =>
				@log.error "Change stream error: #{error}"
				cursor.close()

			cursor = @mongoConnector.changeStream {
				model
				collection
				onError
				onClose
				onChange
				pipeline
				options:
					fullDocument: "updateLookup" # make this optionable in query?
			}

			@changeStreams[streamId] = cursor

			@_updateGaugeStreams()

			cb()

	_handleConnection: (socket, req) =>
		url = req.url.split("/live").shift().slice(1)

		route = _.find @watches, path: url

		return socket.close 4004, "#{req.url} not found" unless route

		{ identityKey, model, collection, blacklistFields } = route

		aclHeaders               = _.pick req.headers, @aclHeaders
		streamId                 = uuid.v4()
		ip                       = req.connection.remoteAddress
		splitUrl                 = req.url.split "?"
		query                    = qs.parse splitUrl[1]
		subscribe                = query.subscribe or @defaultOperationTypes
		{
			fields          = []
			extension       = []
			ids             = []
		} = query

		extension       = [ extension ]       if typeof extension is "string"
		subscribe       = [ subscribe ]       if typeof subscribe is "string"
		fields          = [ fields ]          if typeof fields    is "string"
		ids             = [ ids ]             if typeof ids       is "string"

		pipeline = [
			$match:
				$and: []
		]

		operationCondition = _.map subscribe, (operationType) ->
			{ operationType }

		pipeline[0].$match.$and.push $or: operationCondition

		##########################
		# TODO if fields and/or excludeFields, apply it in two ways
		##########################

		# 	trigger only on changes on these fields
		# 	$or: _.map ["lastHeartBeart", "alive"], (field) ->
		# 		"updateDescription.updatedFields.#{field}": $exists: true

		# 	for operationType insert give us only these fields
		# 	$project:
		# 		identity:   1
		# 		alive:      1
		# 		connectors: 1

		onChange = (change) ->
			unless socket.readyState is WebSocket.OPEN
				return @log.error "Socket not open"

			{ operationType } = change

			switch operationType
				when "insert"
					if fields.length
						data = _.pick change.fullDocument, fields
					else
						data = change.fullDocument

				when "update"
					if fields.length
						update = _.pick change.updateDescription.updatedFields, fields
					else
						update = change.updateDescription.updatedFields

					extra = _.pick change.fullDocument, extension

					data  = _.extend {}, update, extra

				else
					throw new Error "Recieved unknown operation type! --> #{operationType}"

			data = _.omit data, blacklistFields

			socket.send (JSON.stringify "#{operationType}": data), (error) =>
				@log.error error if error

		onClose = =>
			debug "Calling close down for change stream with id: #{streamId}"

			return unless @changeStreams[streamId]

			@changeStreams[streamId].removeAllListeners [ "close" ]
			@changeStreams[streamId].close()
			delete @changeStreams[streamId]

			# socket.removeAllListeners [ "close" ]
			socket.close()

			@_updateGaugeStreams()

		@log.info "Client connects. Connection id: #{streamId}.", {
			extension
			fields
			ids
			ip
			subscribe
			url
			aclHeaders
		}

		handleSocketDisconnect = =>
			@log.info "Client disconnects. Connection id: #{streamId}"

			onClose()

			@_updateGaugeSockets()

		handleSocketError = (error) =>
			socket.disconnect()
			@log.error "Websocket error: #{error.message}"

		socket
			.once "close", handleSocketDisconnect
			.once "error", handleSocketError

		@_setupStream {
			identityKey
			ids
			model
			collection
			onChange
			onClose
			pipeline
			socket
			streamId
			aclHeaders
		}, (error) =>
			if error
				@log.error error.message
				return onClose()

			@_updateGaugeSockets()

	start: (cb) =>
		debug "Mongo Live Server starting"

		async.series [
			(cb) =>
				return cb() unless @mongo.initReplset

				@mongoConnector.initReplset cb

			(cb) =>
				@mongoConnector.start (error) =>
					return cb error if error

					if @mongo.useMongoose
						@mongooseConnection = @mongoConnector.mongooseConnection
						@models             = @mongooseConnection.models
					else
						@mongoClient = @mongoConnector.mongoClient
						@db          = @mongoConnector.db

					cb()

			(cb) =>
				return cb() if @unControlledHTTP
				return cb() if @httpServer.listening

				@httpServer.listen port: @port, (error) =>
					return cb error if error

					@log.info "WebSocket server listening on #{@httpServer.address().port}"

					cb()

		], (error) ->
			cb? error

	stop: (cb) =>
		debug "Mongo Live Server stopping"

		# Sockets do NOT close when http server.close is called
		@wsServer.clients.forEach (client) ->
			client.close()

		# this shouldn't be necessary, for we have onClose functions
		# _.each (_.values @changeStreams), (stream) ->
		# 	stream.removeAllListeners [ "close" ]
		# 	stream.close()

		async.series [
			(cb) =>
				@mongoConnector.stop cb

			(cb) =>
				return cb() if @unControlledHTTP
				return cb() unless @httpServer.listening

				@httpServer.close (error) =>
					return cb error if error

					@log.info "WebSocket server stopped listening"

					cb()
		], (error) ->
			cb? error

module.exports = MongoLiveServer
