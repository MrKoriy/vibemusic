import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: avtest <stream-url>")
    exit(2)
}
guard let url = URL(string: args[1]) else { print("bad url"); exit(2) }

let item = AVPlayerItem(url: url)
let player = AVPlayer(playerItem: item)
player.volume = 0.0
player.automaticallyWaitsToMinimizeStalling = true
player.play()

let start = Date()
let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { t in
    let elapsed = Date().timeIntervalSince(start)
    let statusName = ["unknown", "ready", "failed"][Int(item.status.rawValue)]
    let controlName = ["paused", "waiting", "playing"][Int(player.timeControlStatus.rawValue)]
    print(String(
        format: "[%.1fs] status=%@ control=%@ reason=%@ time=%.2f dur=%.1f",
        elapsed, statusName, controlName,
        player.reasonForWaitingToPlay?.rawValue ?? "-",
        player.currentTime().seconds, item.duration.seconds
    ))
    if item.status == .failed {
        print("ITEM ERROR: \(item.error.map(String.init(describing:)) ?? "nil")")
        t.invalidate()
        exit(1)
    }
    if player.currentTime().seconds > 1.5 {
        print("PLAYING_OK")
        t.invalidate()
        exit(0)
    }
    if elapsed > 14 {
        print("TIMEOUT_STALLED")
        t.invalidate()
        exit(3)
    }
}
RunLoop.main.run()
