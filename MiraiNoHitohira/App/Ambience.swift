import AVFoundation
import SwiftUI

enum JournalLight: CaseIterable, Hashable {
    case morning, midday, evening, night

    init(at date: Date, calendar: Calendar = .current) {
        switch calendar.component(.hour, from: date) {
        case 5..<10: self = .morning
        case 10..<16: self = .midday
        case 16..<19: self = .evening
        default: self = .night
        }
    }

    var usesDarkText: Bool { self == .morning || self == .midday }

    var sky: [Color] {
        switch self {
        case .morning: [tone(0xC6D2E6), tone(0xE7C8CF), tone(0xFADCB4)]
        case .midday: [tone(0xB9D6E4), tone(0xD6E5DE), tone(0xF4ECD1)]
        case .evening: [tone(0x332C47), tone(0x634053), tone(0x805044)]
        case .night: [tone(0x171C34), tone(0x272947), tone(0x463751)]
        }
    }

    var glow: Color {
        switch self {
        case .morning: tone(0xFFF1D1).opacity(0.70)
        case .midday: tone(0xFFF8E0).opacity(0.66)
        case .evening: tone(0xF8B487).opacity(0.12)
        case .night: tone(0xB5AFE4).opacity(0.17)
        }
    }

    var header: Color {
        switch self {
        case .morning: tone(0xEEE0DD)
        case .midday: tone(0xE2EBE8)
        case .evening: tone(0x372D44)
        case .night: tone(0x1A2036)
        }
    }

    var leavesVolume: Float {
        switch self {
        case .morning: 0.34
        case .midday: 0.29
        case .evening: 0.25
        case .night: 0.19
        }
    }

    var birds: (delay: Double, spacing: ClosedRange<Double>, volume: Float)? {
        switch self {
        case .morning: (3, 12...23, 0.42)
        case .midday: (7, 22...38, 0.34)
        case .evening: (13, 35...56, 0.25)
        case .night: nil
        }
    }

    private func tone(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }
}

@MainActor
final class AmbientSoundscape {
    private var leaves: AVAudioPlayer?
    private lazy var calls = ["Sparrow", "Warbler", "Tit", "Dove"].compactMap { player(named: $0) }
    private var birdQueue: [Int] = []
    private var lastBird: Int?
    private var birdTask: Task<Void, Never>?
    private var light: JournalLight?

    func update(_ next: JournalLight?) {
        guard let next else {
            if light != nil {
                birdTask?.cancel()
                birdTask = nil
                leaves?.pause()
                if let lastBird { calls[lastBird].stop() }
                light = nil
            }
            return
        }

        if leaves == nil {
            leaves = player(named: "Leaves")
            leaves?.numberOfLoops = -1
        }
        if leaves?.isPlaying != true {
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
            leaves?.volume = 0
            leaves?.play()
        }
        leaves?.setVolume(next.leavesVolume, fadeDuration: 0.9)
        guard light != next else { return }
        light = next
        birdTask?.cancel()
        birdTask = nil
        if let lastBird { calls[lastBird].stop() }
        guard let birds = next.birds else { return }
        birdTask = Task { [weak self] in
            var delay = birds.delay
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                self.playBird(volume: birds.volume)
                delay = Double.random(in: birds.spacing)
            }
        }
    }

    private func player(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Ambience"),
              let audio = try? AVAudioPlayer(contentsOf: url) else { return nil }
        audio.prepareToPlay()
        return audio
    }

    private func playBird(volume: Float) {
        if birdQueue.isEmpty {
            birdQueue = calls.indices.shuffled()
            if birdQueue.count > 1 && birdQueue.last == lastBird {
                birdQueue.swapAt(0, birdQueue.count - 1)
            }
        }
        guard let next = birdQueue.popLast() else { return }
        lastBird = next
        let call = calls[next]
        call.currentTime = 0
        call.volume = volume
        call.play()
    }
}
