import Foundation

/// The About documents, kept as structure rather than one long string so they can
/// be laid out with real hierarchy instead of rendered as a wall of text.
struct LegalDocument {
    struct Section: Identifiable {
        let heading: String
        var paragraphs: [String] = []
        var bullets: [String] = []

        var id: String { heading }
    }

    let summary: String
    let sections: [Section]
    /// Shown in smaller type at the end, e.g. the "not investment advice" line.
    var footnote: String?
}

enum LegalCopy {
    static var methodology: LegalDocument {
        LegalDocument(
            summary: L10n.text(
                "How Trendyssey turns Binance Spot candles into a breakout journey and a single confidence score — and what that score does not claim to be.",
                "Trendyssey'in Binance Spot mumlarını nasıl bir kırılım sürecine ve tek bir güven puanına dönüştürdüğü — ve bu puanın ne iddia etmediği."
            ),
            sections: [
                .init(
                    heading: L10n.text("Where the data comes from", "Veri nereden geliyor"),
                    paragraphs: [
                        L10n.text(
                            "Trendyssey analyses publicly available Binance Spot market data. Closed candles are collected once on the server and every screen — charts, scenarios and alerts — reads that same shared history; only the still-forming candle is drawn live. The same models run on both sides, so a chart you open agrees with the alert that brought you there.",
                            "Trendyssey, Binance Spot üzerindeki herkese açık piyasa verilerini analiz eder. Kapanmış mumlar sunucuda bir kez toplanır ve grafikler, senaryolar ve bildirimler dahil her ekran aynı ortak geçmişi okur; yalnızca oluşmakta olan mum canlı çizilir. Aynı modeller her iki tarafta da çalışır; açtığınız grafik, sizi oraya getiren bildirimle tutarlıdır."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("The three models", "Üç model"),
                    paragraphs: [
                        L10n.text(
                            "You pick one model in Profile. It drives every journey, score and chart overlay in the app.",
                            "Profil'den tek bir model seçersiniz. Uygulamadaki her süreç, puan ve grafik katmanı ona göre çalışır."
                        )
                    ],
                    bullets: [
                        L10n.text(
                            "EMA Cross 7/25/99 — built on Binance's default moving averages. EMA 7 crossing above EMA 25 opens a journey; EMA 99 is the long-term trend filter.",
                            "EMA Cross 7/25/99 — Binance'in varsayılan hareketli ortalamaları üzerine kuruludur. EMA 7'nin EMA 25'i yukarı kesmesi bir süreç başlatır; EMA 99 uzun vadeli trend filtresidir."
                        ),
                        L10n.text(
                            "Double Bottom — finds two lows at a similar level and follows the break above the neckline between them. A rising move.",
                            "Çift Dip — benzer seviyedeki iki dibi bulur ve aralarındaki boyun çizgisinin yukarı kırılmasını izler. Yükseliş yönlü bir modeldir."
                        ),
                        L10n.text(
                            "Double Top — the mirror image: two highs at a similar level, then the break below the neckline. A falling move, so its phases read as a breakdown and a fall counts as the model being right.",
                            "Çift Tepe — bunun aynadaki hâli: benzer seviyedeki iki tepe ve ardından boyun çizgisinin aşağı kırılması. Düşüş yönlüdür; aşamaları düşüş olarak okunur ve fiyatın düşmesi modelin doğru bilmesi anlamına gelir."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Closed candles only", "Yalnızca kapanmış mumlar"),
                    paragraphs: [
                        L10n.text(
                            "Every evaluation uses closed candles for the selected timeframe. An open candle appears on the chart but is never treated as confirmed evidence. This materially reduces repainting — a phase that flips back and forth inside one bar — but it does not eliminate false signals.",
                            "Tüm değerlendirmeler, seçilen zaman diliminde yalnızca kapanmış mumlarla yapılır. Açık mum grafikte görünür ancak hiçbir zaman doğrulanmış kanıt sayılmaz. Bu ilke, bir aşamanın tek mum içinde gidip gelmesini (yeniden çizim) büyük ölçüde önler; ancak yanlış sinyalleri ortadan kaldırmaz."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("The breakout journey", "Kırılım süreci"),
                    paragraphs: [
                        L10n.text(
                            "Whichever model you choose, its findings are reported through the same five phases, so the app reads the same way after you switch.",
                            "Hangi modeli seçerseniz seçin, bulgular aynı beş aşamayla raporlanır; model değiştirdiğinizde uygulamanın dili değişmez."
                        )
                    ],
                    bullets: [
                        L10n.text("Being watched — conditions are being monitored.", "İzleniyor — koşullar takip ediliyor."),
                        L10n.text("Waiting for breakout — price is close to the tracked level.", "Kırılım bekleniyor — fiyat izlenen seviyeye yaklaştı."),
                        L10n.text("Breakout started — a closed candle cleared the level.", "Kırılım başladı — kapanmış bir mum seviyeyi geçti."),
                        L10n.text("Level being tested — price came back to the level after clearing it.", "Seviye test ediliyor — fiyat geçtiği seviyeye geri döndü."),
                        L10n.text("Breakout strengthening — the level held, or three closes stayed beyond it.", "Kırılım güçleniyor — seviye korundu veya üç kapanış onun ötesinde kaldı."),
                        L10n.text("Signal invalidated — price closed back through the level and the journey ended.", "Sinyal geçersiz oldu — fiyat seviyeyi geri kırdı ve süreç sonlandı.")
                    ]
                ),
                .init(
                    heading: L10n.text("The confidence score", "Güven puanı"),
                    paragraphs: [
                        L10n.text(
                            "Each coin gets a single 0–100 score. Every ingredient is shown with its own points and a plain-language reason, so the number is fully auditable rather than a black box.",
                            "Her coin 0–100 arası tek bir puan alır. Her bileşen kendi puanı ve sade bir gerekçeyle gösterilir; böylece sayı bir kara kutu değil, tamamen denetlenebilir bir sonuçtur."
                        ),
                        L10n.text(
                            "EMA Cross weighs trend alignment (20), crossover freshness (15), retest confirmation (15), volume support (20), long-term trend (10), momentum (10) and higher-timeframe agreement (10). The chart patterns weigh pattern symmetry (20), pattern depth (15), break freshness (15), volume support (20), retest confirmation (15), the strength of the trend being reversed (10) and the same higher-timeframe agreement (10).",
                            "EMA Cross şunları tartar: trend dizilimi (20), kesişim tazeliği (15), retest onayı (15), hacim desteği (20), uzun vadeli trend (10), momentum (10) ve üst dilim uyumu (10). Desen modelleri ise formasyon simetrisi (20), formasyon derinliği (15), kırılım tazeliği (15), hacim desteği (20), retest onayı (15), dönülen trendin gücü (10) ve aynı üst dilim uyumunu (10) tartar."
                        ),
                        L10n.text(
                            "The score is a deterministic summary of current market structure. It is not a probability, a forecast or a guarantee.",
                            "Puan, mevcut piyasa yapısının deterministik bir özetidir. Olasılık, tahmin veya garanti değildir."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Measuring what happened", "Ne olduğunun ölçümü"),
                    paragraphs: [
                        L10n.text(
                            "After a breakout is detected, Trendyssey records the return, the maximum favourable excursion and the maximum adverse excursion over defined candle horizons. Model comparison replays all three models over the same coins, the same candles and the same horizon, and scores a call as a win when price closed the way the model expected.",
                            "Kırılım algılandıktan sonra Trendyssey; tanımlı mum ufuklarında gerçekleşen getiriyi, maksimum olumlu hareketi (MFE) ve maksimum olumsuz hareketi (MAE) kaydeder. Model karşılaştırma ekranı üç modeli de aynı coinler, aynı mumlar ve aynı ufuk üzerinde yeniden oynatır; fiyat modelin beklediği yönde kapandıysa o çağrıyı kazanç sayar."
                        ),
                        L10n.text(
                            "Read those win rates against 50%, which is what a coin flip would produce. A model only has an edge above that line, and a rate resting on a handful of measurements is not yet evidence of anything.",
                            "Bu kazanma oranlarını %50 ile karşılaştırarak okuyun; yazı tura bu oranı üretir. Bir modelin üstünlüğünden ancak bu çizginin üzerinde söz edilebilir ve avuç içi kadar ölçüme dayanan bir oran henüz hiçbir şeyin kanıtı değildir."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Limits", "Sınırlar"),
                    paragraphs: [
                        L10n.text(
                            "Exchange latency, missing candles, thin liquidity, sudden news, slippage and methodology updates all affect results. Scenario screens exclude fees, slippage and tax, so a real position would have earned less than a simulated one.",
                            "Borsa gecikmesi, eksik mumlar, düşük likidite, ani haberler, fiyat kayması ve metodoloji güncellemeleri sonuçları etkiler. Senaryo ekranları komisyon, fiyat kayması ve vergiyi hariç tutar; gerçek bir pozisyon simüle edilenden daha az kazandırırdı."
                        )
                    ]
                )
            ],
            footnote: L10n.text(
                "Trendyssey is a research tool. It should be one input among several, never the sole basis for a trading decision.",
                "Trendyssey bir araştırma aracıdır. Birden fazla girdiden yalnızca biri olmalı, hiçbir zaman tek işlem dayanağı olmamalıdır."
            )
        )
    }

    static var privacy: LegalDocument {
        LegalDocument(
            summary: L10n.text(
                "What Trendyssey stores, why it stores it, and how you remove it.",
                "Trendyssey'in neyi, neden sakladığı ve bunu nasıl kaldırabileceğiniz."
            ),
            sections: [
                .init(
                    heading: L10n.text("Data we process", "İşlediğimiz veriler"),
                    paragraphs: [
                        L10n.text(
                            "Trendyssey analyses publicly available Binance market data. The app never requests your exchange credentials or API keys and never takes custody of your assets. Please do not share exchange secrets in chat or profile fields.",
                            "Trendyssey, herkese açık Binance piyasa verilerini analiz eder. Uygulama hiçbir zaman borsa şifrenizi veya API anahtarlarınızı istemez ve varlıklarınızı saklamaz. Borsa gizli bilgilerinizi sohbet veya profil alanlarında paylaşmayınız."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Account and synchronization", "Hesap ve senkronizasyon"),
                    paragraphs: [
                        L10n.text(
                            "On first launch the app creates an anonymous account so your favorites and preferences can be synchronized. If you choose Sign in with Apple, Apple provides your name and email address according to your sharing preference. Trendyssey stores your display name, avatar, favorites, analysis preferences and alert settings solely to provide these features across your devices.",
                            "İlk açılışta, favorilerinizin ve tercihlerinizin senkronize edilebilmesi için anonim bir hesap oluşturulur. Apple ile Giriş'i seçerseniz Apple, paylaşım tercihinize göre adınızı ve e-posta adresinizi iletir. Trendyssey; görünen adınızı, avatarınızı, favorilerinizi, analiz tercihlerinizi ve uyarı ayarlarınızı yalnızca bu özellikleri cihazlarınız arasında sunmak için saklar."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Notifications and subscriptions", "Bildirimler ve abonelikler"),
                    paragraphs: [
                        L10n.text(
                            "To deliver alerts, Trendyssey stores an APNs device token together with delivery status. Subscription entitlements are verified through Apple transaction identifiers and expiry dates. Payment details are processed exclusively by Apple; Trendyssey never sees or stores them.",
                            "Uyarı iletimi için APNs cihaz token'ı ve teslim durumu saklanır. Abonelik hakları, Apple işlem kimlikleri ve geçerlilik tarihleri üzerinden doğrulanır. Ödeme bilgileri yalnızca Apple tarafından işlenir; Trendyssey bu bilgileri hiçbir şekilde görmez veya saklamaz."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Community content", "Topluluk içeriği"),
                    paragraphs: [
                        L10n.text(
                            "Chat messages and breakout predictions are visible to signed-in users together with your display name, avatar and posting time. Prediction accuracy statistics derived from your resolved predictions are shown publicly as a badge. Do not post personal, financial or confidential information. Content may be retained for continuity, abuse prevention and moderation.",
                            "Sohbet mesajları ve kırılım tahminleri; görünen adınız, avatarınız ve gönderim zamanıyla birlikte giriş yapmış kullanıcılara görünür. Sonuçlanan tahminlerinizden türetilen isabet istatistikleri, herkese açık bir rozet olarak gösterilir. Kişisel, finansal veya gizli bilgi paylaşmayınız. İçerikler süreklilik, kötüye kullanımın önlenmesi ve moderasyon amacıyla saklanabilir."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Security", "Güvenlik"),
                    paragraphs: [
                        L10n.text(
                            "All requests are authenticated, and database access is restricted with row-level security. No server secret or service key is embedded in the app. Session tokens are stored in the device Keychain.",
                            "Tüm istekler kimlik doğrulamalıdır ve veritabanı erişimi satır düzeyi güvenlikle sınırlandırılmıştır. Uygulamaya hiçbir sunucu gizli anahtarı gömülü değildir. Oturum bilgileri cihazın Anahtar Zinciri'nde (Keychain) saklanır."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Your controls", "Kontrolleriniz"),
                    paragraphs: [
                        L10n.text(
                            "You can edit your public name and avatar, sign out at any time, or permanently delete your account from Profile. Account deletion removes your profile, favorites, preferences, predictions and chat identity from our systems.",
                            "Profil bölümünden herkese açık adınızı ve avatarınızı düzenleyebilir, dilediğiniz an oturumu kapatabilir veya hesabınızı kalıcı olarak silebilirsiniz. Hesap silme işlemi; profilinizi, favorilerinizi, tercihlerinizi, tahminlerinizi ve sohbet kimliğinizi sistemlerimizden kaldırır."
                        )
                    ]
                )
            ]
        )
    }

    static var risk: LegalDocument {
        LegalDocument(
            summary: L10n.text(
                "Trendyssey measures market structure. It does not advise, predict or guarantee.",
                "Trendyssey piyasa yapısını ölçer. Tavsiye vermez, tahmin etmez, garanti sunmaz."
            ),
            sections: [
                .init(
                    heading: L10n.text("Not investment advice", "Yatırım tavsiyesi değildir"),
                    paragraphs: [
                        L10n.text(
                            "Nothing in Trendyssey is investment advice, a recommendation or an offer. Signals, scores and scenarios are statistical descriptions of past and present market structure. Every trading decision, and its outcome, is yours alone.",
                            "Trendyssey'deki hiçbir içerik yatırım tavsiyesi, öneri veya teklif değildir. Sinyaller, puanlar ve senaryolar; geçmiş ve mevcut piyasa yapısının istatistiksel betimlemeleridir. Her işlem kararı ve sonucu yalnızca size aittir."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Crypto assets carry high risk", "Kripto varlıklar yüksek risklidir"),
                    paragraphs: [
                        L10n.text(
                            "Crypto markets are volatile and trade without interruption. Prices can move sharply against a position in minutes, and you can lose part or all of your capital. Never commit money you cannot afford to lose.",
                            "Kripto piyasaları oynaktır ve kesintisiz işlem görür. Fiyatlar dakikalar içinde pozisyonun aleyhine sert biçimde hareket edebilir; sermayenizin bir kısmını veya tamamını kaybedebilirsiniz. Kaybetmeyi göze alamayacağınız parayı kullanmayınız."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Past results are not future results", "Geçmiş sonuçlar geleceği göstermez"),
                    paragraphs: [
                        L10n.text(
                            "Hold rates, win rates and scenario profits describe what already happened on a limited sample. Market conditions change, and a model that measured well last week can fail this week. Scenario screens exclude fees, slippage and tax, so a real position would have earned less.",
                            "Tutma oranları, kazanma oranları ve senaryo kârları; sınırlı bir örneklemde geçmişte olanı betimler. Piyasa koşulları değişir ve geçen hafta iyi ölçülen bir model bu hafta başarısız olabilir. Senaryo ekranları komisyon, fiyat kayması ve vergiyi hariç tutar; gerçek bir pozisyon daha az kazandırırdı."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Technical limits", "Teknik sınırlar"),
                    paragraphs: [
                        L10n.text(
                            "Exchange latency, missing or delayed candles, thin liquidity, sudden news and methodology updates all affect what you see. Alerts depend on network and push delivery and may arrive late or not at all.",
                            "Borsa gecikmesi, eksik veya geciken mumlar, düşük likidite, ani haberler ve metodoloji güncellemeleri gördüğünüz sonuçları etkiler. Uyarılar ağ ve push teslimatına bağlıdır; geç gelebilir veya hiç gelmeyebilir."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Your responsibility", "Sorumluluğunuz"),
                    paragraphs: [
                        L10n.text(
                            "You are responsible for complying with the laws and tax rules that apply to you. If you need advice, consult a licensed financial advisor.",
                            "Size uygulanan yasalara ve vergi kurallarına uymaktan siz sorumlusunuz. Tavsiyeye ihtiyaç duyuyorsanız lisanslı bir finansal danışmana başvurunuz."
                        )
                    ]
                )
            ]
        )
    }
}
