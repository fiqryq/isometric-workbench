import Foundation
import Observation
import StoreKit

/// Workbench Pro: one non-consumable unlock, verified with StoreKit 2.
@MainActor
@Observable
final class Store {
    static let shared = Store()
    static let proID = "fiqryq.isometricworkbench.pro"

    private(set) var product: Product?
    private(set) var isPro = false
    private(set) var isPurchasing = false
    private(set) var loadFailed = false
    var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WORKBENCH_PRO"] == "1" { isPro = true }
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates { await self?.handle(result) }
        }
        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProduct()
        }
    }

    var priceText: String { product?.displayPrice ?? "—" }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.proID]).first
            loadFailed = product == nil
        } catch {
            loadFailed = true
        }
    }

    func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else {
            message = "The App Store isn't reachable right now. Try again in a moment."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result): await handle(result)
            case .pending: message = "Your purchase is waiting for approval."
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            message = error.localizedDescription
        }
        await refreshEntitlements()
        if !isPro, message == nil { message = "No Workbench Pro purchase was found for this Apple Account." }
    }

    func refreshEntitlements() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.proID, t.revocationDate == nil { pro = true }
        }
        // currentEntitlements can come back empty for an owned non-consumable.
        if !pro, case .verified(let t)? = await Transaction.latest(for: Self.proID), t.revocationDate == nil {
            pro = true
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["WORKBENCH_PRO"] == "1" { pro = true }
        #endif
        isPro = pro
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let t) = result else { return }
        if t.productID == Self.proID { isPro = t.revocationDate == nil }
        await t.finish()
    }
}

/// What the free version can export.
enum Limits {
    /// Longest side of a free PNG, in pixels.
    static let freeImageSide = 1200.0
    static let freeVideoSeconds = 5.0
    static let freeVideoHeight = 720
}
