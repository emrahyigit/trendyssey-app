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
                "How Trendyssey turns Binance Spot candles into current market states and historical scenarios — and what those observations do not claim to be.",
                "Trendyssey'in Binance Spot mumlarını güncel piyasa durumlarına ve geçmiş senaryolara nasıl dönüştürdüğü — ve bu gözlemlerin ne iddia etmediği."
            ),
            sections: [
                .init(
                    heading: L10n.text("Where the data comes from", "Veri nereden geliyor"),
                    paragraphs: [
                        L10n.text(
                            "Trendyssey analyses publicly available Binance Spot market data. Server models use completed candles only; the app reads the stored signal and market state instead of producing a second competing result.",
                            "Trendyssey, Binance Spot üzerindeki herkese açık piyasa verilerini analiz eder. Sunucu modelleri yalnızca tamamlanmış mumları kullanır; uygulama ikinci ve çelişebilecek bir sonuç üretmek yerine kaydedilmiş sinyal ile piyasa durumunu okur."
                        )
                    ]
                ),
                .init(
                    heading: L10n.text("Current market state", "Güncel piyasa durumu"),
                    paragraphs: [
                        L10n.text(
                            "For every scanned coin and timeframe, Trendyssey reports the current balance between selling pressure and price response. The named state is the primary answer; its component measurements remain visible so the result can be inspected instead of accepted as a black box.",
                            "Trendyssey, taranan her coin ve zaman dilimi için satış baskısı ile fiyat tepkisi arasındaki güncel dengeyi raporlar. Ana cevap isimlendirilmiş durumdur; sonuç kara kutu olarak kabul edilmesin diye bileşen ölçümleri ayrıca gösterilir."
                        )
                    ],
                    bullets: [
                        L10n.text(
                            "Selling pressure and downside response — whether elevated selling is still pushing price lower.",
                            "Satış baskısı ve aşağı yönlü tepki — yüksek satışın fiyatı hâlâ aşağı itip itmediği."
                        ),
                        L10n.text(
                            "Seller efficiency — how much downside movement sellers produce, and whether that impact is strengthening or fading.",
                            "Satıcı etkinliği — satıcıların ne kadar aşağı yönlü hareket ürettiği ve bu etkinin güçlenip zayıflamadığı."
                        ),
                        L10n.text(
                            "Buy-side absorption and price resilience — whether supply is being absorbed without equivalent price damage.",
                            "Alıcı absorpsiyonu ve fiyat dayanıklılığı — arzın aynı ölçüde fiyat hasarı oluşturmadan karşılanıp karşılanmadığı."
                        ),
                        L10n.text(
                            "Bounce readiness and confirmation — whether an early response has begun and whether closed candles have confirmed it.",
                            "Tepki hazırlığı ve teyit — erken tepkinin başlayıp başlamadığı ve kapanmış mumların bunu doğrulayıp doğrulamadığı."
                        ),
                        L10n.text(
                            "Bullish momentum — whether price is already advancing with sustained multi-candle strength, expanding activity and direct closed-candle confirmation.",
                            "Yükseliş momentumu — fiyatın çoklu mum gücü, genişleyen aktivite ve doğrudan kapanış teyidiyle hâlihazırda yükselip yükselmediği."
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
                    heading: L10n.text("What the backtest showed", "Backtest ne gösterdi"),
                    paragraphs: [
                        L10n.text(
                            "Historical simulations help compare signal and exit rules, but the current-state model is evaluated separately against later price behaviour. Two honest caveats: short timeframes are especially sensitive to fees and noise, and past behaviour, however carefully measured, does not bind the future.",
                            "Tarihsel simülasyonlar sinyal ve çıkış kurallarını karşılaştırmaya yardımcı olur; güncel durum modeli ise sonraki fiyat davranışına karşı ayrıca değerlendirilir. İki dürüst uyarı: kısa zaman dilimleri komisyon ve gürültüye özellikle duyarlıdır; geçmiş davranış ne kadar özenle ölçülürse ölçülsün geleceği bağlamaz."
                        ),
                        L10n.text(
                            "A market state is a deterministic description of current conditions. It is not a calibrated success probability, a forecast or a guarantee — and an early reversal state does not mean a coin will rise.",
                            "Piyasa durumu, mevcut koşulların deterministik bir tarifidir. Kalibre edilmiş bir başarı olasılığı, tahmin veya garanti değildir — erken dönüş durumu coinin yükseleceği anlamına gelmez."
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
