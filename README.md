# SlackWebSocket

* Run with environmental variable `SLACK_TOKEN`.
* You need to get the token from Slack. Check docs [here](https://get.slack.help/hc/en-us/articles/215770388-Create-and-regenerate-API-tokens)
* By default it uses [Vapor/WebSocket](https://github.com/vapor/websocket) but you can change to [daltoniam/Starscream](https://github.com/daltoniam/Starscream) by setting the environmental variable `BACKEND=Starscream`.
