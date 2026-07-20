import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class SubscriptionStore {
    static let monthlyProductID = "com.trendyssey.app.pro.monthly"

    enum State: Equatable {
        case loading
        case available
        case subscribed
        case unavailable
    }

    private(set) var state: State = .loading
    private(set) var monthlyProduct: Product?
    var message: String?
    private var updatesTask: Task<Void, Never>?

    var isSubscribed: Bool { state == .subscribed }
    var priceText: String { monthlyProduct?.displayPrice ?? "$9.99" }

    init() {
        updatesTask = Task { await observeTransactions() }
        Task { await refresh() }
    }

    func refresh() async {
        var productLoadFailed = false
        do {
            monthlyProduct = try await Product.products(for: [Self.monthlyProductID]).first
        } catch {
            monthlyProduct = nil
            productLoadFailed = true
        }
        await refreshEntitlement()
        if productLoadFailed && !isSubscribed {
            message = L10n.text("The subscription could not be loaded.", "Abonelik yüklenemedi.")
        }
    }

    func purchase() async {
        guard let monthlyProduct else {
            message = L10n.text("The subscription is not available yet.", "Abonelik henüz kullanıma hazır değil.")
            return
        }
        do {
            let account = await UserSyncService.shared.accountSnapshot()
            let options: Set<Product.PurchaseOption> = account.id.map { [.appAccountToken($0)] } ?? []
            let result = try await monthlyProduct.purchase(options: options)
            if case .success(let verification) = result {
                let transaction = try verified(verification)
                try? await UserSyncService.shared.syncSubscription(signedTransaction: verification.jwsRepresentation)
                await transaction.finish()
                await refreshEntitlement()
            }
        } catch {
            message = L10n.text("The purchase could not be completed.", "Satın alma tamamlanamadı.")
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            message = isSubscribed
                ? L10n.text("Your subscription was restored.", "Aboneliğin geri yüklendi.")
                : L10n.text("No active subscription was found.", "Aktif abonelik bulunamadı.")
        } catch {
            message = L10n.text("Purchases could not be restored.", "Satın almalar geri yüklenemedi.")
        }
    }

    private func refreshEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result), transaction.productID == Self.monthlyProductID else { continue }
            if transaction.revocationDate == nil && transaction.expirationDate.map({ $0 > .now }) != false {
                active = true
                try? await UserSyncService.shared.syncSubscription(signedTransaction: result.jwsRepresentation)
            }
        }
        if !active {
            active = await UserSyncService.shared.hasActiveProEntitlement()
        }
        state = active ? .subscribed : (monthlyProduct == nil ? .unavailable : .available)
    }

    private func observeTransactions() async {
        for await _ in Transaction.updates { await refreshEntitlement() }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified: throw StoreError.failedVerification
        }
    }

    private enum StoreError: Error { case failedVerification }
}
