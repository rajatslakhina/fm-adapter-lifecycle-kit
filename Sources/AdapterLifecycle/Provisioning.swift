/// The seam between this package and everything that actually touches bytes.
///
/// This one protocol is why `AdapterLifecycle` has no dependency on Foundation, on
/// `URLSession`, or on the Foundation Models framework. Fetching an adapter package,
/// verifying its signature, and handing it to `SystemLanguageModel(adapter:)` are all
/// jobs for the app; deciding *whether* to do them is the job of this package. Keeping
/// the two apart is what makes the whole policy layer runnable — and therefore
/// testable — on a Linux CI box that has never heard of Apple Intelligence.
public protocol AdapterProvisioning: Sendable {
    /// Materialises the artifact described by `descriptor` on the device.
    ///
    /// Implementations must be cancellation-aware. The coordinator will abandon a fetch
    /// whose result it can no longer use — most often because the OS replaced the base
    /// model while the download was in flight.
    func fetch(_ descriptor: AdapterDescriptor) async throws
}

/// A provisioner for adapters that are already on the device.
///
/// Used for `.bundled` artifacts and as the default in tests and demos. It is not a
/// stub standing in for missing work: for a bundled adapter there is genuinely nothing
/// to fetch, and modelling that as "a fetch that succeeds immediately" keeps the
/// coordinator from having to special-case distribution at the call site.
public struct AlreadyResidentProvisioner: AdapterProvisioning {
    public init() {}
    public func fetch(_ descriptor: AdapterDescriptor) async throws {
        // Nothing to do. Deliberately does not check `descriptor.distribution`: a caller
        // that wires this up for remote adapters in production has made a configuration
        // mistake that a fake success here would hide, so `AdapterLifecycleCoordinator`
        // reports the distribution in its snapshot instead of failing silently.
        _ = descriptor
    }
}

/// Errors a provisioner may surface that the coordinator understands specifically.
public enum ProvisioningError: Error, Sendable, Equatable {
    case unreachable(locator: String)
    case integrityCheckFailed(AdapterIdentifier)
    case cancelled
}
