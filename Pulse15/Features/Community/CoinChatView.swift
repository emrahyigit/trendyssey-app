import SwiftUI

struct CoinChatPreview: View {
    let symbol: String
    var journeyID: UUID? = nil
    var journeyPhase: SignalStatus? = nil
    @State private var messages: [CoinChatMessage] = []
    @State private var loaded = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.default.rawValue
    private let service = CoinChatService()

    private var language: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .english }

    var body: some View {
        NavigationLink { CoinChatView(symbol: symbol, journeyID: journeyID, journeyPhase: journeyPhase) } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label(L10n.text("Community", "Topluluk"), systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.headline)
                    Spacer()
                    Text(L10n.text("OPEN CHAT", "SOHBETİ AÇ"))
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(PulseColor.accent)
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if messages.isEmpty {
                    Text(L10n.text("No messages yet. Start the conversation about \(symbol).", "Henüz mesaj yok. \(symbol) sohbetini başlat."))
                        .font(.caption).foregroundStyle(PulseColor.secondaryText)
                } else {
                    ForEach(messages.suffix(5)) { message in
                        HStack(alignment: .top, spacing: 9) {
                            PulseAvatarView(key: message.authorAvatarKey, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(message.authorDisplayName).font(.caption.bold())
                                    languageTag(message.languageCode)
                                }
                                Text(message.body).font(.caption).foregroundStyle(PulseColor.secondaryText).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: "\(symbol)|\(appLanguage)") {
            messages = (try? await service.messages(symbol: symbol, language: language, limit: 5)) ?? []
            loaded = true
        }
    }

    private func languageTag(_ code: String) -> some View {
        Text(code.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(PulseColor.accent)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(PulseColor.accent.opacity(0.12), in: Capsule())
    }
}

struct CoinChatView: View {
    let symbol: String
    var journeyID: UUID? = nil
    var journeyPhase: SignalStatus? = nil
    @State private var messages: [CoinChatMessage] = []
    @State private var draft = ""
    @State private var account: UserSyncService.AccountSnapshot = .anonymous
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var nextSendAt: Date?
    @State private var clock = Date()
    @State private var predictionTally: PredictionTally?
    @State private var isSubmittingPrediction = false
    @State private var accuracies: [UUID: PredictionAccuracy] = [:]
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.default.rawValue
    private let service = CoinChatService()
    private let predictionService = SignalPredictionService()

    private var language: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .english }

    private var showsPredictionBar: Bool {
        guard journeyID != nil, let journeyPhase else { return false }
        return [.preBreakout, .breakoutDetected, .retest, .confirmed].contains(journeyPhase)
    }

    var body: some View {
        VStack(spacing: 0) {
            Label(
                language == .turkish ? "Türkçe kanal" : "English channel",
                systemImage: "character.bubble"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PulseColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            if showsPredictionBar { predictionBar }
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            L10n.text("Start the conversation", "Sohbeti başlat"),
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(L10n.text("Share an observation, not financial advice.", "Bir gözlemini paylaş; yatırım tavsiyesi verme."))
                        ).padding(.top, 70)
                    }
                    ForEach(messages) { message in
                        messageRow(message)
                    }
                }
                .padding(16)
            }

            Divider()
            if account.isAnonymous {
                Label(
                    L10n.text("Connect with Apple in Profile to write.", "Yazmak için Profil'de Apple hesabını bağla."),
                    systemImage: "apple.logo"
                )
                .font(.caption.weight(.medium)).foregroundStyle(PulseColor.secondaryText).padding(14)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    PulseAvatarView(key: account.avatarKey, size: 34)
                    TextField(L10n.text("Message in English about \(symbol)…", "\(symbol) hakkında Türkçe mesaj…"), text: $draft, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.plain).padding(11)
                        .background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 15))
                    Button { Task { await send() } } label: {
                        Image(systemName: "arrow.up").font(.headline).foregroundStyle(.black)
                            .frame(width: 38, height: 38).background(PulseColor.accent, in: Circle())
                    }
                    .disabled(sendDisabled)
                }
                .padding(.horizontal, 12).padding(.top, 12)
                if backoffSeconds > 0 {
                    Label(
                        L10n.text("You can send again in \(backoffSeconds)s", "\(backoffSeconds) sn sonra yeniden yazabilirsin"),
                        systemImage: "timer"
                    )
                    .font(.caption2.weight(.medium)).foregroundStyle(PulseColor.secondaryText)
                    .padding(.top, 5).padding(.bottom, 8)
                } else {
                    Text(L10n.text("One message per minute", "Dakikada bir mesaj"))
                        .font(.caption2).foregroundStyle(PulseColor.secondaryText).padding(.vertical, 7)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(PulseColor.negative).padding(.bottom, 8)
            }
        }
        .background(PulseColor.canvas.ignoresSafeArea())
        .navigationTitle("\(symbol) · \(L10n.text("Chat", "Sohbet")) · \(language.rawValue.uppercased())")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(symbol)|\(appLanguage)") {
            account = await UserSyncService.shared.accountSnapshot()
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .task {
            while !Task.isCancelled {
                clock = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var predictionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(L10n.text("Will this breakout hold?", "Bu kırılım tutar mı?"), systemImage: "questionmark.circle.fill")
                    .font(.caption.weight(.bold))
                Spacer()
                if let mine = predictionTally?.mine {
                    Text(mine == "holds" ? L10n.text("Your call: holds", "Oyun: tutar") : L10n.text("Your call: fails", "Oyun: tutmaz"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(PulseColor.accent)
                }
            }
            HStack(spacing: 8) {
                predictionButton(
                    title: L10n.text("Holds", "Tutar"),
                    count: predictionTally?.holds ?? 0,
                    icon: "hand.thumbsup.fill",
                    color: PulseColor.positive,
                    selected: predictionTally?.mine == "holds",
                    holds: true
                )
                predictionButton(
                    title: L10n.text("Fails", "Tutmaz"),
                    count: predictionTally?.fails ?? 0,
                    icon: "hand.thumbsdown.fill",
                    color: PulseColor.negative,
                    selected: predictionTally?.mine == "fails",
                    holds: false
                )
            }
            Text(L10n.text(
                "Resolved automatically when the journey strengthens or fails. Your accuracy becomes a badge next to your name.",
                "Süreç güçlendiğinde veya geçersiz olduğunda otomatik sonuçlanır. İsabet oranın adının yanında rozete dönüşür."
            ))
            .font(.caption2).foregroundStyle(PulseColor.secondaryText)
        }
        .padding(12)
        .background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private func predictionButton(title: String, count: Int, icon: String, color: Color, selected: Bool, holds: Bool) -> some View {
        Button {
            Task { await submitPrediction(holds: holds) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.75)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(selected ? .white : color)
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(selected ? color : color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(predictionTally?.mine != nil || isSubmittingPrediction)
    }

    @MainActor private func submitPrediction(holds: Bool) async {
        guard let journeyID else { return }
        guard !account.isAnonymous else {
            errorMessage = L10n.text("Connect with Apple in Profile to predict.", "Tahmin için Profil'de Apple hesabını bağla.")
            return
        }
        isSubmittingPrediction = true
        do {
            try await predictionService.submit(journeyID: journeyID, symbol: symbol, timeframe: AnalysisTimeframe.selected.rawValue, holds: holds)
            predictionTally = try? await predictionService.tally(journeyID: journeyID)
            errorMessage = nil
        } catch SignalPredictionService.PredictionError.alreadyPredicted {
            predictionTally = try? await predictionService.tally(journeyID: journeyID)
        } catch {
            errorMessage = L10n.text("Prediction could not be saved.", "Tahmin kaydedilemedi.")
        }
        isSubmittingPrediction = false
    }

    @ViewBuilder private func accuracyBadge(for userID: UUID) -> some View {
        if let accuracy = accuracies[userID], accuracy.resolvedCount >= SignalPredictionService.minimumResolvedForBadge {
            HStack(spacing: 3) {
                Image(systemName: "target")
                Text(L10n.text("\(accuracy.accuracyPercent)%", "%\(accuracy.accuracyPercent)"))
                Text("·\(accuracy.resolvedCount)").opacity(0.7)
            }
            .font(.system(size: 8, weight: .bold)).monospacedDigit()
            .foregroundStyle(badgeColor(accuracy.accuracyPercent))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(badgeColor(accuracy.accuracyPercent).opacity(0.12), in: Capsule())
            .accessibilityLabel(L10n.text(
                "Prediction accuracy \(accuracy.accuracyPercent) percent over \(accuracy.resolvedCount) calls",
                "\(accuracy.resolvedCount) tahminde yüzde \(accuracy.accuracyPercent) isabet"
            ))
        }
    }

    private func badgeColor(_ percent: Int) -> Color {
        switch percent {
        case 60...: PulseColor.positive
        case 40..<60: PulseColor.warning
        default: PulseColor.negative
        }
    }

    private func messageRow(_ message: CoinChatMessage) -> some View {
        let mine = message.userID == account.id
        let alignment: HorizontalAlignment = mine ? .trailing : .leading
        return HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 54) }
            VStack(alignment: alignment, spacing: 5) {
                Text(message.body)
                    .font(.subheadline).foregroundStyle(PulseColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(
                        mine ? PulseColor.accent.opacity(0.18) : PulseColor.chatIncoming,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                HStack(spacing: 6) {
                    Text(message.authorDisplayName).font(.caption2.bold()).foregroundStyle(PulseColor.secondaryText)
                    accuracyBadge(for: message.userID)
                    Text(message.languageCode.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(PulseColor.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(PulseColor.accent.opacity(0.12), in: Capsule())
                    Text(message.createdAt, style: .relative).font(.caption2).foregroundStyle(PulseColor.secondaryText)
                    Button { Task { await toggleThumbsUp(message) } } label: {
                        HStack(spacing: 3) {
                            Image(systemName: message.hasThumbedUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                            if message.thumbsUpCount > 0 { Text("\(message.thumbsUpCount)") }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(message.hasThumbedUp ? PulseColor.accent : PulseColor.secondaryText)
                        .frame(minWidth: 24, minHeight: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(account.isAnonymous)
                    if message.hasReported {
                        Image(systemName: "flag.fill").font(.caption2).foregroundStyle(PulseColor.secondaryText)
                            .accessibilityLabel(L10n.text("Reported", "Bildirildi"))
                    } else if !mine && !account.isAnonymous {
                        Menu {
                            Button(role: .destructive) { Task { await report(message) } } label: {
                                Label(L10n.text("Report message", "Mesajı bildir"), systemImage: "flag")
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.caption.bold()).foregroundStyle(PulseColor.secondaryText)
                                .frame(width: 24, height: 20)
                        }
                    }
                }
            }
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 54) }
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor private func refresh() async {
        do { messages = try await service.messages(symbol: symbol, language: language); errorMessage = nil }
        catch { if messages.isEmpty { errorMessage = L10n.text("Chat is temporarily unavailable.", "Sohbet geçici olarak kullanılamıyor.") } }
        if let journeyID, showsPredictionBar {
            predictionTally = try? await predictionService.tally(journeyID: journeyID)
        }
        let authorIDs = Array(Set(messages.map(\.userID)))
        if !authorIDs.isEmpty {
            accuracies = (try? await predictionService.accuracies(userIDs: authorIDs)) ?? accuracies
        }
    }

    @MainActor private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isSending = true
        do {
            try await service.send(body, symbol: symbol, language: language)
            draft = ""
            nextSendAt = Date().addingTimeInterval(60)
            await refresh()
        } catch {
            errorMessage = L10n.text("Message could not be sent. Please wait and try again.", "Mesaj gönderilemedi. Biraz bekleyip yeniden dene.")
        }
        isSending = false
    }

    @MainActor private func toggleThumbsUp(_ message: CoinChatMessage) async {
        do {
            try await service.toggleThumbsUp(messageID: message.id)
            await refresh()
        } catch {
            errorMessage = L10n.text("Reaction could not be updated.", "Beğeni güncellenemedi.")
        }
    }

    @MainActor private func report(_ message: CoinChatMessage) async {
        do {
            try await service.report(messageID: message.id)
            await refresh()
        } catch {
            errorMessage = L10n.text("This report could not be submitted.", "Bu bildirim gönderilemedi.")
        }
    }

    private var backoffSeconds: Int {
        guard let nextSendAt else { return 0 }
        return max(0, Int(ceil(nextSendAt.timeIntervalSince(clock))))
    }

    private var sendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSending || draft.count > 400 || backoffSeconds > 0
    }
}
