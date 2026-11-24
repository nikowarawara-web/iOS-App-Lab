import SwiftUI
import UIKit

@main
struct MiraiApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var model = MorningModel.shared

    var body: some Scene {
        WindowGroup {
            JournalView(model: model)
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

private let ink = Color(red: 0.21, green: 0.15, blue: 0.12)
private let earth = Color(red: 0.43, green: 0.35, blue: 0.29)
private let clay = Color(red: 0.53, green: 0.26, blue: 0.16)
private let parchment = Color(red: 0.98, green: 0.95, blue: 0.90)
private let paper = Color(red: 1, green: 0.99, blue: 0.96)

struct JournalView: View {
    @Bindable var model: MorningModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            LinearGradient(colors: [Color(red: 0.97, green: 0.90, blue: 0.80), parchment, paper],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.stage)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Label("未来の一片", systemImage: "sun.horizon")
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                Spacer(minLength: 6)
                tabs
            }
            tabs
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: 606)
        .frame(maxWidth: .infinity)
        .background(parchment)
        .overlay(alignment: .bottom) { Divider().overlay(clay.opacity(0.1)) }
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
                .background(model.page == page ? clay.opacity(0.12) : .clear, in: Capsule())
                .foregroundStyle(model.page == page ? clay : earth)
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
                    .foregroundStyle(earth)
                title(model.stage == .waking ? "おはようございます" : "今日の一片")
            }
            SceneImage(index: model.passage.image, description: model.passage.description)
            VStack(alignment: .leading, spacing: 17) {
                Text(markedPassage)
                    .font(.system(.title3, design: .serif, weight: .medium))
                    .lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(model.passage.text)
                Divider()
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
                    Text("今日も、よい一日を。").font(.system(.headline, design: .serif))
                    Button("書き写す") { model.startTyping() }
                        .font(.subheadline.weight(.semibold))
                        .tint(clay)
                }
            }
            .padding(19)
            .background(paper, in: RoundedRectangle(cornerRadius: 23))
            .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(clay.opacity(0.14)) }
        }
    }

    private var markedPassage: AttributedString {
        var result = AttributedString()
        var index = 0
        let letters = Passage.letters(model.committed)
        let expected = Passage.letters(model.passage.text)
        for char in model.passage.text.precomposedStringWithCanonicalMapping {
            var part = AttributedString(String(char))
            if !char.isPunctuation && !char.isWhitespace {
                if model.stage == .typing && index < letters.count && index < expected.count {
                    if letters[index] == expected[index] {
                        part.foregroundColor = Color(red: 0.27, green: 0.37, blue: 0.23)
                    } else {
                        part.foregroundColor = Color(red: 0.58, green: 0.15, blue: 0.13)
                        part.backgroundColor = clay.opacity(0.12)
                    }
                }
                index += 1
            }
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
                    .foregroundStyle(earth)
                    .padding(.vertical, 12)
            }
            LazyVStack(spacing: 22) {
                ForEach(model.postcards) { card in
                    VStack(alignment: .leading, spacing: 14) {
                        SceneImage(index: card.art, description: card.description)
                        Text(dateLabel(card.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(earth)
                        Text(card.text)
                            .font(.system(.body, design: .serif))
                            .lineSpacing(5)
                    }
                    .padding(14)
                    .background(paper, in: RoundedRectangle(cornerRadius: 23))
                    .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(clay.opacity(0.14)) }
                }
            }
        }
    }

    private var alarm: some View {
        Group {
            title("朝のアラーム")
            VStack(alignment: .leading, spacing: 14) {
                DatePicker("鳴らす時刻", selection: $model.alarmTime, displayedComponents: .hourAndMinute)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    .tint(clay)
                if let scheduled = model.scheduled {
                    Label(scheduled.formatted(.dateTime.month().day().weekday().hour().minute().locale(Locale(identifier: "ja_JP"))),
                          systemImage: "bell.badge")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(clay)
                }
                primary("次のこの時刻にセット", symbol: "alarm") {
                    Task { await model.scheduleMorning() }
                }
                .disabled(model.busy)
                HStack(spacing: 14) {
                    if model.scheduled == nil {
                        Button("20秒後にテスト") { Task { await model.scheduleMorning(test: true) } }
                    } else {
                        Button("アラームを解除", role: .destructive) { model.cancelMorning() }
                    }
                }
                .font(.subheadline)
                .disabled(model.busy)
                .tint(clay)
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(earth)
                }
            }
            .padding(19)
            .background(paper, in: RoundedRectangle(cornerRadius: 23))
            Toggle("入力音と完了音", isOn: $model.soundEnabled)
                .tint(clay)
                .padding(19)
                .background(paper, in: RoundedRectangle(cornerRadius: 23))
            Text("アラームの「今日の一片を開く」から始めます。入力が1分途切れるか、画面を離れると再び鳴ります。")
                .font(.footnote)
                .foregroundStyle(earth)
        }
    }

    private func title(_ label: String) -> some View {
        Text(label)
            .font(.system(.largeTitle, design: .serif, weight: .semibold))
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

private struct SceneImage: View {
    let index: Int
    let description: String

    var body: some View {
        Color(red: 0.93, green: 0.84, blue: 0.73)
            .aspectRatio(1.6, contentMode: .fit)
            .overlay {
                if let image = UIImage(named: "scene\(index).jpg") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 21))
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
