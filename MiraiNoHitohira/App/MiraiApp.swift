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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var skyInk: Color { light.usesDarkText ? ink : Color(red: 1, green: 0.94, blue: 0.85) }
    private var mutedSkyInk: Color { light.usesDarkText ? earth : Color(red: 0.97, green: 0.89, blue: 0.86) }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width > 500 ? 38.0 : 22.0
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
                SceneImage(index: model.passage.image, description: model.passage.description)
                    .padding(9)
                VStack(alignment: .leading, spacing: 13) {
                    if let name = model.passage.title {
                        Text(name)
                            .font(handwritten(.title2, bold: true))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(markedPassage)
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
                    input
                case .saved:
                    Label("絵葉書に残しました", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(clay)
                    Button("絵葉書を見る") { model.select(.archive) }
                        .font(.subheadline.weight(.semibold))
                        .tint(clay)
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

    private var markedPassage: AttributedString {
        var result = AttributedString()
        var index = 0
        let letters = Passage.letters(model.committed)
        for char in model.passage.text.precomposedStringWithCanonicalMapping {
            var part = AttributedString(String(char))
            let expected = Passage.letters(String(char))
            let typed = letters.dropFirst(index).prefix(expected.count)
            if model.stage == .typing && !typed.isEmpty {
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

    private var input: some View {
        let match = model.match
        return VStack(alignment: .leading, spacing: 11) {
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
            JapaneseInput(text: model.draft, onEdit: model.input)
                .id(model.inputSession)
                .frame(minHeight: 95)
                .padding(7)
                .background(parchment, in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(clay.opacity(0.2)) }
            Text(match.excess ? "文の終わりに余分な文字があります。" :
                    match.incorrect ? "色が付いた文字を確認できます。" : "句読点や空白は省略できます。")
                .font(.footnote)
                .foregroundStyle(earth)
            readButton
        }
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
                Text("書き写し終えた場面が、ここに並びます。")
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

    private var artwork: UIImage? {
        if index < 8 { return UIImage(named: "scene\(index).jpg") }
        let path = Bundle.main.path(forResource: "scene\(index)", ofType: "jpg", inDirectory: "Memories")
        return path.flatMap { UIImage(contentsOfFile: $0) }
    }

    var body: some View {
        Color(red: 0.93, green: 0.84, blue: 0.73)
            .aspectRatio(1.53, contentMode: .fit)
            .overlay {
                if let image = artwork {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(description)
            .accessibilityAddTraits(.isImage)
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
