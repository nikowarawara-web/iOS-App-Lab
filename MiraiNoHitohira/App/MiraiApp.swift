import AVFoundation
import SwiftUI
import UIKit

@main
struct MiraiApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var model = MorningModel.shared
    @State private var soundscape = AmbientSoundscape()

    var body: some Scene {
        WindowGroup {
            TimelineView(.everyMinute) { clock in
                let light = JournalLight(at: clock.date)
                let audibleLight: JournalLight? = model.ambientSoundEnabled && phase == .active ? light : nil
                JournalView(model: model, light: light)
                    .onChange(of: audibleLight, initial: true) { _, value in soundscape.update(value) }
                    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                        guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
                        soundscape.update(type == .ended ? audibleLight : nil)
                    }
            }
            .preferredColorScheme(.light)
            .task { await model.observeAlarms() }
            .onOpenURL { model.openURL($0) }
            .onChange(of: phase) { _, value in
                if value == .active { model.refreshDay() }
                if value == .background { model.enteredBackground() }
            }
        }
    }
}

private let ink = Color(red: 0.20, green: 0.16, blue: 0.17)
private let earth = Color(red: 0.42, green: 0.32, blue: 0.30)
private let clay = Color(red: 0.54, green: 0.28, blue: 0.24)
private let parchment = Color(red: 0.95, green: 0.90, blue: 0.84)
private let paper = Color(red: 0.99, green: 0.96, blue: 0.90)

private func handwritten(_ style: Font.TextStyle, bold: Bool = false) -> Font {
    let face = bold ? "KleeOne-SemiBold" : "KleeOne-Regular"
    let size: CGFloat
    switch style {
    case .largeTitle: size = 34
    case .title2: size = 23
    case .subheadline: size = 15
    default: size = 18
    }
    return .custom(face, size: size, relativeTo: style)
}

struct JournalView: View {
    @Bindable var model: MorningModel
    let light: JournalLight
    @State private var editingAlarm: WakeAlarm?
    @State private var replayCard: Postcard?
    @State private var flight: FlyingPostcard?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var skyInk: Color { light.usesDarkText ? ink : Color(red: 1, green: 0.94, blue: 0.85) }
    private var mutedSkyInk: Color { light.usesDarkText ? earth : Color(red: 0.97, green: 0.89, blue: 0.86) }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width > 500 ? 38.0 : 22.0
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch model.page {
                        case .today: today
                        case .archive: archive
                        case .alarm: alarm
                        }
                    }
                    .frame(maxWidth: 530)
                    .padding(.horizontal, side)
                    .padding(.top, 21)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity)
                    .id(model.page)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .onChange(of: model.letter.canSend(model.passage.text)) { _, ready in
                    if ready && model.page == .today && model.stage == .typing {
                        scroll.scrollTo("sendPostcard", anchor: .bottom)
                    }
                }
                .onChange(of: model.stage == .saved && flight == nil) { _, delivered in
                    guard delivered, model.page == .today,
                          SceneImage.hasMotion(model.passage.image) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                        scroll.scrollTo("todayArtwork", anchor: .top)
                    }
                }
            }
        }
        .foregroundStyle(ink)
        .background {
            ZStack {
                light.header
                ForEach(JournalLight.allCases, id: \.self) { sky in
                    ZStack {
                        LinearGradient(colors: sky.sky, startPoint: .topLeading, endPoint: .bottomTrailing)
                        RadialGradient(colors: [sky.glow, .clear], center: .bottomTrailing, startRadius: 8, endRadius: 480)
                    }
                    .opacity(sky == light ? 1 : 0)
                }
            }
            .ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.stage)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: light)
        .allowsHitTesting(flight == nil)
        .overlay {
            if let flight {
                PostcardFlightOverlay(postcard: flight) { self.flight = nil }
                    .id(flight.id)
            }
        }
        .sheet(item: $replayCard) { card in
            PostcardReplay(card: card, onKey: model.playKeyFeedback, onSent: model.playSendFeedback)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Label("未来の一片", systemImage: "sun.horizon")
                    .font(handwritten(.subheadline, bold: true))
                    .foregroundStyle(skyInk)
                Spacer(minLength: 6)
                tabs
            }
            tabs
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: 606)
        .frame(maxWidth: .infinity)
        .background(light.header)
        .overlay(alignment: .bottom) { Rectangle().fill(skyInk.opacity(0.14)).frame(height: 1) }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tab(.today, "今日", "sun.max")
            tab(.archive, "絵葉書", "tray")
            tab(.alarm, "アラーム", "alarm")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tab(_ page: MorningModel.Page, _ label: String, _ symbol: String) -> some View {
        Button { model.select(page) } label: {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .background(model.page == page ? skyInk.opacity(0.15) : .clear, in: Capsule())
                .foregroundStyle(model.page == page ? skyInk : mutedSkyInk)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.page == page ? .isSelected : [])
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dateLabel(model.date))
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(mutedSkyInk)
                title(model.stage == .waking ? "おはようございます" : "今日の一片")
            }
            VStack(alignment: .leading, spacing: 0) {
                SceneImage(index: model.passage.image, description: model.passage.description,
                           playOnCompletion: model.stage == .saved && flight == nil)
                    .id("todayArtwork")
                    .padding(9)
                VStack(alignment: .leading, spacing: 13) {
                    if let name = model.passage.title {
                        Text(name)
                            .font(handwritten(.title2, bold: true))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(highlightedPassage(model.passage.text, committed: model.stage == .typing ? model.letter.committed : ""))
                        .font(handwritten(.body))
                        .lineSpacing(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(model.passage.text)
                }
                .padding(.horizontal, 18)
                .padding(.top, 7)
                .padding(.bottom, 19)
            }
            .background(paper, in: RoundedRectangle(cornerRadius: 15))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
            VStack(alignment: .leading, spacing: 13) {
                switch model.stage {
                case .waking:
                    if let message = model.message {
                        Text(message).font(.footnote).foregroundStyle(earth)
                    }
                    primary("書き写す", symbol: "pencil") { model.startTyping() }
                    readButton
                case .typing:
                    PostcardComposer(passage: model.passage.text, letter: model.letter,
                                     onEdit: model.input, onSend: sendToday)
                        .id(model.inputSession)
                    readButton
                case .saved:
                    if flight == nil {
                        DeliveryReceipt()
                        Button("絵葉書を見る") { model.select(.archive) }
                            .font(.subheadline.weight(.semibold))
                            .tint(clay)
                    }
                case .reading:
                    Text("今日も、よい一日を。").font(handwritten(.headline, bold: true))
                    Button("書き写す") { model.startTyping() }
                        .font(.subheadline.weight(.semibold))
                        .tint(clay)
                }
            }
            .padding(17)
            .background(parchment, in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func sendToday() {
        guard model.sendToday() else { return }
        let animated = !reduceMotion
        model.playSendFeedback(animated: animated)
        if animated { flight = FlyingPostcard(art: model.passage.image, title: model.passage.title) }
    }

    private var readButton: some View {
        Button("今日は読むだけにする") { model.readOnly() }
            .font(.subheadline.weight(.medium))
            .tint(clay)
            .frame(minHeight: 44, alignment: .leading)
    }

    private var archive: some View {
        Group {
            title("未来の絵葉書")
            if model.postcards.isEmpty {
                Text("未来へ送った絵葉書が、ここに並びます。")
                    .foregroundStyle(mutedSkyInk)
                    .padding(.vertical, 12)
            }
            LazyVStack(spacing: 22) {
                ForEach(model.postcards) { card in
                    VStack(alignment: .leading, spacing: 14) {
                        SceneImage(index: card.art, description: card.description)
                        Text(dateLabel(card.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(earth)
                        if let name = card.title {
                            Text(name).font(handwritten(.title2, bold: true)).accessibilityAddTraits(.isHeader)
                        }
                        Text(card.text)
                            .font(handwritten(.body))
                            .lineSpacing(7)
                        Button {
                            replayCard = card
                        } label: {
                            Label("もう一度書く", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(clay)
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(13)
                    .background(paper, in: RoundedRectangle(cornerRadius: 15))
                    .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
                }
            }
        }
    }

    private var alarm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                title("朝のアラーム")
                Spacer(minLength: 12)
                Button {
                    editingAlarm = WakeAlarm()
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 46, height: 46)
                        .background(skyInk.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(skyInk)
                .accessibilityLabel("アラームを追加")
                .disabled(model.busy)
            }
            if model.wakeAlarms.isEmpty {
                Text("＋から起きる時刻を設定できます。")
                    .font(.subheadline)
                    .foregroundStyle(mutedSkyInk)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.wakeAlarms) { alarm in
                        HStack(spacing: 14) {
                            Button {
                                editingAlarm = alarm
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(alarm.timeLabel)
                                        .font(.system(.title, design: .rounded, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(ink)
                                    Text(alarm.repeatLabel)
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(earth)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy)
                            .accessibilityHint("編集")
                            Toggle("", isOn: Binding(
                                get: { alarm.enabled },
                                set: { enabled in Task { await model.setAlarmEnabled(alarm, enabled: enabled) } }
                            ))
                            .labelsHidden()
                            .tint(clay)
                            .accessibilityLabel("\(alarm.timeLabel)のアラーム")
                            .disabled(model.busy)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        if alarm.id != model.wakeAlarms.last?.id {
                            Divider().padding(.horizontal, 18)
                        }
                    }
                }
                .background(paper, in: RoundedRectangle(cornerRadius: 18))
            }
            VStack(alignment: .leading, spacing: 13) {
                Toggle("入力音と完了音", isOn: $model.soundEnabled).tint(clay)
                Toggle("環境音", isOn: $model.ambientSoundEnabled).tint(clay)
                Divider()
                if model.testScheduled {
                    Button("テストを取り消す", role: .destructive) { model.cancelTest() }
                        .disabled(model.busy)
                } else {
                    Button("20秒後にテスト") { Task { await model.scheduleTest() } }
                        .disabled(model.busy)
                }
                if let message = model.alarmMessage {
                    Text(message).font(.footnote).foregroundStyle(earth)
                }
            }
            .font(.subheadline)
            .foregroundStyle(ink)
            .tint(clay)
            .padding(18)
            .background(paper, in: RoundedRectangle(cornerRadius: 18))
            Text("「今日の一片を開く」で絵と文章を表示します。入力が１分途切れるか、画面を離れると再び鳴ります。")
                .font(.footnote)
                .foregroundStyle(mutedSkyInk)
        }
        .sheet(item: $editingAlarm) { draft in
            AlarmEditor(model: model, alarm: draft)
        }
    }

    private func title(_ label: String) -> some View {
        Text(label)
            .font(handwritten(.largeTitle, bold: true))
            .foregroundStyle(skyInk)
            .accessibilityAddTraits(.isHeader)
    }

    private func primary(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(clay)
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "ja_JP")))
    }
}

private struct AlarmEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: MorningModel
    let isExisting: Bool
    @State private var draft: WakeAlarm
    @State private var clock: Date

    init(model: MorningModel, alarm: WakeAlarm) {
        self.model = model
        isExisting = model.wakeAlarms.contains { $0.id == alarm.id }
        _draft = State(initialValue: alarm)
        _clock = State(initialValue: alarm.dateSelection)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("時刻", selection: $clock, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    .frame(maxWidth: .infinity)
                Section("繰り返し") {
                    ViewThatFits {
                        HStack(spacing: 18) { presets }
                        VStack(alignment: .leading, spacing: 8) { presets }
                    }
                    .buttonStyle(.borderless)
                    ForEach(WakeDay.allCases) { day in
                        Button {
                            if draft.days.contains(day) { draft.days.remove(day) }
                            else { draft.days.insert(day) }
                        } label: {
                            HStack {
                                Text(day.name).foregroundStyle(ink)
                                Spacer()
                                if draft.days.contains(day) {
                                    Image(systemName: "checkmark").foregroundStyle(clay)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.days.contains(day) ? .isSelected : [])
                    }
                }
                if isExisting {
                    Section {
                        Button("アラームを削除", role: .destructive) {
                            if model.deleteAlarm(draft) { dismiss() }
                        }
                    }
                }
                if let message = model.alarmMessage {
                    Section { Text(message).font(.footnote).foregroundStyle(earth) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(parchment)
            .navigationTitle(isExisting ? "アラームを編集" : "アラームを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let time = Calendar.current.dateComponents([.hour, .minute], from: clock)
                        var next = draft
                        next.hour = time.hour ?? 5
                        next.minute = time.minute ?? 30
                        Task { if await model.saveAlarm(next) { dismiss() } }
                    }
                    .fontWeight(.semibold)
                }
            }
            .disabled(model.busy)
            .interactiveDismissDisabled(model.busy)
            .tint(clay)
        }
    }

    private var presets: some View {
        Group {
            Button("１回のみ") { draft.days = [] }
            Button("毎日") { draft.days = Set(WakeDay.allCases) }
            Button("平日") { draft.days = Set(WakeDay.allCases.prefix(5)) }
        }
    }
}

private struct SceneImage: View {
    let index: Int
    let description: String
    var playOnCompletion = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?

    static func hasMotion(_ index: Int) -> Bool { motionResource(for: index) != nil }

    private static func motionResource(for index: Int) -> URL? {
        Bundle.main.url(forResource: "scene\(index)", withExtension: "mp4", subdirectory: "Motion")
    }

    static func artwork(for index: Int) -> UIImage? {
        if index < 8 { return UIImage(named: "scene\(index).jpg") }
        let path = Bundle.main.path(forResource: "scene\(index)", ofType: "jpg", inDirectory: "Memories")
        return path.flatMap { UIImage(contentsOfFile: $0) }
    }

    private var motionURL: URL? {
        reduceMotion ? nil : Self.motionResource(for: index)
    }

    var body: some View {
        Group {
            if motionURL != nil {
                Button(action: playMotion) { picture }
                    .buttonStyle(.plain)
                    .accessibilityLabel(description)
                    .accessibilityHint("絵のアニメーションを再生")
            } else {
                picture.accessibilityLabel(description).accessibilityAddTraits(.isImage)
            }
        }
        .onChange(of: playOnCompletion) { _, completed in
            if completed { playMotion() }
        }
        .onChange(of: index) { _, _ in releasePlayer() }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { releasePlayer() }
        }
        .onDisappear(perform: releasePlayer)
    }

    private var picture: some View {
        Color(red: 0.93, green: 0.84, blue: 0.73)
            .aspectRatio(1.53, contentMode: .fit)
            .overlay {
                if let image = Self.artwork(for: index) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                if let player {
                    InlineMotion(player: player)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func playMotion() {
        guard let motionURL else { return }
        releasePlayer()
        let next = AVPlayer(url: motionURL)
        next.isMuted = true
        next.actionAtItemEnd = .pause
        player = next
        next.play()
    }

    private func releasePlayer() {
        player?.pause()
        player = nil
    }
}

private struct InlineMotion: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.isOpaque = false
        surface.backgroundColor = .clear
        surface.video.videoGravity = .resizeAspectFill
        return surface
    }

    func updateUIView(_ surface: Surface, context: Context) {
        surface.setPlayer(player)
    }

    static func dismantleUIView(_ surface: Surface, coordinator: ()) {
        surface.setPlayer(nil)
    }

    final class Surface: UIView {
        private var readiness: NSKeyValueObservation?
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var video: AVPlayerLayer { layer as! AVPlayerLayer }

        func setPlayer(_ player: AVPlayer?) {
            guard video.player !== player else { return }
            readiness = nil
            video.opacity = 0
            video.player = player
            if let player {
                readiness = video.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak player] _, _ in
                    DispatchQueue.main.async {
                        guard let self, let player, self.video.player === player else { return }
                        self.video.opacity = self.video.isReadyForDisplay ? 1 : 0
                    }
                }
            }
        }
    }
}

private func highlightedPassage(_ passage: String, committed: String) -> AttributedString {
    var result = AttributedString()
    var index = 0
    let letters = Passage.letters(committed)
    for char in passage.precomposedStringWithCanonicalMapping {
        var part = AttributedString(String(char))
        let expected = Passage.letters(String(char))
        let typed = letters.dropFirst(index).prefix(expected.count)
        if !typed.isEmpty {
            if typed.elementsEqual(expected.prefix(typed.count)) {
                part.foregroundColor = Color(red: 0.27, green: 0.37, blue: 0.23)
            } else {
                part.foregroundColor = Color(red: 0.58, green: 0.15, blue: 0.13)
                part.backgroundColor = clay.opacity(0.12)
            }
        }
        index += expected.count
        result.append(part)
    }
    return result
}

private struct PostcardComposer: View {
    let passage: String
    let letter: LetterDraft
    let onEdit: (String, Bool) -> Void
    let onSend: () -> Void

    var body: some View {
        let match = letter.match(passage)
        let canSend = letter.canSend(passage)
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("上の文章を書き写す").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(match.matched) / \(match.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(earth)
                    .accessibilityLabel("一致した文字数")
                    .accessibilityValue("\(match.matched)文字、全\(match.count)文字")
            }
            ProgressView(value: Double(match.matched), total: Double(max(1, match.count)))
                .tint(clay)
                .accessibilityHidden(true)
            JapaneseInput(text: letter.text, onEdit: onEdit)
                .frame(minHeight: 95)
                .padding(7)
                .background(paper, in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(clay.opacity(0.19)) }

            Text(hint(match, canSend: canSend))
                .font(.footnote)
                .foregroundStyle(earth)

            Button(action: onSend) {
                Label("未来へ送る", systemImage: "paperplane.fill")
                    .font(handwritten(.subheadline, bold: true))
                    .frame(maxWidth: .infinity, minHeight: 47)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(clay)
            .disabled(!canSend)
            .id("sendPostcard")
        }
    }

    private func hint(_ match: MatchState, canSend: Bool) -> String {
        if letter.isComposing { return "変換を確定すると照合できます。" }
        if canSend { return "書き写せました。未来の自分に送れます。" }
        if match.excess { return "文の終わりに余分な文字があります。" }
        if match.incorrect { return "色が付いた文字と句読点を確認してください。" }
        return "句読点とかぎ括弧まで写します。空白は省略できます。"
    }
}

private struct FlyingPostcard: Identifiable {
    let id = UUID()
    let artwork: UIImage?
    let title: String?
    let launchedAt = Date()

    init(art: Int, title: String?) {
        self.artwork = SceneImage.artwork(for: art)
        self.title = title
    }
}

private struct PostcardFlightOverlay: View {
    let postcard: FlyingPostcard
    let onArrival: () -> Void

    var body: some View {
        GeometryReader { bounds in
            let screen = bounds.size
            let width = max(20, min(screen.width * 0.75, screen.height * 0.68, 340))
            let cardSize = CGSize(width: width, height: (width - 16) / 1.53 + 49)
            let launchY = min(screen.height * 0.73, screen.height - cardSize.height * 0.44 - 18)
            let hoverY = max(screen.height * 0.28, cardSize.height * 0.5 + 57)
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { clock in
                let time = max(0, clock.date.timeIntervalSince(postcard.launchedAt))
                let lift = ease(time / 1.72)
                let reveal = ease(time / 0.28)
                let curtain = reveal * (1 - ease((time - 3.63) / 1.02))
                let sway = sin(lift * .pi)
                let hover = sin(time * 3.6) * 2.6 * lift
                let firelight = ease((time - PostcardBurn.ignition) / 0.36) * (1 - ease((time - 3.53) / 0.92))
                ZStack {
                    Color(red: 0.11, green: 0.073, blue: 0.10).opacity(0.64 * curtain)
                    RadialGradient(colors: [.orange.opacity(0.10 * curtain + 0.17 * firelight), .clear],
                                   center: UnitPoint(x: 0.50, y: 0.30), startRadius: 0, endRadius: width)
                    burningCard(size: cardSize, time: time)
                        .scaleEffect(CGFloat(0.78 + 0.22 * lift + 0.035 * sway))
                        .rotationEffect(.degrees(-7 + 7 * lift + 14 * sway))
                        .opacity(reveal)
                        .position(x: screen.width * CGFloat(0.49 + 0.12 * sway),
                                  y: launchY + (hoverY - launchY) * lift + hover)
                }
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { @MainActor in
            let remaining = max(0, PostcardBurn.duration + postcard.launchedAt.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            onArrival()
        }
    }

    private func burningCard(size: CGSize, time: Double) -> some View {
        let burn = PostcardBurn(time: time, size: size)
        let bleed: CGFloat = 144
        return face(size: size)
            .overlay {
                if time >= PostcardBurn.ignition {
                    Canvas { context, _ in burn.drawScorch(in: context) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .mask(burn.remainingPaper().fill(.white))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .overlay {
                if time >= PostcardBurn.ignition {
                    Canvas { context, _ in burn.drawLight(in: context, bleed: bleed) }
                        .frame(width: size.width + 2 * bleed, height: size.height + 2 * bleed)
                }
            }
    }

    private func face(size: CGSize) -> some View {
        let imageWidth = size.width - 16
        return VStack(spacing: 7) {
            if let image = postcard.artwork {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1.53, contentMode: .fill)
                    .frame(width: imageWidth, height: imageWidth / 1.53)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            HStack {
                if let title = postcard.title {
                    Text(title)
                        .font(handwritten(.subheadline, bold: true))
                        .lineLimit(1)
                }
                Spacer(minLength: 5)
                Image(systemName: "paperplane")
                    .font(.caption)
                    .foregroundStyle(clay)
            }
            .padding(.horizontal, 3)
            .frame(height: 26)
        }
        .padding(8)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(ink)
        .background(paper, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(clay.opacity(0.18)) }
    }

    private func ease(_ amount: Double) -> Double {
        let t = min(1, max(0, amount))
        return t * t * (3 - 2 * t)
    }
}

private struct DeliveryReceipt: View {
    var body: some View {
        Label("未来へ送りました", systemImage: "paperplane.fill")
            .font(handwritten(.headline, bold: true))
            .foregroundStyle(clay)
            .transition(.opacity.combined(with: .offset(y: 7)))
    }
}

private struct PostcardReplay: View {
    let card: Postcard
    let onKey: () -> Void
    let onSent: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var letter = LetterDraft()
    @State private var sent = false
    @State private var flight: FlyingPostcard?

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            SceneImage(index: card.art, description: card.description, playOnCompletion: sent && flight == nil)
                                .id("replayArtwork")
                            if let title = card.title {
                                Text(title).font(handwritten(.title2, bold: true))
                                    .accessibilityAddTraits(.isHeader)
                            }
                            Text(highlightedPassage(card.text, committed: sent ? "" : letter.committed))
                                .font(handwritten(.body))
                                .lineSpacing(7)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(card.text)
                        }
                        .padding(13)
                        .background(paper, in: RoundedRectangle(cornerRadius: 15))
                        if sent {
                            if flight == nil {
                                VStack(alignment: .leading, spacing: 13) {
                                    DeliveryReceipt()
                                    Button("絵葉書に戻る") { dismiss() }
                                        .font(.subheadline.weight(.semibold))
                                        .tint(clay)
                                }
                                .padding(14)
                            }
                        } else {
                            PostcardComposer(passage: card.text, letter: letter,
                                             onEdit: updateDraft, onSend: sendAgain)
                        }
                    }
                    .frame(maxWidth: 530)
                    .padding(17)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: sent)
                .onChange(of: letter.canSend(card.text)) { _, ready in
                    if ready && !sent { scroll.scrollTo("sendPostcard", anchor: .bottom) }
                }
                .onChange(of: sent && flight == nil) { _, delivered in
                    if delivered {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            scroll.scrollTo("replayArtwork", anchor: .top)
                        }
                    }
                }
            }
            .background(parchment)
            .foregroundStyle(ink)
            .navigationTitle("もう一度書く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }.tint(clay)
                }
            }
        }
        .allowsHitTesting(flight == nil)
        .overlay {
            if let flight {
                PostcardFlightOverlay(postcard: flight) { self.flight = nil }
                    .id(flight.id)
            }
        }
        .interactiveDismissDisabled(flight != nil)
    }

    private func updateDraft(_ text: String, _ isComposing: Bool) {
        guard !sent else { return }
        if letter.text != text { onKey() }
        letter.edit(text, isComposing: isComposing)
    }

    private func sendAgain() {
        guard !sent, letter.canSend(card.text) else { return }
        let animated = !reduceMotion
        onSent(animated)
        if animated { flight = FlyingPostcard(art: card.art, title: card.title) }
        sent = true
    }
}

private struct JapaneseInput: UIViewRepresentable {
    let text: String
    let onEdit: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.text = text
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocapitalizationType = .none
        view.accessibilityLabel = "文章入力"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        if view.markedTextRange == nil && view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: 95)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String, Bool) -> Void
        private var lastText: String?
        private var lastComposing = false

        init(onEdit: @escaping (String, Bool) -> Void) { self.onEdit = onEdit }

        func textViewDidChange(_ view: UITextView) { report(view) }
        func textViewDidChangeSelection(_ view: UITextView) { report(view) }
        func textViewDidEndEditing(_ view: UITextView) { report(view) }

        private func report(_ view: UITextView) {
            // Selection can change just before UIKit updates the IME's marked range.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                let text = view.text ?? ""
                let composing = view.markedTextRange != nil
                guard lastText != text || lastComposing != composing else { return }
                lastText = text
                lastComposing = composing
                onEdit(text, composing)
            }
        }
    }
}
