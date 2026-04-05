import SwiftUI
import Combine
import Foundation

func getLocalIPAddress() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0 {
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
    }
    return address
}

enum Player: Int {
    case p1 = 1
    case p2 = 2
    
    mutating func cycle() {
        self = (self == .p1) ? .p2 : .p1
    }
    
    var next: Player {
        return (self == .p1) ? .p2 : .p1
    }
}

struct GameRules {
    static func calculateScore(selectedDice: [Int]) -> UInt {
        if selectedDice.isEmpty { return 0 }
        
        var counts: [Int: Int] = [:]
        for die in selectedDice {
            counts[die, default: 0] += 1
        }
        
        var score: UInt = 0
        var usedCount = 0
        
        // Full straight (1-6) - 1500 points
        if (1...6).allSatisfy({ counts[$0, default: 0] >= 1 }) {
            score += 1500
            for i in 1...6 { counts[i, default: 0] -= 1 }
            usedCount += 6
        }
        
        // Multiples (3+ of a kind)
        for die in 1...6 {
            let count = counts[die, default: 0]
            if count >= 3 {
                let threeOfAKindScore: UInt = die == 1 ? 1000 : UInt(die) * 100
                if count > 3 {
                    score += threeOfAKindScore * UInt(1 << (count - 3))
                } else {
                    score += threeOfAKindScore
                }
                usedCount += count
                counts[die] = 0
            }
        }
        
        // Partial straights
        if (1...5).allSatisfy({ counts[$0, default: 0] >= 1 }) {
            score += 500
            for i in 1...5 { counts[i, default: 0] -= 1 }
            usedCount += 5
        }
        if (2...6).allSatisfy({ counts[$0, default: 0] >= 1 }) {
            score += 750
            for i in 2...6 { counts[i, default: 0] -= 1 }
            usedCount += 5
        }
        
        // Singles (1s and 5s)
        let remainingOnes = counts[1, default: 0]
        score += UInt(remainingOnes) * 100
        usedCount += remainingOnes
        counts[1] = 0
        
        let remainingFives = counts[5, default: 0]
        score += UInt(remainingFives) * 50
        usedCount += remainingFives
        counts[5] = 0
        
        return usedCount == selectedDice.count ? score : 0
    }
    
    static func getScoringIndices(dice: [Int]) -> [Int] {
        var scoringIndices: [Int] = []
        for (idx, die) in dice.enumerated() {
            if die == 1 || die == 5 {
                scoringIndices.append(idx)
            }
        }
        
        var counts: [Int: Int] = [:]
        for die in dice {
            counts[die, default: 0] += 1
        }
        
        for (die, count) in counts {
            if count >= 3 {
                for (idx, value) in dice.enumerated() {
                    if value == die && !scoringIndices.contains(idx) {
                        scoringIndices.append(idx)
                    }
                }
            }
        }
        
        let sorted = dice.sorted()
        if sorted == [1, 2, 3, 4, 5, 6] {
            return Array(0..<dice.count)
        }
        
        func hasAll(_ vals: [Int]) -> Bool {
            for v in vals {
                if !sorted.contains(v) { return false }
            }
            return true
        }
        
        if hasAll([1, 2, 3, 4, 5]) {
            var indices: [Int] = []
            var used: Set<Int> = []
            for v in [1, 2, 3, 4, 5] {
                if let idx = dice.enumerated().first(where: { $0.element == v && !used.contains($0.offset) })?.offset {
                    indices.append(idx)
                    used.insert(idx)
                }
            }
            return indices
        }
        
        if hasAll([2, 3, 4, 5, 6]) {
            var indices: [Int] = []
            var used: Set<Int> = []
            for v in [2, 3, 4, 5, 6] {
                if let idx = dice.enumerated().first(where: { $0.element == v && !used.contains($0.offset) })?.offset {
                    indices.append(idx)
                    used.insert(idx)
                }
            }
            return indices
        }
        
        return scoringIndices
    }
}

class Game: ObservableObject {
    @Published var winPoints: UInt = 2000
    @Published private var playerScores: [Player: UInt] = [.p1: 0, .p2: 0]
    
    @Published var currentPlayer: Player = .p1
    @Published var state: GameState = .ROLLING {
        didSet {
            if state == .ROLLING {
                startRollingAnimation()
            } else {
                stopRollingAnimation()
            }
        }
    }
    @Published var winner: Player? = nil
    
    @Published var turnScore: UInt = 0
    @Published var remainingDice: [Int] = []
    @Published var selectedDice: Set<Int> = [] // indices
    @Published var currentDieIndex = 0
    
    @Published var isNetworkGame = false
    @Published var myPlayer: Player = .p1
    @Published var p1Ready = false
    @Published var p2Ready = false
    
    @Published var localP1Name: String = "Player 1"
    @Published var localP2Name: String = "Player 2"
    
    @Published var rollingDice: [Int] = []
    @Published var diceRotations: [Int: Double] = [:] // Map index to rotation
    private var rollingTimer: Timer?
    
    func getScore(player: Player) -> UInt {
        return playerScores[player] ?? 0
    }
    
    func setScore(player: Player, score: UInt) {
        playerScores[player] = score
    }
    
    func start() {
        playerScores = [.p1: 0, .p2: 0]
        winner = nil
        currentPlayer = Bool.random() ? .p1 : .p2
        print("[GAME] Random starting player: \(currentPlayer == .p1 ? "P1 (Host)" : "P2 (Client)")")
        p1Ready = false
        p2Ready = false
        resetTurn()
    }
    
    func resetTurn() {
        turnScore = 0
        rollNewDice(num: 6)
    }
    
    private func rollNewDice(num: Int) {
        withAnimation(nil) {
            state = .ROLLING
            // Prepare rolling dice count immediately to avoid a visual jump in die count
            rollingDice = (0..<num).map { _ in Int.random(in: 1...100) } // interim values
            // Set remainingDice count immediately so syncState broadcasts the correct count
            remainingDice = (0..<num).map { _ in 0 }
        }
        syncState()
        
        if isLocalAuthority {
            // Local game or host: wait 1.5s before showing results to match Kotlin behavior
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.state == .ROLLING else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    self.remainingDice = self.rollDice(numDice: num)
                    // Generate new random rotations for the new roll
                    var newRotations: [Int: Double] = [:]
                    for i in 0..<self.remainingDice.count {
                        newRotations[i] = Double.random(in: -15...15)
                    }
                    self.diceRotations = newRotations
                    self.selectedDice.removeAll()
                    self.currentDieIndex = 0
                    self.checkBust()
                    self.syncState()
                }
            }
        } else {
            // Client: clear old dice while waiting for host's authoritative update
            remainingDice = []
            selectedDice.removeAll()
            currentDieIndex = 0
        }
    }
    
    func rollDice(numDice: Int) -> [Int] {
        return (0..<numDice).map { _ in Int.random(in: 1...6) }
    }
    
    func calculateSelectedScore() -> UInt {
        let dice = selectedDice.compactMap { idx -> Int? in
            guard idx >= 0 && idx < remainingDice.count else { return nil }
            return remainingDice[idx]
        }
        return GameRules.calculateScore(selectedDice: dice)
    }
    
    @discardableResult
    func scoreAndContinue() -> Bool {
        let score = calculateSelectedScore()
        if score == 0 { return false }
        
        turnScore += score
        
        // Safety: ensure indices are within bounds
        let validSelected = selectedDice.filter { $0 >= 0 && $0 < remainingDice.count }
        var newRemaining: [Int] = []
        for (idx, die) in remainingDice.enumerated() {
            if !validSelected.contains(idx) {
                newRemaining.append(die)
            }
        }
        remainingDice = newRemaining
        // Re-randomize rotations for the remaining dice to make it look like they were moved/re-settled
        var updatedRotations: [Int: Double] = [:]
        for i in 0..<remainingDice.count {
            updatedRotations[i] = Double.random(in: -15...15)
        }
        diceRotations = updatedRotations
        selectedDice.removeAll()
        currentDieIndex = 0
        
        if remainingDice.isEmpty {
            rollNewDice(num: 6)
        } else {
            rollNewDice(num: remainingDice.count)
        }
        return true
    }
    
    @discardableResult
    func scoreAndEndTurn() -> Bool {
        let score = calculateSelectedScore()
        if score == 0 { return false }
        
        turnScore += score
        let newScore = getScore(player: currentPlayer) + turnScore
        setScore(player: currentPlayer, score: newScore)
        
        if newScore >= winPoints {
            state = .GAME_OVER
            winner = currentPlayer
        } else {
            state = .END_TURN
        }
        
        if state == .END_TURN {
            currentPlayer = currentPlayer.next
            resetTurn()
        }
        return true
    }
    
    func checkBust() {
        if GameRules.getScoringIndices(dice: remainingDice).isEmpty {
            state = .BUST
            syncState()
            
            // Automatic transition for local/host players
            if isLocalAuthority {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, self.state == .BUST else { return }
                    self.nextPlayerAfterBust()
                    self.syncState()
                }
            }
        } else {
            state = .TURN
            syncState()
        }
    }
    
    func nextPlayerAfterBust() {
        guard state == .BUST else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            currentPlayer = currentPlayer.next
            // Explicitly suppress layout animations for the reset-turn transition
            withAnimation(nil) {
                resetTurn()
            }
        }
    }
    
    func toggleDieSelection(index: Int) {
        objectWillChange.send()
        if selectedDice.contains(index) {
            selectedDice.remove(index)
        } else {
            selectedDice.insert(index)
        }
    }
    
    func moveFocusHorizontal(offset: Int) {
        guard !remainingDice.isEmpty else { return }
        let count = remainingDice.count
        let col = currentDieIndex % 3
        let row = currentDieIndex / 3
        
        if offset == -1 {
            if col > 0 {
                let targetIdx = row * 3 + (col - 1)
                if targetIdx < count {
                    currentDieIndex = targetIdx
                }
            }
        } else if offset == 1 {
            if col < 2 {
                let targetIdx = row * 3 + (col + 1)
                if targetIdx < count {
                    currentDieIndex = targetIdx
                } else {
                    var found = false
                    for c in (col + 1)...2 {
                        for r in 0...1 {
                            let idx = r * 3 + c
                            if idx < count {
                                currentDieIndex = idx
                                found = true
                                break
                            }
                        }
                        if found { break }
                    }
                }
            }
        }
    }
    
    func moveFocusVertical(offset: Int) {
        guard !remainingDice.isEmpty else { return }
        let count = remainingDice.count
        let col = currentDieIndex % 3
        let row = currentDieIndex / 3
        
        if offset == -1 {
            if row > 0 {
                let targetIdx = (row - 1) * 3 + col
                if targetIdx < count {
                    currentDieIndex = targetIdx
                }
            }
        } else if offset == 1 {
            if row < 1 {
                let targetIdx = (row + 1) * 3 + col
                if targetIdx < count {
                    currentDieIndex = targetIdx
                } else {
                    for c in stride(from: col, through: 0, by: -1) {
                        let idx = (row + 1) * 3 + c
                        if idx < count {
                            currentDieIndex = idx
                            break
                        }
                    }
                }
            }
        }
    }
    
    func toggleSelectedDie() {
        guard !remainingDice.isEmpty && currentDieIndex < remainingDice.count else { return }
        toggleDieSelection(index: currentDieIndex)
    }
    
    func playerName(for player: Player) -> String {
        if isNetworkGame {
            return player == myPlayer ? "You" : "Opponent"
        } else {
            return player == .p1 ? localP1Name : localP2Name
        }
    }
    
    // Networking
    func toPacket() -> GameStatePacket {
        return GameStatePacket(
            p1Score: Int(getScore(player: .p1)),
            p2Score: Int(getScore(player: .p2)),
            p1Ready: p1Ready,
            p2Ready: p2Ready,
            currentPlayer: currentPlayer.rawValue,
            turnScore: Int(turnScore),
            remainingDice: remainingDice,
            selectedDice: selectedDice,
            state: state,
            winner: winner?.rawValue ?? 0,
            goal: Int(winPoints)
        )
    }
    
    func fromPacket(_ packet: GameStatePacket) {
        objectWillChange.send()
        setScore(player: .p1, score: UInt(packet.p1Score))
        setScore(player: .p2, score: UInt(packet.p2Score))
        p1Ready = packet.p1Ready
        p2Ready = packet.p2Ready
        currentPlayer = Player(rawValue: packet.currentPlayer) ?? .p1
        turnScore = UInt(packet.turnScore)
        remainingDice = packet.remainingDice
        // Safety: filter incoming selectedDice indices
        selectedDice = packet.selectedDice.filter { $0 >= 0 && $0 < packet.remainingDice.count }
        
        let oldState = self.state
        state = packet.state
        
        // Handle animation transition
        if state == .ROLLING && oldState != .ROLLING {
            startRollingAnimation()
        } else if state != .ROLLING && oldState == .ROLLING {
            stopRollingAnimation()
        }
        
        winner = Player(rawValue: packet.winner)
        winPoints = UInt(packet.goal)
        
        if !remainingDice.isEmpty {
            currentDieIndex = min(currentDieIndex, remainingDice.count - 1)
        } else {
            currentDieIndex = 0
        }
        
        print("[SYNC] Received selectedDice: \(selectedDice), state: \(state)")
    }
    
    private func startRollingAnimation() {
        rollingTimer?.invalidate()
        
        rollingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // Maintain the count currently set in rollingDice
                let currentCount = self.rollingDice.count > 0 ? self.rollingDice.count : (self.remainingDice.isEmpty ? 6 : self.remainingDice.count)
                self.rollingDice = (0..<currentCount).map { _ in Int.random(in: 1...6) }
            }
        }
    }
    
    private func stopRollingAnimation() {
        rollingTimer?.invalidate()
        rollingTimer = nil
        rollingDice = []
    }
    
    var isLocalTurn: Bool {
        return !isNetworkGame || currentPlayer == myPlayer
    }
    
    var isLocalAuthority: Bool {
        return !isNetworkGame || NetworkManager.shared.isHosting
    }
    
    func syncState() {
        if isNetworkGame && NetworkManager.shared.isHosting {
            let packet = toPacket()
            print("[NET] Host Sending State. selectedDice: \(packet.selectedDice)")
            NetworkManager.shared.sendState(packet)
        }
    }
}

struct ActionButtonStyleModifier: ViewModifier {
    var color: Color
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(20)
            .shadow(radius: 3)
    }
}

extension View {
    func actionButtonStyle(color: Color) -> some View {
        self.modifier(ActionButtonStyleModifier(color: color))
    }
}

struct DieView: View {
    let value: Int
    let isSelected: Bool
    let isFocused: Bool
    var isRolling: Bool = false
    var rotation: Double = 0
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(isSelected ? Color.yellow : Color.white)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.2), radius: 5, x: 2, y: 2)
            
            GeometryReader { geometry in
                let size = geometry.size.width / 5
                
                Group {
                    if value == 1 || value == 3 || value == 5 {
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                    if value > 1 {
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width * 0.25, y: geometry.size.height * 0.25)
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width * 0.75, y: geometry.size.height * 0.75)
                    }
                    if value > 3 {
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width * 0.25, y: geometry.size.height * 0.75)
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width * 0.75, y: geometry.size.height * 0.25)
                    }
                    if value == 6 {
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width * 0.25, y: geometry.size.height * 0.5)
                        Circle().fill(Color.black).frame(width: size, height: size)
                            .position(x: geometry.size.width * 0.75, y: geometry.size.height * 0.5)
                    }
                }
            }
            .padding(10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.blue, lineWidth: isFocused ? 4 : 0)
        )
        .frame(width: 70, height: 70)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .rotationEffect(.degrees(isRolling ? Double.random(in: -20...20) : (rotation + (isSelected ? 5 : 0))))
        .animation(isRolling ? .linear(duration: 0.1) : .interactiveSpring(response: 0.3, dampingFraction: 0.7), value: value)
    }
}

enum FocusField: Hashable {
    case hostIP, p1Name, p2Name
}

struct ContentView: View {
    @StateObject private var game = Game()
    @ObservedObject private var networkManager = NetworkManager.shared
    @State private var isStarted = false
    @State private var hostIP = "127.0.0.1"
    @State private var goalScore: UInt = 2000
    @State private var isConfiguring = false
    @State private var hasReceivedInitialState = false
    @State private var showRules = false
    
    @State private var p1NameInput = ""
    @State private var p2NameInput = ""
    
    @FocusState private var focusedField: FocusField?
    
    var isWaiting: Bool {
        game.isNetworkGame && !networkManager.isConnected
    }
    
    var actionEnabled: Bool {
        game.isLocalTurn && !isWaiting && hasReceivedInitialState
    }
    
    var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        #if DEBUG
        return "v\(version) (\(build)) (debug)"
        #else
        return "v\(version) (\(build))"
        #endif
    }
    
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                gradient: Gradient(colors: [Color(red: 0.1, green: 0.4, blue: 0.2), Color(red: 0.05, green: 0.2, blue: 0.1)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            if !isStarted {
                VStack(spacing: 20) {
                    Text("YanFarkle")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(radius: 5)
                        .padding(.bottom, 20)
                    
                    Button(action: {
                        focusedField = nil
                        game.start()
                        hasReceivedInitialState = true
                        game.isNetworkGame = false
                        withAnimation {
                            isStarted = true
                            isConfiguring = true
                        }
                    }) {
                        Text("Start Local Game")
                            .font(.title2.bold())
                            .padding(.horizontal, 40)
                            .padding(.vertical, 15)
                            .frame(maxWidth: 300)
                            .background(Color.white)
                            .foregroundColor(Color(red: 0.1, green: 0.4, blue: 0.2))
                            .cornerRadius(25)
                            .shadow(radius: 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        focusedField = nil
                        game.start()
                        hasReceivedInitialState = true
                        game.isNetworkGame = true
                        game.myPlayer = .p1
                        NetworkManager.shared.host()
                        setupNetworkCallbacks()
                        withAnimation {
                            isStarted = true
                        }
                    }) {
                        Text("Host Online Game")
                            .font(.title2.bold())
                            .padding(.horizontal, 40)
                            .padding(.vertical, 15)
                            .frame(maxWidth: 300)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                            .shadow(radius: 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    VStack(spacing: 12) {
                        HStack {
                            TextField("Host IP", text: $hostIP)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.white)
                                .foregroundColor(.black)
                                .cornerRadius(8)
                                .focused($focusedField, equals: .hostIP)
                                .frame(width: 150)
                            
                            Button(action: {
                                focusedField = nil
                                game.start()
                                hasReceivedInitialState = false
                                game.isNetworkGame = true
                                game.myPlayer = .p2
                                NetworkManager.shared.connect(host: hostIP)
                                setupNetworkCallbacks()
                            }) {
                                Group {
                                    if NetworkManager.shared.isConnecting {
                                        ProgressView()
                                            .tint(.white)
                                            .frame(width: 40)
                                    } else {
                                        Text("Join")
                                            .font(.title3.bold())
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(NetworkManager.shared.isConnecting ? Color.gray : Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(NetworkManager.shared.isConnecting)
                        }
                        
                        if NetworkManager.shared.isConnecting {
                            Text("Connecting...")
                                .font(.caption.bold())
                                .foregroundColor(.yellow)
                        } else if let error = NetworkManager.shared.connectionError {
                            Text(error)
                                .font(.caption.bold())
                                .foregroundColor(.red)
                                .frame(maxWidth: 250)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 10)
                    
                    Button(action: {
                        showRules = true
                    }) {
                        Text("How to Play")
                            .font(.headline)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)
                }
                
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(appVersionString)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                            .padding()
                    }
                }
            } else if isConfiguring {
                VStack(spacing: 20) {
                    Text("Game Setup")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    if !game.isNetworkGame {
                        VStack(spacing: 15) {
                            HStack {
                                Text("P1 Name:")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 100, alignment: .trailing)
                                TextField("Player 1", text: $p1NameInput)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .focused($focusedField, equals: .p1Name)
                                    .foregroundColor(.primary)
                                    .frame(width: 200)
                            }
                            HStack {
                                Text("P2 Name:")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 100, alignment: .trailing)
                                TextField("Player 2", text: $p2NameInput)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .focused($focusedField, equals: .p2Name)
                                    .foregroundColor(.primary)
                                    .frame(width: 200)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(15)
                    }
                    
                    HStack(spacing: 20) {
                        Text("Goal:")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Button(action: {
                            if goalScore > 1000 { goalScore -= 1000 }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        
                        Text("\(goalScore)")
                            .font(.title.bold())
                            .foregroundColor(.yellow)
                            .frame(width: 120) // Wider frame to prevent wrap
                        
                        Button(action: {
                            if goalScore < 10000 { goalScore += 1000 }
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 20)
                    
                    Button(action: {
                        focusedField = nil
                        game.winPoints = goalScore
                        if !game.isNetworkGame {
                            game.localP1Name = p1NameInput.isEmpty ? "Player 1" : p1NameInput
                            game.localP2Name = p2NameInput.isEmpty ? "Player 2" : p2NameInput
                        }
                        game.start()
                        withAnimation {
                            isConfiguring = false
                        }
                        if game.isNetworkGame {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                game.syncState()
                            }
                        }
                    }) {
                        Text("Start Game")
                            .font(.title2.bold())
                            .padding(.horizontal, 40)
                            .padding(.vertical, 15)
                            .frame(maxWidth: 300)
                            .background(Color.white)
                            .foregroundColor(Color(red: 0.1, green: 0.4, blue: 0.2))
                            .cornerRadius(25)
                            .shadow(radius: 5)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        focusedField = nil
                        NetworkManager.shared.stop()
                        withAnimation {
                            isStarted = false
                            isConfiguring = false
                        }
                    }) {
                        Text("Cancel")
                            .font(.headline)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 15)
                            .frame(maxWidth: 300)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                            .shadow(radius: 5)
                    }
                    .buttonStyle(.plain)
                }
            } else if game.state == .GAME_OVER {
                VStack(spacing: 30) {
                    if game.winner == game.myPlayer && game.isNetworkGame {
                        Text("You Win!")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    } else {
                        Text("\(game.winner != nil ? (game.winner == game.myPlayer ? "You Win!" : "\(game.playerName(for: game.winner!)) Wins!") : "Someone Wins!")")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    
                    if game.isNetworkGame && !NetworkManager.shared.isConnected {
                        Text("Opponent Disconnected")
                            .font(.title2.bold())
                            .foregroundColor(.red)
                    } else {
                        Text("Final Score")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    HStack(spacing: 40) {
                        VStack {
                            Text(game.playerName(for: game.myPlayer))
                                .font(.headline)
                            Text("\(game.getScore(player: game.myPlayer))")
                                .font(.largeTitle.bold())
                        }
                        VStack {
                            Text(game.playerName(for: game.myPlayer.next))
                                .font(.headline)
                            Text("\(game.getScore(player: game.myPlayer.next))")
                                .font(.largeTitle.bold())
                        }
                    }
                    .foregroundColor(.white)
                    
                    if game.isNetworkGame {
                        if NetworkManager.shared.isConnected {
                            let myReady = game.myPlayer == .p1 ? game.p1Ready : game.p2Ready
                            let opReady = game.myPlayer == .p1 ? game.p2Ready : game.p1Ready
                            Text("Ready: \(myReady ? "[You]" : "You") | \(opReady ? "[Opponent]" : "Opponent")")
                                .font(.headline)
                                .foregroundColor(.yellow)
                            
                            Button(action: {
                                if game.isLocalAuthority {
                                    withAnimation {
                                        game.p1Ready = true
                                        if game.p1Ready && game.p2Ready {
                                            game.start()
                                        }
                                        game.syncState()
                                    }
                                } else {
                                    game.p2Ready = true
                                    NetworkManager.shared.sendAction(.READY_UP, value: game.myPlayer.rawValue)
                                }
                            }) {
                                Text(!game.isLocalAuthority ? "Ready to Play Again" : "Play Again")
                                    .font(.title2.bold())
                                    .padding(.horizontal, 40)
                                    .padding(.vertical, 15)
                                    .background(Color.white)
                                    .foregroundColor(Color(red: 0.1, green: 0.4, blue: 0.2))
                                    .cornerRadius(25)
                                    .shadow(radius: 5)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button(action: {
                            withAnimation {
                                game.start()
                            }
                        }) {
                            Text("Play Again")
                                .font(.title2.bold())
                                .padding(.horizontal, 40)
                                .padding(.vertical, 15)
                                .background(Color.white)
                                .foregroundColor(Color(red: 0.1, green: 0.4, blue: 0.2))
                                .cornerRadius(25)
                                .shadow(radius: 5)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button(action: {
                        NetworkManager.shared.stop()
                        withAnimation {
                            isStarted = false
                            isConfiguring = false
                        }
                    }) {
                        Text("Exit to Menu")
                            .font(.headline)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 15)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                            .shadow(radius: 5)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                gameView
            }
        }
        .sheet(isPresented: $showRules) {
            RulesView()
        }
    }
    
    var gameView: some View {
        VStack {
            // Top Bar
            HStack(alignment: .top) {
                Button(action: {
                    NetworkManager.shared.stop()
                    withAnimation {
                        isStarted = false
                    }
                }) {
                    Text("Leave Game")
                        .font(.headline)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if game.isNetworkGame {
                    VStack(alignment: .trailing) {
                        Text(NetworkManager.shared.isHosting ? "Hosting Game" : "Connected to Host")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        if let err = NetworkManager.shared.connectionError {
                            Text("Error: \(err)")
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if !NetworkManager.shared.isConnected {
                            Text("Waiting for opponent...")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    }
                }
                
                Button(action: {
                    showRules = true
                }) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(8)
                        .background(Color.black.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 15)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            
            // Score Board
            HStack {
                scoreCard(for: game.myPlayer)
                Spacer()
                scoreCard(for: game.myPlayer.next)
            }
            .padding()
            
            Spacer()
            
            // Turn Info
            if !isWaiting && hasReceivedInitialState {
                VStack(spacing: 10) {
                    Text(game.isNetworkGame ? (game.isLocalTurn ? "Your Turn" : "Opponent's Turn") : "\(game.playerName(for: game.currentPlayer))'s Turn")
                        .font(.title.bold())
                        .foregroundColor(.white)
                    
                    Text("Goal: \(game.winPoints)")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Text("Turn Score: \(game.turnScore)")
                        .font(.title2)
                        .foregroundColor(.yellow)
                }
            }
            
            Spacer()
            
            // Dice Area
            if isWaiting {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Waiting for opponent...")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    if NetworkManager.shared.isHosting {
                        Text("Host IP: \(getLocalIPAddress())")
                            .font(.headline)
                            .foregroundColor(.yellow)
                            .padding(.top, 10)
                    }
                }
                .padding(40)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
            } else if game.isNetworkGame && !hasReceivedInitialState {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Connected to Host")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("The host is configuring the game setup.")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(40)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
            } else {
                VStack(spacing: 20) {
                    // Fixed-height header container to prevent the dice grid from shifting
                    VStack(spacing: 12) {
                        if game.state == .BUST {
                            Text("BUST!")
                                .font(.system(size: 64, weight: .heavy, design: .rounded))
                                .foregroundColor(.red)
                                .shadow(radius: 5)
                                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                        } else {
                            // Empty space filler to maintain layout stability
                            Spacer().frame(height: 0)
                        }
                    }
                    .frame(height: 100) // Fixed height for message area
                    
                    LazyVGrid(columns: [
                        GridItem(.fixed(70), spacing: 20),
                        GridItem(.fixed(70), spacing: 20),
                        GridItem(.fixed(70), spacing: 20)
                    ], spacing: 20) {
                        let diceToShow = game.state == .ROLLING ? game.rollingDice : game.remainingDice
                        ForEach(0..<6, id: \.self) { index in
                            if index < diceToShow.count {
                                let die = diceToShow[index]
                                DieView(
                                    value: die,
                                    isSelected: game.state == .ROLLING ? false : game.selectedDice.contains(index),
                                    isFocused: {
                                        #if os(macOS)
                                        return game.state != .ROLLING && game.isLocalTurn && game.currentDieIndex == index
                                        #else
                                        return false
                                        #endif
                                    }(),
                                    isRolling: game.state == .ROLLING,
                                    rotation: game.state == .ROLLING ? 0 : (game.diceRotations[index] ?? 0)
                                )
                                .animation(nil, value: game.state == .ROLLING)
                                .onTapGesture {
                                    guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                    
                                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                        game.currentDieIndex = index
                                        if game.isLocalAuthority {
                                            game.toggleDieSelection(index: index)
                                            game.syncState()
                                        } else {
                                            game.toggleDieSelection(index: index) // optimistic
                                            networkManager.sendAction(.SELECT, value: index)
                                        }
                                    }
                                }
                            } else {
                                // Transparent placeholder for layout stability
                                Color.clear.frame(width: 70, height: 70)
                            }
                        }
                    }
                    .frame(width: 250)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .overlay {
                        if game.state == .BUST {
                            Color.black.opacity(0.1)
                                .cornerRadius(20)
                        }
                    }
                    // Hidden buttons for keyboard navigation
                    .background(
                        ZStack {
                            Button("") { 
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusHorizontal(offset: -1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else if game.isLocalTurn {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("a", modifiers: [])
                            Button("") { 
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusHorizontal(offset: 1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else if game.isLocalTurn {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("d", modifiers: [])
                            Button("") { 
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusVertical(offset: -1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else if game.isLocalTurn {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("w", modifiers: [])
                            Button("") { 
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusVertical(offset: 1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else if game.isLocalTurn {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("s", modifiers: [])
                            Button("") { 
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.toggleSelectedDie()
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else if game.isLocalTurn {
                                        networkManager.sendAction(.SELECT, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("e", modifiers: [])
                            Button("") { 
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.toggleSelectedDie()
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else if game.isLocalTurn {
                                        networkManager.sendAction(.SELECT, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut(.space, modifiers: [])
                        }
                        .opacity(0)
                    )
                }
            }
            
            Spacer()
            
            // Selected Dice Score
            let potentialScore = game.calculateSelectedScore()
            if !isWaiting && hasReceivedInitialState {
                Text("Selected Score: \(potentialScore)")
                    .font(.headline)
                    .foregroundColor(potentialScore > 0 ? .green : .white)
                    .padding(.bottom, 10)
            }
            
            // Actions
            HStack(spacing: 20) {
                if game.state != .BUST {
                    Button(action: {
                        guard actionEnabled else { return }
                        withAnimation {
                            if game.isLocalAuthority {
                                _ = game.scoreAndContinue()
                                game.syncState()
                            } else {
                                NetworkManager.shared.sendAction(.CONTINUE)
                            }
                        }
                    }) {
                        Text("Score & Roll")
                            .actionButtonStyle(color: actionEnabled ? .blue : .gray)
                    }
                    .buttonStyle(.plain)
                    .disabled(potentialScore == 0 || !actionEnabled)
                    .opacity((potentialScore == 0 || !actionEnabled) ? 0.5 : 1)
                    .keyboardShortcut("f", modifiers: [])
                    
                    Button(action: {
                        guard actionEnabled else { return }
                        withAnimation {
                            if game.isLocalAuthority {
                                _ = game.scoreAndEndTurn()
                                game.syncState()
                            } else {
                                NetworkManager.shared.sendAction(.END_TURN)
                            }
                        }
                    }) {
                        Text("Score & End")
                            .actionButtonStyle(color: actionEnabled ? .orange : .gray)
                    }
                    .buttonStyle(.plain)
                    .disabled(potentialScore == 0 || !actionEnabled)
                    .opacity((potentialScore == 0 || !actionEnabled) ? 0.5 : 1)
                    .keyboardShortcut("q", modifiers: [])
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    @ViewBuilder
    func scoreCard(for player: Player) -> some View {
        let isHighlighted = game.currentPlayer == player && !isWaiting && hasReceivedInitialState
        VStack {
            Text(game.playerName(for: player))
                .font(.headline)
            Text("\(game.getScore(player: player))")
                .font(.title2.bold())
        }
        .padding()
        .background(isHighlighted ? Color.white.opacity(0.3) : Color.black.opacity(0.3))
        .cornerRadius(15)
        .foregroundColor(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(isHighlighted ? Color.yellow : Color.clear, lineWidth: 2)
        )
    }
    
    func setupNetworkCallbacks() {
        NetworkManager.shared.onStateReceived = { state in
            hasReceivedInitialState = true
            withAnimation {
                game.fromPacket(state)
            }
        }
        
        NetworkManager.shared.onActionReceived = { action, value in
            guard game.isLocalAuthority else { return }
            
            withAnimation {
                switch action {
                case .MOVE_TO:
                    game.currentDieIndex = value
                case .SELECT:
                    game.currentDieIndex = value // Safety: ensure Host's record of Client cursor state matches
                    game.toggleDieSelection(index: value)
                case .CONTINUE:
                    _ = game.scoreAndContinue()
                case .END_TURN:
                    _ = game.scoreAndEndTurn()
                case .BUST:
                    game.nextPlayerAfterBust()
                case .READY_UP:
                    let sender = Player(rawValue: value)
                    if sender == .p1 { game.p1Ready = true }
                    else if sender == .p2 { game.p2Ready = true }
                    
                    if game.p1Ready && game.p2Ready {
                        game.start()
                    }
                default:
                    break
                }
                
                game.syncState()
            }
        }
        
        NetworkManager.shared.onDisconnected = {
            if game.state != .GAME_OVER {
                game.state = .GAME_OVER
                game.winner = game.myPlayer
            } else {
                withAnimation {
                    isStarted = false
                    isConfiguring = false
                }
            }
        }
        
        NetworkManager.shared.onConnected = {
            if game.isLocalAuthority {
                withAnimation {
                    isConfiguring = true
                }
            } else {
                withAnimation {
                    isStarted = true
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

struct RulesView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Header
            HStack {
                Text("YanFarkle Rules")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .shadow(radius: 1)
                
                Spacer()
                
                Button(action: {
                    dismiss()
                }) {
                    Text("Done")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.2))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(red: 0.05, green: 0.2, blue: 0.1))
            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
            
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.1, green: 0.4, blue: 0.2), Color(red: 0.05, green: 0.2, blue: 0.1)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        // Header Content
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How to Play YanFarkle")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                            
                            Text("The goal is to score points by rolling dice. Be the first to reach the goal score to win!")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.top)
                        
                        Divider().background(Color.white.opacity(0.3))
                        
                        // Scoring Section
                        VStack(alignment: .leading, spacing: 15) {
                            SectionHeader(title: "Scoring Table", icon: "list.bullet.rectangle.fill")
                            
                            VStack(spacing: 8) {
                                ScoringRow(label: "Single 1", points: "100 pts")
                                ScoringRow(label: "Single 5", points: "50 pts")
                                ScoringRow(label: "Three 1s", points: "1000 pts")
                                ScoringRow(label: "Three of a Kind (2-6)", points: "100x Value")
                                ScoringRow(label: "Four/Five/Six of a Kind", points: "Double for each extra")
                                ScoringRow(label: "Straight (1-6)", points: "1500 pts")
                                ScoringRow(label: "Small Straight (1-5)", points: "500 pts")
                                ScoringRow(label: "Large Straight (2-6)", points: "750 pts")
                            }
                            .padding()
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(15)
                        }
                        
                        // Gameplay Section
                        VStack(alignment: .leading, spacing: 15) {
                            SectionHeader(title: "Gameplay Mechanics", icon: "gamecontroller.fill")
                            
                            VStack(alignment: .leading, spacing: 12) {
                                BulletPoint(title: "Selecting Dice", text: "You must select at least one scoring die after each roll to continue your turn.")
                                BulletPoint(title: "Score & Roll (F)", text: "Lock in your current dice score and roll the remaining dice to increase your turn total.")
                                BulletPoint(title: "Score & End (Q)", text: "Bank your total turn score into your overall score and end your turn.")
                                BulletPoint(title: "Farkle (Bust!)", text: "If a roll results in NO scoring combinations, you 'farkle' and lose ALL points earned during that turn.")
                                BulletPoint(title: "Hot Dice", text: "If you manage to score with all six dice, you can roll all six again! Keep the momentum going until you decide to score or you farkle.")
                            }
                        }
                        
                        Spacer(minLength: 50)
                    }
                    .padding()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 600)
        #endif
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.yellow)
            Text(title)
                .font(.title2.bold())
                .foregroundColor(.yellow)
                .shadow(radius: 1)
        }
    }
}

struct ScoringRow: View {
    let label: String
    let points: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.white)
            Spacer()
            Text(points)
                .fontWeight(.bold)
                .foregroundColor(.yellow)
        }
    }
}

struct BulletPoint: View {
    let title: String
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("• \(title)")
                .font(.headline)
                .foregroundColor(.yellow)
                .shadow(radius: 1)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .padding(.leading, 15)
        }
    }
}
