module.exports =
	initModels: (connection) ->
		{ models } = connection
		{ Schema } = connection.base

		schema = new Schema
			active:
				type:     Boolean
				default:  false

			identity:       type: String, unique: true

			forbiddenField: type: String

			lastHeartbeat:  type: Date

			alive:
				type:    Boolean
				default: false

			nested:
				new Schema
					field: String

		,
			timestamps: true

		connection.model "Chargestation", schema
