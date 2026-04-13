import Foundation
import Network
import Combine
import GameKit

enum NetworkMode {
    case none, lan, gameCenter
}

enum GameState: String, Codable {
    case ROLLING, BUST, TURN, END_TURN, GAME_OVER
}

struct GameStatePacket: Codable, Equatable {
    var p1Score: Int
    var p2Score: Int
    var currentPlayer: Int
    var turnScore: Int
    var remainingDice: [Int]
    var selectedDice: Set<Int>
    var state: GameState
    var winner: Int
    var goal: Int
}

enum GameAction: String, Codable {
    case SELECT, MOVE_LEFT, MOVE_RIGHT, MOVE_TO, ROLL, SCORE, BUST_ACK, NEXT_TURN, MOVE_UP, MOVE_DOWN, CONTINUE, END_TURN, BUST, READY_UP
}

struct StateUpdatePacket: Codable {
    var type: String = "aqario.farkle.network.NetworkPacket.StateUpdate"
    var state: GameStatePacket
}

struct ActionPacket: Codable {
    var type: String = "aqario.farkle.network.NetworkPacket.Action"
    var gameAction: GameAction
    var value: Int = 0
}

struct ChatMessagePacket: Codable {
    var type: String = "aqario.farkle.network.NetworkPacket.Chat"
    var message: String
}

enum NetworkPacket {
    case stateUpdate(GameStatePacket)
    case action(GameAction, Int)
    case chat(String)
}

struct NetworkPacketDecodable: Decodable {
    let packet: NetworkPacket?
    
    enum CodingKeys: String, CodingKey {
        case type, state, gameAction, value, message
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type.contains("StateUpdate") {
            let state = try container.decode(GameStatePacket.self, forKey: .state)
            packet = .stateUpdate(state)
        } else if type.contains("Action") {
            let action = try container.decode(GameAction.self, forKey: .gameAction)
            let value = try container.decodeIfPresent(Int.self, forKey: .value) ?? 0
            packet = .action(action, value)
        } else if type.contains("Chat") {
            let message = try container.decode(String.self, forKey: .message)
            packet = .chat(message)
        } else {
            packet = nil
        }
    }
}

class NetworkManager: NSObject, ObservableObject, GKMatchDelegate, GKLocalPlayerListener {
    static let shared = NetworkManager()
    
    @Published var networkMode: NetworkMode = .none
    @Published var isAuthenticated = false
    @Published var isHosting = false
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String? = nil
    
    private var match: GKMatch?
    
    private var listener: NWListener?
    private var connection: NWConnection?
    
    private var timeoutWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "NetworkQueue")
    
    var onStateReceived: ((GameStatePacket) -> Void)?
    var onActionReceived: ((GameAction, Int) -> Void)?
    var onChatReceived: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onConnected: (() -> Void)?
    var onMatchmakingComplete: (() -> Void)?
    
    func host(port: UInt16 = 9999) {
        stop(notify: false)
        networkMode = .lan
        isHosting = true
        isConnecting = true
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isConnecting = false
                    case .failed(let error):
                        self?.connectionError = error.localizedDescription
                        self?.stop()
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.listener?.cancel()
                self?.listener = nil
                self?.setupConnection(newConnection)
            }
            
            listener?.start(queue: queue)
        } catch {
            DispatchQueue.main.async {
                self.connectionError = error.localizedDescription
                self.stop()
            }
        }
    }
    
    func connect(host: String, port: UInt16 = 9999) {
        stop(notify: false)
        networkMode = .lan
        isConnecting = true
        connectionError = nil
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let newConnection = NWConnection(to: endpoint, using: .tcp)
        
        // Start timeout timer
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isConnecting else { return }
            self.connectionError = "Connection timed out. Make sure the host is online and you have the correct IP."
            self.stop()
        }
        self.timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
        
        setupConnection(newConnection)
    }
    
    private func setupConnection(_ newConnection: NWConnection) {
        connection = newConnection
        
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.timeoutWorkItem?.cancel()
                    self?.timeoutWorkItem = nil
                    let wasConnected = self?.isConnected ?? false
                    self?.isConnected = true
                    self?.isConnecting = false
                    if !wasConnected {
                        self?.onConnected?()
                    }
                    self?.receiveNextMessage()
                case .failed(let error):
                    self?.connectionError = error.localizedDescription
                    self?.stop()
                case .cancelled:
                    self?.stop()
                default:
                    break
                }
            }
        }
        
        connection?.start(queue: queue)
    }
    
    private func receiveNextMessage() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, context, isComplete, error in
            if let data = content, !data.isEmpty {
                self?.processData(data)
            }
            
            if error == nil && isComplete == false {
                self?.receiveNextMessage()
            } else if error != nil || isComplete {
                DispatchQueue.main.async {
                    self?.stop()
                }
            }
        }
    }
    
    private var buffer = Data()
    
    private func processData(_ data: Data) {
        buffer.append(data)
        
        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
            let messageData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            buffer.removeSubrange(0..<newlineRange.upperBound)
            
            if !messageData.isEmpty {
                parseMessage(messageData)
            }
        }
    }
    
    private func parseMessage(_ data: Data) {
        do {
            let packet = try JSONDecoder().decode(NetworkPacketDecodable.self, from: data)
            DispatchQueue.main.async {
                if let p = packet.packet {
                    switch p {
                    case .stateUpdate(let state):
                        print("[NET] Received StateUpdate. State: \(state.state), currentPlayer: \(state.currentPlayer)")
                        self.onStateReceived?(state)
                    case .action(let action, let value):
                        print("[NET] Received Action: \(action), Value: \(value)")
                        self.onActionReceived?(action, value)
                    case .chat(let message):
                        print("[NET] Received Chat: \(message)")
                        self.onChatReceived?(message)
                    }
                }
            }
        } catch {
            print("[NET] Decoding error: \(error)")
            if let str = String(data: data, encoding: .utf8) {
                print("[NET] Raw json: \(str)")
            }
        }
    }
    
    func sendState(_ state: GameStatePacket) {
        let packet = StateUpdatePacket(state: state)
        if let data = try? JSONEncoder().encode(packet) {
            sendData(data)
        }
    }
    
    func sendAction(_ action: GameAction, value: Int = 0) {
        let packet = ActionPacket(gameAction: action, value: value)
        if let data = try? JSONEncoder().encode(packet) {
            sendData(data)
        }
    }
    
    func sendChat(_ message: String) {
        let packet = ChatMessagePacket(message: message)
        if let data = try? JSONEncoder().encode(packet) {
            sendData(data)
        }
    }
    
    private func sendData(_ data: Data) {
        if networkMode == .gameCenter {
            do {
                try match?.sendData(toAllPlayers: data, with: .reliable)
            } catch {
                print("GameKit send error: \(error)")
            }
        } else {
            var messageData = data
            messageData.append(Data("\n".utf8))
            connection?.send(content: messageData, completion: .contentProcessed({ error in
                if let error = error {
                    print("Send error: \(error)")
                }
            }))
        }
    }
    
    func stop(notify: Bool = true) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        
        match?.disconnect()
        match = nil
        
        let wasConnected = self.isConnected
        self.isConnected = false
        self.isConnecting = false
        self.isHosting = false
        self.networkMode = .none
        self.buffer.removeAll()
        
        if wasConnected && notify {
            DispatchQueue.main.async {
                self.onDisconnected?()
            }
        }
    }
    
    // MARK: - GameKit Integration
    func authenticateGameCenter() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] vc, error in
            DispatchQueue.main.async {
                if GKLocalPlayer.local.isAuthenticated {
                    self?.isAuthenticated = true
                    GKLocalPlayer.local.register(self!)
                } else {
                    self?.isAuthenticated = false
                    print("GameCenter Auth Error: \(error?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }
    
    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        parseMessage(data)
    }
    
    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                // We use playerIDs to cleanly assign the "Authority/Host" player
                let amIAuthority = GKLocalPlayer.local.teamPlayerID > player.teamPlayerID
                self.isHosting = amIAuthority
            case .disconnected:
                self.connectionError = "Opponent disconnected."
                self.stop()
            default:
                break
            }
        }
    }
}

extension NetworkManager: GKMatchmakerViewControllerDelegate {
    func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        onMatchmakingComplete?()
        stop()
    }
    
    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        onMatchmakingComplete?()
        connectionError = error.localizedDescription
        stop()
    }
    
    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        onMatchmakingComplete?()
        self.match = match
        match.delegate = self
        
        DispatchQueue.main.async {
            self.networkMode = .gameCenter
            self.isConnected = true
            self.onConnected?()
        }
    }
}
