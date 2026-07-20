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
    @AppStorage(AnalysisModelSelection.storageKey) private var preferredAnalysisModel = AnalysisModelSelection.defaultSlug
    @AppStorage("notificationStatuses") private var notificationStatuses = "preBreakout,breakoutDetected,confirmed,retest,failed,expired"
    @AppStorage("notificationScope") private var notificationScope = "favorites"
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.default.rawValue
    @AppStorage("themeMode") private var themeMode = AppThemeMode.system.rawValue
    @State private var permissionMessage: String?
    @State private var notificationAuthorized = false
    @State private var account: UserSyncService.AccountSnapshot = .anonymous
    @State private var appleNonce = ""
    @State private var accountMessage: String?
    @State private var isLinkingApple = false
    @State private var isEditingProfile = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeletion = false
    @State private var isProcessingAccountAction = false
    @State private var analysisModels: [AnalysisModelOption] = [.fallback]

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
                                 : account.email ?? L10n.text("Connected with Apple", "Apple ile bağlandı"))
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
                        Text(environment.subscriptionStore.isSubscribed ? L10n.text("Active", "Aktif") : L10n.text("3-day free trial", "3 günlük ücretsiz deneme"))
                            .foregroundStyle(environment.subscriptionStore.isSubscribed ? TrendysseyColor.positive : TrendysseyColor.secondaryText)
                    } label: {
                        Label("Trendyssey Pro", systemImage: "sparkles")
                    }
                }
            }
            Section(L10n.text("ANALYSIS MODEL", "ANALİZ MODELİ")) {
                if !environment.subscriptionStore.isSubscribed {
                    NavigationLink { SubscriptionView() } label: {
                        Label(L10n.text("Unlock model selection", "Model seçimini aç"), systemImage: "lock.fill")
                            .foregroundStyle(TrendysseyColor.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                Picker(L10n.text("Model", "Model"), selection: $preferredAnalysisModel) {
                    ForEach(analysisModels) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                }
                .disabled(!environment.subscriptionStore.isSubscribed)
                Picker(L10n.text("Timeframe", "Zaman dilimi"), selection: $preferredTimeframe) {
                    ForEach(AnalysisTimeframe.allCases) { timeframe in
                        Text(timeframe.title).tag(timeframe.rawValue)
                    }
                }
                NavigationLink {
                    if environment.subscriptionStore.isSubscribed { DailyRecapView() }
                    else { SubscriptionView() }
                } label: {
                    proAnalysisLabel(L10n.text("What happened today", "Bugün ne oldu"))
                }
                NavigationLink {
                    if environment.subscriptionStore.isSubscribed { WeeklyReportCardView() }
                    else { SubscriptionView() }
                } label: {
                    proAnalysisLabel(L10n.text("Weekly report card", "Haftalık model karnesi"))
                }
                NavigationLink {
                    if environment.subscriptionStore.isSubscribed { DailyBreakoutSimulatorView() }
                    else { SubscriptionView() }
                } label: {
                    proAnalysisLabel(L10n.text("Daily breakout scenario", "Günlük kırılım senaryosu"))
                }
                NavigationLink {
                    if environment.subscriptionStore.isSubscribed { ModelPerformanceComparisonView() }
                    else { SubscriptionView() }
                } label: {
                    proAnalysisLabel(L10n.text("Model performance", "Model performansı"))
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
                    ForEach(notificationEligibleStatuses, id: \.self) { status in
                        Toggle(status.title, isOn: statusBinding(for: status))
                    }
                } label: {
                    LabeledContent(L10n.text("Signal stages", "Sinyal aşamaları"), value: L10n.text("\(selectedStatuses.count) selected", "\(selectedStatuses.count) seçili"))
                }
                .disabled(!environment.subscriptionStore.isSubscribed)
                if let permissionMessage { Text(permissionMessage).font(.caption).foregroundStyle(TrendysseyColor.secondaryText) }
                Text(notificationScope == "all"
                     ? L10n.text("All tracked spot coins matching the timeframe and selected signal states can trigger an alert.", "Zaman dilimi ve seçilen sinyal durumlarına uyan tüm spot coinler uyarı oluşturabilir.")
                     : L10n.text("Only favorite coins matching the timeframe and selected signal states can trigger an alert.", "Yalnızca zaman dilimi ve seçilen sinyal durumlarına uyan favori coinler uyarı oluşturabilir."))
                    .font(.caption)
                    .foregroundStyle(TrendysseyColor.secondaryText)
            }
            Section(L10n.text("LANGUAGE & APPEARANCE", "DİL VE GÖRÜNÜM")) {
                Picker(L10n.text("Language", "Dil"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
                }
                Picker(L10n.text("Appearance", "Görünüm"), selection: $themeMode) {
                    ForEach(AppThemeMode.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                }
                LabeledContent(L10n.text("Market", "Market"), value: "Binance Spot")
            }
            Section(L10n.text("ABOUT", "HAKKINDA")) {
                NavigationLink(L10n.text("Analysis methodology", "Analiz metodolojisi")) { LegalInfoView(title: L10n.text("Analysis methodology", "Analiz metodolojisi"), text: LegalCopy.methodology) }
                NavigationLink(L10n.text("Privacy", "Gizlilik")) { LegalInfoView(title: L10n.text("Privacy", "Gizlilik"), text: LegalCopy.privacy) }
                NavigationLink(L10n.text("Risk disclosure", "Risk bildirimi")) { LegalInfoView(title: L10n.text("Risk disclosure", "Risk bildirimi"), text: LegalCopy.risk) }
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
                await loadAnalysisModels()
                await refreshNotificationStatus()
                if !environment.subscriptionStore.isSubscribed, notifications {
                    notifications = false
                    syncPreferences()
                }
            }
            .onChange(of: preferenceFingerprint) { _, _ in syncPreferences() }
            .onChange(of: environment.subscriptionStore.isSubscribed) { _, isPro in
                guard !isPro,
                      analysisModels.first(where: { $0.slug == preferredAnalysisModel })?.isDefault == false,
                      let defaultModel = analysisModels.first(where: \.isDefault) else { return }
                preferredAnalysisModel = defaultModel.slug
            }
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
                    permissionMessage = granted ? L10n.text("Notification permission granted.", "Bildirim izni verildi.") : L10n.text("Notifications can be enabled in Settings.", "Bildirim izni Ayarlar uygulamasından açılabilir.")
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                    else { notifications = false }
                }
            } catch { await MainActor.run { permissionMessage = L10n.text("Notification permission could not be requested.", "Bildirim izni alınamadı."); notifications = false } }
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationAuthorized = authorized
        if authorized { UIApplication.shared.registerForRemoteNotifications() }
        if notifications && !authorized { notifications = false }
        permissionMessage = authorized ? L10n.text("Notifications are active on this device.", "Bildirimler bu cihazda aktif.") : L10n.text("Notification permission is required.", "Bildirim göndermek için izin gerekli.")
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

    private var preferenceFingerprint: String {
        "\(notifications)|\(preferredTimeframe)|\(preferredAnalysisModel)|\(notificationStatuses)|\(notificationScope)|\(appLanguage)"
    }

    private func loadAnalysisModels() async {
        let loaded = (try? await AnalysisModelService().activeModels()) ?? []
        analysisModels = loaded.isEmpty ? [.fallback] : loaded
        if !analysisModels.contains(where: { $0.slug == preferredAnalysisModel }) {
            preferredAnalysisModel = analysisModels.first(where: \.isDefault)?.slug
                ?? analysisModels[0].slug
        }
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
    let text: String
    var body: some View { ScrollView { Text(text).font(.body).lineSpacing(5).padding().frame(maxWidth: .infinity, alignment: .leading) }.background(TrendysseyColor.canvas).navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
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

private enum LegalCopy {
    static var methodology: String { L10n.text(
        """
        OVERVIEW

        Trendyssey analyzes publicly available Binance Spot market data. Price charts load directly from Binance on your device, while server-side scans maintain durable signal records, journey history, outcome measurements and notifications. The same analysis model runs on both sides, so what you see in the app always matches what the scans record.

        THE EMA CROSS 7/25/99 MODEL

        The model is built on Binance's default exponential moving averages. A crossover of EMA 7 above EMA 25 opens a Breakout Journey; the journey advances through defined phases — waiting for breakout, breakout started, level being tested and breakout strengthening — and ends when the trend structure breaks down. EMA 99 serves as the long-term trend filter.

        CLOSED-CANDLE PRINCIPLE

        All evaluations use closed candles only for the selected timeframe. An open candle may appear on the chart, but it is never treated as confirmed evidence. This materially reduces repainting; it does not eliminate false signals.

        THE CONFIDENCE SCORE

        Each coin receives a single 0–100 confidence score composed of seven weighted ingredients: trend alignment (20), crossover freshness (15), retest confirmation (15), volume support (20), long-term trend (10), momentum (10) and higher-timeframe confluence (10) — agreement with the next timeframe up. Every ingredient is displayed with its own points and rationale, so the score is fully auditable. It is a deterministic summary of current market structure — not a probability, forecast or guarantee.

        OUTCOME MEASUREMENT

        After a breakout is detected, Trendyssey records the subsequent return, maximum favorable excursion (MFE) and maximum adverse excursion (MAE) over defined candle horizons. These records audit what actually happened and power the performance and report-card screens; they do not predict future results.

        LIMITATIONS

        Exchange latency, missing candles, thin liquidity, sudden news, slippage and methodology updates can all affect results. Trendyssey is a research tool and should be one input among several — never the sole basis for a trading decision.
        """,
        """
        GENEL BAKIŞ

        Trendyssey, Binance Spot üzerindeki herkese açık piyasa verilerini analiz eder. Fiyat grafikleri doğrudan cihazınıza Binance'tan yüklenir; sunucu tarafındaki taramalar ise kalıcı sinyal kayıtlarını, süreç geçmişini, sonuç ölçümlerini ve bildirimleri yönetir. Her iki tarafta da aynı analiz modeli çalışır; uygulamada gördüğünüz sonuçlar tarama kayıtlarıyla her zaman tutarlıdır.

        EMA CROSS 7/25/99 MODELİ

        Model, Binance'in varsayılan üssel hareketli ortalamaları üzerine kuruludur. EMA 7'nin EMA 25'i yukarı kesmesi bir Kırılım Süreci başlatır; süreç tanımlı aşamalardan geçer — kırılım bekleniyor, kırılım başladı, seviye test ediliyor, kırılım güçleniyor — ve trend yapısı bozulduğunda sona erer. EMA 99 uzun vadeli trend filtresi olarak görev yapar.

        KAPANMIŞ MUM İLKESİ

        Tüm değerlendirmeler, seçilen zaman diliminde yalnızca kapanmış mumlarla yapılır. Açık mum grafikte görünebilir ancak hiçbir zaman doğrulanmış kanıt sayılmaz. Bu ilke yeniden çizimi önemli ölçüde azaltır; yanlış sinyalleri tamamen ortadan kaldırmaz.

        GÜVEN PUANI

        Her coin, yedi ağırlıklı bileşenden oluşan 0–100 arası tek bir güven puanı alır: trend dizilimi (20), kesişim tazeliği (15), retest onayı (15), hacim desteği (20), uzun vadeli trend (10), momentum (10) ve üst dilim uyumu (10) — bir üst zaman dilimiyle yön birliği. Her bileşen kendi puanı ve gerekçesiyle birlikte gösterilir; böylece puan tamamen denetlenebilirdir. Güven puanı mevcut piyasa yapısının deterministik bir özetidir — olasılık, tahmin veya garanti değildir.

        SONUÇ ÖLÇÜMÜ

        Kırılım algılandıktan sonra Trendyssey; tanımlı mum ufuklarında gerçekleşen getiriyi, maksimum olumlu hareketi (MFE) ve maksimum olumsuz hareketi (MAE) kaydeder. Bu kayıtlar gerçekte ne olduğunu denetler, performans ve karne ekranlarını besler; gelecekteki sonuçları öngörmez.

        SINIRLAR

        Borsa gecikmesi, eksik mumlar, düşük likidite, ani haberler, fiyat kayması ve metodoloji güncellemeleri sonuçları etkileyebilir. Trendyssey bir araştırma aracıdır; birden fazla girdiden yalnızca biri olmalı, hiçbir zaman tek işlem dayanağı olmamalıdır.
        """
    ) }

    static var privacy: String { L10n.text(
        """
        DATA WE PROCESS

        Trendyssey analyzes publicly available Binance market data. The app never requests your exchange credentials or API keys and never takes custody of your assets. Please do not share exchange secrets in chat or profile fields.

        ACCOUNT AND SYNCHRONIZATION

        On first launch the app creates an anonymous account so your favorites and preferences can be synchronized. If you choose Sign in with Apple, Apple provides your name and email address according to your sharing preference. Trendyssey stores your display name, avatar, favorites, analysis preferences and alert settings solely to provide these features across your devices.

        NOTIFICATIONS AND SUBSCRIPTIONS

        To deliver alerts, Trendyssey stores an APNs device token together with delivery status. Subscription entitlements are verified through Apple transaction identifiers and expiry dates. Payment details are processed exclusively by Apple; Trendyssey never sees or stores them.

        COMMUNITY CONTENT

        Chat messages and breakout predictions are visible to signed-in users together with your display name, avatar and posting time. Prediction accuracy statistics derived from your resolved predictions are shown publicly as a badge. Do not post personal, financial or confidential information. Content may be retained for continuity, abuse prevention and moderation.

        SECURITY

        All requests are authenticated, and database access is restricted with row-level security. No server secret or service key is embedded in the app. Session tokens are stored in the device Keychain.

        YOUR CONTROLS

        You can edit your public name and avatar, sign out at any time, or permanently delete your account from Profile. Account deletion removes your profile, favorites, preferences, predictions and chat identity from our systems.
        """,
        """
        İŞLEDİĞİMİZ VERİLER

        Trendyssey, herkese açık Binance piyasa verilerini analiz eder. Uygulama hiçbir zaman borsa şifrenizi veya API anahtarlarınızı istemez ve varlıklarınızı saklamaz. Borsa gizli bilgilerinizi sohbet veya profil alanlarında paylaşmayınız.

        HESAP VE SENKRONİZASYON

        İlk açılışta, favorilerinizin ve tercihlerinizin senkronize edilebilmesi için anonim bir hesap oluşturulur. Apple ile Giriş'i seçerseniz Apple, paylaşım tercihinize göre adınızı ve e-posta adresinizi iletir. Trendyssey; görünen adınızı, avatarınızı, favorilerinizi, analiz tercihlerinizi ve uyarı ayarlarınızı yalnızca bu özellikleri cihazlarınız arasında sunmak için saklar.

        BİLDİRİMLER VE ABONELİKLER

        Uyarı iletimi için APNs cihaz token'ı ve teslim durumu saklanır. Abonelik hakları, Apple işlem kimlikleri ve geçerlilik tarihleri üzerinden doğrulanır. Ödeme bilgileri yalnızca Apple tarafından işlenir; Trendyssey bu bilgileri hiçbir şekilde görmez veya saklamaz.

        TOPLULUK İÇERİĞİ

        Sohbet mesajları ve kırılım tahminleri; görünen adınız, avatarınız ve gönderim zamanıyla birlikte giriş yapmış kullanıcılara görünür. Sonuçlanan tahminlerinizden türetilen isabet istatistikleri, herkese açık bir rozet olarak gösterilir. Kişisel, finansal veya gizli bilgi paylaşmayınız. İçerikler süreklilik, kötüye kullanımın önlenmesi ve moderasyon amacıyla saklanabilir.

        GÜVENLİK

        Tüm istekler kimlik doğrulamalıdır ve veritabanı erişimi satır düzeyi güvenlikle sınırlandırılmıştır. Uygulamaya hiçbir sunucu gizli anahtarı gömülü değildir. Oturum bilgileri cihazın Anahtar Zinciri'nde (Keychain) saklanır.

        KONTROLLERİNİZ

        Profil bölümünden herkese açık adınızı ve avatarınızı düzenleyebilir, dilediğiniz an oturumu kapatabilir veya hesabınızı kalıcı olarak silebilirsiniz. Hesap silme işlemi; profilinizi, favorilerinizi, tercihlerinizi, tahminlerinizi ve sohbet kimliğinizi sistemlerimizden kaldırır.
        """
    ) }

    static var risk: String { L10n.text(
        """
        NO INVESTMENT ADVICE

        Trendyssey provides statistical market observations and community discussion for educational and research purposes only. Nothing in the app constitutes investment, legal, tax or personalized financial advice, a recommendation, or an offer or solicitation to buy or sell any asset.

        MATERIAL RISK OF LOSS

        Crypto assets are highly volatile and largely unregulated. You may lose part or all of the capital you commit. Leverage magnifies losses and can lead to liquidation. Commit only capital whose loss you understand and can afford.

        MODEL AND SIGNAL LIMITATIONS

        A high confidence score describes current market structure; it is not a probability of success. Breakouts fail regularly — due to liquidity conditions, news events, manipulation, price gaps, data latency or changing market regimes. Historical outcome measurements, model statistics and community predictions do not guarantee future performance.

        EXECUTION RISK

        Trendyssey does not execute orders and cannot account for your fees, taxes, slippage, position sizing or exchange availability. Market data and notifications may be delayed or temporarily unavailable. Always verify price and conditions on the exchange before acting.

        YOUR RESPONSIBILITY

        You remain solely responsible for your research, decisions, account security and compliance with the laws of your jurisdiction. Community content is user-generated and may be inaccurate, biased or promotional; popularity is not evidence.
        """,
        """
        YATIRIM TAVSİYESİ DEĞİLDİR

        Trendyssey; yalnızca eğitim ve araştırma amacıyla istatistiksel piyasa gözlemleri ve topluluk tartışması sunar. Uygulamadaki hiçbir içerik yatırım, hukuk, vergi veya kişiye özel finansal danışmanlık, öneri ya da herhangi bir varlığın alım-satımına yönelik teklif niteliği taşımaz.

        ÖNEMLİ KAYIP RİSKİ

        Kripto varlıklar yüksek oynaklığa sahiptir ve büyük ölçüde düzenlenmemiştir. Ayırdığınız sermayenin bir kısmını veya tamamını kaybedebilirsiniz. Kaldıraç kayıpları büyütür ve likidasyona yol açabilir. Yalnızca kaybını anlayabildiğiniz ve karşılayabileceğiniz sermayeyi kullanın.

        MODEL VE SİNYAL SINIRLARI

        Yüksek güven puanı mevcut piyasa yapısını tanımlar; bir başarı olasılığı değildir. Kırılımlar düzenli olarak başarısız olur — likidite koşulları, haber akışı, manipülasyon, fiyat boşlukları, veri gecikmesi veya değişen piyasa rejimleri nedeniyle. Geçmiş sonuç ölçümleri, model istatistikleri ve topluluk tahminleri gelecekteki performansı garanti etmez.

        İŞLEM RİSKİ

        Trendyssey emir iletmez; komisyonlarınızı, vergilerinizi, fiyat kaymasını, pozisyon büyüklüğünüzü veya borsa erişilebilirliğini hesaba katamaz. Piyasa verileri ve bildirimler gecikebilir veya geçici olarak kullanılamayabilir. İşlem yapmadan önce fiyatı ve koşulları her zaman borsada doğrulayın.

        SORUMLULUĞUNUZ

        Araştırmanızdan, kararlarınızdan, hesap güvenliğinizden ve bulunduğunuz ülkenin mevzuatına uyumdan yalnızca siz sorumlusunuz. Topluluk içerikleri kullanıcı üretimidir; hatalı, taraflı veya tanıtım amaçlı olabilir. Popülerlik kanıt değildir.
        """
    ) }
}
