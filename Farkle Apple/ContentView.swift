import SwiftUI
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
    
    var name: String {
        return self == .p1 ? "Player 1" : "Player 2"
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

@Observable
class Game {
    var winPoints: UInt = 2000
    private var playerScores: [Player: UInt] = [.p1: 0, .p2: 0]
    
    var currentPlayer: Player = .p1
    var finished: Bool = false
    var winner: Player? = nil
    
    var turnScore: UInt = 0
    var remainingDice: [Int] = []
    var selectedDice: Set<Int> = [] // indices
    var isBust: Bool = false
    var currentDieIndex = 0
    
    var isNetworkGame = false
    var myPlayer: Player = .p1
    var isRolling = false
    var p1Ready = false
    var p2Ready = false
    
    func getScore(player: Player) -> UInt {
        return playerScores[player] ?? 0
    }
    
    func setScore(player: Player, score: UInt) {
        playerScores[player] = score
    }
    
    func start() {
        playerScores = [.p1: 0, .p2: 0]
        finished = false
        winner = nil
        currentPlayer = .p1
        p1Ready = false
        p2Ready = false
        resetTurn()
    }
    
    func resetTurn() {
        turnScore = 0
        isBust = false
        rollNewDice(num: 6)
    }
    
    private func rollNewDice(num: Int) {
        isBust = false
        remainingDice = rollDice(numDice: num)
        selectedDice.removeAll()
        currentDieIndex = 0
        checkBust()
    }
    
    func rollDice(numDice: Int) -> [Int] {
        return (0..<numDice).map { _ in Int.random(in: 1...6) }
    }
    
    func calculateSelectedScore() -> UInt {
        let dice = selectedDice.map { remainingDice[$0] }
        return GameRules.calculateScore(selectedDice: dice)
    }
    
    @discardableResult
    func scoreAndContinue() -> Bool {
        let score = calculateSelectedScore()
        if score == 0 { return false }
        
        turnScore += score
        var newRemaining: [Int] = []
        for (idx, die) in remainingDice.enumerated() {
            if !selectedDice.contains(idx) {
                newRemaining.append(die)
            }
        }
        remainingDice = newRemaining
        selectedDice.removeAll()
        
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
            finished = true
            winner = currentPlayer
        }
        
        if !finished {
            currentPlayer = currentPlayer.next
            resetTurn()
        }
        return true
    }
    
    func checkBust() {
        if GameRules.getScoringIndices(dice: remainingDice).isEmpty {
            isBust = true
        }
    }
    
    func nextPlayerAfterBust() {
        currentPlayer = currentPlayer.next
        resetTurn()
    }
    
    func toggleDieSelection(index: Int) {
        if selectedDice.contains(index) {
            selectedDice.remove(index)
        } else {
            selectedDice.insert(index)
        }
    }
    
    // Networking
    func toPacket() -> GameStatePacket {
        return GameStatePacket(
            player1Score: Int(getScore(player: .p1)),
            player2Score: Int(getScore(player: .p2)),
            currentPlayer: currentPlayer.rawValue,
            turnScore: Int(turnScore),
            remainingDice: remainingDice,
            selectedDice: selectedDice,
            currentDieIndex: currentDieIndex,
            isBust: isBust,
            finished: finished,
            winner: winner?.rawValue ?? 0,
            winPoints: Int(winPoints),
            isRolling: isRolling,
            p1Ready: p1Ready,
            p2Ready: p2Ready
        )
    }
    
    func fromPacket(_ packet: GameStatePacket) {
        setScore(player: .p1, score: UInt(packet.player1Score))
        setScore(player: .p2, score: UInt(packet.player2Score))
        currentPlayer = Player(rawValue: packet.currentPlayer) ?? .p1
        turnScore = UInt(packet.turnScore)
        remainingDice = packet.remainingDice
        selectedDice = packet.selectedDice
        currentDieIndex = packet.remainingDice.isEmpty ? 0 : min(packet.currentDieIndex, packet.remainingDice.count - 1)
        isBust = packet.isBust
        finished = packet.finished
        winner = Player(rawValue: packet.winner)
        winPoints = UInt(packet.winPoints)
        isRolling = packet.isRolling ?? false
        p1Ready = packet.p1Ready ?? false
        p2Ready = packet.p2Ready ?? false
    }
    
    var isLocalTurn: Bool {
        return !isNetworkGame || currentPlayer == myPlayer
    }
    
    var isLocalAuthority: Bool {
        return !isNetworkGame || NetworkManager.shared.isHosting
    }
    
    func syncState() {
        if isNetworkGame && NetworkManager.shared.isHosting {
            NetworkManager.shared.sendState(toPacket())
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
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .rotationEffect(.degrees(isSelected ? 5 : 0))
    }
}

struct ContentView: View {
    @State private var game = Game()
    @State private var isStarted = false
    @State private var hostIP = "127.0.0.1"
    @State private var goalScore: UInt = 2000
    @State private var isConfiguring = false
    @State private var hasReceivedInitialState = false
    
    var isWaiting: Bool {
        game.isNetworkGame && !NetworkManager.shared.isConnected
    }
    
    var actionEnabled: Bool {
        game.isLocalTurn && !isWaiting && hasReceivedInitialState
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
                    Text("Farkle")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(radius: 5)
                        .padding(.bottom, 20)
                    
                    Button(action: {
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
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
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
                    }
                    .buttonStyle(.plain)
                    
                    HStack {
                        TextField("Host IP", text: $hostIP)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 150)
                            .padding()
                            .background(Color.white)
                            .cornerRadius(10)
                            .foregroundColor(.black)
                        
                        Button(action: {
                            game.start()
                            hasReceivedInitialState = false
                            game.isNetworkGame = true
                            game.myPlayer = .p2
                            NetworkManager.shared.connect(host: hostIP)
                            setupNetworkCallbacks()
                            withAnimation {
                                isStarted = true
                            }
                        }) {
                            Text("Join")
                                .font(.title3.bold())
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                }
            } else if isConfiguring {
                VStack(spacing: 30) {
                    Text("Game Setup")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    HStack {
                        Text("Victory Goal:")
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
                            .frame(width: 80)
                        
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
                        game.winPoints = goalScore
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
            } else if game.finished {
                VStack(spacing: 30) {
                    Text("\(game.winner?.name ?? "Someone") Wins!")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
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
                            Text("Player 1")
                                .font(.headline)
                            Text("\(game.getScore(player: .p1))")
                                .font(.largeTitle.bold())
                        }
                        VStack {
                            Text("Player 2")
                                .font(.headline)
                            Text("\(game.getScore(player: .p2))")
                                .font(.largeTitle.bold())
                        }
                    }
                    .foregroundColor(.white)
                    
                    if game.isNetworkGame {
                        if NetworkManager.shared.isConnected {
                            Text("Ready: \(game.p1Ready ? "[Player 1]" : "Player 1") | \(game.p2Ready ? "[Player 2]" : "Player 2")")
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
                                    NetworkManager.shared.sendAction(.RESTART, value: game.myPlayer.rawValue)
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
            }
            .padding(.horizontal)
            .padding(.top, 10)
            
            // Score Board
            HStack {
                scoreCard(for: .p1)
                Spacer()
                scoreCard(for: .p2)
            }
            .padding()
            
            Spacer()
            
            // Turn Info
            VStack(spacing: 10) {
                Text("\(game.currentPlayer.name)'s Turn" + (game.isNetworkGame ? (game.isLocalTurn ? " (You)" : "") : ""))
                    .font(.title.bold())
                    .foregroundColor(.white)
                
                if !isWaiting && hasReceivedInitialState {
                    Text("Goal: \(game.winPoints)")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Text("Turn Score: \(game.turnScore)")
                    .font(.title2)
                    .foregroundColor(.yellow)
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
            } else if game.isBust {
                Text("BUST!")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundColor(.red)
                    .shadow(radius: 5)
                    .transition(.scale)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 20) {
                    ForEach(Array(game.remainingDice.enumerated()), id: \.offset) { index, die in
                        DieView(value: die, isSelected: game.selectedDice.contains(index))
                            .onTapGesture {
                                guard game.isLocalTurn else { return }
                                
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    if game.isLocalAuthority {
                                        game.toggleDieSelection(index: index)
                                        game.syncState()
                                    } else {
                                        game.toggleDieSelection(index: index) // optimistic
                                        NetworkManager.shared.sendAction(.SELECT, value: index)
                                    }
                                }
                            }
                    }
                }
                .padding()
            }
            
            Spacer()
            
            // Selected Dice Score
            let potentialScore = game.calculateSelectedScore()
            Text("Selected Score: \(potentialScore)")
                .font(.headline)
                .foregroundColor(potentialScore > 0 ? .green : .white)
                .padding(.bottom, 10)
            
            // Actions
            HStack(spacing: 20) {
                if game.isBust {
                    Button(action: {
                        guard actionEnabled else { return }
                        withAnimation {
                            if game.isLocalAuthority {
                                game.nextPlayerAfterBust()
                                game.syncState()
                            } else {
                                NetworkManager.shared.sendAction(.BUST)
                            }
                        }
                    }) {
                        Text("Next Player")
                            .actionButtonStyle(color: actionEnabled ? .red : .gray)
                    }
                    .buttonStyle(.plain)
                    .disabled(!actionEnabled)
                } else {
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
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    @ViewBuilder
    func scoreCard(for player: Player) -> some View {
        VStack {
            Text(player.name)
                .font(.headline)
            Text("\(game.getScore(player: player))")
                .font(.title2.bold())
        }
        .padding()
        .background(game.currentPlayer == player ? Color.white.opacity(0.3) : Color.black.opacity(0.3))
        .cornerRadius(15)
        .foregroundColor(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(game.currentPlayer == player ? Color.yellow : Color.clear, lineWidth: 2)
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
                    game.toggleDieSelection(index: value)
                case .CONTINUE:
                    _ = game.scoreAndContinue()
                case .END_TURN:
                    _ = game.scoreAndEndTurn()
                case .BUST:
                    game.nextPlayerAfterBust()
                case .RESTART:
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
            if !game.finished {
                game.finished = true
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
            }
        }
    }
}

#Preview {
    ContentView()
}
