module.exports =
	host: "localhost"
	port:  9999

	mongo:
		database:    "test_cs_live_data_server"
		throwHappy:  false
		options:
			poolSize: 50
			replicaSet: "rs0"

