import SwiftUI

/// Pro: a recap of the last 24 hours of breakout journeys.
struct DailyRecapView: View {
    @State private var started: [BreakoutScenarioEntry] = []
    @State private var confirmed: [BreakoutScenarioEntry] = []
    @State private var failed: [BreakoutScenarioEntry] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"

    private var successShare: Double {
        let resolved = confirmed.count + failed.count
        guard resolved > 0 else { return 0 }
        return Double(confirmed.count) / Double(resolved)
    }

    private var topMoves: [BreakoutScenarioEntry] {
        Array(started.sorted { $0.maximumReturnPercent > $1.maximumReturnPercent }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("PRO RECAP", "PRO ÖZET"), systemImage: "clock.arrow.circlepath")
                        .font(.caption.bold()).foregroundStyle(PulseColor.accent)
                    Text(L10n.text("What happened today?", "Bugün ne oldu?"))
                        .font(.title2.bold())
                    Text(L10n.text(
                        "EMA Cross 7/25/99 journeys from the last 24 hours on \(AnalysisTimeframe.selected.title) candles.",
                        "Son 24 saatte \(AnalysisTimeframe.selected.title) mumlarında EMA Cross 7/25/99 süreçleri."
                    ))
                    .font(.subheadline).foregroundStyle(PulseColor.secondaryText)
                }
                if isLoading {
                    SurfaceCard { ProgressView(L10n.text("Preparing the recap…", "Özet hazırlanıyor…")).frame(maxWidth: .infinity).padding(.vertical, 28) }
                } else if loadFailed {
                    SurfaceCard { ContentUnavailableView(L10n.text("Recap unavailable", "Özet yüklenemedi"), systemImage: "wifi.exclamationmark") }
                } else {
                    HStack(spacing: 10) {
                        recapStat(L10n.text("STARTED", "BAŞLAYAN"), "\(started.count)", PulseColor.accent)
                        recapStat(L10n.text("STRENGTHENED", "GÜÇLENEN"), "\(confirmed.count)", PulseColor.positive)
                        recapStat(L10n.text("INVALIDATED", "GEÇERSİZ"), "\(failed.count)", PulseColor.negative)
                    }
                    if confirmed.count + failed.count > 0 {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.text("HOLD RATE", "TUTMA ORANI")).font(.caption2.bold()).foregroundStyle(PulseColor.secondaryText)
                                Text(successShare, format: .percent.precision(.fractionLength(0)))
                                    .font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(successShare >= 0.5 ? PulseColor.positive : PulseColor.warning)
                                Text(L10n.text(
                                    "Share of journeys that strengthened instead of failing among those resolved in the last 24 hours.",
                                    "Son 24 saatte sonuçlanan süreçler içinde geçersiz olmak yerine güçlenenlerin payı."
                                ))
                                .font(.caption).foregroundStyle(PulseColor.secondaryText)
                            }
                        }
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 13) {
                            Label(L10n.text("Today's strongest moves", "Günün en güçlü hareketleri"), systemImage: "flame.fill")
                                .font(.headline)
                            if topMoves.isEmpty {
                                Text(L10n.text("No breakout started in the last 24 hours.", "Son 24 saatte başlayan kırılım yok."))
                                    .font(.caption).foregroundStyle(PulseColor.secondaryText)
                            } else {
                                ForEach(topMoves) { entry in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.symbol.replacingOccurrences(of: "USDT", with: "")).font(.subheadline.bold())
                                            Text(entry.entryDate.formatted(date: .omitted, time: .shortened))
                                                .font(.caption2).foregroundStyle(PulseColor.secondaryText)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text(entry.maximumReturnPercent / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(2)))
                                                .font(.subheadline.bold()).monospacedDigit()
                                                .foregroundStyle(entry.maximumReturnPercent >= 0 ? PulseColor.positive : PulseColor.negative)
                                            Text(L10n.text("peak after start", "başlangıç sonrası zirve"))
                                                .font(.caption2).foregroundStyle(PulseColor.secondaryText)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    Label(
                        L10n.text("Historical observation, not investment advice.", "Geçmişe dönük gözlemdir; yatırım tavsiyesi değildir."),
                        systemImage: "info.circle"
                    )
                    .font(.caption).foregroundStyle(PulseColor.secondaryText)
                }
            }
            .padding(18)
        }
        .background(PulseColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("What Happened Today", "Bugün Ne Oldu"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: preferredTimeframe) { await load() }
    }

    private func recapStat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.title.bold()).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(PulseColor.secondaryText).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        let service = AnalysisInsightsService()
        let slug = AnalysisModelSelection.selectedSlug
        let since = Date.now.addingTimeInterval(-86_400)
        do {
            async let startedEntries = service.scenarioEntries(modelSlug: slug, timeframe: preferredTimeframe, status: .breakoutDetected, since: since)
            async let confirmedEntries = service.scenarioEntries(modelSlug: slug, timeframe: preferredTimeframe, status: .confirmed, since: since)
            async let failedEntries = service.scenarioEntries(modelSlug: slug, timeframe: preferredTimeframe, status: .failed, since: since)
            (started, confirmed, failed) = try await (startedEntries, confirmedEntries, failedEntries)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

/// Pro: the model's measured report card over the last 7 days.
struct WeeklyReportCardView: View {
    @State private var report: WeeklyModelReport?
    @State private var isLoading = true
    @State private var loadFailed = false
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("PRO REPORT CARD", "PRO KARNE"), systemImage: "checkmark.seal.fill")
                        .font(.caption.bold()).foregroundStyle(PulseColor.accent)
                    Text(L10n.text("Weekly model report card", "Haftalık model karnesi"))
                        .font(.title2.bold())
                    Text(L10n.text(
                        "EMA Cross 7/25/99 outcomes measured over the last 7 days on \(AnalysisTimeframe.selected.title) candles.",
                        "Son 7 günde \(AnalysisTimeframe.selected.title) mumlarında ölçülen EMA Cross 7/25/99 sonuçları."
                    ))
                    .font(.subheadline).foregroundStyle(PulseColor.secondaryText)
                }
                if isLoading {
                    SurfaceCard { ProgressView(L10n.text("Grading the week…", "Hafta notlandırılıyor…")).frame(maxWidth: .infinity).padding(.vertical, 28) }
                } else if loadFailed {
                    SurfaceCard { ContentUnavailableView(L10n.text("Report unavailable", "Karne yüklenemedi"), systemImage: "wifi.exclamationmark") }
                } else if let report, report.evaluatedCount > 0 {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text("HOLD RATE", "BAŞARI ORANI")).font(.caption2.bold()).foregroundStyle(PulseColor.secondaryText)
                            Text(report.winRate / 100, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(report.winRate >= 50 ? PulseColor.positive : PulseColor.warning)
                            Text(L10n.text(
                                "\(report.evaluatedCount) measured outcomes: \(report.winCount) held, \(report.flatCount) flat, \(report.lossCount) failed.",
                                "\(report.evaluatedCount) ölçülen sonuç: \(report.winCount) korudu, \(report.flatCount) yatay, \(report.lossCount) bozuldu."
                            ))
                            .font(.caption).foregroundStyle(PulseColor.secondaryText)
                        }
                    }
                    HStack(spacing: 10) {
                        reportStat(L10n.text("AVG. RETURN", "ORT. GETİRİ"), report.averageReturnPercent, neutral: false)
                        reportStat(L10n.text("BEST", "EN İYİ"), report.bestReturnPercent, neutral: false)
                        reportStat(L10n.text("WORST", "EN KÖTÜ"), report.worstReturnPercent, neutral: false)
                    }
                    Label(
                        L10n.text(
                            "Measured from breakout-detected closes across defined candle horizons. Past results do not guarantee future performance.",
                            "Kırılımın algılandığı kapanıştan itibaren tanımlı mum ufuklarında ölçülür. Geçmiş sonuçlar geleceği garanti etmez."
                        ),
                        systemImage: "info.circle"
                    )
                    .font(.caption).foregroundStyle(PulseColor.secondaryText).lineSpacing(3)
                } else {
                    SurfaceCard {
                        ContentUnavailableView(
                            L10n.text("Not enough measurements yet", "Henüz yeterli ölçüm yok"),
                            systemImage: "chart.bar.xaxis",
                            description: Text(L10n.text("The report card fills in as outcomes are evaluated this week.", "Bu hafta sonuçlar değerlendirildikçe karne dolacak."))
                        )
                    }
                }
            }
            .padding(18)
        }
        .background(PulseColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Weekly Report Card", "Haftalık Karne"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: preferredTimeframe) { await load() }
    }

    private func reportStat(_ title: String, _ value: Double, neutral: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(2)))
                .font(.headline.bold()).monospacedDigit()
                .foregroundStyle(neutral ? PulseColor.accent : (value >= 0 ? PulseColor.positive : PulseColor.negative))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(PulseColor.secondaryText).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await AnalysisInsightsService().weeklyReport(timeframe: preferredTimeframe)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}
