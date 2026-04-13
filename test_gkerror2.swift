import GameKit

for code in 0...50 {
    let error = GKError.Code(rawValue: code)
    if code == 38 {
        print("Code 38 rawValue exists: \(String(describing: error))")
    }
}
