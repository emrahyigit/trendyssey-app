import SwiftUI
import UserNotifications
import AuthenticationServices
import CryptoKit
import Security

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("notificationsEnabled") private var notifications = false
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.donchian20.rawValue
    @AppStorage("notificationStatuses") private var notificationStatuses = "preBreakout,breakoutDetected,confirmed,retest,failed,expired"
    @AppStorage("notificationScope") private var notificationScope = "favorites"
    @AppStorage("notificationMinimumRegimeScore") private var notificationMinimumRegimeScore = 0
    @AppStorage("notificationMinimumReadinessScore") private var notificationMinimumReadinessScore = 0
    // Keep the legacy key so existing installs preserve their quality threshold.
    @AppStorage("notificationMinimumScore") private var notificationMinimumBreakoutQualityScore = 0
    @AppStorage("notificationMinimumConfirmationScore") private var notificationMinimumConfirmationScore = 0
    /// Same minimum 24h USDT volume used by the breakout-scenario screen.
    /// Stored in millions to keep the stepper compact and understandable.
    @AppStorage("notificationMinimumVolumeMillions") private var notificationMinimumVolumeMillions = 0
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.default.rawValue
    @AppStorage("themeMode") private var themeMode = AppThemeMode.system.rawValue
    @State private var notificationAuthorized = false
    @State private var account: UserSyncService.AccountSnapshot = .anonymous
    @State private var appleNonce = ""
    @State private var accountMessage: String?
    @State private var isLinkingApple = false
    @State private var isEditingProfile = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeletion = false
    @State private var isProcessingAccountAction = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        if account.isAnonymous {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 44)).foregroundStyle(TrendysseyColor.accent)
                        } else {
                            TrendysseyAvatarView(key: account.avatarKey, size: 52)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName).font(.headline)
                            Text(account.isAnonymous
                                 ? L10n.text("Anonymous local account", "Anonim yerel hesap")
                                 : L10n.text("Connected with Apple", "Apple ile bağlandı"))
                                .font(.caption)
                                .foregroundStyle(TrendysseyColor.secondaryText)
                        }
                        Spacer()
                        if !account.isAnonymous {
                            Button(L10n.text("Edit", "Düzenle")) { isEditingProfile = true }
                                .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
                        }
                    }
                    if account.isAnonymous {
                        Text(L10n.text(
                            "Connect Apple to protect favorites, alerts and subscription access across devices.",
                            "Favorileri, uyarıları ve abonelik erişimini cihazlar arasında korumak için Apple hesabını bağla."
                        ))
                        .font(.caption)
                        .foregroundStyle(TrendysseyColor.secondaryText)

                        SignInWithAppleButton(.continue) { request in
                            let nonce = Self.randomNonce()
                            appleNonce = nonce
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = Self.sha256(nonce)
                        } onCompletion: { result in
                            handleAppleAuthorization(result)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 46)
                        .disabled(isLinkingApple)
                    }
                    if isLinkingApple { ProgressView(L10n.text("Connecting account…", "Hesap bağlanıyor…")) }
                    if let accountMessage {
                        Text(accountMessage).font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                    }
                }
            }
            Section(L10n.text("SUBSCRIPTION", "ABONELİK")) {
                NavigationLink { SubscriptionView() } label: {
                    LabeledContent {
                        Text(environment.subscriptionStore.isSubscribed ? L10n.text("Active", "Aktif") : L10n.text("View Pro", "Pro'yu İncele"))
                            .foregroundStyle(environment.subscriptionStore.isSubscribed ? TrendysseyColor.positive : TrendysseyColor.secondaryText)
                    } label: {
                        Label("Trendyssey Pro", systemImage: "sparkles")
                    }
                }
            }
            Section(L10n.text("ANALYSIS MODEL", "ANALİZ MODELİ")) {
                Picker(L10n.text("Model", "Model"), selection: $journeyModel) {
                    ForEach(JourneyModel.selectableCases) { model in
                        Text(model.title).tag(model.rawValue)
                    }
                }
                Picker(L10n.text("Timeframe", "Zaman dilimi"), selection: $preferredTimeframe) {
                    ForEach(AnalysisTimeframe.allCases) { timeframe in
                        Text(timeframe.title).tag(timeframe.rawValue)
                    }
                }
                NavigationLink {
                    if environment.subscriptionStore.isSubscribed { DailyBreakoutSimulatorView() }
                    else { SubscriptionView() }
                } label: {
                    proAnalysisLabel(L10n.text("Breakout scenario", "Kırılım senaryosu"))
                }
            }
            Section(L10n.text("NOTIFICATIONS & FILTERS", "BİLDİRİM VE FİLTRELER")) {
                if !environment.subscriptionStore.isSubscribed {
                    NavigationLink { SubscriptionView() } label: {
                        Label(L10n.text("Unlock Pro alerts and filters", "Pro uyarıları ve filtreleri aç"), systemImage: "lock.fill")
                            .foregroundStyle(TrendysseyColor.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                Toggle(L10n.text("Signal notifications", "Sinyal bildirimleri"), isOn: $notifications)
                    .disabled(!environment.subscriptionStore.isSubscribed)
                    .onChange(of: notifications) { _, enabled in
                        if enabled { requestNotificationPermission() }
                        else { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
                    }
                Picker(L10n.text("Alert coverage", "Uyarı kapsamı"), selection: $notificationScope) {
                    Text(L10n.text("Favorites", "Favoriler")).tag("favorites")
                    Text(L10n.text("All coins", "Tüm coinler")).tag("all")
                }
                .pickerStyle(.segmented)
                .disabled(!environment.subscriptionStore.isSubscribed)
                DisclosureGroup {
                    notificationScoreStepper(
                        L10n.text("Minimum regime", "Minimum rejim"),
                        value: $notificationMinimumRegimeScore
                    )
                    notificationScoreStepper(
                        L10n.text("Minimum readiness", "Minimum hazırlık"),
                        value: $notificationMinimumReadinessScore
                    )
                    notificationScoreStepper(
                        L10n.text("Minimum breakout quality", "Minimum kırılım kalitesi"),
                        value: $notificationMinimumBreakoutQualityScore
                    )
                    notificationScoreStepper(
                        L10n.text("Minimum confirmation", "Minimum teyit"),
                        value: $notificationMinimumConfirmationScore
                    )
                    Text(L10n.text(
                        "All four enabled thresholds must pass. Scores that do not apply yet are 0; leave later-stage thresholds at 0 to receive early alerts.",
                        "Etkin dört eşiğin tamamı geçilmelidir. Henüz oluşmayan aşamaların puanı 0'dır; erken uyarılar için sonraki aşama eşiklerini 0 bırak."
                    ))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                } label: {
                    LabeledContent(
                        L10n.text("Score thresholds", "Puan eşikleri"),
                        value: L10n.text(
                            "R\(notificationMinimumRegimeScore) · Rd\(notificationMinimumReadinessScore) · Q\(notificationMinimumBreakoutQualityScore) · C\(notificationMinimumConfirmationScore)",
                            "R\(notificationMinimumRegimeScore) · H\(notificationMinimumReadinessScore) · K\(notificationMinimumBreakoutQualityScore) · T\(notificationMinimumConfirmationScore)"
                        )
                    )
                }
                .disabled(!environment.subscriptionStore.isSubscribed)
                Stepper(
                    L10n.text(
                        "Minimum 24h volume: \(notificationMinimumVolumeText)",
                        "Minimum 24s hacim: \(notificationMinimumVolumeText)"
                    ),
                    value: $notificationMinimumVolumeMillions,
                    in: 0...100,
                    step: 5
                )
                .disabled(!environment.subscriptionStore.isSubscribed)
                DisclosureGroup {
                    ForEach(notificationEligibleStatuses, id: \.self) { status in
                        Toggle(status.title(alertModel.direction), isOn: statusBinding(for: status))
                    }
                } label: {
                    LabeledContent(L10n.text("Signal stages", "Sinyal aşamaları"), value: L10n.text("\(selectedStatuses.count) selected", "\(selectedStatuses.count) seçili"))
                }
                .disabled(!environment.subscriptionStore.isSubscribed)
            }
            Section(L10n.text("LANGUAGE & APPEARANCE", "DİL VE GÖRÜNÜM")) {
                Picker(L10n.text("Language", "Dil"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
                }
                Picker(L10n.text("Appearance", "Görünüm"), selection: $themeMode) {
                    ForEach(AppThemeMode.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                }
            }
            Section(L10n.text("ABOUT", "HAKKINDA")) {
                NavigationLink(L10n.text("Analysis methodology", "Analiz metodolojisi")) { LegalInfoView(title: L10n.text("Analysis methodology", "Analiz metodolojisi"), document: LegalCopy.methodology) }
                NavigationLink(L10n.text("Privacy", "Gizlilik")) { LegalInfoView(title: L10n.text("Privacy", "Gizlilik"), document: LegalCopy.privacy) }
                NavigationLink(L10n.text("Risk disclosure", "Risk bildirimi")) { LegalInfoView(title: L10n.text("Risk disclosure", "Risk bildirimi"), document: LegalCopy.risk) }
            }
            if !account.isAnonymous {
                Section(L10n.text("ACCOUNT MANAGEMENT", "HESAP YÖNETİMİ")) {
                    Button {
                        isConfirmingSignOut = true
                    } label: {
                        Label(L10n.text("Sign out", "Çıkış yap"), systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(TrendysseyColor.primaryText)
                    }
                    .disabled(isProcessingAccountAction)
                    .confirmationDialog(
                        L10n.text("Sign out of this account?", "Bu hesaptan çıkılsın mı?"),
                        isPresented: $isConfirmingSignOut,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.text("Sign out", "Çıkış yap"), role: .destructive) { performSignOut() }
                    } message: {
                        Text(L10n.text(
                            "Favorites and preferences stay linked to your Apple account and return when you sign in again.",
                            "Favoriler ve tercihler Apple hesabına bağlı kalır; tekrar giriş yaptığında geri gelir."
                        ))
                    }
                    Button {
                        isConfirmingDeletion = true
                    } label: {
                        Label(L10n.text("Delete my account", "Hesabımı sil"), systemImage: "trash")
                            .foregroundStyle(TrendysseyColor.primaryText)
                    }
                    .disabled(isProcessingAccountAction)
                    .confirmationDialog(
                        L10n.text("Permanently delete this account?", "Bu hesap kalıcı olarak silinsin mi?"),
                        isPresented: $isConfirmingDeletion,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.text("Delete permanently", "Kalıcı olarak sil"), role: .destructive) { performDeleteAccount() }
                    } message: {
                        Text(L10n.text(
                            "Your profile, favorites, preferences, predictions and chat identity are removed. This cannot be undone.",
                            "Profilin, favorilerin, tercihlerin, tahminlerin ve sohbet kimliğin silinir. Bu işlem geri alınamaz."
                        ))
                    }
                }
            }
        }.trendysseyBackground().navigationTitle(L10n.text("Profile", "Profil"))
            .sheet(isPresented: $isEditingProfile) {
                NavigationStack {
                    ProfileEditorView(account: account) { updated in account = updated }
                }
            }
            .task {
                account = await UserSyncService.shared.accountSnapshot()
                await refreshNotificationStatus()
                if !environment.subscriptionStore.isSubscribed, notifications {
                    notifications = false
                    syncPreferences()
                }
            }
            .onChange(of: preferenceFingerprint) { _, _ in syncPreferences() }
    }

    /// The single model choice in the app: it drives on-device journeys and
    /// scores, and — through `serverSlug` — which backend model the alerts and the
    /// recorded signal history come from.
    private var selectedJourneyModel: JourneyModel {
        JourneyModel(rawValue: journeyModel) ?? .donchian20
    }

    /// The model alerts actually come from. Alerts are raised by the backend, so a
    /// device-only model falls back to the one the backend does run.
    private var alertModel: JourneyModel {
        selectedJourneyModel.deliversAlerts
            ? selectedJourneyModel
            : JourneyModel.selectableCases.first(where: \.deliversAlerts) ?? .donchian20
    }

    private func proAnalysisLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !environment.subscriptionStore.isSubscribed {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
    }

    private func performSignOut() {
        isProcessingAccountAction = true
        Task {
            await UserSyncService.shared.signOut()
            account = await UserSyncService.shared.accountSnapshot()
            await UserSyncService.shared.syncCurrentState(watchlist: Array(environment.watchlist))
            accountMessage = L10n.text("Signed out. You are now using a new anonymous session.", "Çıkış yapıldı. Artık yeni bir anonim oturum kullanıyorsun.")
            isProcessingAccountAction = false
        }
    }

    private func performDeleteAccount() {
        isProcessingAccountAction = true
        Task {
            do {
                try await UserSyncService.shared.deleteAccount()
                account = await UserSyncService.shared.accountSnapshot()
                accountMessage = L10n.text("Your account was permanently deleted.", "Hesabın kalıcı olarak silindi.")
            } catch {
                accountMessage = L10n.text("The account could not be deleted. Please try again.", "Hesap silinemedi. Lütfen tekrar dene.")
            }
            isProcessingAccountAction = false
        }
    }

    private func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                await MainActor.run {
                    notificationAuthorized = granted
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                    else { notifications = false }
                }
            } catch { await MainActor.run { notifications = false } }
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationAuthorized = authorized
        if authorized { UIApplication.shared.registerForRemoteNotifications() }
        if notifications && !authorized { notifications = false }
    }

    private var selectedStatuses: Set<SignalStatus> {
        Set(notificationStatuses.split(separator: ",").compactMap { value in
            notificationEligibleStatuses.first { $0.rawValue == value }
        })
    }

    private var notificationEligibleStatuses: [SignalStatus] {
        SignalStatus.userSelectableCases
    }

    private func statusBinding(for status: SignalStatus) -> Binding<Bool> {
        Binding(
            get: { selectedStatuses.contains(status) },
            set: { isSelected in
                var statuses = selectedStatuses
                if isSelected { statuses.insert(status) } else { statuses.remove(status) }
                notificationStatuses = notificationEligibleStatuses
                    .filter(statuses.contains)
                    .map(\.rawValue)
                    .joined(separator: ",")
            }
        )
    }

    private func notificationScoreStepper(_ title: String, value: Binding<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: 0...90, step: 10)
    }

    private var notificationMinimumVolumeText: String {
        notificationMinimumVolumeMillions <= 0
            ? L10n.text("Off", "Kapalı")
            : "$\(notificationMinimumVolumeMillions)M"
    }

    private var preferenceFingerprint: String {
        "\(notifications)|\(preferredTimeframe)|\(journeyModel)|\(notificationStatuses)|\(notificationScope)|\(notificationMinimumRegimeScore)|\(notificationMinimumReadinessScore)|\(notificationMinimumBreakoutQualityScore)|\(notificationMinimumConfirmationScore)|\(notificationMinimumVolumeMillions)|\(appLanguage)"
    }

    private func syncPreferences() {
        let watchlist = Array(environment.watchlist)
        Task { await UserSyncService.shared.syncCurrentState(watchlist: watchlist) }
    }

    private func handleAppleAuthorization(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              !appleNonce.isEmpty else {
            if case .failure(let error) = result,
               (error as? ASAuthorizationError)?.code != .canceled {
                accountMessage = L10n.text("Apple account could not be connected.", "Apple hesabı bağlanamadı.")
            }
            return
        }

        let fullName = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        isLinkingApple = true
        accountMessage = nil
        Task {
            do {
                account = try await UserSyncService.shared.linkAppleIdentity(
                    idToken: idToken,
                    nonce: appleNonce,
                    fullName: fullName
                )
                await UserSyncService.shared.syncCurrentState(watchlist: Array(environment.watchlist))
                accountMessage = L10n.text("Apple account connected.", "Apple hesabı bağlandı.")
            } catch {
                accountMessage = L10n.text("Apple account could not be connected. Check the provider configuration.", "Apple hesabı bağlanamadı. Sağlayıcı yapılandırmasını kontrol et.")
            }
            isLinkingApple = false
        }
    }

    nonisolated private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString }
            for byte in bytes where remaining > 0 {
                guard byte < characters.count else { continue }
                result.append(characters[Int(byte)])
                remaining -= 1
            }
        }
        return result
    }
}

private struct LegalInfoView: View {
    let title: String
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(document.summary)
                    .font(.headline)
                    .foregroundStyle(TrendysseyColor.primaryText)
                    .lineSpacing(4)
                    .padding(.bottom, 2)
                ForEach(document.sections) { section in
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.heading.uppercased())
                                .font(.caption2.bold())
                                .tracking(0.8)
                                .foregroundStyle(TrendysseyColor.accent)
                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.subheadline)
                                    .foregroundStyle(TrendysseyColor.secondaryText)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !section.bullets.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle()
                                                .fill(TrendysseyColor.accent)
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 7)
                                            Text(bullet)
                                                .font(.subheadline)
                                                .foregroundStyle(TrendysseyColor.secondaryText)
                                                .lineSpacing(4)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let footnote = document.footnote {
                    Label(footnote, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(TrendysseyColor.secondaryText)
                        .lineSpacing(3)
                        .padding(.top, 2)
                }
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let account: UserSyncService.AccountSnapshot
    let onSaved: (UserSyncService.AccountSnapshot) -> Void
    @State private var name: String
    @State private var avatarKey: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: UserSyncService.AccountSnapshot, onSaved: @escaping (UserSyncService.AccountSnapshot) -> Void) {
        self.account = account
        self.onSaved = onSaved
        _name = State(initialValue: account.displayName)
        _avatarKey = State(initialValue: account.avatarKey)
    }

    var body: some View {
        Form {
            Section(L10n.text("DISPLAY NAME", "GÖRÜNEN AD")) {
                TextField(L10n.text("Your name", "Adın"), text: $name)
                    .textInputAutocapitalization(.words)
                Text(L10n.text("2–24 characters. This name is visible in coin chats.", "2–24 karakter. Bu ad coin sohbetlerinde görünür."))
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            }
            Section(L10n.text("AVATAR", "AVATAR")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                    ForEach(TrendysseyAvatar.all) { avatar in
                        Button { avatarKey = avatar.id } label: {
                            TrendysseyAvatarView(key: avatar.id, size: 58)
                                .padding(5)
                                .overlay(Circle().stroke(avatarKey == avatar.id ? TrendysseyColor.accent : .clear, lineWidth: 3))
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 8)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(TrendysseyColor.negative) }
        }
        .trendysseyBackground()
        .navigationTitle(L10n.text("Edit Profile", "Profili Düzenle"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel", "Vazgeç")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("Save", "Kaydet")) { Task { await save() } }
                    .disabled(isSaving || !(2...24).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count))
            }
        }
    }

    @MainActor private func save() async {
        isSaving = true
        do {
            let updated = try await UserSyncService.shared.updateProfile(displayName: name, avatarKey: avatarKey)
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = L10n.text("Profile could not be updated.", "Profil güncellenemedi.")
        }
        isSaving = false
    }
}
