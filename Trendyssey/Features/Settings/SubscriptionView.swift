import SwiftUI

struct SubscriptionView: View {
    @Environment(AppEnvironment.self) private var environment
    private var store: SubscriptionStore { environment.subscriptionStore }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                proMark
                VStack(spacing: 8) {
                    Text("Trendyssey Pro").font(.largeTitle.bold())
                    Text(L10n.text(
                        "Filter breakouts for your strategy and follow every move from setup to confirmation.",
                        "Kırılımları stratejine göre filtrele; hazırlıktan teyide kadar her hareketi takip et."
                    ))
                        .multilineTextAlignment(.center).foregroundStyle(TrendysseyColor.secondaryText)
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        benefit("square.stack.3d.up.fill", L10n.text("Six specialized breakout models", "Altı özel kırılım modeli"))
                        benefit("clock.arrow.circlepath", L10n.text("Four closed-candle timeframes", "Dört kapanmış mum zaman dilimi"))
                        benefit("slider.horizontal.3", L10n.text("Score, volume and signal-stage filters", "Puan, hacim ve sinyal aşaması filtreleri"))
                        benefit("bell.badge.fill", L10n.text("Real-time background push alerts", "Gerçek zamanlı arka plan bildirimleri"))
                        benefit("chart.xyaxis.line", L10n.text("Breakout scenario simulator", "Kırılım senaryosu simülatörü"))
                    }
                }
                if store.isSubscribed {
                    Label(L10n.text("Trendyssey Pro is active", "Trendyssey Pro aktif"), systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(TrendysseyColor.positive)
                } else {
                    VStack(spacing: 6) {
                        Text(store.trialText ?? L10n.text("Trendyssey Pro", "Trendyssey Pro"))
                            .font(.title2.bold())
                        Text(store.hasFreeTrial
                             ? L10n.text("Then \(store.priceText) per month. Cancel anytime.", "Sonrasında aylık \(store.priceText). İstediğin zaman iptal et.")
                             : L10n.text("\(store.priceText) per month. Cancel anytime.", "Aylık \(store.priceText). İstediğin zaman iptal et."))
                            .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText)
                    }
                    Button { Task { await store.purchase() } } label: {
                        Text(store.hasFreeTrial
                             ? L10n.text("Start Free Trial", "Ücretsiz Denemeyi Başlat")
                             : L10n.text("Start Pro", "Pro'yu Başlat"))
                            .font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent).tint(TrendysseyColor.accent)
                    .disabled(store.state == .loading || store.state == .unavailable)
                }
                Button(L10n.text("Restore Purchases", "Satın Almaları Geri Yükle")) { Task { await store.restore() } }
                if let message = store.message { Text(message).font(.caption).foregroundStyle(TrendysseyColor.secondaryText) }
                Text(L10n.text("The offer and renewal are managed by Apple. Payment is charged to your Apple ID unless cancelled at least 24 hours before renewal.", "Teklif ve yenileme Apple tarafından yönetilir. Yenilemeden en az 24 saat önce iptal edilmezse ödeme Apple ID hesabından alınır."))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Subscription", "Abonelik"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
    }

    private func benefit(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.medium)).foregroundStyle(TrendysseyColor.primaryText)
    }

    private var proMark: some View {
        ZStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.78, blue: 0.08),
                        Color(red: 1.0, green: 0.91, blue: 0.45),
                        Color(red: 1.0, green: 0.97, blue: 0.76)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.62, green: 0.88, blue: 1.0).opacity(0.72),
                                Color(red: 0.28, green: 0.72, blue: 0.96).opacity(0.88)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 120, height: 31)
                    .blur(radius: 5)
                    .offset(y: 39)
                Ellipse()
                    .fill(Color(red: 0.53, green: 0.85, blue: 1.0).opacity(0.68))
                    .frame(width: 142, height: 31)
                    .blur(radius: 8)
                    .offset(x: 2, y: 29)
                Ellipse()
                    .fill(Color(red: 1.0, green: 0.92, blue: 0.50).opacity(0.58))
                    .frame(width: 104, height: 17)
                    .blur(radius: 7)
                    .offset(x: -2, y: 21)
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.82), .white.opacity(0.20), Color.blue.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.25
                    )
            }
            .shadow(color: Color(red: 0.20, green: 0.56, blue: 0.90).opacity(0.28), radius: 24, y: 12)
            Image("TrendysseyLogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .shadow(color: Color(red: 0.62, green: 0.43, blue: 0.04).opacity(0.18), radius: 2.5, y: 1.5)
        }
        .accessibilityLabel("Trendyssey Pro")
    }
}
