import Foundation

/// Maps the model id on the wire to the display name the usage endpoint uses for that
/// model's own weekly window.
///
/// The usage API reports scoped windows as `scope.model.display_name` ("Fable"), while
/// requests carry ids like `claude-fable-5`. Matching on the display name appearing in
/// the id keeps working when a new generation lands (`claude-fable-6`) without a table
/// to update, and an unrecognised model simply has no scoped window — which is the
/// correct answer for a plan that does not cap it.
public enum ModelRouting {
    /// The model named in a `/v1/messages` request body, if there is one.
    public static func model(inRequestBody body: Data) -> String? {
        guard !body.isEmpty, body.count < 64 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = object["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// Whether a scoped window governs this model id.
    public static func window(_ window: UsageWindow, governs modelID: String) -> Bool {
        guard window.kind == .weeklyScoped, let name = window.modelName, !name.isEmpty
        else { return false }
        return modelID.lowercased().contains(name.lowercased())
    }

    /// Windows that actually gate a request for `modelID`: the 5-hour and weekly-all
    /// windows always, plus that model's own weekly window when the plan has one. A
    /// scoped window for a *different* model is deliberately excluded — a spent Fable
    /// week does not stop an Opus request.
    public static func bindingWindows(for modelID: String?,
                                      in usage: UsageSnapshot?) -> [UsageWindow] {
        guard let usage else { return [] }
        return usage.windows.filter { window in
            switch window.kind {
            case .session, .weeklyAll:
                return true
            case .weeklyScoped:
                guard let modelID else { return false }
                return self.window(window, governs: modelID)
            case .other:
                return false
            }
        }
    }

    /// Headroom on the tightest window gating this model, or nil when nothing is known.
    public static func headroom(for modelID: String?, in usage: UsageSnapshot?) -> Double? {
        let windows = bindingWindows(for: modelID, in: usage)
        guard !windows.isEmpty else { return nil }
        return windows.map(\.headroom).min()
    }

    /// Whether this account can serve a request for `modelID` right now.
    ///
    /// An account with no usage data yet is allowed through: the alternative is refusing
    /// to use an account we simply have not measured, and the response itself will
    /// correct us.
    public static func canServe(_ modelID: String?, usage: UsageSnapshot?) -> Bool {
        guard let headroom = headroom(for: modelID, in: usage) else { return true }
        return headroom > 0
    }

    /// When this account could next serve `modelID`: now if it already can, otherwise
    /// the reset of whichever gating window is exhausted and resets last.
    public static func availableAt(_ modelID: String?, usage: UsageSnapshot?,
                                   now: Date = Date()) -> Date? {
        let windows = bindingWindows(for: modelID, in: usage)
        guard !windows.isEmpty else { return now }
        let blocked = windows.filter { $0.headroom <= 0 }
        guard !blocked.isEmpty else { return now }
        // Every blocking window has to clear, so the account is free at the last of them.
        // A blocked window with no known reset makes the answer unknowable.
        let resets = blocked.map(\.resetsAt)
        guard !resets.contains(where: { $0 == nil }) else { return nil }
        return resets.compactMap { $0 }.max()
    }

    /// The soonest any of these accounts could serve `modelID`, and which one.
    public static func soonestAvailable(_ modelID: String?, accounts: [Account],
                                        usage: [String: UsageSnapshot], now: Date = Date())
        -> (accountID: String, at: Date)? {
        accounts
            .filter { $0.health != .needsRelogin }
            .compactMap { account -> (String, Date)? in
                guard let at = availableAt(modelID, usage: usage[account.id], now: now)
                else { return nil }
                return (account.id, at)
            }
            .min { $0.1 < $1.1 }
            .map { (accountID: $0.0, at: $0.1) }
    }
}
