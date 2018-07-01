import Foundation
import WebSocket
import Starscream

struct ConnectResponse: Decodable {
    
    let ok: Bool
    let error: String?
    let url: String?
    
}

struct WebsockerResponse: Decodable {
    
    let type: String?
    let ts: String?
    let user: String?
    let text: String?
    let channel: String?
    
}

struct WebsocketMessage: Codable {
    
    let id: UInt
    let type: String = "message"
    let channel: String
    let text: String
    
    init(id: UInt, channel: String, text: String) {
        self.id = id
        self.channel = channel
        self.text = text
    }
    
    func serialize() throws -> Data {
        return try JSONEncoder().encode(self)
    }
    
}

final class Counter {
    
    private var counter: UInt = 0
    private let queue = DispatchQueue(label: "counter")
    
    func increment() {
        queue.sync {
            self.counter += 1
        }
    }
    
    func get() -> UInt {
        return queue.sync { self.counter }
    }
    
}

public class StarscreamRTM: WebSocketDelegate {
    
    private var webSocket: Starscream.WebSocket
    let counter = Counter()
    let sem = DispatchSemaphore(value: 0)
    
    public init(url: URL) {
        self.webSocket = WebSocket(url: url)
        self.webSocket.callbackQueue = DispatchQueue(label: "StarscremQueue")
    }
    
    // MARK: - RTM
    public func connect() {
        webSocket.delegate = self
        print("Connecting ...")
        webSocket.connect()
        sem.wait()
    }
    
    public func disconnect() {
        webSocket.disconnect()
    }
    
    public func websocketDidConnect(socket: WebSocketClient) {
        print("DID CONNECT!")
        _ = sem.signal()
    }
    
    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        print("DISCONNECT WITH ERROR: \(error?.localizedDescription ?? "")")
        _ = sem.signal()
    }
    
    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        print("got some text: \(text)")
        counter.increment()
        guard let data = text.data(using: .utf8) else {
            print("ERROR - Cannot deserialize data")
            return
        }
        do {
            let response = try JSONDecoder().decode(WebsockerResponse.self, from: data)
            guard response.type == "message", let channel = response.channel else {
                return
            }
            sendMessage("👍", channel: channel)
        } catch let error {
            print("ERROR: \(error)")
        }
    }
    
    public func sendMessage(_ message: String, channel: String? = .none) {
        do {
            let messageData = try WebsocketMessage(id: counter.get(), channel: channel ?? "", text: message).serialize()
            webSocket.write(data: messageData)
        } catch let error {
            print("ERROR - Serializing message: \(error)")
        }
    }
    
    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        print("Did receive data!")
    }
}

let env = ProcessInfo.processInfo.environment
guard let slackToken = env["SLACK_TOKEN"] else {
    fatalError("Missing SLACK_TOKEN env variable!")
}

let useVapor = env["BACKEND"] != "Starscream"
let session = URLSession.shared
let rtmConnectUrl = URL(string: "https://slack.com/api/rtm.connect?token=\(slackToken)")!
let sem = DispatchSemaphore(value: 0)
var maybeWebsocketUrl: URL? = env["WEBSOCKET_SERVER_URL"].flatMap(URL.init(string:))

if maybeWebsocketUrl == nil {
    session.dataTask(with: rtmConnectUrl) { maybeData, maybeResponse, maybeError in
        defer {
            _ = sem.signal()
        }
        
        if let error = maybeError {
            print("ERROR - Cannot connect to RTM: \(error)")
            return
        }
        guard let response = (maybeResponse as? HTTPURLResponse) else {
            print("ERROR - Cannot cast response to HTTPURLResponse")
            return
        }
        guard response.statusCode == 200 else {
            print("ERROR - Invalid response code \(response.statusCode)")
            return
        }
        guard let data = maybeData else {
            print("ERROR - Data value is not available")
            return
        }
        do {
            let connectResponse = try JSONDecoder().decode(ConnectResponse.self, from: data)
            guard connectResponse.ok else {
                print("ERROR - Connect response is not successfull: \(connectResponse.error ?? "NO_ERROR")")
                return
            }
            guard let url = connectResponse.url else {
                print("ERROR - Websocket URL is not present")
                return
            }
            maybeWebsocketUrl = URL(string: url)
        } catch let error {
            print("ERROR - Cannot decode connect response: \(error)")
            return
        }
    }
    .resume()
    sem.wait()
}

guard var websocketUrl = maybeWebsocketUrl else {
    print("ERROR - Invalid websocket URL")
    exit(1)
}
print("Websocket URL: \(websocketUrl.absoluteString)")

if useVapor {
    print("Using vapor ...")
    let eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let scheme: HTTPScheme = websocketUrl.scheme == "wss" ? .wss : .ws
    let port: Int? = env["WEBSOCKET_SERVER_PORT"].flatMap(Int.init)
    print("Connectin to websocket ...")
    let ws = try HTTPClient.webSocket(
        scheme: scheme,
        hostname: websocketUrl.host!,
        port: port,
        path: websocketUrl.path,
        on: eventLoop
    ).wait()

    let counter = Counter()
    print("Connection established!")
    // Set a new callback for receiving text formatted data.
    ws.onText { ws, text in
        print("Server echo: \(text)")
        counter.increment()
        guard let data = text.data(using: .utf8) else {
            print("ERROR - Cannot deserialize data")
            return
        }
        do {
            let response = try JSONDecoder().decode(WebsockerResponse.self, from: data)
            guard response.type == "message", let channel = response.channel else {
                return
            }
            let messageData = try WebsocketMessage(id: counter.get(), channel: channel, text: "👍").serialize()
            if let message = String(data: messageData, encoding: .utf8) {
                ws.send(message)
            }
        } catch let error {
            print("ERROR: \(error)")
        }
    }
    ws.onError { ws, error in
        print("ERROR - \(error)")
        exit(1)
    }
    ws.onCloseCode { error in
        print("ERROR CODE - \(error)")
        exit(1)
    }
    ws.onBinary { ws, data in
        print("DATA received")
    }

    while let line = readLine(), line != "q" {
        if line == "i" {
            print("isClosed?: \(ws.isClosed)")
        }
        if line == "s" {
            if let messageData = try? WebsocketMessage(id: 0, channel: "channel", text: "hello from vapor").serialize(),
                let message = String(data: messageData, encoding: .utf8) {
                print("Sending message: \(message)")
                ws.send(message)
            } else {
                print("ERROR - cannot serialize message")
            }
        }
        continue
    }

    print("Exiting ...")
    ws.close()
    // Wait for the Websocket to closre.
    try ws.onClose.wait()

    print("Bye")
} else {
    print("Using Starscream ... ")
    let ws = StarscreamRTM(url: websocketUrl)
    ws.connect()
    
    print("Entering loop!")
    while let line = readLine(), line != "q" {
        if line == "s" {
            print("Sending message ...")
            ws.sendMessage("Hello from starscream!")
        }
        continue
    }
    
    print("Exiting ...")
    ws.disconnect()
    
    print("Bye")
}
