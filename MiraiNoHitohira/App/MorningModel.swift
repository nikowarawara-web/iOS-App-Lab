import AlarmKit
import AppIntents
import AVFoundation
import SwiftUI
import UIKit

struct MorningMetadata: AlarmMetadata {}

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
    var alarmTime: Date
    var message: String?
    var busy = false
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: "soundEnabled") }
    }
    private(set) var date = Date()
    private(set) var passage: Passage
    private(set) var postcards: [Postcard]
    private(set) var scheduled: Date?
    private(set) var wakeSession = false

    private let library: SceneLibrary
    private let defaults = UserDefaults.standard
    private let manager = AlarmManager.shared
    private let sounds = Effects()
    private var mainID: UUID?
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
        postcards = cards
        alarmTime = Calendar.current.date(bySettingHour: 5, minute: 30, second: 0, of: now) ?? now
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        scheduled = defaults.object(forKey: "mainDate") as? Date
        mainID = defaults.string(forKey: "mainID").flatMap(UUID.init(uuidString:))
        reminderID = defaults.string(forKey: "reminderID").flatMap(UUID.init(uuidString:))
        if let scheduled { alarmTime = scheduled }
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
        if let mainID, scheduled.map({ $0 <= Date() }) == true,
           !alarms.contains(where: { $0.id == mainID }) {
            setMain(nil, at: nil)
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
        let card = Postcard(day: Postcard.dayKey(date), date: date, text: passage.text, art: passage.image, description: passage.description)
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

    func scheduleMorning(test: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            let status = manager.authorizationState
            if status == .notDetermined { _ = try await manager.requestAuthorization() }
            guard manager.authorizationState == .authorized else {
                message = "iPhoneの「設定」で、このアプリのアラームを許可してください。"
                return
            }
            var time = Calendar.current.dateComponents([.hour, .minute], from: alarmTime)
            time.second = 0
            let date: Date
            if test {
                date = Date().addingTimeInterval(20)
            } else if let next = Calendar.current.nextDate(after: .now, matching: time, matchingPolicy: .nextTime) {
                date = next
            } else {
                message = "時刻を選び直してください。"
                return
            }
            let newID = UUID()
            try await schedule(newID, date: date, isInitial: true)
            if let mainID {
                do { try remove(mainID) } catch {
                    try? remove(newID)
                    throw error
                }
            }
            setMain(newID, at: date)
            message = test ? "20秒後に鳴ります。画面をロックして試せます。" : "アラームを設定しました。"
        } catch {
            message = "アラームを設定できませんでした。もう一度お試しください。"
        }
    }

    func cancelMorning() {
        guard let mainID else { return }
        do {
            try remove(mainID)
            setMain(nil, at: nil)
            message = "アラームを解除しました。"
        } catch {
            message = "アラームを解除できませんでした。もう一度お試しください。"
        }
    }

    func openFromAlarm(_ id: UUID) {
        let resume = (id == reminderID || wakeSession) && Postcard.dayKey(date) == Postcard.dayKey(.now)
        message = nil
        if id == mainID { setMain(nil, at: nil) }
        if id == reminderID { setReminder(nil) }
        // AlarmKit may have already stopped a one-shot alarm when its button was pressed.
        do { try remove(id) } catch { message = "鳴り続ける場合は、iPhoneのアラーム画面で停止できます。" }
        if !resume { restoreToday() }
        page = .today
        stage = .waking
        wakeSession = true
        defaults.set(Postcard.dayKey(date), forKey: "pendingWakeDay")
        resetIdleTimer()
    }

    func silenceFromSystem(_ id: UUID, isInitial: Bool) async {
        if isInitial {
            if let mainID, mainID != id { return }
            openFromAlarm(id)
            idleTask?.cancel()
            await scheduleReminder(after: 60)
        } else if reminderID == id || (reminderID == nil && wakeSession && stage == .waking) {
            finishWake()
            restoreToday()
        }
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
            try await schedule(id, date: Date().addingTimeInterval(delay), isInitial: false)
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

    private func schedule(_ id: UUID, date: Date, isInitial: Bool) async throws {
        let presentation = AlarmPresentation(alert: .init(
            title: "未来の一片",
            stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill"),
            secondaryButton: AlarmButton(text: "今日の一片を開く", textColor: .white, systemImageName: "sun.horizon.fill"),
            secondaryButtonBehavior: .custom
        ))
        let configuration = AlarmManager.AlarmConfiguration<MorningMetadata>.alarm(
            schedule: .fixed(date),
            attributes: AlarmAttributes(presentation: presentation, metadata: MorningMetadata(), tintColor: Color(red: 0.58, green: 0.27, blue: 0.15)),
            stopIntent: SilenceMorningIntent(alarmID: id, isInitial: isInitial),
            secondaryIntent: OpenMorningIntent(alarmID: id),
            sound: .named("Dawn.wav")
        )
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    private func setMain(_ id: UUID?, at date: Date?) {
        mainID = id
        scheduled = date
        defaults.set(id?.uuidString, forKey: "mainID")
        defaults.set(date, forKey: "mainDate")
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
