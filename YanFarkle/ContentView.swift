import SwiftUI
import Combine
import Foundation
import GameKit

#if canImport(UIKit)
import UIKit

struct MatchmakerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GKMatchmakerViewController {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = "Let's play Farkle!"
        
        let vc = GKMatchmakerViewController(matchRequest: request) ?? GKMatchmakerViewController()
        vc.matchmakerDelegate = NetworkManager.shared
        return vc
    }
    
    func updateUIViewController(_ uiViewController: GKMatchmakerViewController, context: Context) {}
}
#elseif canImport(AppKit)
import AppKit

struct MatchmakerView: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> GKMatchmakerViewController {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = "Let's play Farkle!"
        
        let vc = GKMatchmakerViewController(matchRequest: request) ?? GKMatchmakerViewController()
        vc.matchmakerDelegate = NetworkManager.shared
        return vc
    }
    
    func updateNSViewController(_ nsViewController: GKMatchmakerViewController, context: Context) {}
}
#endif

#if canImport(GameController)
import GameController
#endif

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

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isMe: Bool
}

class Game: ObservableObject {
    @Published var winPoints: UInt = 2000
    @Published private var playerScores: [Player: UInt] = [.p1: 0, .p2: 0]
    @Published var isBotGame: Bool = false
    
    @Published var currentPlayer: Player = .p1
    @Published var state: GameState = .ROLLING {
        didSet {
            if state == .ROLLING {
                startRollingAnimation()
            } else {
                stopRollingAnimation()
            }
            if state == .TURN && isBotGame && currentPlayer == .p2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.executeBotTurn()
                }
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
    
    @Published var chatMessages: [ChatMessage] = []
    
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
        chatMessages.removeAll()
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
    
    func executeBotTurn() {
        guard state == .TURN, isBotGame, currentPlayer == .p2 else { return }
        
        let scoringIndices = GameRules.getScoringIndices(dice: remainingDice)
        guard !scoringIndices.isEmpty else { return }
        
        withAnimation(.spring()) {
            self.selectedDice = Set(scoringIndices)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.state == .TURN, self.currentPlayer == .p2 else { return }
            
            let calculated = self.calculateSelectedScore()
            let currentBank = self.getScore(player: .p2)
            let remainingCount = self.remainingDice.count - self.selectedDice.count
            
            let totalPotential = calculated + self.turnScore
            
            if totalPotential + currentBank >= self.winPoints {
                self.scoreAndEndTurn()
            } else if remainingCount == 0 {
                // Hot Dice: Always choose to roll again!
                self.scoreAndContinue()
            } else if totalPotential > 300 || remainingCount <= 2 {
                self.scoreAndEndTurn()
            } else {
                self.scoreAndContinue()
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
        
        let oldWinner = winner
        winner = Player(rawValue: packet.winner)
        winPoints = UInt(packet.goal)
        
        if oldWinner != nil && winner == nil {
            p1Ready = false
            p2Ready = false
        }
        
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
        if isBotGame && currentPlayer == .p2 { return false }
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

extension View {
    @ViewBuilder
    func onChangeWithBackwardCompatibility<T: Equatable>(of value: T, perform action: @escaping (T) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
    
    func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
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
    @State private var showChat = false
    @State private var showScanner = false
    @State private var isIPCopied = false
    @State private var showMatchmaker = false
    
    @State private var p1NameInput = ""
    @State private var p2NameInput = ""
    
    @State private var chatInput = ""
    @FocusState private var isChatFocused: Bool
    
    @State private var recentMessage: ChatMessage?
    @State private var showEmoteDropdown = false
    @State private var recentMessageTimer: Timer?
    
    @State private var myEmoteText: String?
    @State private var myEmoteTimer: Timer?
    @State private var opponentEmoteText: String?
    @State private var opponentEmoteTimer: Timer?
    
    private let allEmotes = ["😂", "😡", "🎲", "😭", "👍", "👎", "🔥", "🎉"]
    
    @FocusState private var focusedField: FocusField?
    
    @State private var isHardwareKeyboardAttached: Bool = {
        #if os(macOS)
        return true
        #elseif canImport(GameController)
        return GCKeyboard.coalesced != nil
        #else
        return false
        #endif
    }()
    
    var isWaiting: Bool {
        game.isNetworkGame && !networkManager.isConnected
    }
    
    var actionEnabled: Bool {
        game.isLocalTurn && !isWaiting && hasReceivedInitialState
    }
    
    var isMobileDevice: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .phone || UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
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
                        game.isBotGame = true
                        withAnimation {
                            isStarted = true
                            isConfiguring = true
                        }
                    }) {
                        Text("1 Player (Vs Bot)")
                            .font(.title2.bold())
                            .padding(.horizontal, 40)
                            .padding(.vertical, 15)
                            .frame(maxWidth: 300)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                            .shadow(radius: 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        focusedField = nil
                        game.start()
                        hasReceivedInitialState = true
                        game.isNetworkGame = false
                        game.isBotGame = false
                        withAnimation {
                            isStarted = true
                            isConfiguring = true
                        }
                    }) {
                        Text("2 Players (Local)")
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
                    
                    if NetworkManager.shared.isAuthenticated {
                        Button(action: {
                            focusedField = nil
                            game.start()
                            hasReceivedInitialState = false
                            game.isNetworkGame = true
                            game.isBotGame = false
                            game.myPlayer = .p1
                            setupNetworkCallbacks()
                            showMatchmaker = true
                        }) {
                            Text("Play Online (Game Center)")
                                .font(.title2.bold())
                                .padding(.horizontal, 40)
                                .padding(.vertical, 15)
                                .frame(maxWidth: 300)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(25)
                                .shadow(radius: 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button(action: {
                        focusedField = nil
                        game.start()
                        hasReceivedInitialState = true
                        game.isNetworkGame = true
                        game.isBotGame = false
                        game.myPlayer = .p1
                        NetworkManager.shared.host()
                        setupNetworkCallbacks()
                        withAnimation {
                            isStarted = true
                        }
                    }) {
                        Text("Host LAN Game")
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

                            if isMobileDevice {
                                Button(action: {
                                    showScanner = true
                                }) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                        .padding(10)
                                        .background(Color.blue.opacity(0.8))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }

                            Button(action: {
                                focusedField = nil
                                game.start()
                                hasReceivedInitialState = false
                                game.isNetworkGame = true
                                game.isBotGame = false
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
                                        Text("Join LAN")
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
                        } else if let error = NetworkManager.shared.connectionError, ProcessInfo.processInfo.environment["DEBUG"] != nil {
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
                                    .foregroundColor(game.isBotGame ? .gray : .primary)
                                    .frame(width: 200)
                                    .disabled(game.isBotGame)
                            }
                        }
                        .onAppear {
                            if game.isBotGame {
                                p2NameInput = "Bot"
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
                            if game.isBotGame {
                                game.localP2Name = "Bot"
                            } else {
                                game.localP2Name = p2NameInput.isEmpty ? "Player 2" : p2NameInput
                            }
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
                    if let winner = game.winner {
                        if game.isNetworkGame && winner == game.myPlayer {
                            Text("You Win!")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        } else {
                            Text("\(game.playerName(for: winner)) Wins!")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    } else {
                        Text("Someone Wins!")
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
                                withAnimation {
                                    if game.myPlayer == .p1 {
                                        game.p1Ready.toggle()
                                    } else {
                                        game.p2Ready.toggle()
                                    }
                                    NetworkManager.shared.sendAction(.READY_UP, value: game.myPlayer.rawValue)
                                    
                                    if game.isLocalAuthority && game.p1Ready && game.p2Ready {
                                        game.start()
                                        game.syncState()
                                    }
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
        .sheet(isPresented: $showScanner) {
            #if canImport(UIKit)
            VStack {
                HStack {
                    Text("Scan Host QR Code")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") {
                        showScanner = false
                    }
                }
                .padding()
                
                QRScannerView { code in
                    hostIP = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    showScanner = false
                    focusedField = nil
                    game.start()
                    hasReceivedInitialState = false
                    game.isNetworkGame = true
                    game.myPlayer = .p2
                    NetworkManager.shared.connect(host: hostIP)
                    setupNetworkCallbacks()
                    withAnimation {
                        isStarted = true
                    }
                }
                .ignoresSafeArea()
            }
            #else
            Text("Scanning not supported")
            #endif
        }
        #if !os(macOS) && canImport(GameController)
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            isHardwareKeyboardAttached = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            isHardwareKeyboardAttached = false
        }
        #endif
        .sheet(isPresented: $showMatchmaker) {
            MatchmakerView()
            #if os(macOS)
                .frame(minWidth: 600, minHeight: 450)
            #endif
                .ignoresSafeArea()
                .onAppear {
                    NetworkManager.shared.onMatchmakingComplete = {
                        showMatchmaker = false
                    }
                }
        }
        .onAppear {
            NetworkManager.shared.authenticateGameCenter()
        }
    }
    
    var gameView: some View {
        Group {
            gameContent
                .padding(.bottom, 20)
        }
        .sheet(isPresented: $showChat) {
            chatModal
        }
        .overlay(
            VStack {
                if let msg = recentMessage {
                    Text("\(game.playerName(for: msg.isMe ? game.myPlayer : game.myPlayer.next)): \(msg.text)")
                        .font(.headline)
                        .padding(12)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(radius: 5)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 40)
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.3), value: recentMessage)
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    var gameContent: some View {
        VStack(spacing: 0) {
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
                        if let err = NetworkManager.shared.connectionError, ProcessInfo.processInfo.environment["DEBUG"] != nil {
                            Text("Error: \(err)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                HStack(spacing: 8) {
                    if game.isNetworkGame {
                        Button(action: {
                            showChat = true
                        }) {
                            Image(systemName: "message.fill")
                                .font(.title2)
                                .frame(width: 24, height: 24)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(8)
                                .background(Color.black.opacity(0.2))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                showEmoteDropdown.toggle()
                            }
                        }) {
                            Image(systemName: "face.smiling")
                                .font(.title2)
                                .frame(width: 24, height: 24)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(8)
                                .background(Color.black.opacity(0.2))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            if showEmoteDropdown {
                                VStack(spacing: 12) {
                                    HStack(spacing: 12) {
                                        ForEach(allEmotes.prefix(4), id: \.self) { emote in
                                            Button {
                                                sendChat(text: emote, isEmote: true)
                                                withAnimation { showEmoteDropdown = false }
                                            } label: {
                                                Text(emote)
                                                    .font(.title)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    HStack(spacing: 12) {
                                        ForEach(allEmotes.suffix(4), id: \.self) { emote in
                                            Button {
                                                sendChat(text: emote, isEmote: true)
                                                withAnimation { showEmoteDropdown = false }
                                            } label: {
                                                Text(emote)
                                                    .font(.title)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(16)
                                .frame(width: 180)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color(white: 0.15))
                                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.white)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                                .offset(x: -10, y: 50)
                                .zIndex(100)
                            }
                        }
                    }
                    
                    Button(action: {
                        showRules = true
                    }) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.title2)
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 10)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .zIndex(100)

            // Score Board
            HStack {
                scoreCard(for: game.myPlayer)
                Spacer()
                scoreCard(for: game.myPlayer.next)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Spacer(minLength: 10)

            // Turn Info
            if !isWaiting && hasReceivedInitialState {
                VStack(spacing: 5) {
                    Text(game.isNetworkGame ? (game.isLocalTurn ? "Your Turn" : "Opponent's Turn") : "\(game.playerName(for: game.currentPlayer))'s Turn")
                        .font(.title.bold())
                        .foregroundColor(.white)

                    Text("Goal: \(game.winPoints)")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))

                    Text("Turn Score: \(game.turnScore)")
                        .font(.title2)
                        .foregroundColor(.yellow)
                }
            }

            Spacer(minLength: 10)

            // Dice Area
            if isWaiting {
                VStack(spacing: 15) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Waiting for opponent...")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    if NetworkManager.shared.isHosting {
                        let ip = getLocalIPAddress()
                        QRCodeView(text: "yanfarkle://\(ip)")
                            .frame(width: 150, height: 150)
                            .padding(.bottom, 10)
                            
                        HStack(spacing: 8) {
                            Text("Host IP: \(ip)")
                                .font(.headline)
                                .foregroundColor(.yellow)

                            Button(action: {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ip, forType: .string)
                                #else
                                UIPasteboard.general.string = ip
                                #endif

                                withAnimation {
                                    isIPCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation {
                                        isIPCopied = false
                                    }
                                }
                            }) {
                                Image(systemName: isIPCopied ? "checkmark" : "doc.on.doc.fill")
                                    .font(.body)
                                    .foregroundColor(isIPCopied ? .green : .white)
                                    .padding(8)
                                    .background(Color.white.opacity(0.3))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Copy IP Address")
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(30)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
            } else if game.isNetworkGame && !hasReceivedInitialState {
                VStack(spacing: 15) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Connected to Host")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("The host is configuring the game setup.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(30)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
            } else {
                VStack(spacing: 15) {
                    // Fixed-height header container to prevent the dice grid from shifting
                    VStack(spacing: 8) {
                        if game.state == .BUST {
                            Text("BUST!")
                                .font(.system(size: 56, weight: .heavy, design: .rounded))
                                .foregroundColor(.red)
                                .shadow(radius: 5)
                                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                        } else {
                            // Empty space filler to maintain layout stability
                            Spacer(minLength: 0).frame(height: 0)
                        }
                    }
                    .frame(height: 60) // Fixed height for message area

                    VStack(spacing: 15) {
                        let diceToShow = game.state == .ROLLING ? game.rollingDice : game.remainingDice
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 15) {
                                ForEach(0..<3, id: \.self) { col in
                                    let index = row * 3 + col
                                    if index < diceToShow.count {
                                        let die = diceToShow[index]
                                        DieView(
                                            value: die,
                                            isSelected: game.state == .ROLLING ? false : game.selectedDice.contains(index),
                                            isFocused: isHardwareKeyboardAttached && game.state != .ROLLING && game.isLocalTurn && game.currentDieIndex == index,
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
                        }
                    }
                    .frame(width: 250)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
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
                                guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusHorizontal(offset: -1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("a", modifiers: [])
                            Button("") { 
                                guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusHorizontal(offset: 1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("d", modifiers: [])
                            Button("") { 
                                guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusVertical(offset: -1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("w", modifiers: [])
                            Button("") { 
                                guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.moveFocusVertical(offset: 1)
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else {
                                        networkManager.sendAction(.MOVE_TO, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("s", modifiers: [])
                            Button("") { 
                                guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.toggleSelectedDie()
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else {
                                        networkManager.sendAction(.SELECT, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut("e", modifiers: [])
                            Button("") { 
                                guard game.state != .ROLLING && game.isLocalTurn && game.state != .BUST else { return }
                                withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                                    game.toggleSelectedDie()
                                    if game.isLocalAuthority {
                                        game.syncState()
                                    } else {
                                        networkManager.sendAction(.SELECT, value: game.currentDieIndex)
                                    }
                                }
                            }.keyboardShortcut(.space, modifiers: [])
                        }
                        .opacity(0)
                    )
                }
            }

            Spacer(minLength: 10)

            // Selected Dice Score
            let potentialScore = game.calculateSelectedScore()
            if !isWaiting && hasReceivedInitialState {
                Text("Selected Score: \(potentialScore)")
                    .font(.headline)
                    .foregroundColor(potentialScore > 0 ? .green : .white)
                    .padding(.bottom, 5)
            }

            // Actions
            HStack(spacing: 15) {
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
                        Text("Score & Roll\(isHardwareKeyboardAttached ? " (f)" : "")")
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
                        Text("Score & End\(isHardwareKeyboardAttached ? " (q)" : "")")
                            .actionButtonStyle(color: actionEnabled ? .orange : .gray)
                    }
                    .buttonStyle(.plain)
                    .disabled(potentialScore == 0 || !actionEnabled)
                    .opacity((potentialScore == 0 || !actionEnabled) ? 0.5 : 1)
                    .keyboardShortcut("q", modifiers: [])
                }
            }
            .padding(.bottom, 10)
        }
    }
                    @ViewBuilder
                    var chatModal: some View {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Chat")
                                    .font(.title2.bold())
                                Spacer()
                                Button("Close") {
                                    showChat = false
                                }
                                .font(.headline)
                            }
                            .padding()
                            .background(Color.gray.opacity(0.15))
                            
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(game.chatMessages) { msg in
                                            HStack {
                                                if msg.isMe {
                                                    Spacer()
                                                    Text(msg.text)
                                                        .padding(12)
                                                        .background(Color.blue)
                                                        .foregroundColor(.white)
                                                        .cornerRadius(15)
                                                } else {
                                                    Text(msg.text)
                                                        .padding(12)
                                                        .background(Color.gray.opacity(0.2))
                                                        .foregroundColor(.primary)
                                                        .cornerRadius(15)
                                                    Spacer()
                                                }
                                            }
                                        }
                                    }
                                    .padding()
                                    
                                    Color.clear.frame(height: 1).id("chat_bottom")
                                }
                                .frame(maxHeight: .infinity)
                                .onChangeWithBackwardCompatibility(of: game.chatMessages) { messages in
                                    if !messages.isEmpty {
                                        withAnimation {
                                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                                        }
                                    }
                                }
                                #if canImport(UIKit)
                                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation {
                                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                                        }
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        withAnimation {
                                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                                        }
                                    }
                                }
                                #endif
                            }
                            
                            VStack(spacing: 15) {
                                HStack {
                                    TextField("Chat...", text: $chatInput)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($isChatFocused)
                                        .onSubmit {
                                            sendChat()
                                        }
                                        #if os(macOS)
                                        .toolbar {
                                            ToolbarItemGroup(placement: .keyboard) {
                                                Spacer()
                                                Button("Done") {
                                                    isChatFocused = false
                                                }
                                            }
                                        }
                                        #endif
                                    
                                    Button("Send") {
                                        sendChat()
                                    }
                                    .disabled(chatInput.isEmpty)
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.horizontal)
                            }
                            .padding(.vertical, 10)
                            .background(Color.gray.opacity(0.15))
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                DragGesture()
                                    .onChanged { value in
                                        if value.translation.height > 10 && isChatFocused {
                                            hideKeyboard()
                                            isChatFocused = false
                                        }
                                    }
                            )
                        }
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .frame(width: 400, height: 500)
                        #endif
                        .onTapGesture {
                            hideKeyboard()
                            isChatFocused = false
                        }
                    }

                    @ViewBuilder
                    func scoreCard(for player: Player) -> some View {        let isHighlighted = game.currentPlayer == player && !isWaiting && hasReceivedInitialState
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
        .overlay(alignment: .bottom) {
            ZStack {
                if player == game.myPlayer, let text = myEmoteText {
                    Text(text)
                        .font(.system(size: 60))
                        .fixedSize()
                        .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 5)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .offset(y: 45)
                } else if player == game.myPlayer.next, let text = opponentEmoteText {
                    Text(text)
                        .font(.system(size: 60))
                        .fixedSize()
                        .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 5)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .offset(y: 45)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.5), value: player == game.myPlayer ? myEmoteText : opponentEmoteText)
            .allowsHitTesting(false)
            .zIndex(50)
        }
    }
    
    func sendChat(text: String? = nil, isEmote: Bool = false) {
        let message = text ?? chatInput
        guard !message.isEmpty else { return }
        
        let chatMsg = ChatMessage(text: message, isMe: true)
        game.chatMessages.append(chatMsg)
        NetworkManager.shared.sendChat(message)
        
        if isEmote {
            myEmoteText = message
            myEmoteTimer?.invalidate()
            myEmoteTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                    myEmoteText = nil
                }
            }
        }
        
        if text == nil {
            chatInput = ""
        }
    }
    
    func setupNetworkCallbacks() {
        NetworkManager.shared.onStateReceived = { state in
            hasReceivedInitialState = true
            withAnimation {
                game.fromPacket(state)
            }
        }
        
        NetworkManager.shared.onChatReceived = { message in
            let emotes = ["😂", "😡", "🎲", "😭", "👍", "👎", "🔥", "🎉"]
            let isEmote = emotes.contains(message)
            
            withAnimation {
                let chatMsg = ChatMessage(text: message, isMe: false)
                game.chatMessages.append(chatMsg)
            }
            
            if isEmote {
                opponentEmoteText = message
                opponentEmoteTimer?.invalidate()
                opponentEmoteTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { opponentEmoteText = nil }
                }
            } else {
                recentMessage = ChatMessage(text: message, isMe: false)
                recentMessageTimer?.invalidate()
                recentMessageTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                    withAnimation { recentMessage = nil }
                }
            }
        }
        
        NetworkManager.shared.onActionReceived = { action, value in
            if action == .READY_UP {
                withAnimation {
                    let sender = Player(rawValue: value)
                    if sender == .p1 { game.p1Ready.toggle() }
                    else if sender == .p2 { game.p2Ready.toggle() }
                    
                    if game.isLocalAuthority && game.p1Ready && game.p2Ready {
                        game.start()
                        game.syncState()
                    }
                }
                return
            }
            
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
    @State private var currentPage = 0
    let totalPages = 6
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Header
            HStack {
                Text("How to Play")
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
                
                Group {
                    switch currentPage {
                    case 0: RulePage1().transition(.opacity)
                    case 1: RulePage2().transition(.opacity)
                    case 2: RulePage3().transition(.opacity)
                    case 3: RulePage4().transition(.opacity)
                    case 4: RulePage6().transition(.opacity)
                    case 5: RulePage5().transition(.opacity)
                    default: EmptyView()
                    }
                }
                .animation(.easeInOut, value: currentPage)
                
                // Next/Prev Buttons Overlay
                VStack {
                    Spacer()
                    HStack {
                        if currentPage > 0 {
                            Button(action: { withAnimation { currentPage -= 1 } }) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        if currentPage < totalPages - 1 {
                            Button(action: { withAnimation { currentPage += 1 } }) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 650)
        #endif
    }
}

struct RulePage1: View {
    @State private var diceValues = [1, 5, 3, 4, 6, 2]
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Welcome to YanFarkle!")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            Text("The goal is to reach the winning score by rolling dice and banking points.")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            HStack(spacing: 15) {
                DieView(value: diceValues[0], isSelected: false, isFocused: false, isRolling: true)
                DieView(value: diceValues[1], isSelected: false, isFocused: false, isRolling: true)
                DieView(value: diceValues[2], isSelected: false, isFocused: false, isRolling: true)
            }
            HStack(spacing: 15) {
                DieView(value: diceValues[3], isSelected: false, isFocused: false, isRolling: true)
                DieView(value: diceValues[4], isSelected: false, isFocused: false, isRolling: true)
                DieView(value: diceValues[5], isSelected: false, isFocused: false, isRolling: true)
            }
            
            Text("You roll 6 dice. You must select at least one scoring die to continue your turn.")
                .font(.headline)
                .foregroundColor(.yellow)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top, 40)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                diceValues = (0..<6).map { _ in Int.random(in: 1...6) }
            }
        }
    }
}

struct RulePage2: View {
    var body: some View {
        VStack(spacing: 30) {
            Text("Basic Scoring")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("Single 1s and 5s are your bread and butter.")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            
            VStack(spacing: 20) {
                HStack(spacing: 20) {
                    DieView(value: 1, isSelected: true, isFocused: false)
                    Text("= 100 points")
                        .font(.title2.bold())
                        .foregroundColor(.yellow)
                }
                .padding()
                .background(Color.black.opacity(0.3))
                .cornerRadius(15)
                
                HStack(spacing: 20) {
                    DieView(value: 5, isSelected: true, isFocused: false)
                    Text("= 50 points")
                        .font(.title2.bold())
                        .foregroundColor(.yellow)
                }
                .padding()
                .background(Color.black.opacity(0.3))
                .cornerRadius(15)
            }
            
            Text("Select these dice to lock in points and either score them or roll the remaining dice for more!")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top, 40)
    }
}

struct RulePage3: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Multiples")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("Three of a kind gives you big points!")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))
            
            VStack(spacing: 10) {
                HStack {
                    ForEach(0..<3, id: \.self) { _ in DieView(value: 1, isSelected: true, isFocused: false).scaleEffect(0.6).frame(width: 45, height: 45) }
                    Spacer()
                    Text("1000 pts")
                        .font(.title3.bold())
                        .foregroundColor(.yellow)
                }
                
                HStack {
                    ForEach(0..<3, id: \.self) { _ in DieView(value: 4, isSelected: true, isFocused: false).scaleEffect(0.6).frame(width: 45, height: 45) }
                    Spacer()
                    Text("400 pts")
                        .font(.title3.bold())
                        .foregroundColor(.yellow)
                }
                Text("For 2-6, it's 100 x Face Value")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(10)
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            .padding(.horizontal, 20)
            
            Text("Four, Five, or Six of a kind doubles the score for each extra die!")
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            HStack {
                ForEach(0..<4, id: \.self) { _ in DieView(value: 4, isSelected: true, isFocused: false).scaleEffect(0.6).frame(width: 45, height: 45) }
                Spacer()
                Text("800 pts")
                    .font(.title3.bold())
                    .foregroundColor(.yellow)
            }
            .padding(10)
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            .padding(.horizontal, 20)
            
            Spacer()
        }
        .padding(.top, 30)
    }
}

struct RulePage4: View {
    var body: some View {
        VStack(spacing: 30) {
            Text("Straights")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("Roll a sequence of numbers for massive points!")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))
            
            VStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Small Straight (1-5) = 500 pts").font(.headline).foregroundColor(.yellow)
                    HStack(spacing: 5) {
                        ForEach(1...5, id: \.self) { i in DieView(value: i, isSelected: true, isFocused: false).scaleEffect(0.8).frame(width: 50, height: 50) }
                    }
                }
                
                VStack(alignment: .leading) {
                    Text("Large Straight (2-6) = 750 pts").font(.headline).foregroundColor(.yellow)
                    HStack(spacing: 5) {
                        ForEach(2...6, id: \.self) { i in DieView(value: i, isSelected: true, isFocused: false).scaleEffect(0.8).frame(width: 50, height: 50) }
                    }
                }
                
                VStack(alignment: .leading) {
                    Text("Full Straight (1-6) = 1500 pts").font(.headline).foregroundColor(.yellow)
                    HStack(spacing: 5) {
                        ForEach(1...6, id: \.self) { i in DieView(value: i, isSelected: true, isFocused: false).scaleEffect(0.8).frame(width: 50, height: 50) }
                    }
                }
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            
            Spacer()
        }
        .padding(.top, 40)
    }
}

struct RulePage5: View {
    var body: some View {
        VStack(spacing: 25) {
            Text("Farkle & Hot Dice")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            VStack(spacing: 15) {
                Text("FARKLE (Bust!)")
                    .font(.title2.bold())
                    .foregroundColor(.red)
                
                HStack {
                    DieView(value: 2, isSelected: false, isFocused: false)
                    DieView(value: 3, isSelected: false, isFocused: false)
                    DieView(value: 4, isSelected: false, isFocused: false)
                    DieView(value: 6, isSelected: false, isFocused: false)
                }
                
                Text("If your roll has NO scoring dice, you Farkle! You lose all points accumulated during that turn.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            .padding(.horizontal)
            
            VStack(spacing: 15) {
                Text("🔥 HOT DICE! 🔥")
                    .font(.title2.bold())
                    .foregroundColor(.orange)
                
                HStack {
                    ForEach(1...6, id: \.self) { _ in
                        DieView(value: 5, isSelected: true, isFocused: false).scaleEffect(0.7).frame(width: 45, height: 45)
                    }
                }
                
                Text("If you manage to select and score with ALL 6 dice, you get Hot Dice! You can roll all 6 again and keep building your turn score.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top, 30)
    }
}

struct RulePage6: View {
    var body: some View {
        VStack(spacing: 25) {
            Text("Score & Roll vs Score & End")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            Text("After selecting scoring dice, you have two choices:")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(spacing: 15) {
                Text("Score & Roll")
                    .actionButtonStyle(color: .blue)
                
                Text("Locks in your selected dice points to your turn score and rolls the remaining dice. It's risky but rewarding!")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            .padding(.horizontal)
            
            VStack(spacing: 15) {
                Text("Score & End")
                    .actionButtonStyle(color: .orange)
                
                Text("Banks your total turn score into your overall score and safely ends your turn.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(15)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top, 30)
    }
}

import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let text: String
    
    var body: some View {
        if let cgimg = generateQRCode(from: text) {
            Image(cgimg, scale: 1.0, label: Text("QR Code"))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Text("Failed to generate QR Code")
        }
    }
    
    func generateQRCode(from string: String) -> CGImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        
        if let outputImage = filter.outputImage {
            return context.createCGImage(outputImage, from: outputImage.extent)
        }
        return nil
    }
}

#if canImport(UIKit)
import AVFoundation
import UIKit

class ScannerViewController: UIViewController {
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var delegate: AVCaptureMetadataOutputObjectsDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let session = AVCaptureSession()
        self.captureSession = session
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        let videoInput: AVCaptureDeviceInput
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            return
        }
        
        if (session.canAddInput(videoInput)) {
            session.addInput(videoInput)
        } else {
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if (session.canAddOutput(metadataOutput)) {
            session.addOutput(metadataOutput)
            
            if let delegate = delegate {
                metadataOutput.setMetadataObjectsDelegate(delegate, queue: DispatchQueue.main)
            }
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            return
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        
        DispatchQueue.global(qos: .background).async {
            session.startRunning()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
            if let windowScene = view.window?.windowScene {
                switch windowScene.interfaceOrientation {
                case .landscapeLeft:
                    connection.videoOrientation = .landscapeLeft
                case .landscapeRight:
                    connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown:
                    connection.videoOrientation = .portraitUpsideDown
                default:
                    connection.videoOrientation = .portrait
                }
            }
        }
        previewLayer?.frame = view.bounds
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var didFindCode: (String) -> Void
    
    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var parent: QRScannerView
        var hasFoundCode = false
        
        init(parent: QRScannerView) {
            self.parent = parent
        }
        
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if !hasFoundCode, let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject {
                guard let stringValue = metadataObject.stringValue else { return }
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("yanfarkle://") else { return }
                hasFoundCode = true
                parent.didFindCode(String(trimmed.dropFirst("yanfarkle://".count)))
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    func makeUIViewController(context: Context) -> ScannerViewController {
        let viewController = ScannerViewController()
        viewController.delegate = context.coordinator
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) { }
    
    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: Coordinator) {
        uiViewController.captureSession?.stopRunning()
    }
}
#endif
