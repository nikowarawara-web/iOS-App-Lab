import AlarmKit
import AppIntents
import AVFoundation
import SwiftUI
import UIKit

struct MorningMetadata: AlarmMetadata {}

enum WakeDay: Int, CaseIterable, Codable, Hashable, Identifiable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    var id: Int { rawValue }
    var shortName: String { ["月", "火", "水", "木", "金", "土", "日"][rawValue] }
    var name: String { shortName + "曜日" }

    var systemDay: Locale.Weekday {
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday][rawValue]
    }
}

struct WakeAlarm: Identifiable, Codable {
    var id = UUID()
    var hour = 5
    var minute = 30
    var days: Set<WakeDay> = []
    var enabled = true
    var systemID: UUID?

    var timeLabel: String { String(format: "%02d:%02d", hour, minute) }

    var dateSelection: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    var repeatLabel: String {
        if days.isEmpty { return "１回のみ" }
        if days.count == 7 { return "毎日" }
        if days == Set(WakeDay.allCases.prefix(5)) { return "平日" }
        if days == [.saturday, .sunday] { return "土・日" }
        return WakeDay.allCases.filter(days.contains).map(\.shortName).joined(separator: "・")
    }

    var schedule: Alarm.Schedule {
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        let weekdays = WakeDay.allCases.filter(days.contains).map(\.systemDay)
        return .relative(.init(time: time, repeats: weekdays.isEmpty ? .never : .weekly(weekdays)))
    }
}

struct OpenMorningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "今日の一片を開く"
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "アラームID")
    var alarmID: String

    init() { alarmID = "" }
    init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            MorningModel.shared.openFromAlarm(id)
        }
        return .result()
    }
}

struct SilenceMorningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "アラーム音を停止"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "アラームID")
    var alarmID: String

    @Parameter(title: "起床アラーム")
    var isInitial: Bool

    init() {
        alarmID = ""
        isInitial = false
    }

    init(alarmID: UUID, isInitial: Bool) {
        self.alarmID = alarmID.uuidString
        self.isInitial = isInitial
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            await MorningModel.shared.silenceFromSystem(id, isInitial: isInitial)
        }
        return .result()
    }
}

@MainActor
@Observable
final class MorningModel {
    enum Page { case today, archive, alarm }
    enum Stage { case typing, waking, saved, reading }

    static let shared = MorningModel()

    var page: Page = .today
    var stage: Stage = .typing
    var draft = ""
    var committed = ""
    var inputSession = 0
    var customText = ""
    var message: String?
    var alarmMessage: String?
    var busy = false
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: "soundEnabled") }
    }
    private(set) var date = Date()
    private(set) var passage: Passage
    private(set) var postcards: [Postcard]
    private(set) var wakeAlarms: [WakeAlarm]
    private(set) var testScheduled = false
    private(set) var wakeSession = false

    private let library: SceneLibrary
    private let defaults = UserDefaults.standard
    private let manager = AlarmManager.shared
    private let sounds = Effects()
    private var testID: UUID?
    private var reminderID: UUID?
    private var pendingReminders: Set<UUID> = []
    private var idleTask: Task<Void, Never>?
    private var observing = false

    private init() {
        let library = SceneLibrary.load()
        self.library = library
        let now = Date()
        let defaults = UserDefaults.standard
        let cards = defaults.data(forKey: "postcards").flatMap { try? JSONDecoder().decode([Postcard].self, from: $0) } ?? []
        date = now
        passage = library.passage(on: now, custom: nil)
        let revisedCards = cards.map(library.revisedPostcard)
        postcards = revisedCards
        if revisedCards.map(\.id) != cards.map(\.id),
           let data = try? JSONEncoder().encode(revisedCards) {
            defaults.set(data, forKey: "postcards")
        }
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        if let data = defaults.data(forKey: "wakeAlarms"),
           let saved = try? JSONDecoder().decode([WakeAlarm].self, from: data) {
            wakeAlarms = saved
        } else if let oldDate = defaults.object(forKey: "mainDate") as? Date,
                  let oldID = defaults.string(forKey: "mainID").flatMap(UUID.init(uuidString:)) {
            let clock = Calendar.current.dateComponents([.hour, .minute], from: oldDate)
            wakeAlarms = [WakeAlarm(hour: clock.hour ?? 5, minute: clock.minute ?? 30, systemID: oldID)]
        } else {
            wakeAlarms = []
        }
        testID = defaults.string(forKey: "testAlarmID").flatMap(UUID.init(uuidString:))
        testScheduled = testID != nil
        reminderID = defaults.string(forKey: "reminderID").flatMap(UUID.init(uuidString:))
        persistAlarms()
        restoreToday()
        if reminderID != nil && defaults.string(forKey: "pendingWakeDay") == Postcard.dayKey(now) {
            stage = .waking
            wakeSession = true
        }
    }

    var match: MatchState { MatchState(reference: passage.text, typed: committed) }

    func observeAlarms() async {
        guard !observing else { return }
        observing = true
        defer { observing = false }
        receiveAlarmList(try? manager.alarms)
        for await alarms in manager.alarmUpdates {
            receiveAlarmList(alarms)
        }
    }

    private func receiveAlarmList(_ alarms: [Alarm]?) {
        guard let alarms else { return }
        if !busy {
            let ids = Set(alarms.map(\.id))
            let missing = wakeAlarms.indices.filter { index in
                let alarm = wakeAlarms[index]
                return alarm.enabled && alarm.systemID.map { !ids.contains($0) } == true
            }
            for index in missing { wakeAlarms[index].enabled = false }
            if !missing.isEmpty { persistAlarms() }
            if let testID, !ids.contains(testID) {
                testScheduled = false
                if alarmMessage?.hasPrefix("20秒後") == true { alarmMessage = nil }
            }
        }
        if let reminderID, !pendingReminders.contains(reminderID),
           !alarms.contains(where: { $0.id == reminderID }) {
            setReminder(nil)
        }
    }

    func refreshDay() {
        guard !wakeSession, Postcard.dayKey(date) != Postcard.dayKey(.now) else { return }
        restoreToday()
    }

    func openURL(_ url: URL) {
        guard url.scheme == "mirai-hitohira", url.host == "today",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value,
              !Passage.letters(text).isEmpty else { return }
        finishWake()
        customText = text
        page = .today
        restoreToday()
    }

    private func restoreToday() {
        date = .now
        passage = library.passage(on: date, custom: customText)
        draft = ""
        committed = ""
        stage = postcards.contains { $0.day == Postcard.dayKey(date) && $0.text == passage.text } ? .saved : .typing
    }

    func select(_ target: Page) {
        if page == .today && target != .today && wakeSession {
            interruptWake()
        }
        if target == .today { refreshDay() }
        page = target
    }

    func input(_ text: String, isComposing: Bool) {
        guard page == .today, stage == .typing else { return }
        if draft != text, soundEnabled { sounds.playKey() }
        draft = text
        resetIdleTimer()
        guard !isComposing else { return }
        committed = text
        guard match.complete else { return }
        let card = Postcard(day: Postcard.dayKey(date), date: date, text: passage.text, art: passage.image, description: passage.description, title: passage.title)
        if !postcards.contains(where: { $0.id == card.id }) {
            postcards.insert(card, at: 0)
            if let data = try? JSONEncoder().encode(postcards) { defaults.set(data, forKey: "postcards") }
        }
        finishWake()
        stage = .saved
        if soundEnabled { sounds.playSaved() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func readOnly() {
        finishWake()
        stage = .reading
    }

    func startTyping() {
        if cancelReminder() == false { return }
        message = nil
        stage = .typing
        inputSession += 1
        resetIdleTimer()
    }

    func saveAlarm(_ draft: WakeAlarm) async -> Bool {
        guard !busy else { return false }
        busy = true
        alarmMessage = nil
        defer { busy = false }
        let previous = wakeAlarms.first { $0.id == draft.id }
        var next = draft
        next.systemID = nil
        do {
            if next.enabled {
                try await authorizeAlarms()
                let id = UUID()
                try await schedule(id, schedule: next.schedule, isInitial: true)
                next.systemID = id
            }
            if let oldID = previous?.systemID {
                do { try cancelAlarm(oldID) }
                catch {
                    if let newID = next.systemID { try? cancelAlarm(newID) }
                    throw error
                }
            }
            if let index = wakeAlarms.firstIndex(where: { $0.id == draft.id }) {
                wakeAlarms[index] = next
            } else {
                wakeAlarms.append(next)
            }
            wakeAlarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
            persistAlarms()
            return true
        } catch AlarmAccess.denied {
            alarmMessage = "iPhoneの「設定」で、このアプリのアラームを許可してください。"
        } catch {
            alarmMessage = "変更を保存できませんでした。もう一度お試しください。"
        }
        return false
    }

    func setAlarmEnabled(_ alarm: WakeAlarm, enabled: Bool) async {
        var draft = alarm
        draft.enabled = enabled
        _ = await saveAlarm(draft)
    }

    func deleteAlarm(_ alarm: WakeAlarm) -> Bool {
        guard !busy else { return false }
        do {
            if let id = alarm.systemID { try cancelAlarm(id) }
            wakeAlarms.removeAll { $0.id == alarm.id }
            persistAlarms()
            alarmMessage = nil
            return true
        } catch {
            alarmMessage = "アラームを削除できませんでした。もう一度お試しください。"
            return false
        }
    }

    func scheduleTest() async {
        guard !busy, !testScheduled else { return }
        busy = true
        defer { busy = false }
        do {
            try await authorizeAlarms()
            let id = UUID()
            try await schedule(id, schedule: .fixed(.now.addingTimeInterval(20)), isInitial: true)
            testID = id
            testScheduled = true
            defaults.set(id.uuidString, forKey: "testAlarmID")
            alarmMessage = "20秒後に鳴ります。画面をロックして試せます。"
        } catch AlarmAccess.denied {
            alarmMessage = "iPhoneの「設定」で、このアプリのアラームを許可してください。"
        } catch {
            alarmMessage = "テストを設定できませんでした。"
        }
    }

    func cancelTest() {
        guard !busy, let testID else { return }
        do {
            try cancelAlarm(testID)
            testScheduled = false
            alarmMessage = nil
        } catch {
            alarmMessage = "テストを取り消せませんでした。"
        }
    }

    func openFromAlarm(_ id: UUID) {
        let resume = (id == reminderID || wakeSession) && Postcard.dayKey(date) == Postcard.dayKey(.now)
        message = nil
        if id == reminderID { setReminder(nil) }
        if id == testID { testScheduled = false }
        if let index = wakeAlarms.firstIndex(where: { $0.systemID == id }), wakeAlarms[index].days.isEmpty {
            wakeAlarms[index].enabled = false
            persistAlarms()
        }
        // Stop only the current occurrence, so a weekly schedule stays registered.
        do {
            if try manager.alarms.contains(where: { $0.id == id && $0.state == .alerting }) {
                try manager.stop(id: id)
            }
        } catch {
            message = "鳴り続ける場合は、iPhoneのアラーム画面で停止できます。"
        }
        if !resume { restoreToday() }
        page = .today
        stage = .waking
        wakeSession = true
        defaults.set(Postcard.dayKey(date), forKey: "pendingWakeDay")
        resetIdleTimer()
    }

    func silenceFromSystem(_ id: UUID, isInitial: Bool) async {
        if isInitial {
            guard testID == id || wakeAlarms.contains(where: { $0.systemID == id }) else { return }
            openFromAlarm(id)
            idleTask?.cancel()
            await scheduleReminder(after: 60)
        } else if reminderID == id || (reminderID == nil && wakeSession && stage == .waking) {
            finishWake()
            restoreToday()
        }
    }

    private enum AlarmAccess: Error { case denied }

    private func authorizeAlarms() async throws {
        if manager.authorizationState == .notDetermined { _ = try await manager.requestAuthorization() }
        guard manager.authorizationState == .authorized else { throw AlarmAccess.denied }
    }

    private func persistAlarms() {
        if let data = try? JSONEncoder().encode(wakeAlarms) {
            defaults.set(data, forKey: "wakeAlarms")
        }
    }

    private func cancelAlarm(_ id: UUID) throws {
        if try manager.alarms.contains(where: { $0.id == id }) { try manager.cancel(id: id) }
    }

    func enteredBackground() {
        if wakeSession { interruptWake() }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        guard wakeSession else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.interruptWake()
        }
    }

    private func interruptWake() {
        guard wakeSession, reminderID == nil else { return }
        idleTask?.cancel()
        stage = .waking
        let application = UIApplication.shared
        let background = application.beginBackgroundTask(withName: "Schedule morning reminder", expirationHandler: nil)
        Task {
            defer {
                if background != .invalid { application.endBackgroundTask(background) }
            }
            await scheduleReminder(after: 4)
        }
    }

    private func scheduleReminder(after delay: TimeInterval) async {
        guard wakeSession, reminderID == nil else { return }
        let id = UUID()
        setReminder(id)
        pendingReminders.insert(id)
        defer { pendingReminders.remove(id) }
        do {
            try await schedule(id, schedule: .fixed(.now.addingTimeInterval(delay)), isInitial: false)
            if !wakeSession || reminderID != id { try? remove(id) }
        } catch {
            if reminderID == id { setReminder(nil) }
            if wakeSession { message = "再アラームを設定できませんでした。" }
        }
    }

    private func finishWake() {
        wakeSession = false
        defaults.removeObject(forKey: "pendingWakeDay")
        idleTask?.cancel()
        _ = cancelReminder()
    }

    private func cancelReminder() -> Bool {
        guard let reminderID else { return true }
        do {
            try remove(reminderID)
            setReminder(nil)
            return true
        } catch {
            message = "再アラームを停止できませんでした。もう一度お試しください。"
            return false
        }
    }

    private func remove(_ id: UUID) throws {
        guard let alarm = try manager.alarms.first(where: { $0.id == id }) else { return }
        if alarm.state == .alerting {
            try manager.stop(id: id)
        } else {
            try manager.cancel(id: id)
        }
    }

    private func schedule(_ id: UUID, schedule: Alarm.Schedule, isInitial: Bool) async throws {
        let presentation = AlarmPresentation(alert: .init(
            title: "未来の一片",
            stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill"),
            secondaryButton: AlarmButton(text: "今日の一片を開く", textColor: .white, systemImageName: "sun.horizon.fill"),
            secondaryButtonBehavior: .custom
        ))
        let configuration = AlarmManager.AlarmConfiguration<MorningMetadata>.alarm(
            schedule: schedule,
            attributes: AlarmAttributes(presentation: presentation, metadata: MorningMetadata(), tintColor: Color(red: 0.58, green: 0.27, blue: 0.15)),
            stopIntent: SilenceMorningIntent(alarmID: id, isInitial: isInitial),
            secondaryIntent: OpenMorningIntent(alarmID: id),
            sound: .named("Dawn.wav")
        )
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    private func setReminder(_ id: UUID?) {
        reminderID = id
        defaults.set(id?.uuidString, forKey: "reminderID")
    }
}

@MainActor
private final class Effects {
    private lazy var keys = (0..<4).compactMap { _ in player("Key") }
    private lazy var saved = player("Saved")
    private var next = 0

    private func player(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let audio = try? AVAudioPlayer(contentsOf: url) else { return nil }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        audio.prepareToPlay()
        return audio
    }

    func playKey() {
        guard !keys.isEmpty else { return }
        let key = keys[next]
        next = (next + 1) % keys.count
        key.currentTime = 0
        key.play()
    }

    func playSaved() {
        saved?.currentTime = 0
        saved?.play()
    }
}
