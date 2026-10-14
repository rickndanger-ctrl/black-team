import Foundation

// The "Set up your agents" plan (Integrations/SetupPlan.swift) for this Backend: what is on this computer, the offer, and the run.
// The window reaches these through Desktop/DesktopSetup.swift; the command line calls them directly (`black-team setup`).

extension Backend {
    func setupContext() -> SetupContext {
        let settings = (try? integrations.read()) ?? IntegrationSettings()
        let model = (try? configStore.read())?.model.name ?? ""
        let found: DiscoveryResult
        var installs: [HermesInstall] = []
        #if os(Linux)
        let looked = discoverLinux(home: home, env: setupEnvironment, saved: settings.hermes,
                                   extraSources: [HermesInstaller.sourceFolder(dataFolder: dataFolder)])
        found = looked.result
        installs = integrations.hermesSupported ? looked.hermes : []
        #else
        found = discoverInstalled(home: home, env: setupEnvironment)
        #endif
        // The background service step is the desktop service's: the window offers the switch, and the terminal's plan lists it too.
        let manager = ServiceManager(home: home, dataFolder: dataFolder)
        #if os(Linux)
        let serviceSupported = Tools.findProgram("systemctl") != nil
        #else
        let serviceSupported = true
        #endif
        return SetupContext(found: found, hermesInstalls: installs, settings: settings, hermesSupported: integrations.hermesSupported,
                            tooling: findHermesTooling(home: home, env: setupEnvironment), modelName: model, dataFolder: dataFolder,
                            serviceSupported: serviceSupported, serviceInstalled: manager.isInstalled())
    }

    /// The steps that would set up every agent on this computer, each marked done, will do, or needs something.
    /// Only looks at files; nothing is run, downloaded or changed.
    public func setupPlan() -> SetupPlan { buildSetupPlan(setupContext()) }

    /// The plan with whether to put it in front of the person unasked. `reason` is "model-ready", "found-something-new" or "asked";
    /// "asked" (the person opened it themselves) always shows. Anything else shows only when a step is waiting that
    /// "Not now" has not already been said to.
    public func offerSetup(reason: String) -> SetupOffer {
        let plan = setupPlan()
        let show = reason == "asked" ? true : SetupOfferStore(dataFolder: dataFolder).shouldOffer(plan)
        return SetupOffer(show: show, reason: reason, plan: plan)
    }

    /// Call this when a model has just become ready for the first time, for example when a download has finished and the model
    /// is saved: it answers whether the setup card should now be offered, and what it lists. It starts nothing and changes
    /// nothing; the window shows the card and asks the person to approve. A "Not now" said earlier is respected.
    /// In the window, the same hook is `offerSetupAfterModelReady` in `src/setupOffer.mjs`.
    public func offerSetupAfterModelReady() -> SetupOffer { offerSetup(reason: "model-ready") }

    /// Remembers "Not now" for what the plan offers today, so the card does not come back for it. A newly found agent is offered again.
    public func dismissSetupOffer() throws {
        try SetupOfferStore(dataFolder: dataFolder).dismiss(setupPlan().pending.map(\.id))
    }

    /// Runs the approved steps, in plan order. Setup actions never overlap. A failed step does not stop the rest; each step's
    /// result is returned. Stopping (`cancelSetUp`) stops the running step.
    @discardableResult
    public func applySetup(approved ids: [String], progress: (@Sendable (SetupEvent) -> Void)? = nil) async throws -> [SetupStepResult] {
        try await exclusive {
            if isBusy { throw BlackTeamError("Wait for the current task before changing integrations.") }
            let downloader = makeDownloader()
            locked { setupDownloads = [downloader] }
            defer { locked { setupDownloads = [] } }
            let installer = hermesInstallerOverride?(downloader)
                ?? HermesInstaller(dataFolder: dataFolder, downloader: downloader, home: home, environment: setupEnvironment)
            let services = SetupServices(store: integrations, context: { [unowned self] in self.setupContext() }, installer: installer,
                                         service: serviceInstallerOverride ?? ServiceManager(home: home, dataFolder: dataFolder))
            let results = await BlackTeamKit.applySetup(approved: ids, services: services, progress: progress)
            changed()
            return results
        }
    }
}
